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
# $Id: plot.cgi,v 1.16 2011-01-05 23:14:45 gray Exp $
#

#
# Solar Power Graphing CGI Script
#

use strict;
use DBI;
use GD::Graph::bars;
use GD::Graph::lines;
use GD::Text;
use POSIX qw(strftime);

# some defaults and constants
my $SECS_IN_HOUR = 60 * 60;
my $SECS_IN_DAY = 24 * $SECS_IN_HOUR;
my $MAX_PERIOD = 90 * $SECS_IN_DAY;
my $DEFAULT_WIDTH = 750;
my $DEFAULT_HEIGHT = 400;
my $MAX_WIDTH = 1024;
my $MAX_HEIGHT = 768;
my $ALL = "all";

# how many pixels between two x-labels
my $X_LABEL_WIDTH = 80;

# my name
my $PLOT_HTML = "plot.shtml";
my $PLOT_CGI = "plot.cgi";

# time periods: seconds => label
my %periods = ( $SECS_IN_DAY * 30 =>	"1 Month",
	       $SECS_IN_DAY * 7 =>	"1 Week",
	       $SECS_IN_DAY * 3 =>	"3 Days",
	       $SECS_IN_DAY =>		"1 Day",
	       12 * 3600 =>		"12 Hours",
	       6 * 3600 =>		"6 Hours",
	       3 * 3600 =>		"3 Hours",
	       3600 =>			"1 Hour",
	       1800 =>			"30 Minutes",
	       600 =>			"10 Minutes",
	       );
# channels to monitor: db-field => label
my %channel_list = (
		    "Pac" =>		[ 0, 0, 0, "Watts" ],
		    "Ipv" =>		[ 0, 0, 0, "DC Amps" ],
		    "Vpv" =>		[ 0, 0, 0, "DC Volts" ],
		    "E-Total" =>	[ 0, 0, 0, "Total Kilowatts" ],
		    "E-Total.dct" =>	[ 1, 1, 1, "Kilowatts/Day" ],
		    "h-Total" =>	[ 0, 0, 0, "Operating Hours" ],
		    "h-Total.dct" =>	[ 1, 1, 1, "Operating Hrs/Day" ],
		    "Temperature" =>	[ 0, 0, 0, "Temp of Unit F" ],
		    "Vac" =>		[ 0, 0, 0, "Grid Volts AC" ],
		    "Fac" =>		[ 0, 0, 0, "Grid Freq Hz" ],
		    );

# connect to the DB
my $PG_CONN = DBI->connect("dbi:Pg:dbname=solar", "solar", "",
			{ RaiseError => 0, PrintError => 0, AutoCommit => 1 });
if (not $PG_CONN) {
  my $errstr = $DBI::errstr;
  print qq[Content-type: text/html

<html><body><h1> DB connect failed: $errstr </h1></body></html>
];
  exit 1;
}

# process the environment
my %which;
my $form = process_env();

###############################################################################

#
# Read our environment either looking for query-string or content-length
# env variables.
#
sub process_env
{
  my $buffer = "";
  
  # if there is a CONTENT_LENGTH env var then this was a POST
  if ($ENV{CONTENT_LENGTH}) {
    # Read in from stdin the POSTed arguments.
    read(STDIN, $buffer, $ENV{CONTENT_LENGTH});
  }
  elsif ($ENV{QUERY_STRING}) {
    # Arguments from a GET are in the QUERY_STRING env variable
    $buffer = $ENV{QUERY_STRING};
  }
  
  # Split the name-value pairs
  my @pairs = split(/\&/, $buffer);
  my %form;
  
  foreach my $pair (@pairs) {
    my ($name, $value) = split(/=/, $pair);
    
    # Un-Webify plus signs and %-encoding
    $value =~ tr/+/ /;
    $value =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
    
    # Stop people from using subshells to execute commands
    # Not a big deal when using sendmail, but very important
    # when using UCB mail (aka mailx).
    # $value =~ s/~!/ ~!/g; 
    
    if ($name eq "which") {
      $which{$value} = 1;
    }
    else {
      $form{$name} = $value;
    }
    #  print "<!-- $name == $form->{$name} -->\n";
  }
  
  return \%form;
}

###############################################################################

#
# Page trailer for the bottom of the page.
#
sub loc_trailer
{
  print qq[
</body>
</html>
];
  exit 0;
}

###############################################################################

#
# Do the SQL query and load the data into our hash
#
sub get_data
{
  my ($channel, $data, $total) = @_;
  
  # this is a LOT faster then comparing against epoch stuff
  my $from_stamp = strftime "%m/%d/%Y %T", localtime($form->{from});
  my $to_stamp = strftime "%m/%d/%Y %T", localtime($form->{from} +
						   $form->{period});
  
  my $daily_b = $channel_list{$channel}->[0];
  my $change_b = $channel_list{$channel}->[1];
  my $total_b = $channel_list{$channel}->[2];
  $channel = $1 if $channel =~ m/^(.*)\..*$/;
  
  my $stmt = $PG_CONN->prepare(qq{
    SELECT EXTRACT(epoch FROM stamp) AS stamp,addr,"$channel"
      FROM stats
	WHERE stamp >= '$from_stamp' AND stamp < '$to_stamp'
	  ORDER BY stamp; });
  if (not $stmt) {
    my $errstr = $PG_CONN->errstr;
    print "<p> Preparing query failed: $errstr </p>\n";
    loc_trailer();
  }
  if (not $stmt->execute) {
    my $errstr = $PG_CONN->errstr;
    print "<p> Executing query failed: $errstr </p>\n";
    loc_trailer();
  }
  
  # So the $data hash reference has keys which are time in seconds
  # since epoche and values which are array references.  This array
  # contains objects which are arrary references which store the actual
  # variable name, value, and source address.
  my %last_days;
  my %last_vals;
  while (my $row = $stmt->fetchrow_hashref) {
    if ($daily_b) {
      my $stamp_day = strftime "%Y%m%d", localtime($row->{stamp});
      # skip the entry that are not the 1st one in a new day
      next if ($last_days{$row->{addr}}
	       && $stamp_day == $last_days{$row->{addr}});
      $last_days{$row->{addr}} = $stamp_day;
      $row->{stamp} = 3600 * int(($row->{stamp} + 1800) / 3600);
    }
    if ($change_b) {
      my $current = $row->{$channel};
      if ($last_vals{$channel} && $last_vals{$channel}->{$row->{addr}}) {
	$row->{$channel} -= $last_vals{$channel}->{$row->{addr}};
      }
      $last_vals{$channel}->{$row->{addr}} = $current;
      next if $current == $row->{$channel};
    }
    $row->{addr} = 0 if $total_b;
    my $entry = $data->{$row->{stamp}} || [];
    if ($total_b && @$entry) {
      foreach my $field (@$entry) {
	next unless $field->[0] eq $channel;
	$field->[1] += $row->{$channel};
	last;
      }
    }
    else {
      push @$entry, [ $channel, $row->{$channel}, $row->{addr} ];
    }
    $data->{$row->{stamp}} = $entry;
  }
}

###############################################################################

#
# build and draw the graph image
#
sub draw_graph
{
  my ($which, $title, $data) = @_;
  
  my @which_channels = keys(%$which);
  my $graph;
  my $bars_b = 0;
  if (scalar(@which_channels) == 1 && $channel_list{$which_channels[0]}->[0]) {
    $graph = GD::Graph::bars->new($form->{width}, $form->{height});
    $bars_b = 1;
  }
  else {
    $graph = GD::Graph::lines->new($form->{width}, $form->{height});
  }
  
  # find the min and max values
  my $max_y = 0;
  my $min_y = 1000000;
  my $max_x = 0;
  my $min_x = 2000000000;
  my @sorted_keys = sort(keys(%$data));
  foreach my $epoch (@sorted_keys) {
    $max_x = $epoch if $epoch > $max_x;
    $min_x = $epoch if $epoch < $min_x;
    my $entries = $data->{$epoch};
    foreach my $channel (@$entries) {
      my $val = $$channel[1];
      # this is important otherwith it will be 0
      next unless defined($val);
      $max_y = $val if $val > $max_y;
      $min_y = $val if $val < $min_y;
    }
  }
  
  my $y_range = $max_y - $min_y;
  # set the y-format based on how much range we have on the y axis
  my $y_format = "%d";
  $y_format = "%.1f" if $y_range < 4;
  $y_format = "%.3f" if $y_range < 2;
  
  # give ourselves a little padding in the Y axis
  my $extra = $y_range * 0.05;
  $extra = 1 unless $extra;
  $max_y += $extra;
  $min_y -= $extra;
  $min_y = 0 if $min_y < 0;
  
  # determine the format of our X axis labels
  my $time_format;
  if ($max_x - $min_x >= $SECS_IN_DAY * 3) {
    $time_format = "%m/%d";
    $X_LABEL_WIDTH = "50";
  }
  else {
    my @min_lt = localtime($min_x);
    my @max_lt = localtime($max_x);
    # time format is MM/DD HH:MM
    $time_format = "%m/%d %H:%M";
    # if all of the data points are in the same day then we can just do
    # HH:MM
    if ($min_lt[5] == $max_lt[5]
	&& $min_lt[4] == $max_lt[4]
	&& $min_lt[3] == $max_lt[3]) {
      $time_format = "%H:%M";
      $X_LABEL_WIDTH = "50";
    }
  }
    
  # figure out how often to print the x-labels
  my $label_incr = scalar(keys(%$data)) / ($form->{width} / $X_LABEL_WIDTH);
  my $time_str;
  if ($form->{height} < 120) {
    $time_str = strftime "%m/%d %H:%M:%S", localtime($form->{from});
  }
  elsif ($form->{height} < 180) {
    $time_str = strftime "%m/%d %H:%M:%S %Z", localtime($form->{from});
  }
  else {
    $time_str = strftime "%m/%d/%Y %H:%M:%S %Z", localtime($form->{from});
  }
  
  my $line_width = $form->{line_width} || 1;
  $graph->set(
	      title		=> "$title for $periods{$form->{period}}",
	      line_width	=> $line_width,
	      marker_size	=> 1,
	      legend_placement	=> 'BC',
	      x_label_skip	=> $label_incr,
	      y_max_value	=> $max_y,
	      y_long_ticks	=> 1,
	      y_number_format	=> $y_format,
	      y_label		=> $time_str,
	      skip_undef	=> 1,
	      #fgclr		=> 'black',
	      #accentclr	=> 'black',
	      #labelclr		=> 'black',
	      #axislabelclr	=> 'black',
	      #legendclr	=> 'black',
	      #valuesclr	=> 'black',
	      #textclr		=> 'black',
	      ) || die $graph->error;
  die $graph->error
    if ((not $bars_b) && (not $graph->set(y_min_value => $min_y)));
  GD::Text->font_path('/usr/X11R6/lib/X11/fonts/');
  my $line_width = $form->{line_width} || 1;

  my $font = 'webfonts/verdana';
  my $base_font = $form->{base_font} || 7;
  $graph->set_title_font($font, $base_font + 8);
  $graph->set_legend_font($font, $base_font + 4);
  $graph->set_x_label_font($font, $base_font + 2);
  $graph->set_y_label_font($font, $base_font + 2);
  $graph->set_x_axis_font($font, $base_font);
  $graph->set_y_axis_font($font, $base_font);
  $graph->set_values_font($font, $base_font + 4);
  
  my @final;
  push @final, [];
  
  # determine how many different rows we have
  my %legends;
  foreach my $epoch (@sorted_keys) {
    my $entries = $data->{$epoch};
    foreach my $channel (@$entries) {
      my $var = $$channel[0];
      my $addr = $$channel[2];
      
      my $slot = "$var $addr";
      next if $legends{$slot};
      
      push @final, [];
      $legends{$slot} = 1;
    }
  }
  
  # sort the legend entries and then number them
  my @legend_keys;
  foreach my $varAddr (sort(keys(%legends))) {
    my ($var, $addr) = $varAddr =~ m/^(.*)\s+(.*)$/;
    my $list = $channel_list{$var};
    if ($addr eq $ALL) {
      push(@legend_keys, "$$list[3]");
    } else {
      push(@legend_keys, "$$list[3] (${addr})");
    }
  }
  $graph->set_legend(@legend_keys);
  my $col_c = 1;
  foreach my $slot (sort(keys(%legends))) {
    $legends{$slot} = $col_c++;
  }
  
  # now build our data arrays
  my $next_label = 0;
  my $label_c = 0;
  foreach my $epoch (@sorted_keys) {
    push @{$final[0]}, strftime($time_format, localtime($epoch));
    my $entries = $data->{$epoch};
    foreach my $channel (@$entries) {
      my $var = $channel->[0];
      my $val = $channel->[1];
      my $addr = $channel->[2];
      my $slot = "${var} ${addr}";
      push @{$final[$legends{$slot}]}, $val;
    }
    my $fill_c = 1;
    while ($fill_c < $col_c) {
      while (scalar(@{$final[0]}) > scalar(@{$final[$fill_c]})) {
	push @{$final[$fill_c]}, undef;
      }
      $fill_c++;
    }
  }
  
  # plot the graph and get the image
  my $gd = $graph->plot(\@final) || die $graph->error;
  my $image = $gd->png ||  die $graph->error;
  
  # spit out the right headers, content-length, and the image
  print "Content-type: image/png\n";
  print "Content-Length: " . length($image) . "\n\n";
  print $image;
  
  exit 0;
}

###############################################################################

#
# print the raw data out as CSV
#
sub print_data
{
  my ($data) = @_;
  
  print "Content-type: text/plain\n\n";

  # find all of the channels and values
  my %channels;
  my $channelC = 0;
  my %fields;
  my $fieldC = 0;
  foreach my $value (sort(keys(%$data))) {
    my $entries = $data->{$value};
    foreach my $channel (@$entries) {
      my $field = $channel->[0];
      my $channel = $channel->[2];
      $channels{$channel} = $channelC++ unless defined($channels{$channel});
      $fields{$field} = $fieldC++ unless defined($fields{$field});
    }
  }
  
  # spit out the header line
  print "\"Date Time\"";
  my @channels = sort { $channels{$a} <=> $channels{$b} } keys(%channels);
  my @fields = sort { $fields{$a} <=> $fields{$b} } keys(%fields);
  foreach my $channel (@channels) {
    foreach my $field (@fields) {
      my $title = $channel_list{$field}->[3];
      print ",\"$title ($channel)\"";
    }
  }
  print "\n";

  my $lastStamp;
  foreach my $value (sort(keys(%$data))) {
    my $entries = $data->{$value};
    my $stamp = strftime "%m/%d/%Y %H:%M:%S", localtime($value);
    print "\"$stamp\"";
    my %values;
    foreach my $channel (@$entries) {
      my $field = $channel->[0];
      my $val = $channel->[1];
      my $channel = $channel->[2];
      my $key = "$field$channel";
      $values{$key} += $val;
    }
    foreach my $channel (@channels) {
      foreach my $field (@fields) {
	my $key = "$field$channel";
	my $val = $values{$key};
	print ",\"$val\"";
      }
    }
    print "\n";
  }
  
  print "# Watson solar house data http://256.com/solar/\n";
  print "# Produced: " . localtime(time) . "\n";
  exit 0;
}

###############################################################################

#
# Default values for arguments
#
$which{Pac} = 1 unless %which;
$form->{period} = $SECS_IN_DAY unless $form->{period};
my $time_checked = "";
my $latest_checked = "";
my $total_checked = "";
my $separate_checked = "";
$form->{to} = time() unless $form->{to};
if ($form->{from}) {
  $time_checked = "checked=\"checked\"";
}
else {
  $form->{from} = time() - $form->{period};
  $latest_checked = "checked=\"checked\"";
}
if ($form->{separate}) {
  $separate_checked = "checked=\"checked\"";
}
else {
  $total_checked = "checked=\"checked\"";
}
$form->{width} = $DEFAULT_WIDTH unless $form->{width};
$form->{height} = $DEFAULT_HEIGHT unless $form->{height};

my $channel_c = 0;
my $title;
foreach my $channel (keys(%channel_list)) {
  next unless $which{$channel};
  if ($title) {
    $title = "Data";
  }
  else {
    $title = $channel_list{$channel}->[3];
  }
}

# get our data array
my %data;
foreach my $channel (sort(keys(%which))) {
  get_data($channel, \%data);
}
if (not $form->{separate}) {
  foreach my $value (sort(keys(%data))) {
    my $entries = $data{$value};
    my %values;
    foreach my $channel (@$entries) {
      my $field = $channel->[0];
      my $val = $channel->[1];
      my $key = $field;
      $values{$key} += $val;
    }
    my @newData;
    foreach my $field (keys(%values)) {
      push(@newData, [$field, $values{$field}, $ALL]);
    }
    $data{$value} = \@newData;
  }
}
draw_graph(\%which, $title, \%data) if ($form->{image} || $ARGV[0] eq "image");
print_data(\%data) if ($form->{data} || $ARGV[0] eq "data");

#
# Spit out the form and the image reference.
#
my $time_str = localtime($form->{from});
print qq[Content-type: text/html

<form action="$PLOT_HTML" method="get">
<input type="hidden" name="to" value="$form->{to}" />
$time_str <input type="radio" name="from" value="$form->{from}"
$time_checked />
Latest: <input type="radio" name="from" value="0" $latest_checked /><br />
Inverter output:
total <input type="radio" name="separate" value="0" $total_checked />
separate <input type="radio" name="separate" value="1" $separate_checked /><br />
];
foreach my $channel (sort { $channel_list{$a}->[3] cmp $channel_list{$b}->[3] }
		     (keys(%channel_list))) {
  print "<nobr><input type=\"checkbox\" name=\"which\" value=\"$channel\" ";
  print "checked=\"checked\" " if $which{$channel};
  my $label = $channel_list{$channel}->[3];
  $label =~ s/ /&nbsp;/g;
  print "/>$label</nobr>&nbsp;&nbsp;&nbsp;\n";
}
print "<br />\n";

print "<select name=\"period\">\n";
my $select_b = 0;
foreach my $secs (sort { $b <=> $a } (keys(%periods))) {
  my $selected = "";
  if ($form->{period} == $secs) {
    $selected = " selected=\"selected\"";
    $select_b = 1;
  }
  print "<option value=\"$secs\"$selected>$periods{$secs}</option>\n";
}
if (not $select_b) {
  my $time_str = "";
  my $secs = $form->{period};
  if (int($secs / $SECS_IN_DAY) > 0) {
    $time_str .= int($secs / $SECS_IN_DAY) . "d ";
    $secs %= $SECS_IN_DAY;
  }
  $time_str .= sprintf "%02d:", int($secs / $SECS_IN_HOUR);
  $secs %= $SECS_IN_HOUR;
  $time_str .= sprintf "%02d:", int($secs / 60);
  $secs %= 60;
  $time_str .= sprintf "%02d", int($secs);
  print "<option value=\"$form->{period}\" selected=\"selected\">" .
    "Period $time_str</option>\n";
}
print "</select>\n";

my $prev_query_string = "";
if (%data) {
  $prev_query_string = $ENV{QUERY_STRING};
  $prev_query_string =~ s/(\&)?from=(\d+)//;
  my $prev_from = $form->{from} - $form->{period};
  $prev_query_string .= "&amp;from=$prev_from";
}
my $prev_half_query_string = "";
if (%data) {
  $prev_half_query_string = $ENV{QUERY_STRING};
  $prev_half_query_string =~ s/(\&)?from=(\d+)//;
  my $prev_half_from = $form->{from} - $form->{period} / 2;
  $prev_half_query_string .= "&amp;from=$prev_half_from";
}
my $next_query_string = "";
if ($form->{from} < time) {
  $next_query_string = $ENV{QUERY_STRING};
  $next_query_string =~ s/(\&)?from=(\d+)//;
  my $next_from = $form->{from} + $form->{period};
  $next_query_string .= "&amp;from=$next_from";
}
my $next_half_query_string = "";
if ($form->{from} < time) {
  $next_half_query_string = $ENV{QUERY_STRING};
  $next_half_query_string =~ s/(\&)?from=(\d+)//;
  my $next_half_from = $form->{from} + $form->{period} / 2;
  $next_half_query_string .= "&amp;from=$next_half_from";
}

print qq[
<input type="submit" value="Redraw" />
</form>

<table border="0">
<tr>
<td>
<a href="$PLOT_HTML?$prev_query_string">Prev<br />Period</a><br /><br />
<a href="$PLOT_HTML?$prev_half_query_string">Prev<br />Half<br />Period</a>
</td><td>
<img src="$PLOT_CGI?image=1&amp;$ENV{QUERY_STRING}" width="$form->{width}"
height="$form->{height}" alt="solar graph" />
</td><td>
<a href="$PLOT_HTML?$next_query_string">Next<br />Period</a><br /><br />
<a href="$PLOT_HTML?$next_half_query_string">Next<br />Half<br />Period</a>
</td>
</table>

<p> You can also download the <a
href="$PLOT_CGI?data=1&amp;$ENV{QUERY_STRING}">data associated with
this graph</a>. </p>
];

loc_trailer();
