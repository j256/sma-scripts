#!/usr/bin/perl
#
# Copyright 2004 by Gray Watson
#
# Permission to use, copy, modify, and distribute this software for
# any purpose and without fee is hereby granted, provided that the
# above copyright notice and this permission notice appear in all
# copies, and that the name of Gray Watson not be used in advertising
# or publicity pertaining to distribution of the document or software
# without specific, written prior permission.
#
# Gray Watson makes no representations about the suitability of the
# software described herein for any purpose.  It is provided "as is"
# without express or implied warranty.
#
# The author may be contacted via http://256.com/gray/
#
# $Id: sma.pl,v 1.7 2008/10/02 19:56:13 gray Exp $
#

###############################################################################
#
# This script collects data from a SMA Sunnyboy Inverter which
# converts DC voltage coming from a PV array into AC voltage to be fed
# onto the grid.
#
# The SMA units have data collection hardware built in and can be
# talked two via RS232, RS485, or Powerline add-on modules.  This
# script was written to talk across a RS232 port although I think that
# the protocols are the same.  I'd be interested in working with
# someone with the 485 or Powerline modules to get the script working
# for those too.
#
###############################################################################
#
# This script sends a number of SMA protocol commands to get data from
# the units.  Here are the commands and responses in order:
#
# in sub get_device_list:
# 1) sends GET_NET_START
# 2) receives maybe multiple GET_NET_START responses
#
# in sub get_device_channels for each device:
# 3) sends CMD_GET_CINFO
# 4) receives response packets for CMD_GET_CINFO
#
# in sub poll_devices:
# in sub do_cmd_syn_online:
# 5) sends CMD_SYN_ONLINE
# in sub poll_devices for each device for each channel:
# in sub do_cmd_get_data:
# 6) sends CMD_GET_DATA
# 7) receives response packet(s) for CMD_GET_DATA
#
###############################################################################
#
# SENDING and RECEIVING SMA COMMANDS:
#
# Commands to the Sunnyboy inverters are sent and received in a
# particular format.  See the build_request subroutine below for the
# code to create the command and the process_response subroutine which
# disgests incoming commands.  Commands have a number of parts as follows:
#
# A "wakeup" head section which includes in order:
#   2 bytes magic number -- decimal 170 (hex \xAA\xAA)
#   1 byte of "telegram start" -- decimal 104 (hex \x68)
#   1 byte of the length of the user-data -- depends on user data length
#   1 byte of the length of the user-data again -- depends on user data len
#   1 byte of "telegram start" again -- decimal 104 (hex \x68)
# A protocol header:
#   2 bytes source-address -- often decimal 0 (hex \x00\x00)
#                             low-order byte first, then high-order
#   2 bytes destination-address -- address of the SMA unit being commanded
#                                  low-order byte first, then high-order
#   1 byte of control information -- either decimal 0 or 128 (hex \x00 or \x80)
#   1 byte of the byte count of the user-data -- depends on user-data size
#   1 byte of command-number -- see list of SMA commands below
# Data:
#   ? bytes of data -- depends on the command and the data
#
###############################################################################

use strict;
use Config;		# for byteorder
use POSIX qw(strftime);
use Socket;
use Fcntl;
use IO::Handle;
use IO::Socket;

###############################################################################

# Database connector.  You will also need to have the package for your
# database (DBD::mysql or DBD::Pg) loaded on the system.
use DBI;

# Database DBI settings.  Please let me know what suitable MySQL ones
# are as an example.
my $DBI_DATA_SOURCE = "dbi:Pg:dbname=sma";

# Username to use to connect to the database.
my $DBI_USERNAME = "sma";

# Authentication/password to use.  My database does not need one.
my $DBI_AUTH = "";

###############################################################################

# number of seconds before timing out the select
my $TIMEOUT_LONG = 5.0;

# Short sleep in seconds until we've read all of the incoming data.
# When to timeout and say we've gotten the entire response.  Too short
# here and we will not wait for enough time for the 1200 baud
# responses from the unit.
my $TIMEOUT_SHORT = 0.5;

# Seconds between polls of the data.  The script is designed to be
# synchronized with other scripts polling other SMA units.  If this is
# too small then the script takes longer to do poll then the interval.
my $POLL_INTERVAL = 60;

# log the transactions for debugging if necessary
my $LOG_DIR;

# 'Vac' - unit V, gain 1
# 'Pac' - unit W, gain 1
# 'Temperature' - grdC, gain 0.100000001490116
# 'E-Total' - unit kWh, gain 1.66666704899399e-05
# 'h-Total' - unit h, gain 0.000277777813607827
# 'Vpv' - V, gain 1

# the list of channels that we are monitoring
my %channel_list = ( "Pac" =>		"Power Fed to Grid",
		     "Ipv" =>		"Current from PV-panels",
		     "Vpv" =>		"Voltage from PV-panels",
		     "E-Total" =>	"Energy Yield",
		     "h-Total" =>	"Total operation hours",
#		     "Mode" =>		"Mode",
		     "Temperature" =>	"Temperature of unit",
		     "Vac" =>		"Grid voltage",
		     "Fac" =>		"Grid frequency",
		     );
my @channel_keys = keys(%channel_list);

###############################################################################
# List of SMA commands from the documentation.
# cmd  ctrl  name               description
###############################################################################
#   1  0x80  CMD_GET_NET        Request for sunny net configuration
my $CMD_GET_NET = 1;
#   2  0x80  CMD_SEARCH_SWR     Search for SWR via its serial number
my $CMD_SEARCH_SWR = 2;
#   3  0x80  CMD_CFG_SWRADR     Configure SWR network address via serial number
my $CMD_CFG_SWRADR = 3;
#   4     ?  CMD_SET_GRPADR     Set the group address (reserved)
#   5     ?  CMD_DEL_GRPADR     Delete the group address (reserved)
#   6  0x80  CMD_GET_NET_START  Start of request sunny net configuration
my $CMD_GET_NET_START = 6;
#   9  0x00  CMD_GET_CINFO      Request of device configuration
my $CMD_GET_CINFO = 9;
#  10  0x80  CMD_SYN_ONLINE     Synchronization of online data
my $CMD_SYN_ONLINE = 10;
#  11  0x00  CMD_GET_DATA       Data request
my $CMD_GET_DATA = 11;
#  12  0x00  CMD_SET_DATA       Sending of data
my $CMD_SET_DATA = 12;
#  40  0x80  CMD_PDELIMIT       Limitation of Device Power
my $CMD_SET_DATA = 40;

###############################################################################

#
# Turn a buffer into a hex byte string.  Probably a 1 line pack
# statement would do the same thing.
#
sub hex_string
{
  my ($buf) = @_;
  my $resp = "";
  foreach my $char (split(//, $buf)) {
    $resp .= sprintf " %02X", ord($char);
  }
  return $resp;
}

###############################################################################

#
# Dump the response fields to stdout
#
sub print_response
{
  my ($response) = @_;
  
  foreach my $field (keys (%$response)) {
    my $val = $response->{$field};
    if (ref($val) eq "HASH") {
      print "  $field:\n";
      foreach my $subfield (keys (%$val)) {
	print "    $subfield: $val->{$subfield}\n";
      }
    }
    else {
      print "  $field: $val\n";
    }
  }
}

###############################################################################

#
# Process a floating point value
#
sub process_float
{
  my ($float) = @_;
  
  # from http://developer.intel.com/technology/itj/q41999/articles/art_6.htm
  # and http://babbage.cs.qc.edu/courses/cs341/IEEE-754references.html
  # and http://babbage.cs.qc.edu/courses/cs341/IEEE-754hex32.html
  # IEEE-754 float representations are 1 sign, 8 exponent, and 23 data bits
  # number is (+/-1 + data bits) * 2 ^ (exponent - 127)
  
  # unpack the float after possibly reversing the bytes
  $float = reverse($float) if $Config{byteorder} eq "4321";
  return unpack "f", $float;
}

###############################################################################

#
# Process a response from command CMD_GET_NET (1)
#
sub process_resp_get_net
{
  my ($response, $verbose_b, $very_verbose_b) = @_;
  my $user_data = delete $response->{user_data};
  
  # 4 bytes of serial
  # 8 bytes of device type
  if ($user_data !~ m/^(.)(.)(.)(.)(.{8})$/s) {
    print STDERR 'not valid response to command 1\n';
    return 0;
  }
  $response->{serial} =
    ((ord($4) * 256 + ord($3)) * 256 + ord($2)) * 256 + ord($1);
  $response->{type} = $5;
  
  return 1;
}

###############################################################################

#
# Process a response from command CMD_GET_CINFO
#
sub process_resp_get_cinfo
{
  my ($response, $verbose_b, $very_verbose_b) = @_;
  my $user_data = delete $response->{user_data};
  
  while ($user_data) {
    # 1  index byte
    # 1  channel type1 bytes
    # 1  channel type2 bytes
    # 2  data format bytes
    # 2  access level
    # 16 channel name bytes
    if ($user_data !~ m/^(.)(.)(.)(.)(.)(.)(.)(.{16})(.+)$/s) {
      $response->{error} = 'not valid response to command 9';
      print STDERR "$response->{error}\n" if $verbose_b;
      return 0;
    }
    
    my %channel;
    $channel{index} = ord($1);
    # 1=analog, 2=digital, 4=counter, 8=status
    $channel{type_1} = ord($2);
    # 1=input, 2=output, 3=param, 4=spot-values, 8=mean, 16=test
    $channel{type_2} = ord($3);
    $channel{format} = ord($4) + ord($5) * 256;
    $channel{access_level} = ord($6) + ord($7) * 256;
    $channel{name} = $8;
    
    # get the rest of it
    $user_data = $9;
    
    # now trim the channel name which may have a trailing \000
    $channel{name} =~ s/\s+\000?$//;
    
    if ($channel{type_1} == 1) {
      # analog type
      if ($user_data !~ m/^(.{8})(.{4})(.{4})(.*)$/s) {
	$response->{error} = 'invalid analog data for command 9';
	print STDERR "$response->{error}\n" if $verbose_b;
	return 0;
      }
      $channel{unit} = $1;
      $channel{gain} = process_float($2);
      $channel{offset} = process_float($3);
      # get the rest of it
      $user_data = $4;
      # must be down here otherwise it changes the $2, $3
      # trim the end of the unit name 
      $channel{unit} =~ s/\s+\000?$//;
    }
    elsif ($channel{type_1} == 2) {
      # digital type
      if ($user_data !~ m/^(.{16})(.{16})(.*)$/s) {
	$response->{error} = 'invalid digital data for command 9';
	print STDERR "$response->{error}\n" if $verbose_b;
	return 0;
      }
      $channel{text_low} = $1;
      $channel{text_high} = $2;
      # get the rest of it
      $user_data = $3;
    }
    elsif ($channel{type_1} == 4) {
      # counter type
      if ($user_data !~ m/^(.{8})(.{4})(.*)$/s) {
	$response->{error} = 'invalid count data for command 9';
	print STDERR "$response->{error}\n" if $verbose_b;
	return 0;
      }
      $channel{unit} = $1;
      $channel{gain} = process_float($2);
      # get the rest of it
      $user_data = $3;
      # must be down here otherwise it changes the $2, $3
      # trim the end of the unit name 
      $channel{unit} =~ s/\s+\000?$//;
    }
    elsif ($channel{type_1} == 8) {
      # status type
      if ($user_data !~ m/^(.)(.)(.*)$/s) {
	$response->{error} = 'invalid status data for command 9';
	print STDERR "$response->{error}\n" if $verbose_b;
	return 0;
      }
      $channel{size} = ord($1) + ord($2) * 256;
      $user_data = $3;
      if ($user_data !~ m/^(.{$channel{size}})(.*)$/s) {
	$response->{error} = 'invalid status size  data for command 9';
	print STDERR "$response->{error}\n" if $verbose_b;
	return 0;
      }
      $channel{status} = $1;
      # get the rest of it
      $user_data = $2;
    }
    else {
      $response->{error} = "unknown command 9 channel type $channel{type_1}";
      print STDERR "$response->{error}\n" if $verbose_b;
      return 0;
    }
    $response->{$channel{name}} = \%channel;
    
    if ($verbose_b) {
      print "  channel '$channel{name}' ($channel{index}): " .
	"type $channel{type_1}/$channel{type_2}\n";
      if ($channel{unit} && $channel{gain}) {
	print "    unit '$channel{unit}', gain $channel{gain}";
	print ", offset $channel{offset}" if $channel{offset};
	print "\n";
      }
      print "    size $channel{size}, status $channel{status}\n"
	if ($channel{size} && $channel{status});
      print "    text-low $channel{text_low}, text-high $channel{text_high}\n"
	if ($channel{text_low} && $channel{text_high});
      print "    size $channel{size}, status $channel{status}\n"
	if ($channel{size} && $channel{status});
    }
  }
  return 1;
}

###############################################################################

#
# Process a response from command CMD_GET_DATA
#
sub process_resp_get_data
{
  my ($response, $verbose_b, $very_verbose_b) = @_;
  my $user_data = delete $response->{user_data};
  
  # 1  request type1
  # 1  request type2
  # 1  channel number (index)
  # 2  number of data sets
  # 4  seconds since
  # 4  time basis
  # other stuff
  if ($user_data !~ m/^(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.)(.+)$/s) {
    $response->{error} = 'not valid response to command 11';
    return 0;
  }
  
  $response->{type_1} = ord($1);
  $response->{type_2} = ord($2);
  $response->{channel} = ord($3);
  $response->{data_sets} = ord($4) + ord($5) * 256;
  $response->{since} = ord($6) + ord($7) * 256 + ord($8) * 256 * 256
    + ord($9) * 256 * 256 * 256;
  $response->{time_basis} = ord($10) + ord($11) * 256 + ord($12) * 256 * 256
    + ord($13) * 256 * 256 * 256;
  
  # get the rest of it
  $user_data = $14;
  
  while ($user_data) {
    
    if ($response->{type_1} == 1) {
      # analog type
      if ($user_data !~ m/^(.)(.)(.*)$/s) {
	$response->{error} =
	  "invalid response to #9 type $response->{type_1}: '$user_data'";
	return 0;
      }
      $response->{value} = ord($1) + ord($2) * 256;
      # get the rest of it
      $user_data = $3;
    }
    elsif ($response->{type_1} == 2) {
      # NOT SURE THIS IS RIGHT
      # digital type
      if ($user_data !~ m/^(.{16})(.{16})(.*)$/s) {
	$response->{error} =
	  "invalid response to #9 type $response->{type_1}: '$user_data'";
	return 0;
      }
      $response->{text_low} = $1;
      $response->{text_high} = $2;
      # get the rest of it
      $user_data = $3;
    }
    elsif ($response->{type_1} == 4) {
      # counter type
      if ($user_data !~ m/^(.)(.)(.)(.)(.*)$/s) {
	$response->{error} =
	  "invalid response to #9 type $response->{type_1}: '$user_data'";
	return 0;
      }
      $response->{value} = ord($1) + ord($2) * 256 + ord($3) * 256 * 256 +
	  ord($4) * 256 * 256 * 256;
      # get the rest of it
      $user_data = $5;
    }
    elsif ($response->{type_1} == 8) {
      # NOT SURE THIS IS RIGHT
      # status type
      if ($user_data !~ m/^(.{4})(.*)$/s) {
	$response->{error} =
	  "invalid response to #9 type $response->{type_1}: '$user_data'";
	return 0;
      }
      $response->{value} = $1;
      $user_data = $2;
    }
    else {
      $response->{error} =
	"unknown command 9 channel type $response->{type_1}";
      return 0;
    }
  }
  
  return 1;
}

###############################################################################

#
# Process the response from the SMA unit
#
sub process_response
{
  my ($buf, $verbose_b, $very_verbose_b) = @_;
  my %response;
  
  if ($LOG_DIR) {
    my $now = time;
    open(LOG, ">> $LOG_DIR/$now.from")
      || die "Could not write to $LOG_DIR/$now.from: $!\n";
    print LOG $buf;
    close(LOG);
  }
  
  # 2 optional sync bytes
  # 1 telegram start byte (0x68)
  # 1 user length byte
  # 1 user length byte repeated
  # 1 telegram start byte (0x68)
  ### the checksum data block starts here
  # 2 source address bytes
  # 2 destination address bytes
  # 1 control byte (0x40)
  # 1 packet counter byte
  # 1 command type byte
  # X user data bytes
  ### the checksum data block ends here
  # 2 checksum bytes
  # 1 end character byte (0x16)
  if ($buf !~
      m/^(\xAA\xAA)?\x68(.)(.)\x68((.)(.)(.)(.)\x40(.)(.)(.*))(.)(.)\x16$/s) {
    $response{error} = 'not valid response';
    return \%response;
  }
  
  my $user_length = ord($2);
  if ($user_length != ord($3)) {
    $response{error} = 'user length was not duplicated';
    return \%response;
  }
  my $crc_data = $4;
  $response{src_addr} = ord($5) + ord($6) * 256;
  $response{dest_addr} = ord($7) + ord($8) * 256;
  $response{packet_cnt} = ord($9);
  $response{command} = ord($10);
  $response{user_data} = $11;
  my $crc = ord($12) + ord($13) * 256;
  
  # verify the crc
  my $crc_recalc;
  map { $crc_recalc += ord($_) } split (//, $crc_data);
  if ($crc_recalc != $crc) {
    $response{error} = "data crc $crc did not match calculated $crc_recalc";
    return \%response;
  }
  
  print "  read request, packet $response{packet_cnt}\n" if $verbose_b;
  return \%response;
}

###############################################################################

#
# Actually read the bytes from the SMA unit
#
sub read_response
{
  my ($SOCK, $timeout, $verbose_b, $very_verbose_b) = @_;
  my $buf;
  
  my $rin = '';
  vec($rin, fileno($SOCK), 1) = 1;
  
  while (1) {
    #print "waiting\n";
    if (select(my $rout = $rin, undef, undef, $timeout) == 0) {
      #print "timed out\n";
      last;
    }
    elsif (vec($rout, fileno($SOCK), 1)) {
      last unless sysread($SOCK, my $read_buf, 1024);
      #print "read " . length($read_buf) . " bytes\n";
      $buf .= $read_buf;
      $timeout = $TIMEOUT_SHORT;
    }
  }
  
  if ($verbose_b) {
    print "  read " . length($buf) . " bytes in response\n";
    print "  " . hex_string($buf) . "\n" if ($buf && $very_verbose_b);
  }
  
  return $buf;
}

###############################################################################

#
# Construct the SMA command buffer
#
sub build_request
{
  my ($dest_addr, $packet, $command, $control, $user_data) = @_;
  my $front;
  my $mid;
  my $end;
  
  # wakeup bytes
  $front = "\xAA\xAA";
  # telegram start byte
  $front .= "\x68";
  # length of the user data
  $front .= chr(length($user_data));
  # length of the user data sent again
  $front .= chr(length($user_data));
  # telegram start byte
  $front .= "\x68";
  
  # source address
  $mid = "\x00\x00";
  # dest address
  $mid .= chr($dest_addr % 256);
  $mid .= chr($dest_addr / 256);
  # control byte (0 == request single, 64 == response, 128 == request group)
  $mid .= chr($control);
  # packet counter
  $mid .= chr($packet);
  # command
  $mid .= chr($command);
  $mid .= $user_data;
  
  # get the checksum
  my $crc = 0;
  map { $crc += ord($_); } split (//, $mid);
  
  # low byte of crc
  $end = chr($crc % 256);
  # high byte of crc
  $end .= chr($crc / 256);
  # end character
  $end .= "\x16";
  
  return $front . $mid . $end;
}

###############################################################################

#
# Write a command to the SMA unit
#
sub write_command
{
  my ($SOCK, $dest_addr, $command, $packet_cnt, $control, $user_data,
      $verbose_b, $very_verbose_b) = @_;
  
  # build the request buffer
  my $request = build_request($dest_addr, $packet_cnt, $command, $control,
			      $user_data);
  
  if ($LOG_DIR) {
    my $now = time;
    open(LOG, ">> $LOG_DIR/$now.to")
      || die "Could not write to $LOG_DIR/$now.to: $!\n";
    print LOG $request;
    close(LOG);
  }
  
  # write it out to the device
  return 0 unless syswrite($SOCK, $request) == length($request);
  
  if ($verbose_b) {
    print "Wrote request, packet $packet_cnt, command $command\n";
    print "  " . hex_string($request) . "\n" if $very_verbose_b;
  }
  return 1;
}

###############################################################################

#
# Read and process the response from the SMA unit
#
sub handle_response
{
  my ($SOCK, $response, $verbose_b, $very_verbose_b) = @_;
  
  # read our response
  my $resp_buf = read_response($SOCK, $TIMEOUT_LONG, $verbose_b,
			       $very_verbose_b);
  if (not $resp_buf) {
    $response->{error} = "no response";
    return 0;
  }
  
  # process the response buffer
  my $tmp_resp = process_response($resp_buf, $verbose_b, $very_verbose_b);
  if ($tmp_resp->{error}) {
    $response->{error} = "no response";
    return 0;
  }
  
  # foreach field in the temporary response, copy it into the response
  # adding the user-data sections, handling the decreasing packet
  # count, and making sure the other fields are consistent
  foreach my $field (keys (%$tmp_resp)) {
    if (not $response->{$field}) {
      # new field
      $response->{$field} = $tmp_resp->{$field};
    }
    elsif ($field eq "user_data") {
      # append the user-data sections
      $response->{user_data} .= $tmp_resp->{user_data};
    }
    elsif ($field eq "packet_cnt") {
      # correct the packet-count left
      $response->{packet_cnt} = $tmp_resp->{packet_cnt};
    }
    elsif ($response->{$field} ne $tmp_resp->{$field}) {
      $response->{error} = "field $field did not match previous packet";
      return 0;
    }
  }
  
  return 1;
}

###############################################################################

#
# Execute a command on the SMA unit.  This builds and writes the
# command and then reads and processes the response.
#
sub do_command
{
  my ($SOCK, $dest_addr, $command, $control, $user_data, $verbose_b,
      $very_verbose_b) = @_;
  my %response;
  my $packet_c = 0;
  
  # We send a command then wait for the response packet.  The response
  # may be made up of many response packets so we look through the
  # packets and then append the data portion together in
  # handle_response until the packet-count goes to 0.
  
  do {
    # write the command
    if (not write_command($SOCK, $dest_addr, $command, $packet_c, $control,
			  $user_data, $verbose_b, $very_verbose_b)) {
      my %response;
      $response{error} = "writing request failed";
      return \%response;
    }
    
    # handle the response if necessary
    return \%response
      unless handle_response($SOCK, \%response, $verbose_b, $very_verbose_b);
    
    $packet_c = $response{packet_cnt};
  } while ($response{packet_cnt} > 0);
  
  # now handle the data portion for the various command responses
  if ($response{command}) {
    if ($response{command} == $CMD_GET_NET) {
      process_resp_get_net(\%response, $verbose_b, $very_verbose_b);
    }
    elsif ($response{command} == $CMD_GET_NET_START) {
      # NET-START has the same response as NET
      process_resp_get_net(\%response, $verbose_b, $very_verbose_b);
    }
    elsif ($response{command} == $CMD_GET_CINFO) {
      process_resp_get_cinfo(\%response, $verbose_b, $very_verbose_b);
    }
    # NOTE: CMD_GET_DATA is handled by the caller
  }
  
  return \%response;
}

###############################################################################

#
# Do a CMD_SYN_ONLINE command
#
sub do_cmd_syn_online
{
  my ($SOCK, $poll_time, $verbose_b, $very_verbose_b) = @_;
  my $user_data;
  
  # little endian time value
  $user_data .= chr($poll_time % 256);
  $user_data .= chr(($poll_time / 256) % 256);
  $user_data .= chr(($poll_time / (256 * 256)) % 256);
  $user_data .= chr(($poll_time / (256 * 256 * 256)) % 256);
  
  # write the syn online command as a broadcast
  if (write_command($SOCK, 0, $CMD_SYN_ONLINE, 0, 128, $user_data,
		    $verbose_b, $very_verbose_b)) {
    print "Wrote syn-online\n" if $verbose_b;
    return 1;
  }
  else {
    print STDERR "writing syn-online failed\n" if $verbose_b;
    return 0;
  }
}

###############################################################################

#
# do a CMD_GET_DATA command
#
sub do_cmd_get_data
{
  my ($SOCK, $src_addr, $channel, $verbose_b, $very_verbose_b) = @_;
  
  if ($verbose_b) {
    print "Getting data from $src_addr for channel '$channel->{name}':\n";
    print "  type1 $channel->{type_1}, type2 $channel->{type_2}, " .
      "index $channel->{index}\n";
  }
  
  my $user_data;
  $user_data .= chr($channel->{type_1});
  $user_data .= chr($channel->{type_2});
  # this can be index of the item or 0 for all of them
  $user_data .= chr($channel->{index});
  
  my $response = do_command($SOCK, $src_addr, $CMD_GET_DATA, 0, $user_data,
			    $verbose_b, $very_verbose_b);
  
  process_resp_get_data($response, $verbose_b, $very_verbose_b)
    if $response->{command} == $CMD_GET_DATA;
  
  print_response($response) if $verbose_b;
  
  return $response;
}

###############################################################################

#
# Write the log entry to the database.
#
sub write_db
{
  my ($DB_CONN, $dbase, $entry) = @_;
  my @entry_keys = keys(%$entry);
  
  my $stmt = $DB_CONN->prepare("INSERT INTO $dbase (" .
			       join(', ', map { "\"$_\"" } @entry_keys) .
			       ") VALUES (" .
			       join(', ', map { "?" } @entry_keys) . ");");
  if (not $stmt) {
    my $errstr = $DB_CONN->errstr;
    print STDERR "ERROR: session sql insert prepare error: $errstr\n";
    exit 1;
  }
  
  my @values = map { $entry->{$_} } @entry_keys;
  if ($stmt->execute(@values) != 1) {
    my $errstr = $stmt->errstr;
    if ($errstr) {
      print STDERR "ERROR: session sql insert execute error: $errstr\n";
    }
    else {
      print STDERR "ERROR: session sql insert affected 0 rows\n";
    }
    exit 1;
  }
}

###############################################################################

#
# Run the commands to get a list of the devices we are working with.
#
sub get_device_list
{
  my ($SOCK, $DB_CONN, $verbose_b, $very_verbose_b) = @_;
  my %devices;
  
  print "Starting up all of the devices.\n" if $verbose_b;
  
  # write the GET-NET-START command directly since there may be
  # multiple responses from the various devices.
  if (not write_command($SOCK, 0, $CMD_GET_NET_START, 0, 128, "",
			$verbose_b, $very_verbose_b)) {
    write_db($DB_CONN, "comments",
	     { comment => "writing net-start command failed" });
    print STDERR "ERROR: writing net-start command failed\n";
    exit 1;
  }
  
  while (1) {
    my %response;
    
    # read our response
    last unless handle_response($SOCK, \%response, $verbose_b,
				$very_verbose_b);
    
    # make sure we got the right response
    next unless $response{command} == $CMD_GET_NET_START;
    
    # NET-START has the same response as net
    process_resp_get_net(\%response, $verbose_b, $very_verbose_b);
    print_response(\%response) if $verbose_b;
    
    if ($response{src_addr}) {
      write_db($DB_CONN, "comments",
	       { addr => $response{src_addr},
		 comment => "got device: type $response{type}, " .
		   "serial $response{serial}" });
      $devices{$response{src_addr}} = \%response;
    }
    else {
      write_db($DB_CONN, "comments",
	       { comment => "no src-addr in net-start command response" });
      print STDERR "No src-addr in net-start command response.\n";
    }
  }
  
  if (not %devices) {
    write_db($DB_CONN, "comments",
	     { comment => "got no response to net-start command" });
    print STDERR "ERROR: got no response to net-start command\n";
    return undef;
  }
  
  print "  got " . scalar(keys(%devices)) . " devices\n" if $verbose_b;
  return \%devices;
}

###############################################################################

#
# For each device, get the list of data channels available.
#
sub get_device_channels
{
  my ($SOCK, $DB_CONN, $devices, $verbose_b, $very_verbose_b) = @_;
  
  print "Getting channels for the devices\n" if $verbose_b;
  
  foreach my $src_addr (keys(%$devices)) {
    my $device = $devices->{$src_addr};
    
    write_db($DB_CONN, "comments",
	     { addr => $src_addr,
	       comment => "getting channels for devices" });
    
    # get the channel information
    my $response = do_command($SOCK, $src_addr, $CMD_GET_CINFO, 0, "",
			      $verbose_b, $very_verbose_b);
    if (not $response) {
      write_db($DB_CONN, "comments",
	       { addr => $src_addr,
		 comment => "could not get channel info for device" });
      print STDERR "Could not get channel info for device $src_addr\n";
      next;
    }
    
    # store our hash reference into the channels field
    $device->{channels} = $response;
    
    my $channels = $device->{channels};
    foreach my $name (keys(%$channels)) {
      my $channel = $channels->{$name};
      next unless ref($channel) eq "HASH";
      my $comment = "channel '$channel->{name}' (#$channel->{index}): " .
	"type $channel->{type_1}/$channel->{type_2}";
      if ($channel->{unit} && $channel->{gain}) {
	$comment .= ", unit '$channel->{unit}', gain $channel->{gain}";
	$comment .= ", offset $channel->{offset}" if $channel->{offset};
      }
      $comment .= ", size $channel->{size}" if $channel->{size};
      $comment .= ", status $channel->{status}" if $channel->{status};
      $comment .= ", text-low $channel->{text_low}" if $channel->{text_low};
      $comment .= ", text-high $channel->{text_high}" if $channel->{text_high};
      write_db($DB_CONN, "comments",
	       { addr => $src_addr, comment => $comment });
    }
  }
}

###############################################################################

#
# Poll the devices to get all of the data.
#
sub poll_devices
{
  my ($SOCK, $DB_CONN, $devices, $poll_time, $verbose_b, $very_verbose_b) = @_;
  
  print "Handling " . scalar(keys(%$devices)) . " devices:\n" if $verbose_b;
  
  # send the synchronization command at the poll-time
  return unless do_cmd_syn_online($SOCK, $poll_time, $verbose_b,
				  $very_verbose_b);
  
  # Wait a couple of seconds for the units to sync.  Initially I did
  # not have this and the first variable polled would not respond.
  sleep(5);
  
  foreach my $src_addr (keys(%$devices)) {
    my $device = $devices->{$src_addr};
    
    print "Handling device $src_addr:\n" if $verbose_b;
    my $channels = $device->{channels};
    next unless $channels;
    
    my %data;
    
    # now run through and get the data items that we want
    foreach my $name (@channel_keys) {
      my $channel = $channels->{$name};
      next unless $channel;
      
      my $response = do_cmd_get_data($SOCK, $src_addr, $channel, $verbose_b,
				     $very_verbose_b);
      next unless defined $response->{value};
      
      my $value = $response->{value};
      
      # the response-since value should == the poll-time
      write_db($DB_CONN, "comments",
	       { addr => $devices->{src_addr},
		 comment => "poll time $poll_time != " .
		   "response $response->{since}" })
	unless $poll_time == $response->{since};
      
      $value *= $channel->{gain} if $channel->{gain};
      $value += $channel->{offset} if $channel->{offset};
      
      $data{$name} = $value;
    }
    
    next unless %data;
    
    # check to make sure that we got all of the fields
    foreach my $name (@channel_keys) {
      write_db($DB_CONN, "comments",
	       { addr => $src_addr,
		 comment => "could not get data for $name" })
	unless defined $data{$name};
    }
    
    $data{stamp} = strftime "%m/%d/%Y %H:%M:%S", localtime($poll_time);
    $data{addr} = $src_addr;
    
    print "Logging data to db: $data{stamp}, $src_addr\n" if $verbose_b;
    
    # Some sanity checks of the data.  When the unit is starting up,
    # often some of the data fields are 0.  I probably should be
    # keying off another field, but I have not found the correct value
    # yet.
    next unless ($data{'Fac'} > 50
		 && defined $data{'Temperature'}
		 && defined $data{'E-Total'}
		 && defined $data{'h-Total'});
    
    # log our stats from the device
    write_db($DB_CONN, "stats", \%data);
  }
}

###############################################################################

#
# Do whatever is necessary to get a descriptor attached to the SMA
# device.
#
sub device_open
{
  my ($DB_CONN, $device, $verbose_b, $very_verbose_b) = @_;
  my $SOCK;
  
  if ($device =~ m/^(.+):(.+)/) {
    # open the connection to the serial box
    $SOCK = IO::Socket::INET->new(PeerAddr => $1, PeerPort => $2);
    if (not $SOCK) {
      # socket did not connect
      write_db($DB_CONN,  "comments",
	       { comment => "connecting to $1:$2 failed: $!" });
      print STDERR "Connecting to '$1:$2' failed: $!\n" if $verbose_b;
      return undef;
    }
  }
  else {
    # Try and set the serial device modes.  Not sure if this works.
    # Line is 1200 8-N-1 so: speed 1200 cs8 -parenb -cstopb
    # I am not sure if rts/cts lines are supported so: -crtscts
    # Modem control lines are not enabled so: clocal
    #
    # If this does not work then you might need to add 'cread' or
    # 'sane' or some other stty option.
    system("stty raw speed 1200 cs8 -parenb -cstopb -crtscts " .
	   "clocal -ixon -ixoff < $device > $device 2>&1");
    
    if (not open($SOCK, "+< $device")) {
      # socket did not connect
      write_db($DB_CONN,  "comments",
	       { comment => "opening $device failed: $!" });
      print STDERR "Connection to '$device' failed: $!\n" if $verbose_b;
      return undef;
    }
  }
  
  # try to set the socket into non-blocking mode
  my $packed = 0;
  if (not fcntl($SOCK, F_GETFL, $packed)) {
    # socket did not connect
    write_db($DB_CONN, "comments",
	     { comment => "connecting to $device failed: $!" });
    print STDERR "Connection to '$device' failed\n" if $verbose_b;
    return undef;
  }
  $packed ^= O_NONBLOCK;
  if (not fcntl($SOCK, F_SETFL, $packed)) {
    write_db($DB_CONN, "comments",
	     { comment => "fcntl non-block failed: $!" });
  }
  
  # log that we connected to the device 
  write_db($DB_CONN, "comments", { comment => "connected to $device" });
  print "Connected to '$device'\n" if $verbose_b;
  
  return $SOCK;
}

###############################################################################

#
# Close the connection to the device
#
sub device_close
{
  my ($SOCK, $verbose_b, $very_verbose_b) = @_;
  print "closing the socket\n" if $verbose_b;
  close ($SOCK) || die "close: $!";
}

###############################################################################

#
# Spit out to stderr a usage message.
#
sub usage {
  my($arg) = @_;
  print STDERR "$0: invalid argument usage: $arg\n" if $arg;
  print STDERR qq[Usage: $0 [-c] [-i secs] [-l dir] [-p file] [-v] [-V] device
       -c       close device between polls
       -i       seconds interval between data polls
       -l       log transactions to directory for debugging
       -p       filename to write our pid file
       -v       verbose messages
       -V       very verbose messages

       device   name of the device to talk to the SMA unit
                can be in host:port format or /dev/...
];
  exit 1;
}

###############################################################################

# argument variables
my $interval = $POLL_INTERVAL;
my $close_b = 0;
my $verbose_b = 0;
my $very_verbose_b = 0;
my $device;
my $pid_file;

# process arguments
while (@ARGV) {
  $_ = shift @ARGV;
  m/^-i$/ && do { $interval = shift @ARGV || usage($_); next; };
  m/^-c$/ && do { $close_b = 1; next; };
  m/^-l$/ && do { $LOG_DIR = shift @ARGV || usage($_); next; };
  m/^-p$/ && do { $pid_file = shift @ARGV || usage($_); next; };
  m/^-v$/ && do { $verbose_b = 1; next; };
  m/^-V$/ && do { $very_verbose_b = 1; next; };
  m/^-/ && do { usage($_); next; };
  usage($_) if $device;
  $device = $_;
}
usage() unless $device;
$verbose_b = 1 if $very_verbose_b;

######################

# connect to the database
my $DB_CONN = DBI->connect($DBI_DATA_SOURCE, $DBI_USERNAME, $DBI_AUTH,
			   { RaiseError => 0, PrintError => 0,
			     AutoCommit => 1 });
if (not $DB_CONN) {
  my $errstr = $DBI::errstr;
  print STDERR "ERROR: database connection failed: $errstr\n";
  exit 1;
}
print "Opened connection to dbase\n" if $verbose_b;

######################

# get our connection to the device(s)
my $SOCK = device_open($DB_CONN, $device, $verbose_b, $very_verbose_b);
die "Could not connect to '$device'\n" unless $SOCK;

######################

# write the pid file
if ($pid_file) {
  open(PID, "> $pid_file") || die "Could not write pid to $pid_file: $!\n";
  print PID "$$\n";
  close(PID);
}

######################

my $devices;
while (1) {
  # get the list of devices we will be talking to
  $devices = get_device_list($SOCK, $DB_CONN, $verbose_b, $very_verbose_b);
  last if $devices;
  sleep($interval);
}

# for each device, get the list of data channels
get_device_channels($SOCK, $DB_CONN, $devices, $verbose_b, $very_verbose_b);

# now close the connection so we can reopen it.  maybe unnecessary.
if ($close_b) {
  device_close($SOCK, $verbose_b, $very_verbose_b);
  $SOCK = 0;
}
# sleep before we start polling
sleep(5);
STDOUT->flush if $verbose_b;

######################

# So here we calculate the proper time to give the next poll so we can
# synchronize between more than one unit.
my $next_poll = int((time + $interval - 1) / $interval) * $interval;

while (1) {
  
  # we do this in case $interval is smaller than the time it takes to
  # run one of the polls and we always want to be in sync
  my $now = time;
  while ($next_poll < $now) {
    $next_poll += $interval;
  }
  
  # sleep between polls
  my $sleep_secs = $next_poll - $now;
  sleep($sleep_secs) if $sleep_secs > 0;
  
  # make a new connection
  $SOCK = device_open($DB_CONN, $device, $verbose_b, $very_verbose_b)
    unless $SOCK;
  if ($SOCK) {
    # poll the devices for their data
    poll_devices($SOCK, $DB_CONN, $devices, $next_poll, $verbose_b,
		 $very_verbose_b);
    
    # close the device while we are sleeping.  maybe unnecessary.
    if ($close_b) {
      device_close($SOCK, $verbose_b, $very_verbose_b);
      $SOCK = 0;
    }
  }
  
  STDOUT->flush if $verbose_b;
}
