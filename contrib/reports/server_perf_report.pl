#!/usr/bin/perl
#
## $Id: server_perf_report.pl,v 2.0.0 2022/12/15 15:20:00 dougr Exp $
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
# *****************************************************************************

use strict;
our $VERSION = "2.0.0";

use FindBin;
use Cwd 'abs_path';
use lib abs_path("$FindBin::Bin/../../lib");

use POSIX qw();
use Compat::NMIS;
use Compat::Timing;
use Data::Dumper;
use DateTime;
use Excel::Writer::XLSX;
use File::Basename;
use File::Path;
use Getopt::Long;
use MIME::Entity;
use NMISNG::Sys;
use NMISNG::Util;
use Term::ReadKey;
use Text::Abbrev;

# this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX), also the stat modes
use Fcntl qw(:DEFAULT :flock :mode);
use Errno qw(EAGAIN ESRCH EPERM);

my $PROGNAME      = basename($0);
my $debugsw       = 0;
my $exceptionssw  = 0;
my $helpsw        = 0;
my $tsEnd         = 0;
my $tsStart       = 0;
my $usagesw       = 0;
my $versionsw     = 0;
my $defaultConf   = abs_path("$FindBin::Bin/../../conf");
my $dfltPeriod    = 'day';
my $dfltTimespan  = '24hours';
my $beginTimespan = "00";
my $endTimespan   = "24";
my $xlsFile       = "server_perf_report.xlsx";
my $xlsPath       = "server_perf_report.xlsx";
my %nodeIndex;
my %nodeData;
my @SUMMARY;
my @tsEndArray    = ();
my @tsStartArray  = ();

$defaultConf = "$FindBin::Bin/../conf" if (! -d $defaultConf);
$defaultConf = abs_path($defaultConf);
die unless (GetOptions('debug:i'    => \$debugsw,
                       'exceptions' => \$exceptionssw,
                       'help'       => \$helpsw,
                       'usage'      => \$usagesw,
                       'version'    => \$versionsw));

# For the Version mode, just print it and exit.
printSum("$PROGNAME Server Performance Reports, version $VERSION");

if (${versionsw}) {
	print "$PROGNAME NMIS version $NMISNG::VERSION\n";
	exit (0);
}
if ($helpsw) {
   help();
   exit(0);
}

# Variables for command line munging
my $arg = NMISNG::Util::get_args_multi(@ARGV);

if ($usagesw) {
   usage();
   exit(0);
}

print "$PROGNAME Default Configuration directory is '$defaultConf'\n";


# Set debugging level.
my $debug   = $debugsw;
$debug      = NMISNG::Util::getdebug_cli($arg->{debug}) if (exists($arg->{debug}));   # Backwards compatibility
print "Debug = '$debug'\n" if ($debug);
my $exceptions   = $exceptionssw;
$exceptions = NMISNG::Util::getbool_cli($arg->{exceptions}) if (exists($arg->{exceptions}));   # Backwards compatibility

# For group filtering
my $group  = $arg->{group} || "";
	
# For exception filtering
my $filter = $arg->{filter} || "";
	
my $t = Compat::Timing->new();

# Set Directory level.
if ( not defined $arg->{dir} ) {
	print "FATAL The directory argument is required!\n";
	help();
	exit 255;
}
my $dir = abs_path($arg->{dir});

# [period=<day|week|month>] (default: 'day')
my $period   = $dfltPeriod;
my $lcPeriod = lc($period);
$lcPeriod    = lc($arg->{period}) if (defined $arg->{period});
my %pHash = abbrev qw(day week month);
if (exists($pHash{$lcPeriod})) {
	$period = $pHash{$lcPeriod};
	if ($period eq 'day') {
		my $dt = DateTime->now();
		$dt->set( hour => 0, minute => 0, second => 0 );
		$dt->subtract( days => 1 );
		push(@tsStartArray, $dt->epoch());
		print "Date Runs: " . Dumper(@tsStartArray) . "\n\n\n" if ($debug > 2);
	}
	elsif ($period eq 'month') {
		my $dt    = DateTime->now();
		my $month = $dt->month();
		$dt->set( month => $month, day => 1, hour => 0, minute => 0, second => 0 );
		$dt->subtract( months => 1 );
		$month = $dt->month();
		while($month == $dt->month()) {
			push(@tsStartArray, $dt->epoch());
			print "Time: $dt\n";
			$dt->add( days => 1 );
		}
		print "Date Runs: " . Dumper(@tsStartArray) . "\n\n\n" if ($debug > 2);
	}
	elsif ($period eq 'week') {
		my $dt    = DateTime->now();
		my $month = $dt->month();
		my $day   = $dt->day() - $dt->day_of_week();
		$dt->set( month => $month, day => $day, hour => 0, minute => 0, second => 0 );
		$dt->subtract( weeks => 1 );
		for(my $i=0; $i < 7; $i++) {
			push(@tsStartArray, $dt->epoch());
			print "Time: $dt\n";
			$dt->add( days => 1 );
		}
		print "Date Runs: " . Dumper(@tsStartArray) . "\n\n\n" if ($debug > 2);
	}
}
else {
	print "FATAL: invalid period value '$period'.\n";
	exit 255;
}

# [timespan=<24[hours]|HH:HH>] (default: '24hours')
my $timespan   = $dfltTimespan;
my $lcTimespan = lc($timespan);
$lcTimespan    = lc($arg->{timespan}) if (defined $arg->{timespan});
my @testStartArray = @tsStartArray;
@tsStartArray = ();
if ((substr($lcTimespan,0,3) eq '24h') or (substr($lcTimespan,0,4) eq '24 h')) {
	foreach my $eachEpoch (@testStartArray) {
		my $dt = DateTime->from_epoch( epoch => $eachEpoch );
		print "Timespan End:   $dt\n" if ($debug > 1);
		$tsEnd = $dt->epoch();
		$dt->subtract( hours => 24 );
		$tsStart = $dt->epoch();
		print "Timespan Start: $dt\n" if ($debug > 1);
		push(@tsStartArray, $tsStart);
		push(@tsEndArray, $tsEnd);
	}
}
elsif ($lcTimespan =~ /^(.*):(.*)$/) {
	$beginTimespan = $1;
	$endTimespan   = $2;
	if (($beginTimespan > $endTimespan)) {
		print "FATAL: Timespan must be in 24 hour format, Begin time is greater than end timespan!\n";
		print "FATAL: invalid timespan value '$timespan'.\n";
		exit 255;
	}
	elsif (($beginTimespan =~ /^\d{1}$|^[0-1]{1}\d{1}$|^[2]{1}[0-4]{1}$/g) && ($endTimespan =~ /^\d{1}$|^[0-1]{1}\d{1}$|^[2]{1}[0-4]{1}$/g)) {
		$timespan = $lcTimespan;
		foreach my $eachEpoch (@testStartArray) {
			my $dt = DateTime->from_epoch( epoch => $eachEpoch );
			$dt->set( hour => $beginTimespan, minute => 0, second => 0 );
			$tsStart = $dt->epoch();
			print "Timespan Start: $dt\n" if ($debug > 1);
			if ($endTimespan eq "24") {
				$dt->set( hour => 23, minute => 59, second => 59 );
			}
			else {
				$dt->set( hour => $endTimespan, minute => 0, second => 0 );
			}
			$tsEnd = $dt->epoch();
			print "Timespan End:   $dt\n" if ($debug > 1);
			push(@tsStartArray, $tsStart);
			push(@tsEndArray, $tsEnd);
		}
	}
	else {
		print "FATAL: invalid timespan value '$timespan'.\n";
		exit 255;
	}
}
else {
	print "FATAL: invalid timespan value '$timespan'.\n";
	exit 255;
}
#print "Date Runs Start: " . Dumper(@tsStartArray) . "\n\n\n" if ($debug > 2);
#print "Date Runs End    " . Dumper(@tsEndArray) . "\n\n\n" if ($debug > 2);

#print "Period   = '$period'.\n";
printSum("Timespan = '$timespan'");

# Set a default value and if there is a CLI argument, then use it to set the option
my $email = 0;
if (defined $arg->{email}) {
	if ($arg->{email} =~ /\@/) {
		$email = $arg->{email};
	}
	else {
		print "FATAL: invalid email address '$arg->{email}'.\n";
		exit 255;
	}
}

# Set Excel Filename.
if ( defined $arg->{xls} ) {
	$xlsFile = $arg->{xls};
}
$xlsPath = "$dir/$xlsFile";

if ( not defined $arg->{conf}) {
	$arg->{conf} = $defaultConf;
}
else {
	$arg->{conf} = abs_path($arg->{conf});
}

print "Configuration Directory = '$arg->{conf}'\n" if ($debug);
# Load configuration table
our $C = NMISNG::Util::loadConfTable(dir=>$arg->{conf}, debug=>$debug);
our $nmisng = Compat::NMIS::new_nmisng();

if ($group ne "") { 
	my $ok=0;
	my @groups = sort $nmisng->get_group_names;
	print "DEBUG: Group Names: " . Dumper(@groups) . "\n\n\n" if ($debug > 2);
	foreach my $word (@groups){
		if ($group =~ /^$word$/i) {
			$group = $word;
			$ok=1;
			last;
		}
	}
	if (!$ok) {
		print "FATAL: Group '$group' is not a known group.\n";
		exit 255;
	}
	printSum("Limiting output to group: '$group'");
}

# Set Directory.
if (! -d $dir) {
	if (-f $dir) {
		print "ERROR: The directory argument '$dir' points to a file, it must refer to a writable directory!\n";
		help();
		exit 255;
	}
	else {
		my ${key};
		my $IN;
		my $OUT;
		if ($^O =~ /Win32/i)
		{
			sysopen($IN,'CONIN$',O_RDWR);
			sysopen($OUT,'CONOUT$',O_RDWR);
		} else
		{
			open($IN,"</dev/tty");
			open($OUT,">/dev/tty");
		}
		print "Directory '$dir' does not exist!\n\n";
		print "Would you like me to create it? (y/n)  ";
		ReadMode 4, $IN;
		${key} = ReadKey 0, $IN;
		ReadMode 0, $IN;
		print("\r                                \r");
		if (${key} =~ /y/i)
		{
			eval {
				local $SIG{'__DIE__'};  # ignore user-defined die handlers
				mkpath($dir);
			};
			if ($@) {
			    print "FATAL: Error creating dir: $@\n";
				exit 255;
			}
			if (!-d $dir) {
				print "FATAL: Unable to create directory '$dir'.\n";
				exit 255;
			}
			if (-d $dir) {
				print "Directory '$dir' created successfully.\n";
			}
		}
		else {
			print "FATAL: Specify an existing directory with write permission.\n";
			exit 0;
		}
	}
}
if (! -w $dir) {
	print "FATAL: Unable to write to directory '$dir'.\n";
	exit 255;
}

if (-f $xlsPath) {
	my ${key};
	my $IN;
	my $OUT;
	if ($^O =~ /Win32/i)
	{
		sysopen($IN,'CONIN$',O_RDWR);
		sysopen($OUT,'CONOUT$',O_RDWR);
	} else
	{
		open($IN,"</dev/tty");
		open($OUT,">/dev/tty");
	}
	print "The Excel file '$xlsPath' already exists!\n\n";
	print "Would you like me to overwrite it and all corresponding CSV files? (y/n) y\b";
	ReadMode 4, $IN;
	${key} = ReadKey 0, $IN;
	ReadMode 0, $IN;
	print("\r                                                                            \r");
	if ((${key} !~ /y/i) && (${key} !~ /\r/) && (${key} !~ /\n/))
	{
		print "FATAL: Not overwriting files.\n";
		exit 255;
	}
}

my $now = time();
print $t->elapTime(). " Begin\n";

# Step 1: define your prefered seperator
my $sep = "\t";
if ( $arg->{separator} eq "tab" ) {
	$sep = "\t";
}
elsif ( $arg->{separator} eq "comma" ) {
	$sep = ",";
}
elsif (exists($arg->{separator})) {
	$sep = $arg->{separator};
}

# A cache of Card Indexes.
my $cardIndex;

# Step 2: Define the overall order of all the fields.
my @nodeHeaders = (
				"name",
				"group",
#				"summary",
				"issues",
				"isActive",

				"memSize",
				#"memUsed",
				"memUsedAvg",
				"memUsedMax",
				"memUsedStdDev",
				"memUsed95Per",

				"swapSize",
				#"swapUsed",
				"swapUsedAvg",
				"swapUsedMax",
				"swapUsedStdDev",
				"swapUsed95Per",

				"maxDiskDescr",
				"maxDiskCapacity",
				"maxDiskUsed",
				"diskOverall",
				"diskGrowth",
				#"diskTrend",
				"diskTrend_5days", 
				"diskTrend_3days", 
				"diskTrend_today",

				"nodeVendor",
				"nodeModel",
				"nodeType",
				"sysDescr"
			);

# Step 3: Define any CSV header aliases you want
my %nodeAlias = (
				"name"             => 'Name',
				"group"            => 'Group',
				"summary"          => 'Summary',
#				"issues"           => 'Issues',
				"isActive"         => 'Active',

				"memSize"         => 'Memory Size',
				#"memUsed"        => 'Memory Used',
				"memUsedAvg"      => 'Average Memory Used',
				"memUsedMax"      => 'Max Memory Used',
				"memUsedStdDev"   => 'Standard Deviation Memory Used',
				"memUsed95Per"    => '95% Memory Used',

				"swapSize"         => 'Swap Size',
				#"swapUsed"        => 'Swap Used',
				"swapUsedAvg"      => 'Average Swap Used',
				"swapUsedMax"      => 'Max Swap Used',
				"swapUsedStdDev"   => 'Standard Deviation Swap Used',
				"swapUsed95Per"    => '95% Swap Used',

				"maxDiskDescr"     => 'Max Disk Description',
				"maxDiskCapacity"  => 'Max Disk Capacity',
				"maxDiskUsed"      => 'Max Disk Used',
				"diskOverall"      => 'Overall Disk Capacity',
				"diskGrowth"       => 'Disk Growth',
				#"diskTrend"       => 'Disk Growth Trend',
				"diskTrend_5days"  => "Disk 5 Day Growth Trend (Hours: $timespan)",
				"diskTrend_3days"  => "Disk 3 Day Growth Trend (Hours: $timespan)",
				"diskTrend_today"  => "Disk Today Growth Trend (Hours: $timespan)",

				"nodeVendor"       => 'Vendor',
				"nodeModel"        => 'Model',
				"nodeType"         => 'Type',
				"sysDescr"         => 'System Description'
			);

# Step 4: For loading only the local nodes on a Master or a Slave
my $NODES = Compat::NMIS::loadLocalNodeTable();

my $xls;
if ($xlsPath) {
	$xls = start_xlsx(file => $xlsPath);
}

processNodes($xls,"$dir/server_perf_report.csv");

print $t->elapTime(). " End\n";

sub processNodes {
	my $xls   = shift;
	my $file  = shift;
	my $title = "Server Performance";
	my $sheet;
	my $currow;
	my $csvData;
	my @colsize;
	my @badNodes;

	print "Creating $file\n";

	open(CSV,">$file") or die "Error with CSV File $file: $!\n";

	# print a CSV header
	my @aliases;
	my $currcol=0;
	foreach my $header (@nodeHeaders) {
		my $colLen = (($colsize[$currcol] ne '' ) ? $colsize[$currcol] : length($nodeAlias{$header}));
		my $alias  = $header;
		$alias = $nodeAlias{$header} if $nodeAlias{$header};
		$colsize[$currcol] = $colLen;
		push(@aliases,$alias);
		$currcol++;
	}
	my $header = join($sep,@aliases);
	print CSV "$header\n";
	$csvData .= "$header\n";

	if ($xls) {
		$sheet = add_worksheet(xls => $xls, title => $title, columns => \@aliases);
		$currow = 1;								# header is row 0
	}
	else {
		die "ERROR: Internal error, xls is no longer defined.\n";
	}

	my %storage = ();
	foreach my $node (sort keys %{$NODES}) {
		print "DEBUG: '$NODES->{$node}{name}' Active Status is $NODES->{$node}{active}.\n" if ($debug > 1);
		if ( $NODES->{$node}{active} ) {
			my $S = NMISNG::Sys->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $nodeobj       = $nmisng->node(name => $node);
			my $IF            = $nodeobj->ifinfo;
			my $inv           = $S->inventory( concept => 'catchall' );
			my $catchall_data = $inv->data;
			my $MDL           = $S->mdl;
			my $result = $S->nmisng_node->get_inventory_model( concept => "storage", filter => { historic => 0 });
			if (!$result->error)
			{
				%storage = map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});
			}

			my $nodeDown = $catchall_data->{nodedown} // "false";

			print "DEBUG: System Object: " . Dumper($S) . "\n\n\n" if ($debug > 8);
			printSum($t->elapTime() . " - DEBUG: '$NODES->{$node}{name}' Node Down Status is $nodeDown.") if ($debug);
			printSum($t->elapTime() . " - DEBUG: Processing $node active=$NODES->{$node}{active} ping=$NODES->{$node}{ping} collect=$NODES->{$node}{collect}") if $debug;

			my $nodestatus = $catchall_data->{nodestatus};
			$nodestatus = "unreachable" if $nodeDown eq "true";

			print "DEBUG: '$NODES->{$node}{name}' vendor is '$catchall_data->{nodeVendor}'.\n" if ($debug > 1);

			# If we cannot get the software version, try to decipher it.
			if ( not defined $catchall_data->{softwareVersion} or $catchall_data->{softwareVersion} eq "" ) {
				$catchall_data->{softwareVersion} = getVersion($catchall_data->{sysDescr});
			}
			my $sysDescr              =  $catchall_data->{sysDescr};
			$sysDescr                 =~ s/[\x0A\x0D]/\\n/g;
			$sysDescr                 =~ s/,/;/g;
			$NODES->{$node}{sysDescr} =  $sysDescr;
			$NODES->{$node}{group}    =  $catchall_data->{group};


			# Get an uplink address, find any address and put it in a string
			my @ipAddresses;
			foreach my $ifIndex (sort keys %{$IF}) {
				my @addresses;
				if ( defined $IF->{$ifIndex} and defined $IF->{$ifIndex}{ipAdEntAddr1} ) {
					push(@ipAddresses,$IF->{$ifIndex}{ipAdEntAddr1});
				}
				if ( defined $IF->{$ifIndex} and defined $IF->{$ifIndex}{ipAdEntAddr2} ) {
					push(@ipAddresses,$IF->{$ifIndex}{ipAdEntAddr2});
				}
			}
			my $joinChar = $sep eq "," ? " " : ",";
			$NODES->{$node}{uplink} = join($joinChar,@ipAddresses);

			# clone the name!
			$NODES->{$node}{name2} = $NODES->{$node}{name};
			$NODES->{$node}{name3} = $NODES->{$node}{name};
	    
			# handling Node values for these fields.
			$NODES->{$node}{nodeStatus} = $nodestatus;
			$NODES->{$node}{nodeModel}  = $catchall_data->{nodeModel};
#			$NODES->{$node}{nodeModel}  = getModel($catchall_data->{sysObjectName}, $catchall_data->{nodeModel});
			$NODES->{$node}{nodeType}   = getType($catchall_data->{sysObjectName}, $catchall_data->{nodeType});
			$NODES->{$node}{isActive}   = ($NODES->{$node}{active}) ? "True" : "False";


			if ( not defined $NODES->{$node}{relayRack} or $NODES->{$node}{relayRack} eq "" ) {
				$NODES->{$node}{relayRack} = "No Relay Rack Configured";
			}

			if ( not defined $NODES->{$node}{location} or $NODES->{$node}{location} eq "" ) {
				$NODES->{$node}{location} = "No Location Configured";
			}
			my $isServer = 0;
			if ( scalar(keys %storage) > 0) {
				printSum("$node has storage") if $debug;
				$isServer = 1;
				$NODES->{$node}{isServer} = $isServer;
				
#				"39" : {
#					"hrStorageUnits" : "4096",
#					"hrStorageUsed" : "68472271",
#					"hrStorageDescr" : "/data",
#					"hrStorageType" : "Fixed Disk",
#					"hrStorageSize" : "129014382",
#					"hrStorageGraph" : "hrdisk",
#					"index" : "39",
#					"hrStorageIndex" : "39"
#				},
	
				my $maxDisk      = undef;
				my $maxDiskIndex = undef;
				my $ninetyFifth  = undef;
				my $gotDiskData  = 0;
				my $gotMemData   = 0;
				my $gotSwapData  = 0;
				foreach my $disk (sort keys %storage) {
					print "'$node' - Disk '$storage{$disk}{hrStorageDescr}' (Index $disk) is Storage Type '$storage{$disk}{hrStorageType}'\n" if ($debug);
					if ( $storage{$disk}{hrStorageType} eq "Fixed Disk" and $storage{$disk}{hrStorageDescr} !~ /^\/dev$/ ) {
						my $diskUsed = sprintf("%.2f", $storage{$disk}{hrStorageUsed} / $storage{$disk}{hrStorageSize} * 100);
						print "'$node': Index $disk = $storage{$disk}{hrStorageDescr} $diskUsed%\n" if $debug;
						if ( $diskUsed > $maxDisk ) {
							print "'$node' - Disk '$storage{$disk}{hrStorageDescr}' has higher usage than '$storage{$maxDiskIndex}{hrStorageDescr}'\n" if ($debug and defined($maxDiskIndex));
							$maxDiskIndex = $disk;
							$maxDisk      = $diskUsed;
						}
					}
					elsif ( $storage{$disk}{hrStorageType} =~ /Memory|Physical memory|Real Memory|Physical Memory/ ) {
						# First we want the last 24 hours.
						my $start = $now - 2 * 86400;
						my $end = $now;
						my $db = $S->makeRRDname(graphtype => 'hrmem', index=>$disk,item=>undef);
						my $mem = NMISNG::rrdfunc::getRRDStats(database => $db, sys=>$S, graphtype=>"hrmem", mode=>"AVERAGE", start => $start, end => $end,
																hour_from => $beginTimespan, hour_to => $endTimespan, index=>$disk, item=> undef, truncate => -1);
						if ( $mem ) {
							$gotMemData = 1;
							print "DEBUG: Main Memory: " . Dumper($mem) . "\n\n\n" if ($debug > 8);
							$NODES->{$node}{memSize} = scaledbytes($storage{$disk}{hrStorageSize} * $storage{$disk}{hrStorageUnits});
							$NODES->{$node}{memUsed} = sprintf("%.2f", $storage{$disk}{hrStorageUsed} / $storage{$disk}{hrStorageSize} * 100);
							$NODES->{$node}{memUsedAvg} = sprintf("%.2f", $mem->{hrMemUsed}{mean} / $mem->{hrMemSize}{mean} * 100) if $mem->{hrMemUsed}{mean};
							$NODES->{$node}{memUsedMax} = sprintf("%.2f", $mem->{hrMemUsed}{max} / $mem->{hrMemSize}{max} * 100) if $mem->{hrMemUsed}{max};
							$NODES->{$node}{memUsedStdDev} = sprintf("%.2f", $mem->{hrMemUsed}{stddev} / $mem->{hrMemSize}{mean} * 100) if $mem->{hrMemUsed}{stddev};
						
							# calculate the 95th percentile.
							$ninetyFifth = int(@{$mem->{hrMemUsed}{values}} * 0.95) if $mem->{hrMemUsed}{values};
							$NODES->{$node}{memUsed95Per} = sprintf("%.2f", $mem->{hrMemUsed}{values}->[$ninetyFifth] / $mem->{hrMemSize}{mean} * 100) if $mem->{hrMemSize}{mean};
							
							if ( not $mem->{hrMemUsed}{mean} ) {
								$NODES->{$node}{memUsed} = 0;
								$NODES->{$node}{memUsedAvg} = 0;
								$NODES->{$node}{memUsedMax} = 0;
								$NODES->{$node}{memUsedStdDev} = 0;
								$NODES->{$node}{memUsed95Per} = 0;
							}
						}
						print "'$node' - memUsedStdDev=$nodeData{$node}{memUsedStdDev} ninetyFifth=$ninetyFifth memUsed95Per=$nodeData{$node}{memUsed95Per}\n";
						
					}
					elsif ( $storage{$disk}{hrStorageType} eq "Swap space" ) {
						# First we want the last 24 hours.
						my $start = $now - 2 * 86400;
						my $end = $now;
						my $db = $S->makeRRDname(graphtype => 'hrswapmem', index=>$disk,item=>undef);
						my $swap = NMISNG::rrdfunc::getRRDStats(database => $db, sys=>$S, graphtype=>"hrswapmem", mode=>"AVERAGE",
																start => $start, end => $end,
																hour_from => $beginTimespan, hour_to => $endTimespan, index=>$disk, item=> undef,
																truncate => -1);
						if ( $swap ) {
							$gotSwapData = 1;
							print "DEBUG: Swap: " . Dumper($swap) . "\n\n\n" if ($debug > 8);

							$NODES->{$node}{swapSize} = scaledbytes($storage{$disk}{hrStorageSize} * $storage{$disk}{hrStorageUnits});
							$NODES->{$node}{swapUsed} = sprintf("%.2f", $storage{$disk}{hrStorageUsed} / $storage{$disk}{hrStorageSize} * 100);
							$NODES->{$node}{swapUsedAvg} = sprintf("%.2f", $swap->{hrSwapMemUsed}{mean} / $swap->{hrSwapMemSize}{mean} * 100);
							$NODES->{$node}{swapUsedMax} = sprintf("%.2f", $swap->{hrSwapMemUsed}{max} / $swap->{hrSwapMemSize}{max} * 100);
							$NODES->{$node}{swapUsedStdDev} = sprintf("%.2f", $swap->{hrSwapMemUsed}{stddev} / $swap->{hrSwapMemSize}{mean} * 100);
						
							# calculate the 95th percentile.
							$ninetyFifth = int(@{$swap->{hrSwapMemUsed}{values}} * 0.95);
							$NODES->{$node}{swapUsed95Per} = sprintf("%.2f", $swap->{hrSwapMemUsed}{values}->[$ninetyFifth] / $swap->{hrSwapMemSize}{mean} * 100);
						}
						print "'$node' - swapUsedStdDev=$NODES->{$node}{swapUsedStdDev} ninetyFifth=$ninetyFifth swapUsed95Per=$NODES->{$node}{swapUsed95Per}\n";
						
					}
					# if it is swap, get the stats and is the 95% over my threshold, which for interfaces is 75%
				}
				$NODES->{$node}{maxDiskCapacity} = scaledbytes($storage{$maxDiskIndex}{hrStorageSize} * $storage{$maxDiskIndex}{hrStorageUnits});
				$NODES->{$node}{maxDiskUsed} = $maxDisk;
				$NODES->{$node}{maxDiskIndex} = $maxDiskIndex;
				$NODES->{$node}{maxDiskDescr} = $storage{$maxDiskIndex}{hrStorageDescr};
				# get some trend here, e.g. disk calcs for last 3 weeks and show a trend.
				if ( $maxDisk and $maxDiskIndex ) {
					my $diskStats = getDiskStats($node,$S,$maxDiskIndex);
					if ( $diskStats ) {
						$gotDiskData = 1;
						print "DEBUG: Disk Stats: " . Dumper($diskStats) . "\n\n\n" if ($debug > 8);
						$NODES->{$node}{diskTrend} = $diskStats->{summary};
						
						$NODES->{$node}{diskTrend_5days} = $diskStats->{diskTrend_5days};
						$NODES->{$node}{diskTrend_3days} = $diskStats->{diskTrend_3days};
						$NODES->{$node}{diskTrend_today} = $diskStats->{diskTrend_today};
					
						$NODES->{$node}{diskGrowth} = $diskStats->{growth};
						$NODES->{$node}{diskOverall} = $diskStats->{overall};
					}
				}
				if ( not $gotDiskData ) {
					$NODES->{$node}{maxDiskDescr}    = "N/A";
					$NODES->{$node}{maxDiskCapacity} = "N/A";
					$NODES->{$node}{maxDiskUsed}     = "N/A";
					$NODES->{$node}{diskTrend}       = "N/A";
					$NODES->{$node}{diskTrend_5days} = "N/A";
					$NODES->{$node}{diskTrend_3days} = "N/A";
					$NODES->{$node}{diskTrend_today} = "N/A";
					$NODES->{$node}{diskGrowth}      = "N/A";
					$NODES->{$node}{diskOverall}     = "N/A";
				}

				if ( not $gotMemData ) {
					$NODES->{$node}{memSize}         = "N/A";
					$NODES->{$node}{memUsed}         = "N/A";
					$NODES->{$node}{memUsedAvg}      = "N/A";
					$NODES->{$node}{memUsedMax}      = "N/A";
					$NODES->{$node}{memUsedStdDev}   = "N/A";
					$NODES->{$node}{memUsed95Per}    = "N/A";
				}

				if ( not $gotSwapData ) {
					$NODES->{$node}{swapSize}        = "N/A";
					$NODES->{$node}{swapUsed}        = "N/A";
					$NODES->{$node}{swapUsedAvg}     = "N/A";
					$NODES->{$node}{swapUsedMax}     = "N/A";
					$NODES->{$node}{swapUsedStdDev } = "N/A";
					$NODES->{$node}{swapUsed95Per}   = "N/A";					
				}
			
#				true linux memory exhaustion, 
#				hrmem -> "Memory"
#				hrcachemem -> "Memory"
#				or alert on phys mem free minus cache minus buffers getting low (ditto)
#				"1" : {
#					"hrStorageSize" : "16269240",
#					"hrStorageUnits" : "1024",
#					"hrStorageGraph" : "hrmem",
#					"index" : "1",
#					"hrStorageUsed" : "15844736",
#					"hrStorageDescr" : "Physical memory",
#					"hrStorageType" : "Memory"
#				},
#				"7" : {
#					"hrStorageSize" : "10047060",
#					"hrStorageUnits" : "1024",
#					"hrStorageGraph" : "hrcachemem",
#					"index" : "7",
#					"hrStorageUsed" : "10047060",
#					"hrStorageDescr" : "Cached memory",
#					"hrStorageType" : "Other Memory"
#				},
#				"6" : {
#					"hrStorageSize" : "16269240",
#					"hrStorageUnits" : "1024",
#					"hrStorageGraph" : "hrbufmem",
#					"index" : "6",
#					"hrStorageUsed" : "367572",
#					"hrStorageDescr" : "Memory buffers",
#					"hrStorageType" : "Other Memory"
#				},
			
#				net-snmp -> nodehealth -> hrSystemProcesses
#				Windows -> hrProcesses -> hrwin
#				tcp -> tcpCurrEstab
			
	    		    
####################################
#                                  #
#		Generate Report.           #
#                                  #
####################################
				if ( $group eq "" or $group eq $NODES->{$node}{group} ) {
					my $extra         = " for $group" if $group ne "";
					my $nodeException = 0;
					my $intCollect    = 0;
					my $intCount      = 0;
					my $nodeException = 0;
					my $currcol       = 0;
					my @issueList;
					my @columns;
					if ( $NODES->{$node}{maxDiskUsed} > 95 ) {
						$nodeException = 1;
						push(@issueList,"Very high disk usage");
					}
					elsif ( $NODES->{$node}{maxDiskUsed} > 80 ) {
						$nodeException = 1;
						push(@issueList,"High disk usage");
					}
	
					if ( $NODES->{$node}{swapUsedAvg} > 40 ) {
						$nodeException = 1;
						push(@issueList,"High swap space usage");
					}
					elsif ( $NODES->{$node}{swapUsedStdDev} > 5 ) {
						$nodeException = 1;
						push(@issueList,"High swap variation");
					}
					elsif ( $NODES->{$node}{swapUsedStdDev} > 1 ) {
						$nodeException = 1;
						push(@issueList,"Moderate swap variation");
					}
	
					$NODES->{$node}{nodeException} = $nodeException;
					if ( $exceptions and not $nodeException ) {
						next;
					}
					push(@badNodes,$node) if @issueList;
					$NODES->{$node}{issues} = join(":: ",@issueList);
	
					foreach my $header (@nodeHeaders) {
						my $colLen = (($colsize[$currcol] ne '' ) ? $colsize[$currcol] : length($nodeAlias{$header}));
						my $data   = undef;
						if ( defined $NODES->{$node}{$header} ) {
							$data = $NODES->{$node}{$header};
						}
						elsif ( defined $catchall_data->{$header} ) {
							$data = $catchall_data->{$header};	    
						}
						else {
							$data = "TBD";
						}
						$colLen = ((length($data) > 253 || length($nodeAlias{$header}) > 253) 
							? 253 
							: ((length($data) > $colLen) 
								? length($data) 
								: $colLen));
						$data   = changeCellSep($data);
						$colsize[$currcol] = $colLen;
						push(@columns,$data);
						$currcol++;
					}
					my $row = join($sep,@columns);
					print CSV "$row\n";
					$csvData .= "$row\n";
		
					if ($sheet) {
						$sheet->write($currow, 0, [ @columns[0..$#columns] ]);
						++$currow;
					}
				}
			}
			else {
				printSum("'$node' is not a server.") if $debug;
			}
		}
	}
	my $i=0;
	foreach my $header (@nodeHeaders) {
		$sheet->set_column( $i, $i, $colsize[$i]+2);
		$i++;
	}

	close CSV;
	end_xlsx(xls => $xls);
	printSum("XLS saved to $xlsPath");
	NMISNG::Util::setFileProtDiag(file =>$xlsPath);
	
	printSum("\n");

	printSum("There are ". @badNodes . " nodes with issues detected:");
	my $badnoderising = join("\n",@badNodes);
	printSum($badnoderising);

	printSum("\n");
	
	foreach my $node (@badNodes) {
			printSum("$node issues:");	
			$NODES->{$node}{issues} =~ s/:: /\n/g;
			printSum("$NODES->{$node}{issues}\n");	
	}
	if ($email) {
	   notifyByEmail(email => $email, subject => $title,  summary => \@SUMMARY, file_name => $xlsFile, file_path_name => $xlsPath);
	}
}


sub getDiskStats {
	my $node = shift;
	my $S    = shift;
	my $disk = shift;
	
	if ( not $node or not $S or not $disk ) {
		print "ERROR: need to know 'node', 'S' and 'disk'\n";   
		return undef;
	}
	
	my $diskStats;
	
	printSum($t->elapTime(). " - getDiskStats Processing '$node' Index $disk") if $debug;

	my $start     = undef;
	my $end       = undef;
	my $lastDay   = undef;
	my $threeDays = undef;
	my $fiveDays  = undef;

	# first we want the last 24 hours.
	$start = $now - 86400;
	$end = $now;
	my $db = $S->makeRRDname(graphtype => 'hrdisk', index=>$disk,item=>undef);
	$lastDay = NMISNG::rrdfunc::getRRDStats(database => $db, sys=>$S, graphtype=>"hrdisk", mode=>"AVERAGE", start => $start, end => $end,
											hour_from => $beginTimespan, hour_to => $endTimespan, index=>$disk, item=> undef, truncate => -1);

	printSum($t->elapTime(). " - getDiskStats '$node' Index $disk lastDay done") if $debug;

	# now we want 3 days ago
	$start = $now - 3 * 86400;
	$end = $now - 2 * 86400;;
	$threeDays = NMISNG::rrdfunc::getRRDStats(database => $db, sys=>$S, graphtype=>"hrdisk", mode=>"AVERAGE", start => $start, end => $end,
											hour_from => $beginTimespan, hour_to => $endTimespan, index=>$disk, item=> undef, truncate => -1);

	printSum($t->elapTime(). " - getDiskStats '$node' Index $disk threeDays done") if $debug;

	# now we want 5 days ago
	$start = $now - 5 * 86400;
	$end = $now - 4 * 86400;;
	$fiveDays = NMISNG::rrdfunc::getRRDStats(database => $db, sys=>$S, graphtype=>"hrdisk", mode=>"AVERAGE", start => $start, end => $end,
											hour_from => $beginTimespan, hour_to => $endTimespan, index=>$disk, item=> undef, truncate => -1);

	printSum($t->elapTime(). " - getDiskStats '$node' Index $disk fiveDays done") if $debug;

	#print Dumper $lastDay if $debug;
	#print Dumper $threeDays if $debug;
	#print Dumper $fiveDays if $debug;

	if ( not exists $lastDay->{hrDiskUsed}
		or not exists $threeDays->{hrDiskUsed}
		or not exists $fiveDays->{hrDiskUsed}
	) {
		print "ERROR: $node problem with stats from disk $disk\n";   
		return undef;			
	}


	my $lastDayUsage = sprintf("%.2f",$lastDay->{hrDiskUsed}{mean} / $lastDay->{hrDiskSize}{mean} * 100);
	my $threeDaysUsage = sprintf("%.2f",$threeDays->{hrDiskUsed}{mean} / $threeDays->{hrDiskSize}{mean} * 100);
	my $fiveDaysUsage = sprintf("%.2f",$fiveDays->{hrDiskUsed}{mean} / $fiveDays->{hrDiskSize}{mean} * 100);

	# now we have evenly spaced data for some trend analysis.
	
	# what is the delta between the 3 points
	my $deltaOne = $lastDayUsage - $threeDaysUsage;
	my $deltaTwo = $threeDaysUsage - $fiveDaysUsage;
	
	my $growth = undef;
	my $overall = undef;
	
	# no disk growth.
	if ( int($lastDayUsage) == int($fiveDaysUsage) ) {
	  $overall = "No change in Disk usage";
	  $growth = "Flat";	
	}
	# disk usage increasing
	elsif ( $lastDayUsage > $fiveDaysUsage ) {
	  $overall = "Overall Disk usage increasing";
		if ( int($deltaOne) == int($deltaTwo) ) {
			# this means basically liner growth
			$growth = "Linear trend";
		}
		elsif ( int($deltaOne) > int($deltaTwo) ) {
			# this means basically liner growth
			$growth = "Increasing trend";
		}
		elsif ( int($deltaOne) < int($deltaTwo) ) {
			# this means basically liner growth
			$growth = "Decreasing trend";
		}
	}
	elsif ( $lastDayUsage < $fiveDaysUsage ) {
	  $overall = "Overall Disk usage decreasing";
	  $growth = "Negative";
	}
	else {
		printSum("ERROR: $node $disk fiveDaysUsage=$fiveDaysUsage lastDayUsage=$lastDayUsage\n");
	}
	
	$diskStats->{summary} = "5days=$fiveDaysUsage, 3days=$threeDaysUsage, today=$lastDayUsage";
	$diskStats->{diskTrend_5days} = $fiveDaysUsage;
	$diskStats->{diskTrend_3days} = $threeDaysUsage;
	$diskStats->{diskTrend_today} = $lastDayUsage;
	$diskStats->{growth} = $growth;
	$diskStats->{overall} = $overall;
	
	#	$inutil = $statval->{ifInOctets}{mean} * 8 / $ifSpeedIn * 100;
	#	$oututil = $statval->{ifOutOctets}{mean} * 8 / $ifSpeedOut * 100;

	return $diskStats;
}

sub changeCellSep {
	my $string = shift;
	$string =~ s/$sep/;/g;
	$string =~ s/\r\n/\\n/g;
	$string =~ s/\n/\\n/g;
	return $string;
}

sub getStatus {
	# no definitions found?
	return "Installed";
}

sub getModel {
	my $sysObjectName = shift;
	my $nodeModel     = shift;

	if ( $sysObjectName =~ /cisco/ ) {
		$nodeModel = "Cisco";
	}
	if ( $sysObjectName =~ /cat(\d+)/ ) {
		$nodeModel = "Cisco Catalyst $1";
	}

	return $nodeModel;
}

sub getType {
	my $sysObjectName = shift;
	my $nodeType      = shift;
	my $type          = $nodeType // "TBD";

	if ( $sysObjectName =~ /cisco61|cisco62|cisco60|asam/ ) {
		$type = "DSLAM";
	}
	elsif ( $nodeType =~ /router/ ) {
		$type = "Router";
	}
	elsif ( $nodeType =~ /switch/ ) {
		$type = "Switch";
	}

	return $type;
}

sub getPortDuplex {
	my $thing = shift;
	my $duplex = "TBD";

	if ( $thing =~ /SHDSL|ADSL/ ) {
		$duplex = "N/A";
	}

	return $duplex;
}

sub getCardName {
	my $model = shift;
	my $name;

	if ( $model =~ /^.TUC/ ) {
		$name = "xDSL Card";
	}
	elsif ( $model =~ /^NI\-|C6... Network/ ) {
		$name = "Network Intfc  (WRK)";
	}
	elsif ( $model ne "" ) {
		$name = $model;
	}

	return $name;
}

sub usage {
	print <<EO_TEXT;
Usage: $PROGNAME -a -d[=[0-9]] -h -u -v dir=<directory> [option=value...]

$PROGNAME will generate a Server performance Report.

Arguments:
 dir=<Drectory where files should be saved>
 [conf=<Configuration file>] (default: '$defaultConf');
 [email=<Email Address>]
 [exceptions=<true|false>] (if true, spreadsheet will only include exceptions)
 [timespan=<24[hours]|HH:HH>] (default: '$dfltTimespan')
 [separator=<Comma separated  value (CSV) separator character>] (default: tab)
 [xls=<Excel filename>] (default: '$xlsFile')

Enter $PROGNAME -h for complete details.

eg: $PROGNAME dir=/data separator=(comma|tab)
\n
EO_TEXT
# [period=<day|week|month>] (default: '$dfltPeriod')
}


#Cisco IOS XR Software (Cisco CRS-8/S) Version 5.1.3[Default] Copyright (c) 2014 by Cisco Systems Inc.
sub getVersion {
	my $sysDescr = shift;
	my $version;

	if ( $sysDescr =~ /Version ([\d\.\[\]\w]+)/ ) {
		$version = $1;
	}

	return $version;
}

sub start_xlsx
{
	my (%args) = @_;

	my ($xls);
	if ($args{file})
	{
		$xls = Excel::Writer::XLSX->new($args{file});
		$xls->set_optimization();
		die "Cannot create XLSX file ".$args{file}.": $!\n" if (!$xls);
	}
	else {
		die "ERROR: need a file to work on.\n";
	}
	return ($xls);
}

sub add_worksheet
{
	my (%args) = @_;

	my $xls = $args{xls};

	my $sheet;
	if ($xls)
	{
		my $shorttitle = $args{title};
		$shorttitle =~ s/[^a-zA-Z0-9 _\.-]+//g; # remove forbidden characters
		$shorttitle = substr($shorttitle, 0, 31); # xlsx cannot do sheet titles > 31 chars
		$sheet = $xls->add_worksheet($shorttitle);

		if (ref($args{columns}) eq "ARRAY")
		{
			my $format = $xls->add_format();
			$format->set_bold(); $format->set_color('blue');

			for my $col (0..$#{$args{columns}})
			{
				$sheet->write(0, $col, $args{columns}->[$col], $format);
			}
		}
	}
	return ($xls, $sheet);
}

# closes the spreadsheet, returns 1 if ok.
sub end_xlsx
{
	my (%args) = @_;

	my $xls = $args{xls};

	if ($xls)
	{
		return $xls->close;
	}
	else {
		die "ERROR need an xls to work on.\n";
	}
	return 1;
}

sub notifyByEmail {
	my %args = @_;

	my $email          = $args{email};
	my $subject        = $args{subject};
	my $summary        = $args{summary};
	my $file_name      = $args{file_name};
	my $file_path_name = $args{file_path_name};
	my @recipients     = split(/\,/,$email);


	print "Sending email with '$file_name' attachment to '$email'\n" if $debug;

	my $entity = MIME::Entity->build(
		From=>$C->{mail_from}, 
		To=>$email,
		Subject=> $subject,
		Type=>"multipart/mixed"
	);

	my @lines;
	push @lines, $subject;
	#insert some blank lines (a join later adds \n
	push @lines, ("","");

	if ( defined $summary ) {
		push (@lines, @{$summary});
		push @lines, ("","");
	}

	print "Sending summary email to $email\n";

	my $textover = join("\n", @lines);
	$entity->attach(Data => $textover,
									Disposition => "inline",
									Type  => "text/plain");

	$entity->attach(Path => $file_path_name,
									Disposition => "attachment",
									Filename => $file_name,
									Type => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");

	my ($status, $code, $errmsg) = NMISNG::Notify::sendEmail(
	  # params for connection and sending
		sender => $C->{mail_from},
		recipients => \@recipients,

		mailserver => $C->{mail_server},
		serverport => $C->{mail_server_port},
		hello => $C->{mail_domain},
		usetls => $C->{mail_use_tls},
		ipproto => $C->{mail_server_ipproto},

		username => $C->{mail_user},
		password => $C->{mail_password},

		# and params for making the message on the go
		to => $email,
		from => $C->{mail_from},
		subject => $subject,
		mime => $entity
	);

	if (!$status)
	{
		print "ERROR: Sending email to $email failed: $code $errmsg\n";
	}
	else
	{
		print "Email to '$email' sent successfully\n";
	}
} 

sub printSum {
	my $message = shift;
	print "$message\n";
	push(@SUMMARY,$message);
}

sub scaledbytes {
   (sort { length $a <=> length $b }
   map { sprintf '%.3g%s', $_[0]/1024**$_->[1], $_->[0] }
   [" bytes"=>0],[KB=>1],[MB=>2],[GB=>3],[TB=>4],[PB=>5],[EB=>6])[0]
}


###########################################################################
#  Help Function
###########################################################################
sub help
{
   my(${currRow}) = @_;
   my @{lines};
   my ${workLine};
   my ${line};
   my ${key};
   my ${cols};
   my ${rows};
   my ${pixW};
   my ${pixH};
   my ${i};
   my $IN;
   my $OUT;

   if ((-t STDERR) && (-t STDOUT)) {
      if (${currRow} == "")
      {
         ${currRow} = 0;
      }
      if ($^O =~ /Win32/i)
      {
         sysopen($IN,'CONIN$',O_RDWR);
         sysopen($OUT,'CONOUT$',O_RDWR);
      } else
      {
         open($IN,"</dev/tty");
         open($OUT,">/dev/tty");
      }
      ($cols, $rows, $pixW, $pixH) = Term::ReadKey::GetTerminalSize $OUT;
   }
   STDOUT->autoflush(1);
   STDERR->autoflush(1);

   push(@lines, "\n\033[1mNAME\033[0m\n");
   push(@lines, "       $PROGNAME -  Generate a performance report into an Excel spredsheet.\n");
   push(@lines, "\n");
   push(@lines, "\033[1mSYNOPSIS\033[0m\n");
   push(@lines, "       $PROGNAME [options...] dir=<directory> [option=value] ...\n");
   push(@lines, "\n");
   push(@lines, "\033[1mDESCRIPTION\033[0m\n");
   push(@lines, "       The $PROGNAME program generates a Server performance report into an\n");
   push(@lines, "       Excel spreadsheet in the specified directory with the required 'dir'\n" );
   push(@lines, "       parameter. The command also creates a Comma Separated Value (CSV) file\n");
   push(@lines, "       in the same directory.\n");
   push(@lines, "\n");
   push(@lines, "\033[1mOPTIONS\033[0m\n");
   push(@lines, " --debug=[1-9|true|false] - global option to print detailed messages\n");
   push(@lines, " --exceptions             - only include exceptions\n");
   push(@lines, " --help                   - display command line usage\n");
   push(@lines, " --usage                  - display a brief overview of command syntax\n");
   push(@lines, " --version                - print a version message and exit\n");
   push(@lines, "\n");
   push(@lines, "\033[1mARGUMENTS\033[0m\n");
   push(@lines, "     dir=<directory>         - The directory where the files should be stored.\n");
   push(@lines, "                                Both the Excel spreadsheet and the CSV files\n");
   push(@lines, "                                will be stored in this directory. The\n");
   push(@lines, "                                directory should exist and be writable.\n");
   push(@lines, "     [conf=<filename>]       - The location of an alternate configuration file.\n");
   push(@lines, "                                (default: '$defaultConf')\n");
   push(@lines, "     [debug=<true|false|yes|no|info|warn|error|fatal|verbose|0-9>]\n");
   push(@lines, "                             - Set the debug level.\n");
   push(@lines, "     [email=<email_address>] - Send all generated CSV files to the specified.\n");
   push(@lines, "                                email address.\n");
   push(@lines, "     [exceptions=<true|false|yes|no|1|0>]\n");
   push(@lines, "                                Only include exceptions if true.\n");
#  push(@lines, "     [period=<day|week|month>]\n");
#  push(@lines, "                             - An optional date range to collect.\n");
#  push(@lines, "                                One of 'day', 'week', or 'month'.\n");
#  push(@lines, "                                (default: '$dfltPeriod')\n");
   push(@lines, "     [separator=<character>] - A character to be used as the separator in the\n");
   push(@lines, "                                CSV files. The words 'comma' and 'tab' are\n");
   push(@lines, "                                understood. Other characters will be taken\n");
   push(@lines, "                                literally. (default: 'tab')\n");
   push(@lines, "     [timespan=<24[hours]|HH:HH>]\n");
   push(@lines, "                             - An optional timespan for collection.\n");
   push(@lines, "                                Either '24hours', or a start hour and a\n");
   push(@lines, "                                stop hour in 24 hour format separated by a\n");
   push(@lines, "                                colon.\n");
   push(@lines, "                                (default: '$dfltTimespan')\n");
   push(@lines, "     [xls=<filename>]        - The name of the XLS file to be created in the\n");
   push(@lines, "                                directory specified using the 'dir' parameter'.\n");
   push(@lines, "                                (default: '$xlsFile')\n");
   push(@lines, "\n");
   push(@lines, "\033[1mEXIT STATUS\033[0m\n");
   push(@lines, "     The following exit values are returned:\n");
   push(@lines, "     0 Success\n");
   push(@lines, "     215 Failure\n\n");
   push(@lines, "\033[1mEXAMPLE\033[0m\n");
   push(@lines, "   $PROGNAME dir=/tmp separator=comma\n");
   push(@lines, "\n");
   push(@lines, "\n");
   print(STDERR "                       $PROGNAME - ${VERSION}\n");
   print(STDERR "\n");
   ${currRow} += 2;
   foreach (@lines)
   {
      if ((-t STDERR) && (-t STDOUT)) {
         ${i} = tr/\n//;  # Count the newlines in this string
         ${currRow} += ${i};
         if (${currRow} >= ${rows})
         {
            print(STDERR "Press any key to continue.");
            ReadMode 4, $IN;
            ${key} = ReadKey 0, $IN;
            ReadMode 0, $IN;
            print(STDERR "\r                          \r");
            if (${key} =~ /q/i)
            {
               print(STDERR "Exiting per user request. \n");
               return;
            }
            if ((${key} =~ /\r/) || (${key} =~ /\n/))
            {
               ${currRow}--;
            } else
            {
               ${currRow} = 1;
            }
         }
      }
      print(STDERR "$_");
   }
}
