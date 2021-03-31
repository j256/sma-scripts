The following files in this directory were written to monitor and report on the output from my SMA Sunnyboy Solar PV
Inverters.

plot.pl
=======

CGI program which reads from the SQL database and draws the graphs.  It is designed to be included into something like
plot.shtml which is included.  You can tune the html inside of it to like on its own as necessary.  It should be renamed
to plot.cgi before it will work.

If you move it into a directory on your server, you may need to have the following in your .htaccess file if the script
is not going to live in your cgi-bin directory.

	# have the server parse the .shtml extension files
	AddType text/html .shtml
	AddHandler server-parsed .shtml
	# and
	Options ExecCGI Includes

plot.shtml
==========

Example wrapper html file to go around plot.cgi.  It assumes that you are running on apache with the include module
enabled.

NOTE: If you try and load the plot.shtml off my server then you will see an error message.  That's because the plot.pl
file is not executable in this directory.  You will need to download the plot.shtml file and the plot.pl script and set
them up on your server to see it work.

postgres.txt
============

Script to configure the database with the proper tables and fields.  This is in the postgres format but I'd think it
would work with mysql with minor adjustments.  If someone figures out what they are, please kick the changes back to me.

sma.pl
======

The script which monitors the SMA inverters.  It is full of very specific transaction code for talking with the SMA
units.  It was written for a RS232 connections but should be able to work with the RS485 and Powerline versions with a
little tweaking.

swrnet_session_protocol.pdf
===========================

Session protocol documentation from SMA in English.  Very long and involved and missing some details that I had to
infer, ask about, or get elsewhere.

Contact
=======

I can be reached for any questions or feedback at:

  http://256stuff.com/gray/

Gray Watson
