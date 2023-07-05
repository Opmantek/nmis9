#!/usr/bin/perl
#
## $Id: cisco_cpu_mem_report.pl,v 1.1 2023/05/05 05:09:17 dougr Exp $
#
#  Copyright (C) FirstWave Limited (www.firstwave.com)
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
my $averagesw     = 0;
my $csvFile       = "cisco_cpu_mem_report.csv";
my $debugsw       = 0;
my $helpsw        = 0;
my $interfacesw   = 0;
my $tsEnd         = 0;
my $tsStart       = 0;
my $usagesw       = 0;
my $versionsw     = 0;
my $defaultConf   = abs_path("$FindBin::Bin/../../conf");
my $dfltPeriod    = 'day';
my $dfltTimespan  = '24hours';
my $stats_period = "-24 hours";
my $dfltSubject   = "Cisco CPU/Mem Report ". NMISNG::Util::returnDateStamp();
my $xlsFile       = "cisco_cpu_mem_report.xlsx";
my @tsEndArray    = ();
my @tsStartArray  = ();

$defaultConf = "$FindBin::Bin/../conf" if (! -d $defaultConf);
$defaultConf = abs_path($defaultConf);
print "Default Configuration directory is '$defaultConf'\n";

die unless (GetOptions('averages'   => \$averagesw,
                       'debug:i'    => \$debugsw,
                       'help'       => \$helpsw,
                       'interfaces' => \$interfacesw,
                       'usage'      => \$usagesw,
                       'version'    => \$versionsw));

# For the Version mode, just print it and exit.
if (${versionsw}) {
	print "$PROGNAME version=$NMISNG::VERSION\n";
	exit (0);
}
if ($helpsw) {
   help();
   exit(0);
}

my $arg = NMISNG::Util::get_args_multi(@ARGV);

if ($usagesw) {
   usage();
   exit(0);
}

# Set debugging level.
my $debug   = $debugsw;
$debug      = NMISNG::Util::getdebug_cli($arg->{debug}) if (exists($arg->{debug}));   # Backwards compatibility
print "Debug = '$debug'\n" if ($debug);

my $t = Compat::Timing->new();

# Variables for command line munging
my $arg = NMISNG::Util::get_args_multi(@ARGV);

# Set Directory level.
if ( not defined $arg->{dir} ) {
	print "ERROR: The directory argument is required!\n";
	help();
	exit 255;
}
my $dir = abs_path($arg->{dir});

# [period=<day|week|month>] (default: 'day')
#my $period   = $dfltPeriod;
#my $lcPeriod = lc($period);
#$lcPeriod    = lc($arg->{period}) if (defined $arg->{period});
#my %pHash = abbrev qw(day week month);
#if (exists($pHash{$lcPeriod})) {
#	$period = $pHash{$lcPeriod};
#	if ($period eq 'day') {
		my $dt = DateTime->now();
		$dt->set( hour => 0, minute => 0, second => 0 );
		$dt->subtract( days => 1 );
		push(@tsStartArray, $dt->epoch());
#		print "Date Runs: " . Dumper(@tsStartArray) . "\n\n\n" if ($debug > 2);
#	}
#	elsif ($period eq 'month') {
#		my $dt    = DateTime->now();
#		my $month = $dt->month();
#		$dt->set( month => $month, day => 1, hour => 0, minute => 0, second => 0 );
#		$dt->subtract( months => 1 );
#		$month = $dt->month();
#		while($month == $dt->month()) {
#			push(@tsStartArray, $dt->epoch());
#			print "Time: $dt\n";
#			$dt->add( days => 1 );
#		}
#		print "Date Runs: " . Dumper(@tsStartArray) . "\n\n\n" if ($debug > 2);
#	}
#	elsif ($period eq 'week') {
#		my $dt    = DateTime->now();
#		my $month = $dt->month();
#		my $day   = $dt->day() - $dt->day_of_week();
#		$dt->set( month => $month, day => $day, hour => 0, minute => 0, second => 0 );
#		$dt->subtract( weeks => 1 );
#		for(my $i=0; $i < 7; $i++) {
#			push(@tsStartArray, $dt->epoch());
#			print "Time: $dt\n";
#			$dt->add( days => 1 );
#		}
#		print "Date Runs: " . Dumper(@tsStartArray) . "\n\n\n" if ($debug > 2);
#	}
#}
#else {
#	print "FATAL: invalid period value '$period'.\n";
#	exit 255;
#}

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
	my $beginTimespan = $1;
	my $endTimespan   = $2;
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
			$dt->set( hour => $endTimespan, minute => 0, second => 0 );
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
print "Date Runs Start: " . Dumper(@tsStartArray) . "\n\n\n" if ($debug > 2);
print "Date Runs End    " . Dumper(@tsEndArray) . "\n\n\n" if ($debug > 2);

if ($averagesw) {
	print "Running Averages collection.\n";
#	print "Period   = '$period'.\n";
	print "Timespan = '$timespan'.\n";
}

# Set The subject.
my $subject = $dfltSubject;
if ( defined $arg->{subject} ) {
	$subject = $arg->{subject};
}

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

print $t->elapTime(). " Begin\n";

# Set Directory level.
if ( defined $arg->{xls} ) {
	$xlsFile = $arg->{xls};
}
$xlsFile = "$dir/$xlsFile";
$csvFile = "$dir/$csvFile";

if (-f $xlsFile) {
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
	print "The Excel file '$xlsFile' already exists!\n\n";
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

if ( not defined $arg->{conf}) {
	$arg->{conf} = $defaultConf;
}
else {
	$arg->{conf} = abs_path($arg->{conf});
}

print "Configuration Directory = '$arg->{conf}'\n" if ($debug);
# load configuration table
our $C = NMISNG::Util::loadConfTable(dir=>$arg->{conf}, debug=>$debug);
our $nmisng = Compat::NMIS::new_nmisng();

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

#      "serialNum" : "FHK1445735Q",
#      "chassisVer" : "1.0",
#      "configLastSaved" : "508612969",
#      "last_node_config_update" : "508499202",
#      "bootConfigLastChanged" : "423056140",
#      "softwareImage" : "C880DATA-UNIVERSALK9-M",
#      "softwareVersion" : "15.1(1)T1",

# Step 2: Define the overall order of all the fields.
my @nodeHeaders = qw(name host group location nodeVendor nodeModel sysUpTime serialNum softwareVersion softwareImage cbqosInput cbqosOutput RecordsExported RecordsExportedMax ifNumber intfCollect chassisVer last_node_config_update);

# Step 4: Define any CSV header aliases you want
my %nodeAlias = (
	name					=> 'Node',
	host					=> 'Host',
	group					=> 'Group',
	nodeVendor				=> 'Node Vendor',
	nodeModel				=> 'Node Model',
	sysUpTime				=> 'System Up Time',
	serialNum				=> 'Serial Number',
	chassisVer				=> 'Chassis Version',
	softwareVersion			=> 'SoftwareVersion',
	softwareImage			=> 'Software Image',
	rttMonApplVersion		=> 'Ipsla Version',
	rttMonApplResponder		=> 'Ipsla Responder',
	last_node_config_update	=> 'Last Node Configuration Update',
	cbqosInput				=> 'Cbqos Input',
	cbqosOutput				=> 'Cbqos Output',
	location				=> 'Location',
	ifNumber				=> 'Interface Number',
	intfCollect				=> 'Interface Collect',
	RecordsExported			=> 'Netflow Records Per Second',
	RecordsExportedMax		=> 'Netflow MaxRecords Per Second'
);


# Step 5: For loading only the local nodes on a Master or a Slave
my $NODES = Compat::NMIS::loadLocalNodeTable();

my $xls;
if ($xlsFile) {
	$xls = start_xlsx(file => $xlsFile);
}
	
checkNodes($xls);

end_xlsx(xls => $xls);
print "XLS saved to $xlsFile\n";
	
print $t->elapTime(). " End\n";


sub checkNodes {
	my $xls = shift;
	my $title = "$subject ($timespan)";
	my $sheet;
	my $csvData;
	my $currow;
	my @colsize;

	print "Creating Excel Report '$title'\n";

	print "Creating csv file '$csvFile'\n";
	open(CSV,">$csvFile") or die "Error with CSV File $csvFile: $!\n";

	# print a CSV header
	my @aliases;
	my $currcol=0;
	foreach my $header (@nodeHeaders) {
		my $colLen = (($colsize[$currcol] ne '' ) ? $colsize[$currcol] : length($nodeAlias{$header}));
		my $alias = $header;
		$alias = $nodeAlias{$header} if $nodeAlias{$header};
		$colsize[$currcol] = $colLen;
		push(@aliases,$alias);
		$currcol++;
	}

	my $header = join($sep,@aliases);
	print CSV "$header\n";
	$csvData .= "$header\n";

	my $C = NMISNG::Util::loadConfTable();

	my @aliases;
	foreach my $header (@nodeHeaders) {
		my $alias = $header;
		$alias = $nodeAlias{$header} if $nodeAlias{$header};
		push(@aliases,$alias);
	}
			
	if ($xls) {
		$sheet = add_worksheet(xls => $xls, title => $title, columns => \@aliases);
		$currow = 1;								# header is row 0
	}
	else {
		die "ERROR need an xls to work on.\n";	
	}
	
	foreach my $node (sort keys %{$NODES}) {
		if ( $NODES->{$node}{active}) {
			my @comments;
			my $comment;
			my $S = NMISNG::Sys->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $nodeobj       = $nmisng->node(name => $node);
			my $IF            = $nodeobj->ifinfo;
			my $inv           = $S->inventory( concept => 'catchall' );
			my $catchall_data = $inv->data;
			my $MDL           = $S->mdl;

			# move on if this isn't a good one.
			next if $catchall_data->{nodeVendor} !~ /Cisco/;
			
			# is there a decent serial number!
			if ( not defined $catchall_data->{serialNum} or $catchall_data->{serialNum} eq "" or $catchall_data->{serialNum} eq "noSuchObject" ) {
				my %slots  =  undef;
				my %assets =  undef;

				if ( defined $MDL->{systemHealth}{sys}{entityMib} and ref($MDL->{systemHealth}{sys}{entityMib}) eq "HASH") {
					my $result = $S->nmisng_node->get_inventory_model( concept => "entityMib", filter => { historic => 0 });
					if (!$result->error)
					{
						%slots = map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});
					}
				}

				if ( defined $MDL->{systemHealth}{sys}{ciscoAsset} and ref($MDL->{systemHealth}{sys}{ciscoAsset}) eq "HASH") {
					my $result = $S->nmisng_node->get_inventory_model( concept => "ciscoAsset", filter => { historic => 0 });
					if (!$result->error)
					{
						%assets = map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});
					}
				}

				# lets just see if we can find one!
				# this logic works well for Nexus devices which are 149
				foreach my $slotIndex (sort keys %{slots}) {
					if ( defined $slots{$slotIndex}{entPhysicalClass} 
						and $slots{$slotIndex}{entPhysicalClass} =~ /chassis/
						and $slots{$slotIndex}{entPhysicalSerialNum} ne ""
					) {
						$catchall_data->{serialNum} = $slots{$slotIndex}{entPhysicalSerialNum};
						print "INFO: '$NODES->{$node}{name}' Found Serial Number '$catchall_data->{serialNum}' at EntityMIB index $slotIndex.\n" if ($debug);
					}
				}

				# just use the specific index thing for serial number.
				if ( defined $slots{1} and $slots{1}{entPhysicalSerialNum} ne "" ) {
					$catchall_data->{serialNum} = $slots{1}{entPhysicalSerialNum};
					print "INFO: '$NODES->{$node}{name}' Found Serial Number '$catchall_data->{serialNum}' at entPhysicalSerialNum index 1.\n" if ($debug);
				}
				# this works for ME3800
				elsif ( defined $slots{1001} and $slots{1001}{entPhysicalSerialNum} ne "" ) {
					$catchall_data->{serialNum} = $slots{1001}{entPhysicalSerialNum};
					print "INFO: '$NODES->{$node}{name}' Found Serial Number '$catchall_data->{serialNum}' at entPhysicalSerialNum index 1001.\n" if ($debug);
				}
				# this works for IOSXR, CRS, ASR9K
				elsif ( defined $slots{24555730} and $slots{24555730}{entPhysicalSerialNum} ne "" ) {
					$catchall_data->{serialNum} = $slots{24555730}{entPhysicalSerialNum};
					print "INFO: '$NODES->{$node}{name}' Found Serial Number '$catchall_data->{serialNum}' at entPhysicalSerialNum index 24555730.\n" if ($debug);
				}
				# Cisco 61xx DSLAM's
				elsif ( defined $assets{1} and $assets{1}{ceAssetSerialNumber} ne "" ) {
					$catchall_data->{serialNum} = $assets{1}{ceAssetSerialNumber};
					print "INFO: '$NODES->{$node}{name}' Found Serial Number '$catchall_data->{serialNum}' at ceAssetSerialNumber index 1.\n" if ($debug);
				}

				if ( $catchall_data->{serialNum} eq "" ) {
					$catchall_data->{serialNum} = "TBD";
					$comment = "ERROR: $node no serial number not in chassisId entityMib or ciscoAsset";
					print "$comment\n";
					push(@comments,$comment);
				}

				## quadruple enrichment!

				# is this a CRS with two rack chassis stuff.
				if ( defined $slots{24555730} and $slots{24555730}{entPhysicalSerialNum} ne "" 
					and defined $slots{141995845} and $slots{141995845}{entPhysicalSerialNum} ne "" 
				) {
					my $chassis1Name   = $slots{24555730}{entPhysicalName};
					my $chassis1Serial = $slots{24555730}{entPhysicalSerialNum};
					my $chassis2Name   = $slots{141995845}{entPhysicalName};
					my $chassis2Serial = $slots{141995845}{entPhysicalSerialNum};
	
					$catchall_data->{serialNum} = "$chassis1Name $chassis1Serial; $chassis2Name $chassis2Serial";
				}
				# is this a CRS with ONE rack chassis stuff.
				elsif ( defined $slots{24555730} 
					and $slots{24555730}{entPhysicalSerialNum} ne "" 
					and $slots{24555730}{entPhysicalName} =~ /Rack/
				) {
					my $chassis1Name = $slots{24555730}{entPhysicalName};
					my $chassis1Serial = $slots{24555730}{entPhysicalSerialNum};

					$catchall_data->{serialNum} = "$chassis1Name $chassis1Serial";
				}
			}

		    if ( not defined $NODES->{$node}{location} or $NODES->{$node}{location} eq "" ) {
		    	$NODES->{$node}{location} = "No Location Configured";
		    }
		    
		    my $last_node_config_update = $catchall_data->{last_node_config_update};
		    my $bootConfigLastChanged = $catchall_data->{bootConfigLastChanged};
		    if ($last_node_config_update =~ /^\d+$/) {
				$last_node_config_update = NMISNG::Util::returnDateStamp($last_node_config_update);
				$catchall_data->{"last_node_config_update"} = "$last_node_config_update";
				$NODES->{$node}{"last_node_config_update"} = "$last_node_config_update";
		    }
		    	    
			### Cisco Node Configuration Change Only
			if( defined $last_node_config_update && defined $bootConfigLastChanged ) {
				
				### when the router reboots bootConfigLastChanged = 0 and last_node_config_update is about 2 seconds, which are the changes made by booting.
				if( $last_node_config_update > $bootConfigLastChanged and $last_node_config_update > 5000 ) {
					$catchall_data->{"configurationState"} = "Config Not Saved in NVRAM";
				} 
				elsif( $bootConfigLastChanged == 0 and $last_node_config_update <= 5000 ) {
					$catchall_data->{"configurationState"} = "Config Not Changed Since Boot";
				} 
				else {
					$catchall_data->{"configurationState"} = "Config Saved in NVRAM";
				}
			}

			if ( defined $MDL->{systemHealth}{sys}{Cisco_CBQoS} and ref($MDL->{systemHealth}{sys}{Cisco_CBQoS}) eq "HASH") {
				my $result = $S->nmisng_node->get_inventory_model( concept => "Cisco_CBQoS", filter => { historic => 0 });
				if (!$result->error)
				{
					my %qosMap = map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});
					my @input;
					my @output;
					foreach my $cbqos (keys %qosMap) {
						my $qDesc = $qosMap{$cbqos}{ifDescr};
						$qDesc = "Unnamed" if (!$qDesc || $qDesc eq "");
						push(@input,$qDesc)  if $qosMap{$cbqos}{cbQosPolicyDirection} eq "input";
						push(@output,$qDesc) if $qosMap{$cbqos}{cbQosPolicyDirection} eq "output";	
					}
					push(@input,"None found")  if not @input;
					push(@output,"None found") if not @output;	    	
					
					$NODES->{$node}{cbqosInput}  = join(";",@input);
					$NODES->{$node}{cbqosOutput} = join(";",@output);
				}
			}
			else {
				print "ERROR: $node no Cisco_CBQoS MIB Data available, check the model contains it and run an update on the node.\n" if $debug > 1;
			}

			# Get the summary stats
			my $begin    = @tsStartArray[0];
			my $end      = @tsEndArray[0];
			print "Compat::NMIS::getSummaryStats(sys=>\$S,type=>'NetFlowStats',start=>$begin,end=>$end,index=>)\n" if ($debug > 2);
			my $stats = Compat::NMIS::getSummaryStats(sys=>$S,type=>"NetFlowStats",start=>$begin,end=>$end,index=>);
			if ( defined $stats->{RecordsExported} ) {
				$catchall_data->{RecordsExported}    = $stats->{RecordsExported};
				$catchall_data->{RecordsExportedMax} = $stats->{RecordsExportedMax};
			}
			else {
				$catchall_data->{RecordsExported}    = "N/A";
				$catchall_data->{RecordsExportedMax} = "N/A";
			}
		    
		    my @columns;
			$currcol=0;
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
				$colLen = ((length($data) > 253 || length($nodeAlias{$header}) > 253) ? 253 : ((length($data) > $colLen) ? length($data) : $colLen));
		    	$data = changeCellSep($data);
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
	close CSV;
	my $i=0;
	foreach my $header (@nodeHeaders) {
		$sheet->set_column( $i, $i, $colsize[$i]+2);
		$i++;
	}
	if ( defined $arg->{email} and $arg->{email} ne "" ) {
		my $content = "Report for '$title' attached.\n";
		notifyByEmail(email => $email, subject => $subject, content => $content, csvName => "$csvFile", csvData => $csvData);
	}

}

sub notifyByEmail {
	my %args = @_;

	my $email = $args{email};
	my $subject = $args{subject};
	my $content = $args{content};
	my $csvName = $args{csvName};
	my $csvData = $args{csvData};

	if ($content && $email) {

		print "Sending email with '$csvName' to '$email'\n" if $debug;

		my $entity = MIME::Entity->build(
			From=>$C->{mail_from}, 
			To=>$email,
			Subject=> $subject,
			Type=>"multipart/mixed"
		);

		# pad with a couple of blank lines
		$content .= "\n\n";

		$entity->attach(
			Data => $content,
			Disposition => "inline",
			Type  => "text/plain"
		);
										
		if ( $csvData ) {
			$entity->attach(
				Data => $csvData,
				Disposition => "attachment",
				Filename => $csvName,
				Type => "text/csv"
			);
		}

		my ($status, $code, $errmsg) = NMISNG::Notify::sendEmail(
			# params for connection and sending 
			sender => $C->{mail_from},
			recipients => [$email],
		
			mailserver => $C->{mail_server},
			serverport => $C->{mail_server_port},
			hello => $C->{mail_domain},
			usetls => $C->{mail_use_tls},
			ipproto =>  $C->{mail_server_ipproto},
								
			username => $C->{mail_user},
			password => $C->{mail_password},
		
			# and params for making the message on the go
			to => $email,
			from => $C->{mail_from},
		
			subject => $subject,
			mime => $entity,
			priority => "Normal",
		
			debug => $C->{debug}
		);
		
		if (!$status)
		{
			print "Error: Sending email to '$email' failed: $code $errmsg\n";
		}
		else
		{
			print "Email to '$email' sent successfully\n";
		}
	}
} 


sub changeCellSep {
	my $string = shift;
	$string =~ s/$sep/;/g;
	$string =~ s/\r\n/\\n/g;
	$string =~ s/\n/\\n/g;
	return $string;
}


sub start_xlsx
{
	my (%args) = @_;

	my ($xls);
	if ($args{file})
	{
		$xls = Excel::Writer::XLSX->new($args{file});
		die "Cannot create XLSX file ".$args{file}.": $!\n" if (!$xls);
	}
	else {
		die "ERROR need a file to work on.\n";	
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
# [period=<day|week|month>] (default: '$dfltPeriod')
sub usage {
	print <<EO_TEXT;
Usage: $PROGNAME -a -d[=[0-9]] -h -u -v dir=<directory> [option=value...]

$PROGNAME will generate a Cisco Device Report from data in NMIS.

Arguments:
 dir=<Drectory where files should be saved>
 [conf=<Configuration file>] (default: '$defaultConf');
 [email=<Email Address>]
 [separator=<Comma separated  value (CSV) separator character>] (default: tab)
 [timespan=<24[hours]|HH:HH>] (default: '$dfltTimespan')
 [xls=<Excel filename>] (default: '$xlsFile')
 [subject="contents of subject"] (with datestamp appended automatically)

Enter $PROGNAME -h for compleate details.

eg: $PROGNAME dir=/tmp debug=true subject="Cisco Device Report" email=user1\@domain.com,user2\@domain.com
\n
EO_TEXT
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
   push(@lines, "       $PROGNAME -  Will generate a Cisco Device Report from data\n");
   push(@lines, "        in NMIS into an Excel spredsheet.\n");
   push(@lines, "\n");
   push(@lines, "\033[1mSYNOPSIS\033[0m\n");
   push(@lines, "       $PROGNAME [options...] dir=<directory> [option=value] ...\n");
   push(@lines, "\n");
   push(@lines, "\033[1mDESCRIPTION\033[0m\n");
   push(@lines, "       The $PROGNAME program Exports NMIS nodes into an Excel spreadsheet in\n");
   push(@lines, "       the specified directory with the required 'dir' parameter. The command\n" );
   push(@lines, "       also creates Comma Separated Value (CSV) files in the same directory.\n");
   push(@lines, "\n");
   push(@lines, "\033[1mOPTIONS\033[0m\n");
   push(@lines, " --averages               - Collect usage averages over a period of time.\n");
   push(@lines, " --debug=[1-9|true|false] - global option to print detailed messages\n");
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
   push(@lines, "                                 email address.\n");
   #push(@lines, "     [period=<day|week|month>]\n");
   #push(@lines, "                             - An optional date range to collect when the\n");
   #push(@lines, "                                  'averages' option is specified.\n");
   #push(@lines, "                                   One of 'day', 'week', or 'month'.\n");
   #push(@lines, "                                (default: '$dfltPeriod')\n");
   push(@lines, "     [separator=<character>] - A character to be used as the separator in the\n");
   push(@lines, "                                 CSV files. The words 'comma' and 'tab' are\n");
   push(@lines, "                                 understood. Other characters will be taken\n");
   push(@lines, "                                 literally. (default: 'tab')\n");
   push(@lines, "     [subject=<contents of subject>]\n");
   push(@lines, "                             - A string to be used as the subject line.\n");
   push(@lines, "                                 The datestamp will be appended automatically.\n");
   push(@lines, "                                (default: '$dfltSubject')\n");
   push(@lines, "     [timespan=<24[hours]|HH:HH>]\n");
   push(@lines, "                             - An optional timespan for collection when the\n");
   push(@lines, "                                  'averages' option is specified.\n");
   push(@lines, "                                   Either '24hours', or a start hour and a\n");
   push(@lines, "                                   stop hour in 24 hour format separated by a\n");
   push(@lines, "                                   colon.\n");
   push(@lines, "                                (default: '$dfltTimespan')\n");
   push(@lines, "     [xls=<filename>]        - The name of the XLS file to be created in the\n");
   push(@lines, "                                 directory specified using the 'dir' parameter'.\n");
   push(@lines, "                                 (default: '$xlsFile')\n");
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
