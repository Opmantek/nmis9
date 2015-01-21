#!/usr/bin/perl
#
## $Id: logs.pl,v 8.14 2012/08/29 04:41:27 keiths Exp $
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#  
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#  
#  This file is part of Network Management Information System ("NMIS").
#  
#  NMIS is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#  
#  NMIS is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#  
#  You should have received a copy of the GNU General Public License
#  along with NMIS (most likely in a file named LICENSE).  
#  If not, see <http://www.gnu.org/licenses/>
#  
#  For further information on NMIS or for a license other than GPL please see
#  www.opmantek.com or email contact@opmantek.com 
#  
#  User group details:
#  http://support.opmantek.com/users/
#
#*****************************************************************************
#
# 2012-07-19 nmisdev -restyled all code.
# Logs.xxxx configuration file has changed format , example file at end of ths routine.
# Interface changes.
# Logs are now displayed matching their RFC severity level.
# use option 'ALL' to display all logs.
# serach and num of lines displayed logic changed.
# all log files for logname.xx.xx are read and filtered by 'search'
# the list of logs returned can then be displayed, ascending, decsendng, or further filtered by node, group, lines
# only at this point, is  the list of logs truncated by 'lines=ccc';
# the sumamry view is now available from the menubar,and this will summarise over all log fils found.
# The printed output list will be truncated by 'lines=' when displayed.
#
#
# use CGI::Debug( report => 'everything', on => 'anything' );
# Auto configure to the <nmis-base>/lib and <nmis-base>/files/nmis.conf
use FindBin;
use lib "$FindBin::Bin/../lib";
#use lib "/usr/local/rrdtool/lib/perl";
use Data::Dumper;

use Socket;

$SIG{PIPE} = sub { };  # Supress broken pipe error messages.

#
#****** Shouldn't be anything else to customise below here *******************

use strict;
use func;
use csv;
use NMIS;
use Time::Local;
use Fcntl qw(:DEFAULT :flock);
use Sys;

# ----------------------------------------------------

# Prefer to use CGI::Pretty for html processing
use CGI::Pretty qw(:standard *table *Tr *td *th *form *Select *div);
$CGI::Pretty::INDENT = "  ";
$CGI::Pretty::LINEBREAK = "\n";
push @CGI::Pretty::AS_IS, qw(p h1 h2 center b comment option span);
# use CGI qw(:standard);
use CGI::Carp qw(warningsToBrowser fatalsToBrowser);

use URI::Escape;

# declare holder for CGI objects
use vars qw($q $Q $C $AU);
$q = new CGI; # This processes all parameters passed via GET and POST
$Q = $q->Vars; # values in hash

## uncomment for debug
#$Q->{debug} = 'true';
##
if (!($C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug}))) { exit 1; };

# -------------------------------------------------------
# Before going any further, check to see if we must handlegrep
# an authentication login or logout request

# NMIS Authentication module
use Auth;
my $logoutButton;
my $privlevel = 5;
my $user;

# variables used for the security mods
use vars qw($headeropts); $headeropts = {type=>'text/html',expires=>'now'};
$AU = Auth->new(conf => $C);  # Auth::new will reap init values from NMIS configuration

if ($AU->Require) {
	if($C->{auth_method_1} eq "" or $C->{auth_method_1} eq "apache") {
		$Q->{auth_username}=$ENV{'REMOTE_USER'};
		$AU->{username}=$ENV{'REMOTE_USER'};
		$user = $ENV{'REMOTE_USER'} if $ENV{'REMOTE_USER'};
		$logoutButton = qq|disabled="disabled"|;
	}
	exit 0 unless $AU->loginout(conf=>$Q->{conf},type=>$Q->{auth_type},username=>$Q->{auth_username},
				password=>$Q->{auth_password},headeropts=>$headeropts) ;
	$privlevel = $AU->{privlevel};
} else {
	$user = 'Nobody';
	$user = $ENV{'REMOTE_USER'} if $ENV{'REMOTE_USER'};
	$logoutButton = qq|disabled="disabled"|;
}
# -------------------------------------------------------------

# check for remote request
if ($Q->{server} ne "") { exit if requestServer(headeropts=>$headeropts); }

### 2012-08-29 keiths, adding wiget less support, widget on by default.
my $widget = getbool($Q->{widget},"invert")? "false" : "true";
my $wantwidget = $widget eq "true";

### 2012-08-29 keiths, setting default refresh based on widget or not
if ( $Q->{refresh} eq "" and $wantwidget ) { 
	$Q->{refresh} = $C->{widget_refresh_time};
}
elsif ( $Q->{refresh} eq "" and !$wantwidget ) { 
	$Q->{refresh} = $C->{page_refresh_time};
}
#--------------------------------------------------------
# setup common vars here.

# Find the kernel name
# used to identify 'tac -r' utility (ie) scroll log in reverse - latest entry is first displayed. 
my $kernel;
if (defined $C->{kernelname} and $C->{kernelname} ne "") {
	$kernel = $C->{kernelname};
} elsif ( $^O !~ /linux/i) {
	$kernel = $^O;
} else {
	chomp($kernel = lc `uname -s`);
}
#
# setup global vars
my $LL;		# global ref to conf/Logs.xxxx configuration file

### nmisdev 14Jul2012
# the node file is a hash, indexed by a name, which could be an arbitary name, an ip address, or a hostname, or a fqdn hostname.
# this hash also has two other 'name' type records, 
# name=> hostname, or fqdn hostname, or ip address
# host=>hostname, or fqdn hostname, or ip address
# the syslog record that we are parsing for nodename references, which could be a hostname, fqdn hostname, or ip address.
# Therefore, create a hash, keyed by name records, values being the node key.
## TBD - add the node sysName in here, as a log source address could be it's sysname.
my $NT = loadNodeTable();
my $NN;
foreach my $k ( keys %{$NT} ) {
	$NN->{ $NT->{$k}{name} } = $k;			# create reference to node file key in new hash by name
	$NN->{ $NT->{$k}{host} } = $k;			# create reference to node file key in new hash by host
	$NN->{ $k } = $k;										# create reference to node file key in new hash by node file key					
}

my $GT = loadGroupTable();
my $logFileName;						# this gets set to the full qualified filename in conf/Logs.xxxx config fiel

# defaults
my $logName = 'Event_Log';
if ( getbool($C->{server_master}) and $Q->{logname} eq "" ) {
	$logName = 'Slave_Event_Log';
}
elsif ($Q->{logname} ne "" ) {
	$logName = $Q->{logname};
}

my $logSort = defined $Q->{sort} ? $Q->{sort} : 'descending';
my $logLines =  defined $Q->{lines} ? $Q->{lines} : '50' ;
my $logLevel = defined $Q->{level} ? $Q->{level} : 'ALL';
my $logSearch = defined $Q->{search} ? $Q->{search} : '';
my $logGroup = defined $Q->{group} ? $Q->{group} : '';
my $logRefresh = defined $Q->{refresh} ? $Q->{refresh} : '';

# keep the requested value for filtering
my $logLevelRequest = $logLevel;

my $logLevelSummary = {
	fatal => 0,	
	critical => 0,	
	major => 0,	
	minor => 0,	
	warning => 0,	
	normal => 0,	
};

# read contents of conf/Logs.xxxx configuration files
# file is a hash of log names.
# numeric index so hash is auto sorted by userconfiguation
# if no pathname on {logFileName}, then add our root pathname
# else leave as path will point to log outside our dir space.
## capture the log name and file to parse here
	
$LL = loadTable(dir=>'conf',name=>'Logs');
# check each log entry for field 'file', and if no path, add the nmis log dir default path
foreach ( keys %{$LL} ) {
	$LL->{$_}{logFileName} = $C->{'<nmis_logs>'} .'/'. $LL->{$_}{logFileName} if $LL->{$_}{logFileName} !~ /\//;

	# find and store the FQ pathnamme of $logName in config hash 
	if ( lc $LL->{$_}{logName} eq lc $logName ) {
		$logFileName = $LL->{$_}{logFileName};
		$logName = $LL->{$_}{logName};
	}
}

# real work starts now
## set a default link href
# subst node search and level when used.
my $logLinkStart=qq|<a id="nmislogs" onclick="clickMenu(this);return false;" |.
								 qq|href="$C->{'<cgi_url_base>'}/logs.pl?conf=$Q->{conf}&act=log_file_view&logname=$logName&refresh=$logRefresh|.
								 qq|&node=&search=&level=&lines=$logLines&sort=$logSort&widget=$widget&group=$logGroup">|;
my $logLinkEnd=qq|</a>|;

print header($headeropts);

### 2012-08-29 keiths, adding wiget less support.
pageStart(title => "NMIS Log Viewer", refresh => $Q->{refresh}) 
		if (!$wantwidget);

if ($Q->{act} eq 'log_file_view') {
	return unless $AU->CheckAccess($logName); # based on group access
	logMenuBar();
	displayLogFile( loadLogFile($logFileName));

}
# nmisdev 2Jul2012 url for summary view of the current logfile.
# only run this for clearly delimited logfies.
elsif ($Q->{act} eq 'log_file_summary') {

	if ( lc $logName eq 'router_syslog' or  lc $logName eq 'switch_syslog' or lc $logName eq 'event_log' or lc $logName eq 'cisco_pix' or lc $logName eq 'nmis_log' ) {
		return unless $AU->CheckAccess($logName); # based on group access
		logMenuBar();
		logSummary( loadLogFile($logFileName));
	}
	else {
		logMenuBar();
	}
}
elsif ($Q->{act} eq 'log_list_view') {
	return unless $AU->CheckAccess('log_list');
	viewLogList();
}
else {
	notfound();
}

sub notfound {
	viewLogList();
	print "Log: ERROR, Request act=\'act=$Q->{act}\' invalid or logName=$logName not found<br>\n";
	print 'URL: ' . url(-path_info=>1,-query=>1);
}

### 2012-08-29 keiths, adding wiget less support.
pageEnd() if (!$wantwidget);

exit;
# ------------------------------------------------------
# menu of available logs from conf/Logs.xxxx_logs
# display 'UA' if log file not readable.

sub viewLogList {

	my @filestat;
	my $date;
	my $logFileSize;
	
	print start_table;
		#print Tr(td({class=>'header'},'Log List'));
		print	Tr(
						th({class=>'header',style=>'text-align:left'},'Name'),
						th({class=>'header',style=>'text-align:left'},'Description'),
						th({class=>'header',style=>'text-align:left'},'File'),
						th({class=>'header',style=>'text-align:center'},'Size'),
						th({class=>'header',style=>'text-align:center'},'Last Update')
					);
	
		foreach my $i (sort  keys %{$LL} )  {
			if ( $LL->{$i}{logFileName} ne '' and -r $LL->{$i}{logFileName} ) {
					@filestat = stat $LL->{$i}{logFileName};
					$logFileSize = $filestat[7] . ' bytes';
				$date = func::returnDateStamp($filestat[9]);
			}
			else { 
				$date = 'UA';
				$logFileSize = 'UA';
			}
			my $logLink;
			print Tr(
				td({class=>'info',style=>'text-align:left'},
								a({
								-href=>"$C->{'<cgi_url_base>'}/logs.pl?conf=$Q->{conf}&act=log_file_view&logname=$LL->{$i}{logName}&widget=$widget",
								-onclick=>"clickMenu(this);return false;"},
					 			$LL->{$i}{logName} 
								),
					),
				td({class=>'info',style=>'text-align:left'}, $LL->{$i}{logDescr}),
				td({class=>'info',style=>'text-align:left'},$LL->{$i}{logFileName}),
				td({class=>'info',style=>'text-align:center'},$logFileSize),
				td({class=>'info',style=>'text-align:center'},$date)
			);
		}
	print end_table;
}

#---------------------------------------------------
sub loadLogFile {
	my $file = shift;
	
	my $boolean;
	my $dosearch;
	my $search1;
	my $search2;
	my $search3;
	my $search4;
	my $search5;
	my @tmpsearch;
	my $switch;
	my @logRecords;
	my @logSplit;


 	# Open the logfile(s) in suffix (numbered) order, filter by $search and store in array, 
 	# then list array front to back, or back to front.
 	# set a limit here of table_lines, so we dont read file(s) for ever and ever, in case log directory is full of un-arcgived logs...
 	my $logMaxTableLines = $C->{'log_max_table_lines'} || 10000;
 	
	my $index=0;
	return if ! -r $file;		# no file

	if ( $logSearch eq "" ) { 
		$dosearch = "false"; 
		$boolean = "false";
	}
	elsif ( $logSearch =~ /\+/ ) {
		$boolean = "true";
		$switch = "and";
		($search1,$search2,$search3,$search4,$search5) = split(/\+/,$logSearch);
	}
	elsif ( $logSearch =~ /\|/ ) {
		$boolean = "true";
		$switch = "or";
		($search1,$search2,$search3,$search4,$search5) = split(/\|/,$logSearch);
	}

	# nmisdev  18Jun2012 - rescripted filelist.
	# added record counts for debug
	my $readLogNum;
	my $searchLogNum; 

	# get all files that match the glob '$file*'
	# $file includes full path as configured in Logs.xxxx, or derived from default path
	my $tac = "tac";
	my $zcat = "zcat -q";
	if ($kernel =~ /freebsd|tru64|solaris/i) { $tac = "tail -r"; }
	# if the 'tac' comand is referenced in Confg.xxxx, then use that
	if  ( defined $C->{'os_cmd_read_file_reverse'} and $C->{'os_cmd_read_file_reverse'} ne '' ) {
		$tac = $C->{'os_cmd_read_file_reverse'};
	}
	
	# build a list of files - sorted by numeric extension
	my	@fileList =  sort {
		($a =~ /^$file(?:\.(\d+))?(?:\.\w+)?$/)[0] <=> ($b =~ /^$file(?:\.(\d+))?(?:\.\w+)?$/)[0]
		||
		($a)  cmp  ($b) }
	<$file*>;

	foreach my $file ( @fileList ) {
		my $readLogFile = ($file =~ /\.gz/) ? "$zcat $file" : "$tac $file" ;
	
		open (DATA, "$readLogFile |") or warn returnTime." Log.pl, Cannot open the file $readLogFile $!\n";
		while (<DATA>) {
			chomp;
			$_ =~ s/  / /g;
			$readLogNum++;
	
			if ( getbool($boolean) && $switch eq "and" ) {
				if ( 	$_ =~ /$search1/i and
				$_ =~ /$search2/i and
				$_ =~ /$search3/i and
				$_ =~ /$search4/i and
				$_ =~ /$search5/i
				) {
					push @logRecords, $_ ;
					last if scalar @logRecords >= $logMaxTableLines;
					$searchLogNum++;
				}
			}
			if ( getbool($boolean) && $switch eq "or" ) {
				if ( 	$_ =~ /$search1/i or
				$_ =~ /$search2/i or
				$_ =~ /$search3/i or
				$_ =~ /$search4/i or
				$_ =~ /$search5/i
				) {
					push @logRecords, $_ ;
					last if scalar @logRecords >= $logMaxTableLines;
					$searchLogNum++;
				}
			}
			elsif ( getbool($dosearch,"invert") ) {
				push @logRecords, $_ ;
				last if scalar @logRecords >= $logMaxTableLines;
			}
			elsif ( $_ =~ /$logSearch/i ) {
				push @logRecords, $_;
				last if scalar @logRecords >= $logMaxTableLines;
				$searchLogNum++;
			}
		}
		close(DATA);
	} # next file in @fileList
	
	# nmisdev 18Jun2012 inform user if no log records found.
	if ( ! scalar @logRecords ) {
			print "No records found to print for request url:<br>" . url(-path_info=>1,-query=>1);
	}
		# print a debug message
	if ( $Q->{debug} ) {
		my $plist =  join( '<br>', @fileList);
		$searchLogNum = $searchLogNum || '0' ;
		$readLogNum = $readLogNum || '0' ;
		print 'URL:' . url(-path_info=>1,-query=>1) . '<br>';
		print "Read $readLogNum records from files<br>$plist<br>search $logSearch matched $searchLogNum records<br>" . scalar @logRecords . " records for scanning\n"; 
	}

	return \@logRecords;
}
	
#--------------------------------------------
# nmisdev 18Jun2012 use a ref to the list of records, dont copy.
# we count the number of printed lines here
# we have to place all in a list, so we can list acsending or descending.
 
sub displayLogFile {
	my $logRefTable = shift;

	my $numlines;
	my $logPrint;

	return if ref($logRefTable) ne 'ARRAY' or scalar @$logRefTable <= 0;				# handle the zero length file
	print start_table({class=>'tablelog'});
	$numlines = $logLines;				# save the number of lines we are supposed to print
	
	if ( $logSort =~ /Ascending/i) {
		while ( scalar @$logRefTable && $numlines-- > 0 ) {
			$logPrint++ if outputLine( pop @$logRefTable );
		}
	}
	# Must be descending or default
	else {
			while ( scalar @$logRefTable && $numlines-- > 0 ) {
			$logPrint++ if outputLine( shift @$logRefTable );
		}
	}
	print end_table;
	
	## check the criticality summary and decide which audio to play
	my $sound = undef;
	my @sound_levels = split(",",$C->{sound_levels});
	foreach my $level (@sound_levels) {
		print STDERR "DEBUG SOUND: $level logLevelSummary=$logLevelSummary->{$level}\n";
		if ( $C->{"sound_$level"} and $logLevelSummary->{$level} ) {
			$sound = $C->{"sound_$level"};
			last;
		}
	}
	
	print qq|
<audio autoplay>
  <source src="$sound" type="$C->{sound_type}">
  Your browser does not support the audio element.
</audio>
| if $sound;
}

# --------------------------------------------
# 
sub outputLine {
	my $line = shift;
	
	my $outage;
	my $tics;
	
	my $color;
	my $claimed_hostname;
	my @logSplit;
	
	my $logServer;
	my $logEvent;
	my $logEventLinkStart;
	my $logEventLinkEnd;
	my $logEventLink;
	
	my $logLevelLinkStart;
	my $logLevelLinkEnd;
	my $logLevelLink;
	
	my $logNode;
	my $logNodeLinkStart;
	my $logNodeLinkEnd;
	my $logNodeLink;
	
	my $logPixLinkStart;
	my $logPixLinkEnd;
	my $logPixLink;
	my $logPixHostAddr;
	
	### 2012-08-29 keiths, added sub globals
	my $logElement;
	my $logDetails;
	my $logTime;
	
	my $logLevelText = "Unknown";
	
	my $buttons;
	my $logNodeButton;
	
	my $ipaddr;
	my $pos;
	
	

	# ==================================================================================
	### cisco log
	### Nov 28 04:01:25 c2950-1 20548: 020661: Nov 27 04:01:24.521 NZDT: %CDP-4-NATIVE_VLAN_MISMATCH: Native VLAN mismatch discovered on FastEthernet0/24 (30), with core3550 FastEthernet0/24 (1).
	###	0		1		2					3			4				5				6		7	8						9				10													11->
	if ( lc $logName eq 'router_syslog' or  lc $logName eq 'switch_syslog' ) { 

		my $gotEvent = 0;
		@logSplit = split " ", $line, 12 ;	# get up to the syslog key %CDP-4-...... etc
		($logEvent = $logSplit[10]) =~ s/^%|:$//g;		# drop the leading '%' and trailing ':'
		### set the log level in the URL if we have a syslog severity level
		if ( $logEvent =~ m/-(\d+)-/ ) {
			$logLevelText = eventLevelSet($1);
			$gotEvent = 1;
		}
		else {
			my @logParts = [];
			my @logBits = [];
			@logParts = split("%",$line);
			if ( @logParts ) {
				@logBits = split(":",$logParts[1]);
				if ( @logBits ) {
					$logEvent = $logBits[0];
					$gotEvent = 1;
					if ( $logEvent =~ m/-(\d+)-/ ) {
						$logLevelText = eventLevelSet($1);
					}
				}
			}
		}

		++$logLevelSummary->{lc($logLevelText)};
				
		#if ( $logEvent =~ m/-(\d+)-/ ) {
		if ( $gotEvent ) {
			my $urlsafeevent = uri_escape($logEvent);
			($logEventLinkStart = $logLinkStart) =~ s/&search=/&search=$urlsafeevent/;
			$logEventLinkStart =~ s/&level=/&level=$logLevelText/;

			$logEventLink=$logEventLinkStart.$logEvent.$logLinkEnd;
			# update line
			$line =~ s/$logEvent/$logEventLink/;
		}			

		# use the node name hash we setup to find the node record.
		# if not indexed, then the syslog nodename is not current, so dont provide a href
		if ( exists $NN->{$logSplit[3]} and defined $NN->{$logSplit[3]} ) {
			$logNode = $NN->{$logSplit[3]};
			my $urlsafelognode = uri_escape($logNode);
			($logNodeLinkStart = $logLinkStart) =~ s/&search=/&search=$urlsafelognode/;		# dont clobber the template logLinkStart.
			$logNodeLinkStart =~ s/&level=/&level=$logLevelText/g;
			$logNodeLinkStart =~ s/&node=/&node=$urlsafelognode/g ;
			$logNodeLink=$logNodeLinkStart.$logNode.$logLinkEnd;
			# update line
			$line =~ s/$logSplit[3]/$logNodeLink/;
					
			my $id = qq|node_view_$logNode|;
			my $logNodeButton=qq|<a id="$id" onclick="clickMenu(this);return false;" |.
			qq|href="$C->{network}?conf=$Q->{conf}&act=network_node_view|.
			qq|&refresh=$C->{widget_refresh_time}&widget=$widget&node=$urlsafelognode">|.
			qq|<img alt="NMIS" src="$C->{nmis_icon}" border="0"></a>|;
			
			$buttons=
			"<a href=\"$C->{admin}?tool=ping&node=$urlsafelognode\"><img alt=\"ping $logNode\" src=\"$C->{ping_icon}\" border=\"0\"></a>".
			"<a href=\"$C->{admin}?tool=trace&node=$urlsafelognode\"><img alt=\"traceroute $logNode\" src=\"$C->{trace_icon}\" border=\"0\"></a>".
			"<a href=\"telnet://$logNode\"><img alt=\"telnet to $logNode\" src=\"$C->{telnet_icon}\" border=0 align=top></a>";
			
			if ( getbool($C->{node_button_in_logs}) ) {
				#prepend nodebut!
				$line = "$logNodeButton $line";
				}
				if ( getbool($C->{buttons_in_logs}) ) {
				#prepend buttons!
				$line = "$buttons $line";
			}
		}	# end if valid node name
		
	} # elsif cisco.log
	# -----------------------------------------------------------------------------
	# Cisco_PIX
	#
	# Nov 14 04:02:12 pix501 %PIX-4-106023: Deny udp src outside:68.57.138.5/49283 dst inside:192.168.1.254/2424 by access-group "100"
	#		0  1     2      3        4           5 ->
	elsif ( lc $logName eq 'cisco_pix' ) { 
	

		@logSplit = split " ", $line, 6 ;	# get up to the syslog key %CDP-4-...... etc
		($logEvent = $logSplit[4]) =~ s/^%|:$//g;		# drop the leading '%' and trailing ':'

		### set the log level in the URL if we have a syslog severity level
		if ( $logEvent =~ m/-(\d+)-/ ) {
			$logLevelText = eventLevelSet($1);
			my $urlsafeevent = uri_escape($logEvent);
			($logEventLinkStart = $logLinkStart) =~ s/&search=/&search=$urlsafeevent/;
			$logEventLinkStart =~ s/&level=/&level=$logLevelText/;

			$logEventLink=$logEventLinkStart.$logEvent.$logLinkEnd;
			# update line
			$line =~ s/$logEvent/$logEventLink/;
		}	
		
		# add a search link to any host address that we might find
		while (  $logSplit[5]  =~ m/(\d+\.\d+\.\d+\.\d+)/g ) {
			$logPixHostAddr = $1;
			($logPixLinkStart = $logLinkStart) =~ s/&search=/&search=$logPixHostAddr/;		# dont clobber the template logLinkStart.
			$logPixLinkStart =~ s/&level=/&level=ALL/;																		# reset the level

			$logPixLink=$logPixLinkStart.$logPixHostAddr.$logLinkEnd;
			# update line
			$line =~ s/$logPixHostAddr/$logPixLink/;
		}
		
				

		# use the node name hash we setup to find the node record.
		# if not indexed, then the syslog nodename is not current, so dont provide a href
		if ( exists $NN->{$logSplit[3]} and defined $NN->{$logSplit[3]} ) {
			$logNode = $NN->{$logSplit[3]};
			my $urlsafelognode = uri_escape($logNode);
			($logNodeLinkStart = $logLinkStart) =~ s/&search=/&search=$urlsafelognode/;		# dont clobber the template logLinkStart.
			$logNodeLinkStart =~ s/&level=/&level=$logLevelText/g;
			$logNodeLinkStart =~ s/&node=/&node=$urlsafelognode/g ;
			$logNodeLink=$logNodeLinkStart.$logNode.$logLinkEnd;
			# update line
			$line =~ s/$logSplit[3]/$logNodeLink/;
					
			my $id = qq|node_view_$logNode|;
			my $logNodeButton=qq|<a id="$id" onclick="clickMenu(this);return false;" |.
			qq|href="$C->{network}?conf=$Q->{conf}&act=network_node_view|.
			qq|&refresh=$C->{widget_refresh_time}&widget=$widget&node=$urlsafelognode">|.
			qq|<img alt="NMIS" src="$C->{nmis_icon}" border="0"></a>|;
			
			$buttons=
			"<a href=\"$C->{admin}?tool=ping&node=$urlsafelognode\"><img alt=\"ping $logNode\" src=\"$C->{ping_icon}\" border=\"0\"></a>".
			"<a href=\"$C->{admin}?tool=trace&node=$urlsafelognode\"><img alt=\"traceroute $logNode\" src=\"$C->{trace_icon}\" border=\"0\"></a>".
			"<a href=\"telnet://$logNode\"><img alt=\"telnet to $logNode\" src=\"$C->{telnet_icon}\" border=0 align=top></a>";
			
			if ( getbool($C->{node_button_in_logs}) ) {
				#prepend nodebut!
				$line = "$logNodeButton $line";
				}
				if ( getbool($C->{buttons_in_logs}) ) {
				#prepend buttons!
				$line = "$buttons $line";
			}
		}	# end if valid node name

		
	} # end Cisco_PIX
	
	# ------------------------------------------------------------------------------
	## event log
	### 1342256707,localhost,Node Reset,Warning,,Old_sysUpTime=3:09:53 New_sysUpTime=0:04:01
	## slave event log
	### Feb  6 15:45:22 localhost nmis.pl[31797]: NMIS_Event::nmisdev64.dev.opmantek.com::1360129513,meatball,Proactive Interface Input Utilisation,Major,Dialer1,Value=84.88, Threshold=80
	elsif ( lc $logName eq "event_log" or lc $logName eq "slave_event_log" ) {
		if ( lc $logName eq "slave_event_log" and $line =~ /NMIS_Event::([\w\.\-]+)::(.*)/) {	
			$logServer = $1;
			$line = $2;
		}
		else {
			$logServer = "";
		}

		$line =~ s/, /,/g;			
		($logTime,$logNode,$logEvent,$logLevel,$logElement,$logDetails) = split( /,/, $line, 6 );

		#Check the date format and if it doesn't have a - then it is UNIX format
		if ( $logTime !~ /-/ ) { 
			$logTime = returnDateStamp($logTime);
		}
	
		# If the line has ' Time=' in it, convert to Outage Time
		my $outage='';
		my $tics='';
		
		if ( $logDetails =~ /\s+Time=(\d+:\d+:\d+)/i ) {
			$outage = "Event Time=$1";
		}
		if ( $logDetails =~ /\s+tics=(\d+:\d+:\d+)/i  ) {
			$tics = "Planned Outage TICS=$1";
		}

		### 2014-08-27 keiths, do the log Details include a URL to convert into a hyperlink.
		### setting the target to the URL so it goes to different windows depending on the link
		if ( $logDetails =~ /(http:\/\/|https:\/\/)/  ) {
			my @bits = split(" ",$logDetails);
			my @newBits;
			for (my $b = 0; $b <= $#bits; ++$b) {
				if ( $bits[$b] =~ /(^http:\/\/|^https:\/\/)/ ) {
					if ( $bits[$b] =~ /:$/ ) {
						$bits[$b] =~ s/:$//; 
					}
					my $linkName = $bits[$b];
					if ( $linkName =~ "/omk/opTrend" ) {
						$linkName = "opTrend Exception Details";
					}
					$bits[$b] = "<a href=\'$bits[$b]\' target=\'$bits[$b]\'>$linkName</a>:";
				}
			}
			$logDetails = join(" ",@bits);
		}

		# use the node name hash we setup to find the node record.
		# if not indexed, then the syslog nodename is not current, so dont provide a href
		$logLevelText = eventLevelSet($logLevel);
		
		++$logLevelSummary->{lc($logLevel)};
		
		if ( $logServer ) {
			$logServer = " :: $logServer";
		}
		
		if ( exists $NN->{$logNode} and defined $NN->{$logNode} ) {
			$logNode = $NN->{$logNode};
			my $urlsafelognode = uri_escape($logNode);
			
			($logNodeLinkStart = $logLinkStart) =~ s/&search=/&search=$urlsafelognode/;
			$logNodeLinkStart =~ s/&level=/&level=ALL/;
			$logNodeLink=$logNodeLinkStart.$logNode.$logLinkEnd;

			my $urlsafeevent = uri_escape($logEvent);						
			($logEventLinkStart = $logLinkStart) =~ s/&search=/&search=$urlsafeevent/;
			$logEventLinkStart =~ s/&level=/&level=ALL/;
			$logEventLink=$logEventLinkStart.$logEvent.$logLinkEnd;
			
			($logLevelLinkStart = $logLinkStart) =~ s/&level=/&level=$logLevel/;
			$logLevelLink=$logLevelLinkStart.$logLevel.$logLinkEnd;

			my $id = qq|node_view_$logNode|;
			
			# set up the leading buttons
			my $logNodeButton=qq|<a id="$id" onclick="clickMenu(this);return false;" |.
												qq|href="$C->{network}?conf=$Q->{conf}&act=network_node_view|.
												qq|&refresh=$C->{widget_refresh_time}&widget=$widget&node=$urlsafelognode">|.
												qq|<img alt="NMIS" src="$C->{nmis_icon}" border="0"></a>|;
			
			if ( getbool($C->{node_button_in_logs}) ) {
				$line = "$logNodeButton $logTime $logNodeLink $logEventLink $logLevelLink $logElement $logDetails$logServer";
			}
			elsif ( getbool($C->{buttons_in_logs}) ) {
				$buttons =
					"<a href=\"$C->{admin}?tool=ping&node=$urlsafelognode\"><img alt=\"ping $logNode\" src=\"$C->{ping_icon}\" border=\"0\"></a>".
					"<a href=\"$C->{admin}?tool=trace&node=$urlsafelognode\"><img alt=\"traceroute $logNode\" src=\"$C->{trace_icon}\" border=\"0\"></a>".
					"<a href=\"telnet://$logNode\"><img alt=\"telnet to $logNode\" src=\"$C->{telnet_icon}\" border=0 align=top></a>";
				$line = "$buttons $logNodeButton $logTime $logNodeLink $logEventLink $logLevelLink $logElement $logDetails$logServer";		
			}
			else {
				$line = "$logTime $logNodeLink $logEventLink $logLevelLink $logElement $logDetails$logServer";
			}
			if ( $logNodeLink eq "" and $logEventLink eq "" ) {
				$line = "$logTime $logNode $logEvent $logLevel $logElement $logDetails$logServer";
			}
			$logLevelText = $logLevel;
		}
		else {
			$line = "$logTime $logNode $logEvent $logLevel $logElement $logDetails$logServer";
			$logLevelText = 'Normal';
		}
	} # if event.log
	# --------------------------------------------------------------------------------------
	## nmis log

	## 16-Jul-2012 00:37:25,network.pl::viewNode#844Sys::init#105func::loadTable#831<br>
	### ERROR file does not exist dir=var name=192.168.1.234-node, nmis_var=/mnt/hgfs/Master/nmis8/var nmis_conf=/mnt/hgfs/Master/nmis8/conf
	elsif ( lc $logName eq 'nmis_log') {
		
		$line =~ s/\Q<br>\E/,/g ;
		$line =~ s/, /,/g;	
		@logSplit = split( ',', $line, 3 );		# no more than 3 splits
		
 
		$line = "$logSplit[0] $logSplit[1] $logSplit[2]";

		$logLevelText = 'Unknown';
		
	} # elsif nmis.log 
	#5-Jun-2013 07:06:41,nmiscgi.pl#97Auth::loginout#1208Auth::verify_id#333<br>verify_id: cookie not defined
	#5-Jun-2013 07:07:53,nmiscgi.pl#97Auth::loginout#1197<br>user=nmis logged in with config=
	#5-Jun-2013 07:07:56,logs.pl#223Auth::CheckAccess#234<br>CheckAccessCmd: nmis, Event_Log, 1
	elsif ( lc $logName eq 'auth_log') {
		$line =~ s/\Q<br>\E/, /g;
		$logLevelText = 'Unknown';
	} # elsif nmis.log 	
	# ------------------------------------------------------------------------------
	# no match on log type
	else {
		$logLevelText = 'ALL';
	}
	# --------------------------------------------------------------
	# Remove the comma's from the line
	$line =~ s/,/ /g if lc $logName ne 'auth_log';	

	# print STDERR "DEBUG LOGS: auth=$auth lnode=$lnode group=$NT->{$lnode}{group}";
		
	# nmisdev 4Jul2012 - refactored.	
	# if any test fails, then dont print the line.
	# Rule 1: only print lines that match selected $logLevel syslog levels 1-7, or 'ALL' by default

	if ( lc $logLevelRequest ne 'all' and lc $logLevelRequest ne lc $logLevelText ) { return 0 }
	
	### 2012-08-29 keiths, enabling group filtering
	# Rule 2: only print lines that match selected Group
	if ( $logGroup ne "" and $NT->{$logNode}{group} ne $logGroup ) { return 0 }
	
	### 2012-08-29 keiths, enabling Authentication if group not blank
	# Rule 3: if Authentication enabled, only print if user enabled for select Group
	if ( $NT->{$logNode}{group} ne "" and $AU->Require and not $AU->InGroup($NT->{$logNode}{group}) ) { return 0 }
	
	if ( getbool($C->{syslogDNSptr}) and (lc $logName eq "cisco_syslog")) {
		# have a go at finding out the hostname for any ip address that may have been referenced in the log.
		# assumes we have populated our DNS with lots of PTR records !
		my $i = 3;				# put a failsafe loop counter in here !
		while ( $line =~ /(\d+\.\d+\.\d+\.\d+)/g && $i-- != 0 ) {
			$pos = pos($line);				# need to save where we are, so we start the next match from here.
			$ipaddr = inet_aton($1);			# matched string of x.x.x.x
			if ($claimed_hostname = gethostbyaddr($ipaddr, AF_INET)) {
				($claimed_hostname) = split /\./ , $claimed_hostname;	# get the hostname portion
				substr( $line, $pos, 0 ) = " [".$claimed_hostname."] ";	# this will mess the /g match position
				pos($line)=$pos;				# so reset it to make sure we move to the next match
			}
		}
	} # end of name lookup
	
	# now print it
	my $logColor = logRFCColor($logLevelText);
	#print Tr(td({class=>"$logLevelText", style=>"background-color:$logColor;"}, $line));
	print Tr(td({class=>"$logLevelText"}, $line));

	return 1;				# return print status so we can count the actual printed lines
} # end outputLine

# ------------------------------------------

sub logMenuBar {

	# nmisdev 24 Aug 2012 revised
	# nmisdev 28Jun2012 rewrote
	# form enclose's table.
	# name of form must be different to dialog id
	# dialogID saved in <input hidden name=formID, value=formID ( keep all logs as same widget ID, so all logs go to same window
	# formID should really be renamed to dialogID.
	# added summary link
	
	### 2012-08-29 keiths, adding wiget less support
	my $startform = start_form({ action=>"javascript:get('nmislogform1');", -id=>'nmislogform1',
			-href=>"$C->{'<cgi_url_base>'}/logs.pl?"});
	if ( !$wantwidget ) {
		$startform = start_form({ method=>"get", -id=>'nmislogform1',
			action=>"$C->{'<cgi_url_base>'}/logs.pl"});
	}

	### 2012-08-29 keiths, adding wiget less support
	my $submit = submit(-name=>'nmislogform1', -value=>'Go', onClick=>"javascript:get('nmislogform1'); return false;");
	if ( !$wantwidget ) {
		$submit = submit(-name=>'nmislogform1', -value=>'Go');
	}

	print $startform,
		start_table(),
		Tr(
			th({class=>'header'},'Log Name',
				popup_menu(-name=>'logname', -override=>'1',
					-values=> [ map  $LL->{$_}{logName}, sort { $LL->{$a}{logOrder} <=> $LL->{$b}{logOrder} } keys %{$LL} ] ,
					-default=>$logName)),
			th({class=>'header'},'Search String',
				textfield(-name=>'search',size=>'15')),
			th({class=>'header'},'Lines',
				popup_menu(-name=>'lines', 
					-values=>[qw(15 25 50 100 250 500 1000 5000 10000 25000)],
					-default=>$logLines)),
			th({class=>'header'},'Level',
				popup_menu(-name=>'level', -override=>'1',
					-values=>['', qw(ALL Normal Error Warning Minor Major Critical Fatal Unknown)],
					-default=>$logLevel)),
			th({class=>'header'},'Sort',
				popup_menu(-name=>'sort', -override=>'1',
					-values=>['', qw(Descending Ascending)],
					-default=>$logSort)),
			th({class=>'header'},'Group',
				popup_menu(-name=>'group', -override=>'1',
					-values=>['', sort keys %{$GT}],
					-default=>$logGroup)
				),
			th({class=>'header'},
				$submit,
				hidden(-name=>'refresh', -default=>"$C->{widget_refresh_time}",-override=>'1'),
				hidden(-name=>'conf', -value=>$Q->{conf}),
				hidden(-name=>'act', -value=>"log_file_view",-override=>'1'),
				hidden(-name=>'widget', -value=>"$widget",-override=>'1'),
				hidden(-name=>'formID', -value=>'log_file_view')
				),
			),
		# now display on anewline, the links for setting the number of lines rq, and also filtering by Severity ( RFC syslog )
		Tr(
			th({class=>'header', colspan=>'4'},
			 			'Lines:&nbsp;',
			 		 ( 
						map { my $k = $_;
							a({
								-href=>"$C->{'<cgi_url_base>'}/logs.pl?conf=$Q->{conf}&act=log_file_view&logname=$logName&lines=$k&level=$logLevel&search=".uri_escape($logSearch)."&sort=$logSort&widget=$widget&group=$logGroup",
								-onclick=>"clickMenu(this);return false;"},
					 			$k 
								)
							} ('15','25','50','100','250','500','1000'  ) 
						),
						# follow up with the RFC levels
					 '&nbsp;&nbsp;Level:&nbsp;',
					 (
						map { my $k = $_;
									my $txtColor = logRFCColor($k);
							a({
								-href=>"$C->{'<cgi_url_base>'}/logs.pl?conf=$Q->{conf}&act=log_file_view&logname=$logName&level=$k&lines=$logLines&search=".uri_escape($logSearch)."&sort=$logSort&widget=$widget&group=$logGroup",
								-onclick=>"clickMenu(this);return false;", -style=>"color:$txtColor;"},
								$k 
							)
						} ('ALL','Fatal','Critical','Major','Minor','Warning','Error','Normal','Unknown' )
					)	,
				),
				th({class=>'header', colspan=>'1', style=>'text-align:left;'},
				a({
					-href=>"$C->{'<cgi_url_base>'}/logs.pl?conf=$Q->{conf}&act=log_file_summary&widget=$widget&logname=$logName",
					-onclick=>"clickMenu(this);return false;"},
					'Summary'),
				),
				# for completeness, toss in a link to the log list view.
				th({class=>'header', colspan=>'2', style=>'text-align:left'},
				a({
					-href=>"$C->{'<cgi_url_base>'}/logs.pl?conf=$Q->{conf}&act=log_list_view&widget=$widget",
					-onclick=>"clickMenu(this);return false;"},
					'Log List'),
				),
			),	# end_Tr,
			end_table;	
			end_form,
}


# --------------------------------------------------------------------
# NMIS colorised eventlevels map as follows to RFC syslog
# 0 fatal 		RFC emergencies 0
# 1 critical	RFC alerts		1
# 2 major		RFC critical	2
# 3 minor		RFC errors		3
# 4 warnings	RFC warnings	4
# 5 error		RFC notifications 5
# 6 normal		RFC informational 6
# 7 unknown		RFC debugging	7

sub logRFCColor {

	my %RFC = ( 'ALL' => '7',
		'Fatal' => '0.5',
		'Critical' => '1',
		'Major' => '1.8',
		'Minor' => '2.5',
		'Warning' => '2.8',
		'Error' => '3.0',
		'Normal' => '7',
		'Unknown' => '7'
	);
	return colorPercentHi( (100/7)*$RFC{$_[0]} );
}




# ------------------------------------------------------------------
# nmisdev 3Jul2012 rewrote for NMIS8

sub logSummary {
	
	my $logRefTable = shift;
	return if scalar @$logRefTable <= 0;				# handle the zero length file
	

	my %logSum;
	my $logEvent;
	my $logEventTrimmed;
	my $logNode;
	my @logSplit;
	
	foreach my $line ( @$logRefTable ) {
		
		if  (  lc $logName eq 'cisco_pix' ) {
			@logSplit = split " ", $line, 6 ;	# get up to the syslog key %CDP-4-...... etc
			($logEvent = $logSplit[4]) =~ s/^%|:$//g;		# drop the leading '%' and trailing ':'
	
			if ( $logEvent =~ m/-(\d+)-/ ) {
				# use the node name hash we setup to find the node record.
				# if not indexed, then the syslog nodename is not current, so dont provide a href

				if ( exists $NN->{$logSplit[3]} and defined $NN->{$logSplit[3]} ) {
					$logNode = $NN->{$logSplit[3]};
				}
				#			next unless $user->InGroup($NMIS::nodeTable{$logNode}{group});
	
				# fill in the hash table for printing
				$logSum{"Header"}{$logEvent} = 1;
				$logSum{$logNode}{$logEvent} += 1;
			}
		}
		# end summary for Cisco pix
		# --------------------------------------------------------------
		elsif  (  lc $logName eq 'router_syslog' or lc $logName eq 'switch_syslog'  ) {
			
			@logSplit = split " ", $line, 12 ;	# get up to the syslog key %CDP-4-...... etc
			($logEvent = $logSplit[10]) =~ s/^%|:$//g;		# drop the leading '%' and trailing ':'

				if ( $logEvent =~ m/-(\d+)-/ ) {
				# use the node name hash we setup to find the node record.
				# if not indexed, then the syslog nodename is not current, so dont provide a href

				if ( exists $NN->{$logSplit[3]} and defined $NN->{$logSplit[3]} ) {
					$logNode = $NN->{$logSplit[3]};
				}
				#			next unless $user->InGroup($NMIS::nodeTable{$logNode}{group});
	
				# fill in the hash table for printing
				$logSum{"Header"}{$logEvent} = 1;
				$logSum{$logNode}{$logEvent} += 1;
			}
		}
		# end summary for Cisco router/switch
		#
		# event_log
		elsif ( lc $logName eq "event_log" ) {

			$line =~ s/, /,/g;
			@logSplit = split /,/, $line , 4;
			($logEvent = $logSplit[2]) =~ s/^%|:$//g;		# drop the leading '%' and trailing ':'
	
			# trim the event down to the first 4 keywords or less.
			my ($t0, $t1, $t2, $t3, $t4) = split / / , $logEvent, 5 ;
			$logEventTrimmed = "$t0 $t1 $t2 $t3";
	
			# to square off the hash, capture all possible events
			$logSum{"Header"}{$logEventTrimmed} = 1;
			$logSum{$logSplit[1]}{$logEventTrimmed} += 1;
		} # end eventlogsummary
		
		# NMIS Log
		elsif ( lc $logName eq 'nmis_log') {
			
			$line =~ s/\Q<br>\E/,/g ;
			$line =~ s/, /,/g;	
			@logSplit = split( ',', $line, 3 );		# no more than 3 splits
			my $script;
			my $module;
			if ( $logSplit[1] =~ m/^(.+?)::(.*)/ ) {
				$script = $1;
				$module = $2;
			}
			elsif ( $logSplit[1] =~ m/^(.*)\#(.*)/ ) {
				$script = $1;
				$module = $2;
			}
			
			$logSum{"Header"}{$module} = 1;
			$logSum{$script}{$module} += 1;
 
		} # elsif nmis.log
		 
	} # end foreach
	#print what we got - header table first
	print "<table>";
	print "<tr>";
	print "<th class='header'>Nodename</th>";

	for my $event ( sort keys %{ $logSum{"Header"} } ) {
		$event =~ s/_|(?:\:\:)|\#/-/g;			# subst all '_', '::', '#' for hyphen, so browser will wrap text in header columns
		print "<th class='header'>$event</th>";
	}
	print "</tr>";

	for my $index ( sort keys %logSum ) { 
		next if $index eq "Header"; # kill the header
##		next unless $AU->InGroup($NT->{$index}{group});
		print "<tr>";
		print qq|<th class="info"><a onclick="clickMenu(this);return false;" href="$C->{'<cgi_url_base>'}/logs.pl?conf=$Q->{conf}&act=log_file_view&logname=$logName&widget=$widget&search=$index">$index</a></th>|;

   	for my $event ( sort keys %{ $logSum{"Header"} } ) {
			my $urlsafeevent = uri_escape($event);
			if ( $logSum{$index}{$event} ) { print qq|<th class="info"><a onclick="clickMenu(this);return false;" href="$C->{'<cgi_url_base>'}/logs.pl?conf=$Q->{conf}&act=log_file_view&logname=$logName&widget=$widget&search=$urlsafeevent&lines=$logSum{$index}{$event}">$logSum{$index}{$event}</a></th>|;
			}
			else { print "<th class='info'>&nbsp;</th>";} 
		}
		print "</tr>";
	}
	print "</table>";
}

# new format log file
# here for copy and use, if reqired.
# template configuration file /install/Logs.xxxx and working file /conf/Logs.xxxx should match this new format.
# 2012-07-19 nmisdev added a numerical index to keep order on displayed log files
#
# %hash = (
# 
#   '5' => {
#    'logFileName' => 'ciscopix.log',
#    'logName' => 'Cisco_PIX',
#    'logDescr' => 'Cisco PIX-ASA Firewall Syslog [local2]'
#  },
#   '7' => {
#    'logFileName' => '/var/log/messages',
#    'logName' => 'Messages',
#    'logDescr' => 'Messages'
#  },
#  '2' => {
#    'logFileName' => 'event.log',
#    'logName' => 'Event_Log',
#    'logDescr' => 'Event Log'
#  },
#  '1' => {
#    'logFileName' => 'nmis.log',
#    'logName' => 'NMIS_Log',
#    'logDescr' => 'NMIS Log'
#  },
#  '9' => {
#    'logFileName' => '/var/log/httpd/error_log',
#    'logName' => 'Apache_Error_Log',
#    'logDescr' => 'Apache Error Log'
#  },
#  '8' => {
#    'logFileName' => '/var/log/httpd/access_log',
#    'logName' => 'Apache_Access_Log',
#    'logDescr' => 'Apache Access Log'
#  },
#  '3' => {
#    'logFileName' => 'cisco.log',
#    'logName' => 'Router_Syslog',
#    'logDescr' => 'Router Syslog [local1]'
#  },
#   '4' => {
#    'logFileName' => 'switch.log',
#    'logName' => 'Switch_Syslog',
#    'logDescr' => 'Switch Syslog [local3]'
#  },
#     '6' => {
#    'logFileName' => 'unclassified.log',
#    'logName' => 'Generic_Syslog',
#    'logDescr' => 'Generic Device Syslog [local7 default]'
#  }
#);
