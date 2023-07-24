#!/usr/bin/env perl
#
#  Copyright Opmantek Limited (www.opmantek.com)
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
#
# Export the Dslam interfaces.

use strict;
our $VERSION = "2.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use Compat::NMIS;
use Compat::Timing;
use Cwd 'abs_path';
use Data::Dumper;
use Data::Dumper;
use Excel::Writer::XLSX;
use File::Basename;
use File::Path qw(make_path remove_tree);
use File::Path;
use Getopt::Long;
use MIME::Entity;
use NMISNG::Sys;
use NMISNG::Util;
use Net::SFTP::Foreign;
use Net::SNMP qw(oid_lex_sort);
use POSIX qw();
use Term::ReadKey;

# this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX), also the stat modes
use Fcntl qw(:DEFAULT :flock :mode);
use Errno qw(EAGAIN ESRCH EPERM);

my $PROGNAME    = basename($0);
my $configsw    = 0;
my $debugsw     = -1;
my $ftpsw       = 0;
my $helpsw      = 0;
my $interfacesw = 0;
my @invHeaders;
my $usagesw     = 0;
my $versionsw   = 0;
my $csvData;
my $defaultConf = "$FindBin::Bin/../../conf";
my $xlsFile     = "DslamPortExport";

my $exportConfig;
my $exportFiles;
my $sep = "|";
my %headerDone;

$defaultConf = "$FindBin::Bin/../conf" if (! -d $defaultConf);
$defaultConf = abs_path($defaultConf);
print("Default Configuration directory is '$defaultConf'\n");

die unless (GetOptions('config'      => \$configsw,
						'debug:i'    => \$debugsw,
						'ftp'        => \$ftpsw,
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
my $ftp     = $ftpsw;
$debug      = NMISNG::Util::getdebug_cli($arg->{debug}) if (exists($arg->{debug}));   # Backwards compatibility
$ftp        = NMISNG::Util::getbool_cli($arg->{ftp})    if (exists($arg->{ftp}));     # Backwards compatibility
($arg->{ftp}) if (exists($arg->{ftp}));   # Backwards compatibility
print "Debug = '$debug'\n" if ($debug);

if ( not defined $arg->{conf}) {
	$arg->{conf} = $defaultConf;
}
else {
	$arg->{conf} = abs_path($arg->{conf});
}

print "Configuration Directory = '$arg->{conf}'\n" if ($debug);
# load configuration table
our $C      = NMISNG::Util::loadConfTable(dir=>$arg->{conf}, debug=>$debug);

if ($configsw) {
	print "Updating/creating Configuration file for DslamPortExport. \n";
	createConfigFile();
	exit(0);
}

if (NMISNG::Util::existFile(dir=>'conf', name=>"DslamPortExportTest"))
{
	$exportConfig = NMISNG::Util::loadTable(dir=>'conf', name=>'DslamPortExportTest');
	if ($debug)
	{
		print "Export Base Directory            = '$exportConfig->{exportBaseDir}'\n"      if (defined $exportConfig->{exportBaseDir});
		print "Export FTP Server                = '$exportConfig->{exportFtpServer}'\n"    if (defined $exportConfig->{exportFtpServer});
		print "Export FTP User Name             = '$exportConfig->{exportFtpUser}'\n"      if (defined $exportConfig->{exportFtpUser});
		print "Export FTP Password              = '$exportConfig->{exportFtpPassword}'\n"  if (defined $exportConfig->{exportFtpPassword});
		print "Export FTP Destination Directory = '$exportConfig->{exportFtpDirectory}'\n" if (defined $exportConfig->{exportFtpDirectory});
	}
}

my $t = Compat::Timing->new();

# Variables for command line munging
my $arg = NMISNG::Util::get_args_multi(@ARGV);
if ( defined $exportConfig->{exportBaseDir} &&  not defined $arg->{dir} )
{
	$arg->{dir} = $exportConfig->{exportBaseDir};
}

# Set Directory level.
if ( not defined $arg->{dir} ) {
	print "ERROR: The directory argument is required!\n";
	help(2);
	exit 255;
}
my $dir = abs_path($arg->{dir});

# set a default value and if there is a CLI argument, then use it to set the option
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
		help(2);
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

# Set Directory level.
if ( defined $arg->{xls} ) {
	$xlsFile = $arg->{xls};
}
$xlsFile = getFileName("$dir/$xlsFile", $C->{server_name}, "xlsx");

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
	print "Would you like me to overwrite it and all corresponding CSV files? (y/n)  y\b";
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

if ( $ftp ) {
	if (!NMISNG::Util::existFile(dir=>'conf', name=>"DslamPortExportTest"))
	{
		print "Configuration file for DslamPortExport does not exist, which is required for FTP. \n";
		createConfigFile();
	}
}

print $t->elapTime(). " Begin\n";

our $nmisng = Compat::NMIS::new_nmisng();
our $NODES  = Compat::NMIS::loadLocalNodeTable();

#This can be added to the list below if needed
#	atmIfIndex	
my @asamHeaders = qw( 
		ifDescr
		ifIndex
		sysUpTime
		ifLastChange
		ifOperStatus         
		ifAdminStatus
		xdslLinkUpActualNoiseMarginDownstream
		xdslLinkUpActualNoiseMarginUpstream
		xdslLinkUpAttenuationDownstream
		xdslLinkUpAttenuationUpstream
		xdslFarEndLineLoopAttenuationDownstream
		xdslLineLoopAttenuationUpstream
		xdslLineServiceProfileName
		xdslLineServiceProfileNbr
		xdslLinkUpAttainableBitrateDownstream
		xdslLinkUpAttainableBitrateUpstream
		xdslLinkUpActualBitrateDownstream
		xdslLinkUpActualBitrateUpstream
		xdslLineOutputPowerDownstream
		xdslFarEndLineOutputPowerUpstream
		xdslLinkUpMaxBitrateDownstream
		xdslLinkUpMaxBitrateUpstream
		asamIfExtCustomerId
		xdslXturInvSystemSerialNumber
	);

my %asamAlias = (
	node                                     => 'OLT Name',
	host                                     => 'OLT IP',
	sysUpTime                                => 'Ultimo Sincronismo',
	last_update                              => 'Ultimo Datos Actualizar',
	ifIndex                                  => 'Index of port',
	ifDescr                                  => 'Port',
	ifLastChange                             => 'Ultima Bajada',
	ifOperStatus                             => 'Condicion Operativa',
	ifAdminStatus                            => 'Condicion Administrativa',
	adslAtucChanCurrTxRate                   => 'Velocidad Puerto DN',
	adslAturChanCurrTxRate                   => 'Velocidad Puerto UP',
	xdslFarEndLineLoopAttenuationDownstream  => 'Loop Atenuacion Bajada',
	xdslLineLoopAttenuationUpstream          => 'Loop Atenuacion Subida',
	xdslLineServiceProfileNbr                => 'Numero Profile',
	xdslLinkUpActualBitrateDownstream        => 'Velocidad Actual DN',
	xdslLinkUpActualBitrateUpstream          => 'Velocidad Actual UP',
	xdslLineOutputPowerDownstream            => 'Potencia Dslam',
	xdslFarEndLineOutputPowerUpstream        => 'Potencia Moden',
	xdslXturInvSystemSerialNumber            => 'Serial Modem',
	xdslLineServiceProfileName               => 'Nombre Profile'
);

my @adslHeaders = qw( 
	ifDescr
	ifIndex
	sysUpTime
	ifLastChange
	ifOperStatus         
	ifAdminStatus
	adslAturCurrSnrMgn
	adslAtucCurrSnrMgn
	adslAturCurrAtn
	adslAtucCurrAtn
	xdslFarEndLineLoopAttenuationDownstream
	xdslLineLoopAttenuationUpstream
	adslLineConfProfile
	xdslLineServiceProfileNbr
	adslAtucCurrAttainableRate
	adslAturCurrAttainableRate
	xdslLinkUpActualBitrateDownstream
	xdslLinkUpActualBitrateUpstream
	xdslLineOutputPowerDownstream
	xdslFarEndLineOutputPowerUpstream
	adslAtucChanCurrTxRate
	adslAturChanCurrTxRate
	asamIfExtCustomerId
	xdslXturInvSystemSerialNumber
);

my @oltHeaders = qw( 
	sysUpTime
	hwExtSrvFlowPara2
	hwExtSrvFlowPara3
	hwExtSrvFlowPara4
	hwExtSrvFlowVlanid
	hwExtSrvFlowReceiveTrafficDescrIndex
	hwExtSrvFlowTransmitTrafficDescrIndex
	hwExtSrvFlowMultiServiceUserPara
	hwExtSrvFlowAdminStatus
	hwExtSrvFlowOperStatus
	hwExtSrvFlowDescInfo
	hwExtSrvFlowOutboundTrafficTableName
	hwExtSrvFlowInboundTrafficTableName
);

my @gponHeaders = qw( 
	hwGponDeviceOntSn
	hwGponDeviceOntPassword
	hwGponDeviceOntLineProfName
	hwGponDeviceOntServiceProfName
	hwGponDeviceOntDespt
	hwGponDeviceOntEntryStatus
	hwGponDeviceOntControlActive
	hwGponDeviceOntMainSoftVer
	hwGponDeviceOntControlRanging
	hwGponDeviceOntControlLastUpTime
	hwGponDeviceOntControlLastDownTime
	hwGponDeviceOntControlLastDownCause
	hwGponDeviceOntControlBatteryCurStatus
	hwGponOntOpticalDdmTemperature
	hwGponOntOpticalDdmBiasCurrent
	hwGponOntOpticalDdmTxPower
	hwGponOntOpticalDdmRxPower
	hwGponOntOpticalDdmVoltage
	hwXponOntInfoMemoryOccupation
	hwXponOntInfoProductDescription
);

my @gponIpHeaders = qw( 
	hwGponDeviceOntIpAddress
	hwGponDeviceOntNetMask
	hwGponDeviceOntNetGateway
);

my $xls;
if ($xlsFile) {
	$xls = start_xlsx(file => $xlsFile);
}

my $exportType = "DSLAM";

my $exportFile              = getFileName($exportType, $C->{server_name});
$exportFiles->{$exportType} = "$dir/$exportFile";
my $CSV_FH                  = getFileHandle("$dir/$exportFile");
print("Generating $exportType Export File '$dir/$exportFile'\n");

print "Working on DSLAM_Ports \n" if ($debug);

exportAsamDslamPorts(xls         => $xls,
					exportHandle => $CSV_FH,
					exportType   => $exportType,
					section      => "DSLAM_Ports",
					headers      => \@asamHeaders,
					models       => qr/AlcatelASAM/);

print("Working on ADSL_Physical\n");

exportAdslPorts(xls            => $xls,
				exportHandle   => $CSV_FH,
				exportType     => $exportType,
				section        => "ADSL_Physical",
				headers        => \@adslHeaders,
				models         => qr/CiscoDSL/,
				useIfStack     => "true");
exportAdslPorts(xls            => $xls,
				exportHandle   => $CSV_FH,
				exportType     => $exportType,
				section        => "ADSL_Physical",
				headers        => \@adslHeaders,
				models         => qr/LucentStinger/,
				useIfStack     => "false");
exportAdslPorts(xls            => $xls,
				exportHandle   => $CSV_FH,
				exportType     => $exportType,
				section        => "ADSL_Physical",
				headers        => \@adslHeaders,
				models         => qr/ZyXEL-IES/,
				useIfStack     => "false");

close($CSV_FH);
print("Closed Export File $dir/$exportFile\n");

if ( $ftp ) {
	ftpExportFile(file      => $exportFiles->{$exportType},
				  server    => $exportConfig->{exportFtpServer},
				  user      => $exportConfig->{exportFtpUser},
				  password  => $exportConfig->{exportFtpPassword},
				  directory => $exportConfig->{exportFtpDirectory},
				  nmisng    => $nmisng);
}

if ($email) {
	my $content = "Report for 'DSLAM' attached.\n";
	notifyByEmail(email => $email, subject => $content, content => "$content\n", csvName => "$dir/$exportFile", csvData => $csvData);
}
$csvData = "";

$exportType = "OLT";

$exportFile                 = getFileName($exportType, $C->{server_name});
$exportFiles->{$exportType} = "$dir/$exportFile";
$CSV_FH                     = getFileHandle("$dir/$exportFile");

print("Generating $exportType Export File $exportFile\n");

print("Working on OLT_Ports\n");

$exportFiles->{$exportType} = "$dir/$exportFile";

exportOltPorts(xls                => $xls,
				exportHandle      => $CSV_FH,
				exportType        => $exportType,
				section           => "Service_Port",
				headers           => \@oltHeaders,
				secondary_section => "GPON_Device",
				secondary_headers => \@gponHeaders,
				tertiary_section  => "GPON_Device_IP",
				tertiary_headers  => \@gponIpHeaders,
				models            => qr/Huawei-MA5600/);

close($CSV_FH);
print("Closed Export File $dir/$exportFile\n");

if ($email) {
	my $content = "Report for 'OLT' attached.\n";
	notifyByEmail(email => $email, subject => "$content", content => "$content\n", csvName => "$dir/$exportFile", csvData => $csvData);
}

if ( $ftp ) {
	ftpExportFile(file      => $exportFiles->{$exportType},
				  server    => $exportConfig->{exportFtpServer},
				  user      => $exportConfig->{exportFtpUser},
				  password  => $exportConfig->{exportFtpPassword},
				  directory => $exportConfig->{exportFtpDirectory},
				  nmisng    => $nmisng);
}

NMISNG::Util::writeTable(dir => "conf", name => "DslamPortFiles", data => $exportFiles);

exit (0);

# Service_Port.hwExtSrvFlowDescInfo = GPON_Device.hwGponDeviceOntPassword
# GPON_Device.index padded with .0 e.g. 4194329344.22.0 = GPON_Device_IP.index

sub exportOltPorts {
	my (%args) = @_;

	my $xls        = $args{xls};
	my $myHeaders  = $args{headers};
	my $goodModels = $args{models};
	my $exportType = $args{exportType};
	my $CSV        = $args{exportHandle};
	my $title      = $args{section};
	my $sheet;
	my $currow;
	my @colsize;

	my $section = $args{section};
	die "I must know which section!" if not defined $args{section};

	$title = $args{title} if defined $args{title};

	my $secondary_headers = $args{secondary_headers};
	my $secondary_section = $args{secondary_section};

	my $tertiary_headers = $args{tertiary_headers};
	my $tertiary_section = $args{tertiary_section};

	my $model_section_top = "systemHealth";
	$model_section_top = $args{model_section_top} if defined $args{model_section_top};

	my $model_section = $section;
	$model_section = $args{model_section} if defined $args{model_section};

	print("Exporting model_section_top=$model_section_top model_section=$model_section section=$section\n");

	# declare some vars for filling in later.
#	my @invHeaders;
	my %invAlias;
	my $modelCount = 0;

	foreach my $node (sort keys %{$NODES})
	{
		if ( $NODES->{$node}{active} == 1 )
		{
			my $S = NMISNG::Sys->new(nmisng => $nmisng);
			my $nodeobj = $nmisng->node(name => $node);
			$S->init(node => $nodeobj, snmp => 0); # load node info and Model if name exists
			my $catchall_data = $S->inventory( concept => 'catchall' )->{_data};

			my $IF = $nodeobj->ifinfo;	
			my $MDL = $S->mdl;

			my $lastUpdateTime = defined $catchall_data->{last_update} ? $catchall_data->{last_update} : $catchall_data->{lastUpdatePoll};
			my $lastUpdatePoll = defined $lastUpdateTime ? NMISNG::Util::returnDateStamp($lastUpdateTime) : "N/A";

			# handling for this is device/model specific.
			my $INV;
			my $nodemodel = $catchall_data->{nodeModel} eq "Model" ? $catchall_data->{model} : $catchall_data->{nodeModel};
			print "[exportOltPorts] Checking node $node model '$nodemodel' against $goodModels \n" if ($debug);

			if ( $nodemodel =~ /$goodModels/ ) {
				print("Processing Node '$NODES->{$node}{name}'\n");
				$modelCount++;

				my $invIds = $S->nmisng_node->get_inventory_ids(
					concept => "$section");

				if (@$invIds)
				{	
					for my $sectionId (@$invIds)
					{
						my ($section, $error) = $S->nmisng_node->inventory(_id => $sectionId);
						if ($error)
						{
							print("Failed to get inventory $sectionId: $error\n");
							next;
						}
						my $data = $section->data();

						if ( time() - $lastUpdateTime > 86400 ) {
							print("WARNING, Last Update Data collection was more than 1 day ago: $lastUpdatePoll\n");
						}

						$INV->{$data->{index}} = $data;
					}
				}

				# TODO: FixME - If needed
				my $sectionIds = $S->nmisng_node->get_inventory_ids( concept => "GPON_Device");
				if (@$sectionIds)
				{	
					my %gponDeviceIndex;

					for my $sectionId (@$sectionIds)
					{
						my ($section, $error) = $S->nmisng_node->inventory(_id => $sectionId);
						if ($error)
						{
							print("Failed to get inventory $sectionId: $error\n");
							next;
						}
						my $data = $section->data();

						if ( time() - $lastUpdateTime > 86400 ) {
							print("WARNING, Last Update Data collection was more than 1 day ago: $lastUpdatePoll\n");
						}

						my $pwd;
						if ($data->{hwGponDeviceOntPassword} =~ /(\d+)/ ) {
							#print $data->{hwGponDeviceOntPassword} . "\n";
							#$data->{hwGponDeviceOntPassword} = $1;	
							$pwd = $1;
						} else {
							print("ERROR with Service Number: hwGponDeviceOntPassword=$data->{hwGponDeviceOntPassword}\n");
						}
						$gponDeviceIndex{$pwd} = $data->{index};

						#$INV->{$data->{index}} = ($INV->{$data->{index}}) ? merge_hash($data, $INV->{$data->{index}}) : $data;
					}



					# load the gpon device data
					my $gponDevice;
					my $gponDeviceIp;

					my $gponDeviceIds = $S->nmisng_node->get_inventory_ids(
						concept => "GPON_Device",
						filter => { historic => 0 });

					for my $gponDeviceId (@$gponDeviceIds)
					{
						my ($section, $error) = $S->nmisng_node->inventory(_id => $gponDeviceId);
						if ($error)
						{
							print("Failed to get inventory $gponDeviceId: $error\n");
							next;
						}
						$gponDevice->{$section->data()->{index}} = $section->data();
					}

					my $gponDeviceIpIds = $S->nmisng_node->get_inventory_ids(
						concept => "GPON_Device_IP",
						filter => { historic => 0 });

					for my $gponDeviceIpId (@$gponDeviceIpIds)
					{
						my ($section, $error) = $S->nmisng_node->inventory(_id => $gponDeviceIpId);
						if ($error)
						{
							print("Failed to get inventory $gponDeviceIpId: $error\n");
							next;
						}
						$gponDeviceIp->{$section->data()->{index}} = $section->data();
					}

					# we know the device supports this inventory section, so on the first run of a node, setup the headers based on the model.
					if ( not @invHeaders ) {
						# create the aliases from the model data, a few static items are primed
						#print "DEBUG: $model_section_top $model_section $MDL->{$model_section_top}{sys}{$model_section}{headers}\n";
						#print Dumper $MDL;
						if ( not defined $myHeaders ) {
							#print Dumper($MDL);
							@{$myHeaders} = split(",",$MDL->{$model_section_top}{sys}{$model_section}{headers});
						}

						@invHeaders = ('node','host','last_update', @{$myHeaders});

						# fill in the aliases for each of the items from the model	
						foreach my $heading (@invHeaders) {
							if ( defined $MDL->{$model_section_top}{sys}{$model_section}{snmp}{$heading}{title_export} ) {
								$invAlias{$heading} = $MDL->{$model_section_top}{sys}{$model_section}{snmp}{$heading}{title_export};
							}
							else {
								$invAlias{$heading} = $heading;
							}
						}

						# add the secondary headers to the main ones for use later.
						push(@invHeaders,@{$tertiary_headers});

						# now load all the headers from the tertiary model
						foreach my $heading (@{$tertiary_headers}) {
							if ( defined $MDL->{systemHealth}{sys}{$tertiary_section}{snmp}{$heading}{title_export} ) {
								$invAlias{$heading} = $MDL->{systemHealth}{sys}{$tertiary_section}{snmp}{$heading}{title_export};
							}
							else {
								$invAlias{$heading} = $heading;
							}
						}

						# add the secondary headers to the main ones for use later.
						push(@invHeaders,@{$secondary_headers});

						# now load all the headers from the secondary model
						foreach my $heading (@{$secondary_headers})
						{
							if ( defined $MDL->{systemHealth}{sys}{$secondary_section}{snmp}{$heading}{title_export} ) {
								$invAlias{$heading} = $MDL->{systemHealth}{sys}{$secondary_section}{snmp}{$heading}{title_export};
							}
							else {
								$invAlias{$heading} = $heading;
							}
						}

						# set the aliases for the static items
						$invAlias{node} = 'OLT Name';
						$invAlias{host}	= 'OLT IP';
						$invAlias{sysUpTime} = 'Ultimo Sincronismo';
						$invAlias{last_update} = 'Ultimo Datos Actualizar';

						$invAlias{ifIndex} = 'Index of port';
						$invAlias{ifDescr} = 'Port';

						$invAlias{ifLastChange} = 'Ultima Bajada';
						$invAlias{ifOperStatus} = 'Condicion Operativa';
						$invAlias{ifAdminStatus} = 'Condicion Administrativa';

						# create a header
						my @aliases;
						foreach my $header (@invHeaders) {
							my $alias = $header;
							$alias = $invAlias{$header} if $invAlias{$header};
							push(@aliases,"\"$alias\"");
						}
						if ( not $headerDone{$exportType} ) {
							my $row = join($sep,@aliases);
							print $CSV    "$row\n";
							$headerDone{$exportType} = 1;
						}
						if ($xls) {
							print("Adding worksheet '$title'\n");
							$sheet = add_worksheet(xls => $xls, title => $title, columns => \@aliases);
							$currow = 1;								# header is row 0
						}
						else {
							die "ERROR: Internal error, xls is not defined.\n";
						}
					}


					foreach my $idx (oid_lex_sort(keys %{$INV})) {					
						# why shouldn't we process this INV record?
						next if not defined $INV->{$idx};
						next if $INV->{$idx}{hwExtSrvFlowDescInfo} eq "";				

						# OK this is a good one, lets get it into the CSV.
						$INV->{$idx}{node} = $node;
						$INV->{$idx}{host} = $NODES->{$node}{host};
						$INV->{$idx}{sysUpTime} = $catchall_data->{sysUpTime};
						$INV->{$idx}{last_update} = $lastUpdatePoll;

						# lets check if the hwExtSrvFlowDescInfo is clean
						# some crazy examples "8095350195@gold7.claro.net.do", "8095630610@ipfija.net", "cv-8095320056@40917@", FCSTG9A-A2, 132830863, 809382385, 80958343, @gold7.claro.net.do, quit, 1010065137, 147302860, GHPONTEZUE, 809-971-80, 1010015366
						# a good one = "8095335336"
						# lets see if its a good one
						if ( $INV->{$idx}{hwExtSrvFlowDescInfo} =~ /^8[024]9[\d]{6,7}|101[\d]{6,7}$/ ) {
							# this a good one, nothing really to do, but be happy
						}
						elsif ( $INV->{$idx}{hwExtSrvFlowDescInfo} =~ /(8[024]9[\d]{6,7}|101[\d]{6,7})/ ) { 
							# can we just find that number in the middle of the string.
							$INV->{$idx}{hwExtSrvFlowDescInfo} = $1;
						}
						else {
							# no valid number here, lets print an error message
							print("ERROR: $node has bad service number for idx=$idx hwExtSrvFlowDescInfo=$INV->{$idx}{hwExtSrvFlowDescInfo}\n");					
						}

						# lets merge in the data from the secondary section.
						if ( defined $gponDeviceIndex{$INV->{$idx}{hwExtSrvFlowDescInfo}} ) {
							my $gponIndex = $gponDeviceIndex{$INV->{$idx}{hwExtSrvFlowDescInfo}};
							if ( not defined $gponDevice->{$gponIndex} ) {
								print("ERROR: $node no $secondary_section data for gponIndex=$gponIndex\n");					
							}
							else {
								print("INFO: $node, $secondary_section data for hwExtSrvFlowDescInfo=$INV->{$idx}{hwExtSrvFlowDescInfo} gponIndex=$gponIndex\n");					
							}

							foreach my $heading (@{$secondary_headers}) {
								$INV->{$idx}{$heading} = $gponDevice->{$gponIndex}{$heading};
							}

							# now we do the tertiary table join
							my $gponIpIndex = "$gponIndex.0";
							if ( not defined $gponDeviceIp->{$gponIpIndex} ) {
								print("ERROR: $node no $tertiary_section data for hwExtSrvFlowDescInfo=$INV->{$idx}{hwExtSrvFlowDescInfo} gponIpIndex=$gponIpIndex\n");
							}
							foreach my $heading (@{$tertiary_headers}) {
								$INV->{$idx}{$heading} = $gponDeviceIp->{$gponIpIndex}{$heading};
							}
						}

						# now the data is merged, and we can use all the properties to decide what to do.
						# so if this thing does not have a connection, just get rid of it.
						# ks commenting out from Jefri Martinez's request, export will now include inactive services
						#next if $INV->{$idx}{hwGponDeviceOntControlBatteryCurStatus} eq "unknownStatus";

						#### special formating of the HEX strings
						$INV->{$idx}{hwGponDeviceOntControlLastDownTime} = convertDateAndTime($INV->{$idx}{hwGponDeviceOntControlLastDownTime});
						$INV->{$idx}{hwGponDeviceOntControlLastUpTime} = convertDateAndTime($INV->{$idx}{hwGponDeviceOntControlLastUpTime});

						my @columns;
						my $currcol=0;
						foreach my $header (@invHeaders) {
							my $colLen = (($colsize[$currcol] ne '' ) ? $colsize[$currcol] : length($invAlias{$header}));
							my $data   = undef;
							if ( defined $INV->{$idx}{$header} ) {
								# Prevent extrange characters in the output 
								if ($header =~ /hwGponDeviceOntPassword/) {
									my $d = $INV->{$idx}{$header};
									$d =~ s/[^\d]//g;
									$data = $d;
								} else {
									$data = $INV->{$idx}{$header};
								}
							}
							else {
								$data = "TBD";
							}
							$data   = "" if $data eq "noSuchInstance";
							$colLen = ((length($data) > 253 || length($invAlias{$header}) > 253) ? 253 : ((length($data) > $colLen) ? length($data) : $colLen));
							$data   = changeCellSep($data);
							$colsize[$currcol] = $colLen;
							push(@columns,'"' . $data. '"');
							$currcol++;
						}
						my $row = join($sep,@columns);
						print $CSV "$row\n";
						$csvData .= "$row\n";

						if ($sheet) {
							$sheet->write($currow, 0, [ @columns[0..$#columns] ]);
							++$currow;
						}
					}
				} 

			} else {
					print("ERROR: $node no $section MIB Data available, check the model contains it and run an update on the node.\n");
					next;
			}
		}
	}
	print("Processed $modelCount '$goodModels'.\n");
	my $i=0;
	if ($sheet) {
		foreach my $header (@invHeaders) {
			$sheet->set_column( $i, $i, $colsize[$i]+2);
			$i++;
		}
	}
}

sub exportAdslPorts {
	my (%args) = @_;

	my $xls        = $args{xls};
	my $file       = $args{file};
	my $myHeaders  = $args{headers};
	my $goodModels = $args{models};
	my $useIfStack = NMISNG::Util::getbool($args{useIfStack});
	my $exportType = $args{exportType};
	my $CSV        = $args{exportHandle};
	my $title      = $args{section};
	my $sheet;
	my $currow;
	my @colsize;

	my $section = $args{section};
	die "I must know which section!" if not defined $args{section};

	$title = $args{title} if defined $args{title};

	my $model_section_top = "systemHealth";
	$model_section_top = $args{model_section_top} if defined $args{model_section_top};

	my $model_section = $section;
	$model_section = $args{model_section} if defined $args{model_section};

	print("Exporting model_section_top=$model_section_top model_section=$model_section section=$section\n");

	# declare some vars for filling in later.
#	my @invHeaders;
	my %invAlias;
	my $modelCount = 0;

	foreach my $node (sort keys %{$NODES}) {
		if ( $NODES->{$node}{active} == 1 ) {
			my $S = NMISNG::Sys->new(nmisng => $nmisng);
			my $nodeobj = $nmisng->node(name => $node);
			$S->init(node => $nodeobj, snmp => 0); # load node info and Model if name exists
			my $catchall_data = $S->inventory( concept => 'catchall' )->{_data};

			my $IF = $nodeobj->ifinfo;

			my $MDL = $S->mdl;
			my $adslChannel;

			my $lastUpdateTime = defined $catchall_data->{last_update} ? $catchall_data->{last_update} : $catchall_data->{lastUpdatePoll};
			my $lastUpdatePoll = defined $lastUpdateTime ? NMISNG::Util::returnDateStamp($lastUpdateTime) : "N/A";

			# handling for this is device/model specific.
			my $INV;

			my $nodemodel = $catchall_data->{nodeModel} eq "Model" ? $catchall_data->{model} : $catchall_data->{nodeModel};
			print "[exportAdslPorts] Checking node $node model '$nodemodel' against $goodModels \n" if ($debug);

			# TODO: Verify
			if ( $nodemodel =~ /$goodModels/ ) {
				print("Processing Node '$NODES->{$node}{name}'\n");
				$modelCount++;
				# Get inventory by section
				my $sectionIds = $S->nmisng_node->get_inventory_ids(
					concept => "$section",
					filter => { historic => 0 });

				if (@$sectionIds)
				{	
					my %gponDeviceIndex;

					for my $sectionId (@$sectionIds)
					{
						my ($section, $error) = $S->nmisng_node->inventory(_id => $sectionId);
						if ($error)
						{
							print("Failed to get inventory $sectionId: $error\n");
							next;
						}
						my $data = $section->data();

						if ( time() - $lastUpdateTime > 86400 ) {
							print("WARNING, Last Update Data collection was more than 1 day ago: $lastUpdatePoll\n");
						}

						$INV->{$data->{index}} = ($INV->{$data->{index}}) ? merge_hash($data, $INV->{$data->{index}}) : $data;
					}
				}
				else {
					print("ERROR: $node no $section MIB Data available, check the model contains it and run an update on the node.\n");
					next;
				}

				# Get inventory by ADSL_Channel
				my $adslIds = $S->nmisng_node->get_inventory_ids(
					concept => "ADSL_Channel",
					filter => { historic => 0 });

				if (@$adslIds)
				{	
					my %adslIndex;

					for my $sectionId (@$adslIds)
					{
						my ($section, $error) = $S->nmisng_node->inventory(_id => $sectionId);
						if ($error)
						{
							print("Failed to get inventory $sectionId: $error\n");
							next;
						}
						my $data = $section->data();

						if ( time() - $lastUpdateTime > 86400 ) {
							print("WARNING, Last Update Data collection was more than 1 day ago: $lastUpdatePoll\n");
						}

						# TODO: Indexed by other field??? 
						$adslChannel->{$data->{index}} = $data;
					}
				}
				else {
					print("ERROR: $node no $section MIB Data available, check the model contains it and run an update on the node.\n");
					next;
				}

				# we know the device supports this inventory section, so on the first run of a node, setup the headers based on the model.
				if ( not @invHeaders ) {
					# create the aliases from the model data, a few static items are primed
					#print "DEBUG: $model_section_top $model_section $MDL->{$model_section_top}{sys}{$model_section}{headers}\n";
					#print Dumper $MDL;

					if ( not defined $myHeaders ) {
						@{$myHeaders} = split(",",$MDL->{$model_section_top}{sys}{$model_section}{headers});
					}

					@invHeaders = ('node','host','last_update', @{$myHeaders});

					# fill in the aliases for each of the items from the model	
					foreach my $heading (@invHeaders) {
						if ( defined $MDL->{$model_section_top}{sys}{$model_section}{snmp}{$heading}{title_export} ) {
							$invAlias{$heading} = $MDL->{$model_section_top}{sys}{$model_section}{snmp}{$heading}{title_export};
						}
						else {
							$invAlias{$heading} = $heading;
						}
					}

					# set the aliases for the static items
					$invAlias{node} = 'OLT Name';
					$invAlias{host}	= 'OLT IP';
					$invAlias{sysUpTime} = 'Ultimo Sincronismo';
					$invAlias{last_update} = 'Ultimo Datos Actualizar';

					$invAlias{ifIndex} = 'Index of port';
					$invAlias{ifDescr} = 'Port';

					$invAlias{ifLastChange} = 'Ultima Bajada';
					$invAlias{ifOperStatus} = 'Condicion Operativa';
					$invAlias{ifAdminStatus} = 'Condicion Administrativa';

					$invAlias{adslAtucChanCurrTxRate} = 'Velocidad Puerto DN';
					$invAlias{adslAturChanCurrTxRate} = 'Velocidad Puerto UP';

					$invAlias{xdslFarEndLineLoopAttenuationDownstream} = 'Loop Atenuacion Bajada';
					$invAlias{xdslLineLoopAttenuationUpstream} = 'Loop Atenuacion Subida';
					$invAlias{xdslLineServiceProfileNbr} = 'Numero Profile';
					$invAlias{xdslLinkUpActualBitrateDownstream} = 'Velocidad Actual DN';
					$invAlias{xdslLinkUpActualBitrateUpstream} = 'Velocidad Actual UP';
					$invAlias{xdslLineOutputPowerDownstream} = 'Potencia Dslam';
					$invAlias{xdslFarEndLineOutputPowerUpstream} = 'Potencia Moden';
					$invAlias{xdslXturInvSystemSerialNumber} = 'Serial Modem';
					$invAlias{xdslLineServiceProfileName} = 'Nombre Profile';

					# create a header
					my @aliases;
					foreach my $header (@invHeaders) {
						my $alias = $header;
						$alias = $invAlias{$header} if $invAlias{$header};
						push(@aliases,"\"$alias\"");
					}
					if ( not $headerDone{$exportType} ) {
						my $row = join($sep,@aliases);
						print $CSV    "$row\n";
						$headerDone{$exportType} = 1;
					}
					if ($xls) {
						print("Adding worksheet '$title'\n");
						$sheet = add_worksheet(xls => $xls, title => $title, columns => \@aliases);
						$currow = 1;								# header is row 0
					}
					else {
						die "ERROR: Internal error, xls is not defined.\n";
					}
				}				

				foreach my $idx (oid_lex_sort(keys %{$INV})) {
					if ( defined $INV->{$idx} ) {
						$INV->{$idx}{node} = $node;
						$INV->{$idx}{host} = $NODES->{$node}{host};
						$INV->{$idx}{sysUpTime} = $catchall_data->{sysUpTime};
						$INV->{$idx}{last_update} = $lastUpdatePoll;

						# merge in some data from the interfaces table.
						if ( defined $IF->{$idx} ) { 
							$INV->{$idx}{ifIndex} = $IF->{$idx}{ifIndex};
							$INV->{$idx}{ifLastChange} = $IF->{$idx}{ifLastChange};
							$INV->{$idx}{ifOperStatus} = $IF->{$idx}{ifOperStatus};
							$INV->{$idx}{ifAdminStatus} = $IF->{$idx}{ifAdminStatus};
						}

						#using the ifStack relationships, lets find the interleave port which has the adslAtucChanCurrTxRate and adslAturChanCurrTxRate
						my $ifStackHigherLayer = undef;
						# does this device model use ifStack to match the higher layer ports?
						if ( $useIfStack ) {
							if ( defined $IF->{$idx}{ifStackHigherLayer} ) {
								foreach my $ifHigherIndex (@{$IF->{$idx}{ifStackHigherLayer}}) {
									if ( $IF->{$ifHigherIndex}{ifType} eq "interleave" ) {
										$ifStackHigherLayer = $ifHigherIndex;
										last;
									}
								}
							}
						}
						else {
							# it must just be the same port.
							$ifStackHigherLayer = $idx;
						}

						# so now we have an higher later interface, map the data.
						if ( $ifStackHigherLayer ) {
							print("DEBUG: $idx $INV->{$idx}{ifDescr} ifStackHigherLayer=$ifStackHigherLayer $adslChannel->{$ifStackHigherLayer}{ifDescr}\n");
							$INV->{$idx}{adslAtucChanCurrTxRate} = $adslChannel->{$ifStackHigherLayer}{adslAtucChanCurrTxRate};
							$INV->{$idx}{adslAturChanCurrTxRate} = $adslChannel->{$ifStackHigherLayer}{adslAturChanCurrTxRate};							
						}
						else {
							print("ERROR: $idx $INV->{$idx}{ifDescr} has no ifStackHigherLayer\n");
						}

						my @columns;
						my $currcol=0;
						foreach my $header (@invHeaders) {
							my $colLen = (($colsize[$currcol] ne '' ) ? $colsize[$currcol] : length($invAlias{$header}));
							my $data   = undef;
							if ( defined $INV->{$idx}{$header} ) {
								$data = $INV->{$idx}{$header};
							}
							else {
								$data = "TBD";
							}
							$data   = "" if $data eq "noSuchInstance";
							$colLen = ((length($data) > 253 || length($invAlias{$header}) > 253) ? 253 : ((length($data) > $colLen) ? length($data) : $colLen));
							$data   = changeCellSep($data);
							$colsize[$currcol] = $colLen;
							push(@columns,'"' . $data. '"');
							$currcol++;
						}
						my $row = join($sep,@columns);
						print $CSV "$row\n";
						$csvData .= "$row\n";

						if ($sheet) {
							$sheet->write($currow, 0, [ @columns[0..$#columns] ]);
							++$currow;
						}
					}
				}
			}
		}
	}
	print("Processed $modelCount '$goodModels'.\n");
	my $i=0;
	if ($sheet) {
		foreach my $header (@invHeaders) {
			$sheet->set_column( $i, $i, $colsize[$i]+2);
			$i++;
		}
	}
}


sub exportAsamDslamPorts {
	my (%args) = @_;

	my $xls        = $args{xls};
	my $myHeaders  = $args{headers};
	my $goodModels = $args{models};
	my $exportType = $args{exportType};
	my $CSV        = $args{exportHandle};
	my $title      = $args{section};
	my $sheet;
	my $currow;
	my @colsize;

	my $section = $args{section};
	die "I must know which section!" if not defined $args{section};

	$title = $args{title} if defined $args{title};

	my $model_section_top = "systemHealth";
	$model_section_top = $args{model_section_top} if defined $args{model_section_top};

	my $model_section = $section;
	$model_section = $args{model_section} if defined $args{model_section};

	print("Exporting model_section_top=$model_section_top model_section=$model_section section=$section\n");

	# declare some vars for filling in later.
	my @invHeaders;
	my %invAlias;
	my %portIndex;
	my $modelCount = 0;

	foreach my $node (sort keys %{$NODES}) {
		if ( $NODES->{$node}{active} == 1 ) {
			my $S = NMISNG::Sys->new(nmisng => $nmisng);
			my $nodeobj = $nmisng->node(name => $node);
			$S->init(node => $nodeobj, snmp => 0); # load node info and Model if name exists
			my $catchall_data = $S->inventory( concept => 'catchall' )->{_data};

			my $IF = $nodeobj->ifinfo;	
			my $MDL = $S->mdl;

			my $lastUpdateTime = defined $catchall_data->{last_update} ? $catchall_data->{last_update} : $catchall_data->{lastUpdatePoll};
			my $lastUpdatePoll = defined $lastUpdateTime ? NMISNG::Util::returnDateStamp($lastUpdateTime) : "N/A";

			# handling for this is device/model specific.
			my $INV;
			my $nodemodel = $catchall_data->{nodeModel} eq "Model" ? $catchall_data->{model} : $catchall_data->{nodeModel};
			print "[exportAsamDslamPorts] Checking node $node model '$nodemodel' against $goodModels \n" if ($debug);

			if ( $nodemodel =~ /$goodModels/ ) {
				print("Processing Node '$NODES->{$node}{name}'\n");
				$modelCount++;
				my $sectionIds = $S->nmisng_node->get_inventory_ids(
					concept => "$section",
					filter => { historic => 0 });

				if (@$sectionIds)
				{	
					for my $sectionId (@$sectionIds)
					{
						my ($section, $error) = $S->nmisng_node->inventory(_id => $sectionId);
						if ($error)
						{
							print("Failed to get inventory $sectionId: $error\n");
							next;
						}
						my $data = $section->data();

						if ( time() - $lastUpdateTime > 86400 ) {
							print("WARNING, Last Update Data collection was more than 1 day ago: $lastUpdatePoll\n");
						}

						$INV->{$data->{index}} = $data;
					}
				}
				else {
					print("ERROR: $node no $section MIB Data available, check the model contains it and run an update on the node.\n");
					next;
				}

				# we know the device supports this inventory section, so on the first run of a node, setup the headers based on the model.
				if ( not @invHeaders ) {
					# create the aliases from the model data, a few static items are primed
					#print "DEBUG: $model_section_top $model_section $MDL->{$model_section_top}{sys}{$model_section}{headers}\n";
					#print Dumper $MDL;			
					if ( not defined $myHeaders ) {
						@{$myHeaders} = split(",",$MDL->{$model_section_top}{sys}{$model_section}{headers});
					}

					@invHeaders = ('node','host','last_update', @{$myHeaders});

					# fill in the aliases for each of the items from the model	
					foreach my $heading (@invHeaders) {
						if ( defined $MDL->{$model_section_top}{sys}{$model_section}{snmp}{$heading}{title_export} ) {
							$invAlias{$heading} = $MDL->{$model_section_top}{sys}{$model_section}{snmp}{$heading}{title_export};
						}
						else {
							$invAlias{$heading} = $heading;
						}
					}

					# set the aliases for the static items
					$invAlias{node} = 'OLT Name';
					$invAlias{host}	= 'OLT IP';
					$invAlias{sysUpTime} = 'Ultimo Sincronismo';
					$invAlias{last_update} = 'Ultimo Datos Actualizar';
					$invAlias{xdslLineServiceProfileName} = 'Nombre Profile';

					# create a header
					my @aliases;
					foreach my $header (@invHeaders) {
						my $alias = $header;
						$alias = $invAlias{$header} if $invAlias{$header};
						push(@aliases,"\"$alias\"");
					}
					if ( not $headerDone{$exportType} ) {
						my $row = join($sep,@aliases);
						print $CSV    "$row\n";
						$headerDone{$exportType} = 1;
					}
					if ($xls) {
						print("Adding worksheet '$title'\n");
						$sheet = add_worksheet(xls => $xls, title => $title, columns => \@aliases);
						$currow = 1;								# header is row 0
					}
					else {
						die "ERROR: Internal error, xls is not defined.\n";
					}

				}	else {
					print "invHeaders defined\n";
				}
				foreach my $idx (oid_lex_sort(keys %{$INV})) {
					if ( defined $INV->{$idx} ) {	
						my $ifIndex = $INV->{$idx}{ifIndex};

						# has this ifIndex already been processed?
						if ( not $portIndex{$ifIndex} ) {
							$portIndex{$ifIndex} = $INV->{$idx}{atmVclVci};

							$INV->{$idx}{node} = $node;
							$INV->{$idx}{host} = $NODES->{$node}{host};
							$INV->{$idx}{sysUpTime} = $catchall_data->{sysUpTime};
							$INV->{$idx}{last_update} = $lastUpdatePoll;

							# TODO: Is xdslLineServiceProfile in catchall???

							#### SPECIAL HANDLING CROSS LINKING STUFF.
							# get the Service Profile Name based on the xdslLineServiceProfileNbr
							if ( defined $catchall_data->{xdslLineServiceProfile} and defined $INV->{$idx}{xdslLineServiceProfileNbr} ) {
								my $profileNumber = $INV->{$idx}{xdslLineServiceProfileNbr};
								$INV->{$idx}{xdslLineServiceProfileName}  = $catchall_data->{xdslLineServiceProfile}{$profileNumber}{xdslLineServiceProfileName} ? $catchall_data->{xdslLineServiceProfile}{$profileNumber}{xdslLineServiceProfileName} : "";						
							}

							my @columns;
							my $currcol=0;
							foreach my $header (@invHeaders) {
								my $colLen = (($colsize[$currcol] ne '' ) ? $colsize[$currcol] : length($invAlias{$header}));
								my $data   = undef;
								if ( defined $INV->{$idx}{$header} ) {
									$data = $INV->{$idx}{$header};
								}
								else {
									$data = "TBD";
								}
								$data   = "" if $data eq "noSuchInstance";
								$colLen = ((length($data) > 253 || length($invAlias{$header}) > 253) ? 253 : ((length($data) > $colLen) ? length($data) : $colLen));
								$data   = changeCellSep($data);
								$colsize[$currcol] = $colLen;
								push(@columns,'"' . $data. '"');
								$currcol++;
							}
							my $row = join($sep,@columns);
							print $CSV "$row\n";
							$csvData .= "$row\n";

							if ($sheet) {
								$sheet->write($currow, 0, [ @columns[0..$#columns] ]);
								++$currow;
							}
						}
						else {
							print("INFO: skipping $idx as ifIndex $ifIndex has already been seen with atmVclVci $portIndex{$ifIndex}\n");
						}
					}
				}
			}
		}
	}	
	print("Processed $modelCount '$goodModels'.\n");
	my $i=0;
	if ($sheet) {
		foreach my $header (@invHeaders) {
			$sheet->set_column( $i, $i, $colsize[$i]+2);
			$i++;
		}
	}
}

sub merge_hash {
	my $hash1 = shift;
	my $hash2 = shift;
	my $toret;

	$toret = ($hash1, $hash2);
	return $toret;
}

sub changeCellSep {
	my $string = shift;
	if ( $sep ne "|" ) {
		$string =~ s/$sep/;/g;
	}
	else {
		$string =~ s/, / /g;
	}
	$string =~ s/\r\n/\\n/g;
	$string =~ s/\n/\\n/g;
	return $string;
}

# convert the SNMPv2 DateAndTime data
sub convertDateAndTime {
	my $octets = shift;

	if ( defined $octets and $octets =~ /^0x/ ) {
		if ($octets =~ /^0x([a-f0-9]+)$/i)
		{
			$octets = pack("H*", $1);
		}

		my @date = unpack 'n C6 a C2', $octets;
		#Suitable printf formats would be:
		return sprintf "%04d-%02d-%02d %02d:%02d:%02d", @date; # no time +zone
	}		
}

#The format of file should be CSV, with the name: DSLAMYYYYMMDDHHmmSS.csv and OLTYYYYMMDDHHmmSS.csv. 2 single files: (DSLAM and  OLT)

sub getFileName {
	my $type       = shift;
	my $servername = shift;
	my $extension  = shift // "csv";
	my $time       = time();
	return POSIX::strftime("$type%Y%m%d%H%M%S$servername.$extension", localtime($time));
}

sub getFileHandle {
	my $file = shift;
	my $time = time();

	open(CSV_FH,">$file") or print("Problem with file $file: $!\n");

	# return the file handle, its a star!
	return *CSV_FH;
}

sub ftpExportFile {
	my (%args) = @_;

	my $file      = $args{file};
	my $server    = $args{server};
	my $user      = $args{user};
	my $password  = $args{password};
	my $directory = $args{directory};
	my $nmisng    = $args{nmisng};

	my $sftp = Net::SFTP::Foreign->new(
		$server, 
		user => $user,
		password => $password
	);
	print("Unable to establish SFTP connection: " . $sftp->error . "\n") if $sftp->error;

	if ( $sftp ) {
		if (!$sftp->setcwd($directory)) {
			print("unable to change cwd: " . $sftp->error . "\n");
		}
		if (!$sftp->put($file)) {
			print("put failed: " . $sftp->error . "\n");
			return;
		}

		print("Export file $file put to $server:$directory\n");
	}	
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

sub usage {
	print <<EO_TEXT;
Usage: $PROGNAME -d[=[0-9]] -c --config -f --ftp -h --help -u --usage -v --version dir=<directory> [option=value...]

$PROGNAME will export nodes and ports from NMIS for 'AlcatelASAM', 'CiscoDSL', 
           'Huawei-MA5600', 'LucentStinger', and 'ZyXEL-IES' devices.

Arguments:
 conf=<Configuration file> (default: '$defaultConf');
 dir=<Drectory where files should be saved>
 ftp=<true|false> (default: 'true')
 email=<Email Address>
 separator=<Comma separated  value (CSV) separator character (default: tab)
 xls=<Excel filename> (default: '$xlsFile')

Enter $PROGNAME -h for compleate details.

eg: $PROGNAME dir=/data separator=(comma|tab)
\n
EO_TEXT
}

sub createConfigFile
{
	my $exportBaseDir;
	my $exportFtpServer;
	my $exportFtpUser;
	my $exportFtpPassword;
	my $exportFtpDirectory;
	# %hash = (
	#   'exportBaseDir' => '/path/for/source/files',
	#   'exportFtpServer' => '172.x.y.z',
	#   'exportFtpUser' => 'YourUserNameHere',
	#   'exportFtpPassword' => 'YourPasswordHere',
	#   'exportFtpDirectory' => '/path/to/send/files',
	# );
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
	STDOUT->autoflush(1);
	STDERR->autoflush(1);
	ReadMode 0, $IN;
	print "Do you want to store the output directory ('dir' argument) in the configuration file? ";
	my $answer = ReadLine 0, $IN;
	if ($answer =~ /y/i)
	{
		print "Enter Base Directory: ";
		$exportBaseDir = ReadLine 0, $IN;
		$exportBaseDir =~ s/~/$ENV{HOME}/;
	}
	print "Enter FTP Server name: ";
	$exportFtpServer = ReadLine 0, $IN;
	print "Enter FTP User name: ";
	$exportFtpUser = ReadLine 0, $IN;
	print "Enter FTP Password: ";
	ReadMode 2, $IN;
	$exportFtpPassword = ReadLine 0, $IN;
	print "\nEnter FTP destination directory: ";
	ReadMode 0, $IN;
	$exportFtpDirectory = ReadLine 0, $IN;
	$exportFtpDirectory =~ s/~/$ENV{HOME}/;
	chomp($exportBaseDir) if ($answer =~ /y/i);
	chomp($exportFtpServer);
	chomp($exportFtpUser);
	chomp($exportFtpPassword);
	chomp($exportFtpDirectory);
	$exportConfig->{exportBaseDir}      = $exportBaseDir if ($answer =~ /y/i);
	$exportConfig->{exportFtpServer}    = $exportFtpServer;
	$exportConfig->{exportFtpUser}      = $exportFtpUser;
	$exportConfig->{exportFtpPassword}  = $exportFtpPassword;
	$exportConfig->{exportFtpDirectory} = $exportFtpDirectory;
	NMISNG::Util::writeHashtoFile(file=>"$C->{'<nmis_conf>'}/DslamPortExportTest", data=>$exportConfig)
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
   push(@lines, "       The $PROGNAME program Exports NMIS nodes and port into an Excel\n");
   push(@lines, "       spreadsheet in the specified directory with the required 'dir'\n" );
   push(@lines, "       parameter. The command also creates Comma Separated Value (CSV) files\n");
   push(@lines, "       in the same directory. It supports the following devices:\n");
   push(@lines, "       'AlcatelASAM', 'CiscoDSL', 'Huawei-MA5600', 'LucentStinger',\n");
   push(@lines, "       and 'ZyXEL-IES'.\n");
   push(@lines, "\n");
   push(@lines, "\033[1mOPTIONS\033[0m\n");
   push(@lines, " -c | --config               - Create or update the FTP configuration file.\n");
   push(@lines, " -d | --debug=[1-9]          - global option to print detailed messages\n");
   push(@lines, " -f | --ftp                  - Send the output to a configured FTP location\n");
   push(@lines, " -h | --help                 - display command line usage\n");
   push(@lines, " -u | --usage                - display a brief overview of command syntax\n");
   push(@lines, " -v | --version              - print a version message and exit\n");
   push(@lines, "\n");
   push(@lines, "\033[1mARGUMENTS\033[0m\n");
   push(@lines, "     dir=<directory>         - The directory where the files should be stored.\n");
   push(@lines, "                                Both the Excel spreadsheet and the CSV files\n");
   push(@lines, "                                will be stored in this directory. The\n");
   push(@lines, "                                directory should exist and be writable.\n");
   push(@lines, "     [conf=<filename>]       - The location of an alternate NMIS configuration\n");
   push(@lines, "                                file. (default: '$defaultConf')\n");
   push(@lines, "     [debug=<true|false|yes|no|info|warn|error|fatal|verbose|0-9>]\n");
   push(@lines, "                             - Set the debug level.\n");
   push(@lines, "     [email=<email_address>] - Send all generated CSV files to the specified.\n");
   push(@lines, "                                 email address.\n");
   push(@lines, "     [separator=<character>] - A character to be used as the separator in the\n");
   push(@lines, "                                 CSV files. The words 'comma' and 'tab' are\n");
   push(@lines, "                                 understood. Other characters will be taken\n");
   push(@lines, "                                 literally. (default: 'tab')\n");
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
