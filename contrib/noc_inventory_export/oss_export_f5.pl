#!/usr/bin/perl
#
## $Id: export_nodes.pl,v 1.1 2012/08/13 05:09:17 keiths Exp $
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
my $averagesw     = 0;
my $debugsw       = -1;
my $helpsw        = 0;
my $interfacesw   = 0;
my $tsEnd         = 0;
my $tsStart       = 0;
my $usagesw       = 0;
my $versionsw     = 0;
my $defaultConf   = abs_path("$FindBin::Bin/../../conf");
my $dfltPeriod    = 'day';
my $dfltTimespan  = '24hours';
my $xlsFile       = "oss_export.xlsx";
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

# --debug or -d returns 0, so we have to fix the handling.
if ($debugsw == 0)
{
	$debugsw = 1;
}
elsif ($debugsw == -1)
{
	$debugsw = 0;
}

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
	print "Period   = '$period'.\n";
	print "Timespan = '$timespan'.\n";
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

# A cache of Card Indexes.
my $cardIndex;

# Step 2: Define the overall order of all the fields.


my @nodeHeaders = qw(name uuid ossType nodeVendor ossModel sysDescr softwareVersion ossStatus serialNum name2 name3 relayRack location uplink comment);

# Step 4: Define any CSV header aliases you want
my %nodeAlias = (
	name				=> 'Dslam Name',
	uuid				=> 'Equipment ID',
	ossType				=> 'Type',
	nodeVendor			=> 'Name of the Vendor',
	ossModel			=> 'Model',
	sysDescr			=> 'Description of the equipment',
	softwareVersion		=> 'SW Version',
	ossStatus			=> 'Status',
	serialNum			=> 'SerialNumber',
	name2				=> 'Name of the node in the Network',
	name3				=> 'Name in NMS',
	relayRack			=> 'Relay Rack name',
	location			=> 'Location',
	uplink				=> 'UpLink',
	comment				=> 'Comment'
);

# my @F5_PoolsHeaders = qw(poolName poolMemberName poolMemberAddress poolMemberPort poolMemberAvail curConns bitsIn bitsOut pktsIn pktsOut);

#my %F5_PoolsAlias = (
#	poolName			=> 'Pool Name',
#	poolMemberName		=> 'Member Name',
#	poolMemberAddress	=> 'Member Address',
#	poolMemberPort		=> 'Member Port',
#	poolMemberAvail		=> 'Member Availability'
#);

# Step 5: For loading only the local nodes on a Master or a Slave
my $NODES = Compat::NMIS::loadLocalNodeTable();

#What vendors are we going to process
my $goodVendors = qr/F5 Labs, Inc./;

#What models are we going to process
my $goodModels = qr/F5-BigIP/;

#What devices need to get Max message size updated
my $fixMaxMsgSize = qr/cat650.|ciscoWSC65..|cisco61|cisco62|cisco60|cisco76/;

# Step 6: Run the program!

# Step 7: Check the results

nodeCheck();

my $xls;
if ($xlsFile) {
	$xls = start_xlsx(file => $xlsFile);
}

exportNodes($xls,"$dir/oss-nodes.csv");
exportInventory(xls => $xls, file => "$dir/oss-interfaces-data.csv", title => "Interfaces", section => "interface", model_section => "standard", model_section_top => "interface", averages => 0);
exportInventory(xls => $xls, file => "$dir/oss-f5-pools-data.csv", title => "F5 Pools", section => "F5_Pools", averages => 0);
exportInventory(xls => $xls, file => "$dir/oss-virtual-server-table-data.csv", title => "Virtual Server Table", section => "VirtualServTable", averages => 0);
exportInventory(xls => $xls, file => "$dir/oss-f5-temperature-data.csv", title => "F5 Temperature", section => "F5_Temperature", averages => 0);
exportInventory(xls => $xls, file => "$dir/oss-f5_cpu-data.csv", title => "F5 CPU", section => "F5_CPU", averages => $averagesw);
exportInventory(xls => $xls, file => "$dir/oss-f5_core-data.csv", title => "F5 Cores", section => "F5_Cores", averages => $averagesw);
exportInventory(xls => $xls, file => "$dir/oss-f5_memory-data.csv", title => "F5 Memory", section => "F5_Memory", averages => $averagesw);
exportInventory(xls => $xls, file => "$dir/oss-f5_swap_memory-data.csv", title => "F5 Swap Memory", section => "F5_Swap_Memory", averages => $averagesw);
exportInventory(xls => $xls, file => "$dir/oss-f5-storage-data.csv", title => "F5_Storage", section => "F5_Storage", averages => 0);

end_xlsx(xls => $xls);
print "XLS saved to $xlsFile\n";

print $t->elapTime(). " End\n";

sub exportNodes {
	my $xls   = shift;
	my $file  = shift;
	my $title = "Nodes";
	my $sheet;
	my $currow;
	my $csvData;
	my @colsize;

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

	foreach my $node (sort keys %{$NODES}) {
		print "DEBUG: '$NODES->{$node}{name}' Active Status is $NODES->{$node}{active}.\n" if ($debug > 1);
		if ( $NODES->{$node}{active} ) {
			my @comments;
			my $comment;
			my $S = NMISNG::Sys->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $nodeobj       = $nmisng->node(name => $node);
			my $IF            = $nodeobj->ifinfo;
			my $inv           = $S->inventory( concept => 'catchall' );
			my $catchall_data = $inv->data;
			my $MDL           = $S->mdl;

			print "DEBUG: System Object: " . Dumper($S) . "\n\n\n" if ($debug > 8);
			print "DEBUG: '$NODES->{$node}{name}' Node Down Status is $catchall_data->{nodedown}.\n" if ($debug);

			my $nodestatus = $catchall_data->{nodestatus};
			$nodestatus = "unreachable" if $catchall_data->{nodedown} eq "true";

			if ($debug > 1) {
				print "DEBUG: '$NODES->{$node}{name}' vendor is '$catchall_data->{nodeVendor}'.\n";
				my $hasEntityMib = ((defined $MDL->{systemHealth}{sys}{entityMib}) ? "has" : "does not have");
				print "DEBUG: '$NODES->{$node}{name}' $hasEntityMib an entityMib.\n";
			}

			# move on if this isn't a good one.
			if ($catchall_data->{nodeVendor} !~ /$goodVendors/) {
				print "DEBUG: Ignoring system '$NODES->{$node}{name}' as vendor $catchall_data->{nodeVendor} does not qualify.\n" if ($debug);
				next;
			}

			# check for data prerequisites
			if ( $catchall_data->{nodeVendor} =~ /$goodVendors/ and not defined $MDL->{systemHealth}{sys}{entityMib} and $nodestatus eq "reachable" ) {
				$comment = "ERROR: $node is $catchall_data->{nodeVendor} and entityMib data missing";
				print "$comment\n";
				push(@comments,$comment);
			}

			# not got anything useful, try and parse it out of the sysDescr.
			if ( not defined $catchall_data->{softwareVersion} or $catchall_data->{softwareVersion} eq "" ) {
				$catchall_data->{softwareVersion} = getVersion($catchall_data->{sysDescr});
			}

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

			#my @nodeHeaders = qw(name uuid ossType nodeVendor ossModel sysDescr softwareVersion ossStatus serialNum name2 name3 tbd4 group tbd5);
		    
			# clone the name!
			$NODES->{$node}{name2} = $NODES->{$node}{name};
			$NODES->{$node}{name3} = $NODES->{$node}{name};
	    
			# handling OSS values for these fields.
			$NODES->{$node}{ossStatus} = $nodestatus;
			$NODES->{$node}{ossModel}  = getModel($catchall_data->{sysObjectName});
			$NODES->{$node}{ossType}   = getType($catchall_data->{sysObjectName},$catchall_data->{nodeType});

			$NODES->{$node}{comment} = join($joinChar,@comments);

			if ( not defined $NODES->{$node}{relayRack} or $NODES->{$node}{relayRack} eq "" ) {
				$NODES->{$node}{relayRack} = "No Relay Rack Configured";
			}

			if ( not defined $NODES->{$node}{location} or $NODES->{$node}{location} eq "" ) {
				$NODES->{$node}{location} = "No Location Configured";
			}
	    		    
			my @columns;
			my $currcol=0;
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
	my $i=0;
	foreach my $header (@nodeHeaders) {
		$sheet->set_column( $i, $i, $colsize[$i]+2);
		$i++;
	}

	close CSV;
	my $content = "Report for '$title' attached.\n";
	notifyByEmail(email => $email, subject => $title, content => $content, csvName => "$file", csvData => $csvData) if ($email);
}


sub exportInventory {
	my (%args)   = @_;
	my $xls      = $args{xls};
	my $avgFile  = $args{file};
	my $invFile  = $args{file};
	my $avgTitle = $args{section};
	my $invTitle = $args{section};
	my $section  = $args{section};
	my $averages = $args{averages};
	my $found    = 0;
	my $avgPage  = 0;
	my $avgSheet;
	my $invSheet;
	my $avgCurRow;
	my $invCurRow;
	my $avgCSVData;
	my $invCSVData;
	my @exceptions;
	my @avgColSize;
	my @invColSize;

	$invTitle =  $args{title} if defined $args{title};
	$avgTitle =  "$invTitle Averages ($timespan)";
	$avgFile  =~ s/\.csv/_avg.csv/;

	die "I must know which section!" if not defined $args{section};

	my $model_section_top = "systemHealth";
	$model_section_top = $args{model_section_top} if defined $args{model_section_top};

	my $model_section = $section;
	$model_section = $args{model_section} if defined $args{model_section};

	print "Exporting model_section_top=$model_section_top model_section=$model_section section=$section\n";

	print "Creating '$invTitle' sheet with section $section\n";


	# Declare some vars for filling in later.
	my @avgHeaders;
	my @invHeaders;
	my %avgAlias;
	my %invAlias;

	foreach my $node (sort keys %{$NODES}) {
	  if ( $NODES->{$node}{active} ) {
			my $S = NMISNG::Sys->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $nodeobj       = $nmisng->node(name => $node);
			my $inv           = $S->inventory( concept => 'catchall' );
			my $catchall_data = $inv->data;
			my $MDL           = $S->mdl;
			print "DEBUG: Model " . Dumper($MDL) . "\n\n\n" if ($debug > 8);

			# move on if this isn't a good one.
			if ($catchall_data->{nodeVendor} !~ /$goodVendors/) {
				print "DEBUG: Ignoring system '$NODES->{$node}{name}' as vendor $catchall_data->{nodeVendor} does not qualify.\n" if ($debug);
				next;
			}

			# handling for this is device/model specific.
			my %invConcept = undef;
			my %avgConcept = undef;

			if ( $catchall_data->{nodeModel} =~ /$goodModels/ or $catchall_data->{nodeVendor} =~ /$goodVendors/ ) {
				if (( defined $MDL->{system}{rrd}{$section} and ref($MDL->{system}{rrd}{$section}) eq "HASH")
						or ( defined $MDL->{interface}{sys}{$section} and ref($MDL->{interface}{sys}{$section}) eq "HASH")
						or ( defined $MDL->{systemHealth}{sys}{$section} and ref($MDL->{systemHealth}{sys}{$section}) eq "HASH")) {
					my $result = $S->nmisng_node->get_inventory_model( concept => "$section", filter => { historic => 0 });
					print "DEBUG: Concept '$section' Result " . Dumper($result) . "\n\n\n" if ($debug > 8);
					if (!$result->error)
					{
						%invConcept = map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});
						print "DEBUG: Concept '$section' Object: " . Dumper(%invConcept) . "\n\n\n" if ($debug > 3);
					}
					else {
						print "ERROR: $node no $section MIB Data available, check the model contains it and run an update on the node.\n" if $debug > 1;
						next;
					}
				}
				else {
					print "ERROR: $node no $section MIB Data available, check the model contains it and run an update on the node.\n" if $debug > 1;
					next;
				}

				####################################################################################
				#
				# Averages for one day is just added to the normal files as an additional column.
				#
				####################################################################################
				if ($averages && $period eq 'day') {
					my %avgTestHash;
					foreach my $idx (sort keys %invConcept) {
						if ( defined $invConcept{$idx} ) {
							if (-f (my $rrdfilename = $S->makeRRDname(type => $section, index => $idx))) {
								my $begin    = @tsStartArray[0];
								my $end      = @tsEndArray[0];
								print "Compat::NMIS::getSummaryStats(sys=>$S,type=>$section,start=>$begin,end=>$end,index=>$idx)\n" if ($debug > 2);
								my $currentStats = Compat::NMIS::getSummaryStats(sys=>$S,type=>$section,start=>$begin,end=>$end,index=>$idx);
									print "Current Statistics: " . Dumper($currentStats) . "\n\n\n" if ($debug > 2);
								if ( ref($currentStats) eq "HASH" ) {
									next if (0 == keys %$currentStats);
									print "Current Statistics: " . Dumper($currentStats) . "\n\n\n" if ($debug > 2);
									foreach my $avgIndex (keys %$currentStats) {
										my $eachIndex = $$currentStats{$avgIndex};
										foreach my $avgMetric (keys %$eachIndex) {
											my $eachMetric = $$eachIndex{$avgMetric};
											print "Index: $avgIndex:$avgMetric = '$eachMetric'\n" if ($debug > 2);
											if (!exists($avgTestHash{$avgMetric})) {
												$avgTestHash{$avgMetric} = 1;
												push(@avgHeaders, $avgMetric);
											}
											$invConcept{$avgIndex}{$avgMetric}    = $eachMetric;
										}
									}
								}
							}
							else {
								print "Unable to capture RRD data for '$section', index '$idx'.\n";
							}
						}
					}
				}
				####################################################################################
				$found = 1;

				# We know the device supports this inventory section, so on the first run of a node, setup the headers based on the model.
				if ( not @invHeaders ) {
					# create the aliases from the model data, a few static items are primed
					#print "DEBUG: $model_section_top $model_section $MDL->{$model_section_top}{sys}{$model_section}{headers}\n";
					#print Dumper $MDL;
					@invHeaders = ('node','parent','location', split(",",$MDL->{$model_section_top}{sys}{$model_section}{headers}));
					push(@invHeaders, @avgHeaders) if (@avgHeaders > 0);

					# fill in the aliases for each of the items from the model
					foreach my $heading (@invHeaders) {
						if ( defined $MDL->{$model_section_top}{sys}{$model_section}{snmp}{$heading}{title} ) {
							$invAlias{$heading} = $MDL->{$model_section_top}{sys}{$model_section}{snmp}{$heading}{title};
						}
						else {
							$invAlias{$heading} = $heading;
						}
					}
					# Set the aliases for the static items
					$invAlias{node}     = 'Node Name';
					$invAlias{parent}   = 'Parent';
					$invAlias{location} = 'Location';

					print "DEBUG: Inventory Headers for Concept '$section': " . Dumper(@invHeaders) . "\n\n\n" if ($debug > 2);
					print "DEBUG: Inventory Alias for Concept '$section': " . Dumper(%invAlias) . "\n\n\n" if ($debug > 2);

					# create a header
					my @aliases;
					my $currcol=0;
					foreach my $header (@invHeaders) {
						my $colLen = (($invColSize[$currcol] ne '' ) ? $invColSize[$currcol] : length($invAlias{$header}));
						my $alias = $header;
						$alias = $invAlias{$header} if $invAlias{$header};
						$invColSize[$currcol] = $colLen;
						push(@aliases, $alias);
						$currcol++;
					}

					if ($invFile) {
						print "Creating $invFile\n";
						open(INVCSV,">$invFile") or die "Error with CSV File $invFile: $!\n";
						# print a CSV header
						my $header = join($sep,@aliases);
						print INVCSV "$header\n";
						$invCSVData .= "$header\n";
					}
					if ($xls) {
						$invSheet = add_worksheet(xls => $xls, title => $invTitle, columns => \@aliases);
						$invCurRow = 1;								# header is row 0
					}
					else {
						die "ERROR: Internal error, xls is no longer defined.\n";
					}
				}

				foreach my $idx (sort keys %invConcept) {
					$invConcept{$idx}{node}     = $node;
					$invConcept{$idx}{parent}   = $NODES->{$node}{uuid};
					$invConcept{$idx}{location} = $NODES->{$node}{location};

					my @columns;
					my $currcol=0;
					foreach my $header (@invHeaders) {
						my $colLen = (($invColSize[$currcol] ne '' ) ? $invColSize[$currcol] : length($invAlias{$header}));
						my $data   = undef;
						if ( defined $invConcept{$idx}{$header} ) {
							$data = $invConcept{$idx}{$header};
						}
						else {
							$data = "TBD";
						}
						$data = "N/A" if $data eq "noSuchInstance";
						$colLen = ((length($data) > 253 || length($invAlias{$header}) > 253) ? 253 : ((length($data) > $colLen) ? length($data) : $colLen));
						$data   = changeCellSep($data);
						$invColSize[$currcol] = $colLen;
						push(@columns,$data);
						$currcol++;
					}
					my $row = join($sep,@columns);
					print INVCSV "$row\n";
					$invCSVData .= "$row\n";

					if ($invSheet) {
						$invSheet->write($invCurRow, 0, [ @columns[0..$#columns] ]);
						++$invCurRow;
					}
				}

				####################################################################################
				#
				# Averages for a week, or a month is separated into a new sheet/file.
				#
				####################################################################################
				if ($averages && $period ne 'day') {
					$avgPage = 1;
					print "Creating '$avgTitle' sheet with section $section\n";
					my %avgTestHash;
					my @avgBuildHeaders;
					foreach my $idx (sort keys %invConcept) {
						if (-f (my $rrdfilename = $S->makeRRDname(type => $section, index => $idx))) {
							my $now      = time();
							my $endHuman = NMISNG::Util::returnDateStamp($now);
							my $size     = scalar(@tsStartArray);
							$avgConcept{$idx}{NumberOfMetrics} = $size;
							print "There are $size days to capture\n";
							for(my $i=0; $i < $size; $i++) {
								print "Processing day $i\n";
								my $begin    = @tsStartArray[$i];
								my $end      = @tsEndArray[$i];
								my $prtBegin = NMISNG::Util::returnDateStamp($begin);
								my $prtEnd   = NMISNG::Util::returnDateStamp($end);
								print "Processing Timespan: ${prtBegin} -> ${prtEnd} \n";
								$avgConcept{$idx}{date}{$i}     = "${prtBegin} -> ${prtEnd}";
								$avgConcept{$idx}{node}{$i}     = $node;
								$avgConcept{$idx}{parent}{$i}   = $NODES->{$node}{uuid};
								$avgConcept{$idx}{location}{$i} = $NODES->{$node}{location};
								print "Compat::NMIS::getSummaryStats(sys=>$S,type=>$section,start=>$begin,end=>$end,index=>$idx)\n" if ($debug > 2);
								my $currentStats = Compat::NMIS::getSummaryStats(sys=>$S,type=>$section,start=>$begin,end=>$end,index=>$idx);
								if ( ref($currentStats) eq "HASH" ) {
									next if (0 == keys %$currentStats);
									push(@avgBuildHeaders, 'date', 'node','parent','location') if (!@avgBuildHeaders);
									print "Current Statistics: " . Dumper($currentStats) . "\n\n\n" if ($debug > 2);
									foreach my $avgIndex (keys %$currentStats) {
										my $eachIndex = $$currentStats{$avgIndex};
										foreach my $avgMetric (keys %$eachIndex) {
											my $eachMetric = $$eachIndex{$avgMetric};
											print "Index: $avgIndex:$avgMetric = '$eachMetric'\n" if ($debug > 2);
											if (!exists($avgTestHash{$avgMetric})) {
												$avgTestHash{$avgMetric} = 1;
												push(@avgBuildHeaders, $avgMetric);
											}
											$avgConcept{$avgIndex}{$avgMetric}{$i} = $eachMetric;
										}
									}
								}
							}
						}
						else {
							print "Unable to capture RRD data for '$section', index '$idx'.\n";
						}
					}
					if ( @avgBuildHeaders && !@avgHeaders ) {
						@avgHeaders = @avgBuildHeaders;
						# fill in the aliases for each of the items from the model
						foreach my $heading (@avgHeaders) {
							$avgAlias{$heading} = $heading;
						}
						# Set the aliases for the static items
						$avgAlias{date}     = 'Date';
						$avgAlias{node}     = 'Node Name';
						$avgAlias{parent}   = 'Parent';
						$avgAlias{location} = 'Location';
	
						print "DEBUG: Averages Headers for Concept '$section': " . Dumper(@avgHeaders) . "\n\n\n" if ($debug > 2);
						print "DEBUG: Averages Alias for Concept '$section': " . Dumper(%avgAlias) . "\n\n\n" if ($debug > 2);
	
						# Create a header
						my @aliases;
						my $currcol=0;
						foreach my $header (@avgHeaders) {
							my $colLen = (($avgColSize[$currcol] ne '' ) ? $avgColSize[$currcol] : length($avgAlias{$header}));
							my $alias = $header;
							$alias = $avgAlias{$header} if $avgAlias{$header};
							$avgColSize[$currcol] = $colLen;
							push(@aliases, $alias);
							$currcol++;
						}
	
						if ($avgFile) {
							print "Creating $avgFile\n";
							open(AVGCSV,">$avgFile") or die "Error with CSV File $avgFile: $!\n";
							# print a CSV header
							my $header = join($sep,@aliases);
							print AVGCSV "$header\n";
							$avgCSVData .= "$header\n";
						}
						if ($xls) {
							$avgSheet = add_worksheet(xls => $xls, title => $avgTitle, columns => \@aliases);
							$avgCurRow = 1;								# header is row 0
						}
						else {
							die "ERROR: Internal error, xls is no longer defined.\n";
						}
					}
					foreach my $idx (sort keys %avgConcept) {
						my $size = $avgConcept{$idx}{NumberOfMetrics};
						for(my $i=0; $i < $size; $i++) {
							my @columns;
							my $currcol=0;
							print "Saving day $i\n";
							foreach my $header (@avgHeaders) {
								my $colLen = (($avgColSize[$currcol] ne '' ) ? $avgColSize[$currcol] : length($avgAlias{$header}));
								my $data   = undef;
								if ( defined $avgConcept{$idx}{$header}{$i} ) {
									$data = $avgConcept{$idx}{$header}{$i};
								}
								else {
									$data = "TBD";
								}
								$data = "N/A" if $data eq "noSuchInstance";
								$colLen = ((length($data) > 253 || length($avgAlias{$header}) > 253) ? 253 : ((length($data) > $colLen) ? length($data) : $colLen));
								$data   = changeCellSep($data);
								$avgColSize[$currcol] = $colLen;
								push(@columns,$data);
								$currcol++;
							}
							my $row = join($sep,@columns);
							print AVGCSV "$row\n";
							$avgCSVData .= "$row\n";
		
							if ($avgSheet) {
								$avgSheet->write($avgCurRow, 0, [ @columns[0..$#columns] ]);
								++$avgCurRow;
							}
						}
					}
				}
				####################################################################################
			}
		}
	}
	my $i=0;
	foreach my $header (@invHeaders) {
		$invSheet->set_column( $i, $i, $invColSize[$i]+2);
		$i++;
	}
	close INVCSV;
	if ($found && $email) {
		my $content = "Report for '$invTitle' attached.\n";
		notifyByEmail(email => $email, subject => $invTitle, content => $content, csvName => "$invFile", csvData => $invCSVData);
	}
	if ($avgPage) {
		my $i=0;
		foreach my $header (@avgHeaders) {
			$avgSheet->set_column( $i, $i, $avgColSize[$i]+2);
			$i++;
		}
		close INVCSV;
		if ($found && $email) {
			my $content = "Report for '$avgTitle' attached.\n";
			notifyByEmail(email => $email, subject => $avgTitle, content => $content, csvName => "$avgFile", csvData => $avgCSVData);
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

sub getStatus {
	# no definitions found?
	return "Installed";
}

sub getModel {
	my $sysObjectName = shift;

	$sysObjectName =~ s/cisco/Cisco /g;
	if ( $sysObjectName =~ /cat(\d+)/ ) {
		$sysObjectName = "Cisco Catalyst $1";
	}

	return $sysObjectName;
}

sub getType {
	my $sysObjectName = shift;
	my $nodeType = shift;
	my $type = "TBD";

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

$PROGNAME will export nodes and ports from NMIS.

Arguments:
 dir=<Drectory where files should be saved>
 [conf=<Configuration file>] (default: '$defaultConf');
 [email=<Email Address>]
 [period=<day|week|month>] (default: '$dfltPeriod')
 [timespan=<24[hours]|HH:HH>] (default: '$dfltTimespan')
 [separator=<Comma separated  value (CSV) separator character>] (default: tab)
 [xls=<Excel filename>] (default: '$xlsFile')

Enter $PROGNAME -h for compleate details.

eg: $PROGNAME dir=/data separator=(comma|tab)
\n
EO_TEXT
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

sub nodeCheck {

	my $LNT = Compat::NMIS::loadLocalNodeTable();
	print "Running nodeCheck for nodes, model use, snmp max_msg_size and update\n";
	my %updateList;

	foreach my $node (sort keys %{$LNT}) {
		#print "Processing $node\n";
		if ( $LNT->{$node}{active} ) {
			my $S = NMISNG::Sys->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $nodeobj       = $nmisng->node(name => $node);
			my $inv           = $S->inventory( concept => 'catchall' );
			my $catchall_data = $inv->data;

			if ( $catchall_data->{lastUpdatePoll} < time() - 86400 ) {
				$updateList{$node} = $catchall_data->{lastUpdatePoll};
			}


			if ( $LNT->{$node}{model} ne "automatic" ) {
				print "WARNING: $node model not automatic; $LNT->{$node}{model} $catchall_data->{sysDescr}\n";
			}

			#print "updateMaxSnmpMsgSize $node $catchall_data->{sysObjectName}\n";


			if ( $catchall_data->{sysObjectName} =~ /$fixMaxMsgSize/ and $LNT->{$node}{max_msg_size} != 2800) {
				print "$node Updating Max SNMP Message Size\n";
				$LNT->{$node}{max_msg_size} = 2800;
			}
		}
	}

	print "Nodes requiring update:\n";
	foreach my $node (sort keys %updateList) {
		print "$node ". NMISNG::Util::returnDateStamp($updateList{$node}) ."\n";
	}

	NMISNG::Util::writeTable(dir => 'conf', name => "Nodes", data => $LNT);
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
   push(@lines, "       $PROGNAME -  Exports nodes and ports from NMIS into an Excel spredsheet.\n");
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
   push(@lines, "     [period=<day|week|month>]\n");
   push(@lines, "                             - An optional date range to collect when the\n");
   push(@lines, "                                  'averages' option is specified.\n");
   push(@lines, "                                   One of 'day', 'week', or 'month'.\n");
   push(@lines, "                                (default: '$dfltPeriod')\n");
   push(@lines, "     [separator=<character>] - A character to be used as the separator in the\n");
   push(@lines, "                                 CSV files. The words 'comma' and 'tab' are\n");
   push(@lines, "                                 understood. Other characters will be taken\n");
   push(@lines, "                                 literally. (default: 'tab')\n");
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
