-------------------------------------------------------------------------------
The following files in this directory were written to monitor and
report on the output from my SMA Sunnyboy Solar PV Inverters.
$Id: NOTES.txt,v 1.8 2005/04/19 22:17:19 gray Exp $
-------------------------------------------------------------------------------

PLOT.PL

CGI program which reads from the SQL database and draws the graphs.
It is designed to be included into something like plot.shtml which is
included.  You can tune the html inside of it to like on its own as
necessary.  It should be renamed to plot.cgi before it will work.

If you move it into a directory on your server, you may need to have
the following in your .htaccess file if the script is not going to
live in your cgi-bin directory.

	# have the server parse the .shtml extension files
	AddType text/html .shtml
	AddHandler server-parsed .shtml
	# and
	Options ExecCGI Includes

-------------------------------------------------------------------------------

PLOT.SHTML

Example wrapper html file to go around plot.cgi.  It assumes that you
are running on apache with the include module enabled.

NOTE: If you try and load the plot.shtml off my server then you will
see an error message.  That's because the plot.pl file is not
executable in this directory.  You will need to download the
plot.shtml file and the plot.pl script and set them up on your server
to see it work.

-------------------------------------------------------------------------------

POSTGRES.TXT

Script to configure the database with the proper tables and fields.
This is in the postgres format but I'd think it would work with mysql
with minor adjustments.  If someone figures out what they are, please
kick the changes back to me.

-------------------------------------------------------------------------------

SMA.PL

The script which monitors the SMA inverters.  It is full of very
specific transaction code for talking with the SMA units.  It was
written for a RS232 connections but should be able to work with the
RS485 and Powerline versions with a little tweaking.

-------------------------------------------------------------------------------

SWRNET_SESSION_PROTOCOL.PDF

Session protocol documentation from SMA in English.  Very long and
involved and missing some details that I had to infer, ask about, or
get elsewhere.

-------------------------------------------------------------------------------

TRANSACTIONS.LOG

The sma.pl script has a -v (verbose) and -V (very_verbose) options.
This is a capture of my startup output and 2 polls with the -V verbose
option enabled.  It shows what packets are written with their
associated bytes and what responses are read with their bytes and the
packet details.  It should help if you are rolling your own in another
language or something.

-------------------------------------------------------------------------------

TRANSACTIONS_RAW.TGZ

Tar.gz file of binary transactions that were sent to and from one of
my SMA units.  These transactions may help you debug your software or
possibly roll your own.  Take a look at the NOTES.txt file in the
directory for some explanation of the various transactions.  To read
these transactions you will probably need an editor (like emacs) which
can edit binary files.

-------------------------------------------------------------------------------

I can be reached for any questions or feedback at:

  http://256.com/gray/

Gray Watson

-------------------------------------------------------------------------------
