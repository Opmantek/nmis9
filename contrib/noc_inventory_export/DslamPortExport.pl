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
# a small update plugin for converting the cdp index into interface name.

# THIS PERL SCRIPT WAS BORROWED FROM THE PLUGIN ONCE PROVEN SHOULD MAKE OTHER UPDATES

our $VERSION = "1.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use Data::Dumper;
use File::Path qw(make_path remove_tree);
use Net::SNMP qw(oid_lex_sort);
use Net::SFTP::Foreign;

use NMISNG;														# lnt
use NMISNG::Util;
use NMISNG::Sys;
use Compat::NMIS;

my $exportConfig;
my $exportFiles;
my $sep = "|";
my $baseDir;
my %headerDone;
my $DOEXPORT = 1;
my $DOFTP = 1;

# Variables for command line munging
my $arg = NMISNG::Util::get_args_multi(@ARGV);

if ( $arg->{export} eq "" ) {
	usage();
	exit 1;
}

sub usage {
	print qq/$0 will create the DSLAM exports or FTP them.
	
	usage: $0 [export=(true|false)] [ftp=(true|false)] [debug=(true|false)]
	export default = true
	ftp    default = true
	debug  default = false
/;
}

###########################################
# down to business
###########################################

# load configuration table
my $customconfdir = $arg->{dir}? $arg->{dir}."/conf" : "/usr/local/nmis9/conf";
my $C = NMISNG::Util::loadConfTable(dir => $customconfdir, debug => $arg->{debug});
my $debug = $arg->{debug};

my $logfile = $C->{'<nmis_logs>'} . "/cli.log";
my $error = NMISNG::Util::setFileProtDiag(file => $logfile) if (-f $logfile);
warn "failed to set permissions: $error\n" if ($error);

# use debug, or info arg, or configured log_level
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level(
														     debug => $arg->{debug} ) // $C->{log_level},
															 path  => (defined $arg->{debug})? undef : $logfile);

$DOEXPORT = 0 if $arg->{export} =~ /^0$|^f|^F/;
$DOFTP = 0 if $arg->{ftp} =~ /^0$|^f|^F/;

my $nmisng;
after_update_plugin(config => $C);

exit 0;

sub after_update_plugin
{
	my (%args) = @_;
	(my $nodes, my $S ,my $C, $nmisng) = @args{qw(nodes sys config nmisng)};
	my $changesweremade = 0;

	# If we run this standalone we need to initialise some values
	#$nmisng = defined($nmisng) ? $nmisng : Compat::NMIS::new_nmisng(log => $logger);
	$nmisng = defined($nmisng) ? $nmisng : Compat::NMIS::new_nmisng();
	
	if (NMISNG::Util::existFile(dir=>'conf', name=>'DslamPortExport'))
	{
		$exportConfig = NMISNG::Util::loadTable(dir=>'conf', name=>'DslamPortExport');
	}
	else
	{
		$nmisng->log->error("ERROR Configuration file for DslamPortExport missing.");
		print "ERROR Configuration file for DslamPortExport missing. \n" if ($debug);
		return ($changesweremade, undef);
	}

	if (NMISNG::Util::existFile(dir=>'conf', name=>'DslamPortFiles'))
	{
		$exportFiles = NMISNG::Util::loadTable(dir=>'conf', name=>'DslamPortFiles');
	}
	else {
		$nmisng->log->error("ERROR Configuration file for DslamPortFiles missing, auto created first time.");
		print "ERROR Configuration file for DslamPortFiles missing, auto created first time. \n" if ($debug);
	}

	$baseDir = $exportConfig->{exportBaseDir};
	
	if ( not -d $baseDir ) {
		make_path("$baseDir", {chmod => 0770} );	
	}

	my $exportType = "DSLAM";

	my $exportFile = getFileName($exportType, $C->{server_name});
	my $EXPORT = getFileHandle("$baseDir/$exportFile");
	
	if ( $DOEXPORT ) {
		$nmisng->log->info("Generating $exportType Export File $exportFile");
		print "Generating $exportType Export File $exportFile" if ($debug);
		
		$nmisng->log->info("Working on DSLAM_Ports");
		print "Working on DSLAM_Ports \n" if ($debug);
		
		$exportFiles->{$exportType} = "$baseDir/$exportFile";
		
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
		
		exportAsamDslamPortsCsv(exportHandle => $EXPORT,
								exportType => $exportType,
								section => "DSLAM_Ports",
								headers => \@asamHeaders,
								models => qr/AlcatelASAM/) if $EXPORT;
	
		$nmisng->log->info("Working on ADSL_Physical");
	
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
	
		exportAdslPortsCsv(exportHandle => $EXPORT, exportType => $exportType,
						   section => "ADSL_Physical", headers => \@adslHeaders,
						   models => qr/CiscoDSL/, useIfStack => "true") if $EXPORT;
		exportAdslPortsCsv(exportHandle => $EXPORT, exportType => $exportType,
						   section => "ADSL_Physical", headers => \@adslHeaders,
						   models => qr/LucentStinger/, useIfStack => "false") if $EXPORT;
		exportAdslPortsCsv(exportHandle => $EXPORT, exportType => $exportType,
						   section => "ADSL_Physical", headers => \@adslHeaders,
						   models => qr/ZyXEL-IES/, useIfStack => "false") if $EXPORT;
	
		close($EXPORT);
		$nmisng->log->info("Closed Export File $baseDir/$exportFile");
	}
	
	if ( $DOFTP ) {
		ftpExportFile(file => $exportFiles->{$exportType},
					  server => $exportConfig->{exportFtpServer},
					  user => $exportConfig->{exportFtpUser},
					  password => $exportConfig->{exportFtpPassword},
					  directory => $exportConfig->{exportFtpDirectory},
					  nmisng => $nmisng);
	}

	$exportType = "OLT";

	$exportFile = getFileName($exportType, $C->{server_name});
	$EXPORT = getFileHandle("$baseDir/$exportFile");
	
	if ( $DOEXPORT ) {
		$nmisng->log->info("Generating $exportType Export File $exportFile");
		print "Generating $exportType Export File $exportFile \n" if ($debug);
		
		$nmisng->log->info("Working on OLT_Ports");
		print "Working on OLT_Ports \n" if ($debug);
	
		$exportFiles->{$exportType} = "$baseDir/$exportFile";
	
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
	
		exportOltPortsCsv(exportHandle => $EXPORT,
						  exportType => $exportType,
						  section => "Service_Port",
						  headers => \@oltHeaders,
						  secondary_section => "GPON_Device",
						  secondary_headers => \@gponHeaders,
						  tertiary_section => "GPON_Device_IP",
						  tertiary_headers => \@gponIpHeaders,
						  models => qr/Huawei-MA5600/)
			if $EXPORT and $DOEXPORT;
	
		close($EXPORT);
		$nmisng->log->info("Closed Export File $baseDir/$exportFile");
	}
	
	if ( $DOFTP ) {
		ftpExportFile(file => $exportFiles->{$exportType},
					  server => $exportConfig->{exportFtpServer},
					  user => $exportConfig->{exportFtpUser},
					  password => $exportConfig->{exportFtpPassword},
					  directory => $exportConfig->{exportFtpDirectory},
					  nmisng => $nmisng);
	}

	NMISNG::Util::writeTable(dir => "conf", name => "DslamPortFiles", data => $exportFiles);

	return ($changesweremade, undef); # report if we changed anything
}

# Service_Port.hwExtSrvFlowDescInfo = GPON_Device.hwGponDeviceOntPassword
# GPON_Device.index padded with .0 e.g. 4194329344.22.0 = GPON_Device_IP.index

sub exportOltPortsCsv {
	my (%args) = @_;
	
	my $myHeaders = $args{headers};
	my $goodModels = $args{models};
	my $exportType = $args{exportType};
	my $EXPORT = $args{exportHandle};
	
	my $NODES = Compat::NMIS::loadLocalNodeTable();

	my $section = $args{section};
	die "I must know which section!" if not defined $args{section};

	my $secondary_headers = $args{secondary_headers};
	my $secondary_section = $args{secondary_section};

	my $tertiary_headers = $args{tertiary_headers};
	my $tertiary_section = $args{tertiary_section};

	my $model_section_top = "systemHealth";
	$model_section_top = $args{model_section_top} if defined $args{model_section_top};

	my $model_section = $section;
	$model_section = $args{model_section} if defined $args{model_section};
	
	$nmisng->log->info("Exporting model_section_top=$model_section_top model_section=$model_section section=$section");
		
	my $C = NMISNG::Util::loadConfTable();
				
	# declare some vars for filling in later.
	my @invHeaders;
	my %invAlias;
		
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
				
			if ( $nodemodel =~ /$goodModels/ ) {

				my $invIds = $S->nmisng_node->get_inventory_ids(
						concept => {'$in' => [$section]});
				
				if (@$invIds)
				{	
					for my $sectionId (@$invIds)
					{
						my ($section, $error) = $S->nmisng_node->inventory(_id => $sectionId);
						if ($error)
						{
							$nmisng->log->error("Failed to get inventory $sectionId: $error");
							next;
						}
						my $data = $section->data();
		
						if ( time() - $lastUpdateTime > 86400 ) {
							$nmisng->log->warn("WARNING, Last Update Data collection was more than 1 day ago: $lastUpdatePoll");
						}
						
						$INV->{$data->{index}} = $data;
					}
				}
				
				# TODO: FixME - If needed
				my $sectionIds = $S->nmisng_node->get_inventory_ids(
					concept => {'$in' => ["GPON_Device"]});
				
print "*** concept $section  \n";
				if (@$sectionIds)
				{	
					my %gponDeviceIndex;
					
					for my $sectionId (@$sectionIds)
					{
						my ($section, $error) = $S->nmisng_node->inventory(_id => $sectionId);
						if ($error)
						{
							$nmisng->log->error("Failed to get inventory $sectionId: $error");
							next;
						}
						my $data = $section->data();
		
						if ( time() - $lastUpdateTime > 86400 ) {
							$nmisng->log->warn("WARNING, Last Update Data collection was more than 1 day ago: $lastUpdatePoll");
						}
						
						if ($data->{hwGponDeviceOntPassword} =~ /(\d+)/ ) {
							$data->{hwGponDeviceOntPassword} = $1;
						} else {
							$nmisng->log->debug("ERROR with Service Number: hwGponDeviceOntPassword=$data->{hwGponDeviceOntPassword}",1);
						}
						$gponDeviceIndex{$data->{hwGponDeviceOntPassword} } = $data->{index};

						#$INV->{$data->{index}} = ($INV->{$data->{index}}) ? merge_hash($data, $INV->{$data->{index}}) : $data;
					}
					
					
	
					# load the gpon device data
					my $gponDevice;
					my $gponDeviceIp;
					
					my $gponDeviceIds = $S->nmisng_node->get_inventory_ids(
						concept => {'$in' => ["GPON_Device"]},
						filter => { historic => 0 });
					
					for my $gponDeviceId (@$gponDeviceIds)
					{
						my ($section, $error) = $S->nmisng_node->inventory(_id => $gponDeviceId);
						if ($error)
						{
							$nmisng->log->error("Failed to get inventory $gponDeviceId: $error");
							next;
						}
						$gponDevice->{$section->data()->{index}} = $section->data();
					}
					
					my $gponDeviceIpIds = $S->nmisng_node->get_inventory_ids(
						concept => {'$in' => ["GPON_Device_IP"]},
						filter => { historic => 0 });
								
					for my $gponDeviceIpId (@$gponDeviceIpIds)
					{
						my ($section, $error) = $S->nmisng_node->inventory(_id => $gponDeviceIpId);
						if ($error)
						{
							$nmisng->log->error("Failed to get inventory $gponDeviceIpId: $error");
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
						$invAlias{sysUpTime} = 'Ultimo_Sincronismo';
						$invAlias{last_update} = 'Ultimo_Datos_Actualizar';
	
						$invAlias{ifIndex} = 'Index of port';
						$invAlias{ifDescr} = 'Port';
	
						$invAlias{ifLastChange} = 'Ultima_Bajada';
						$invAlias{ifOperStatus} = 'Condicion_Operativa';
						$invAlias{ifAdminStatus} = 'Condicion_Administrativa';
											
						# create a header
						my @aliases;
						foreach my $header (@invHeaders) {
							my $alias = $header;
							$alias = $invAlias{$header} if $invAlias{$header};
							push(@aliases,"\"$alias\"");
						}
						if ( not $headerDone{$exportType} ) {
							my $row = join($sep,@aliases);
							print $EXPORT "$row\n";
							$headerDone{$exportType} = 1;
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
							$nmisng->log->info("ERROR: $node has bad service number for idx=$idx hwExtSrvFlowDescInfo=$INV->{$idx}{hwExtSrvFlowDescInfo}");					
						}

						# lets merge in the data from the secondary section.
						if ( defined $gponDeviceIndex{$INV->{$idx}{hwExtSrvFlowDescInfo}} ) {
							my $gponIndex = $gponDeviceIndex{$INV->{$idx}{hwExtSrvFlowDescInfo}};
							if ( not defined $gponDevice->{$gponIndex} ) {
								$nmisng->log->info("ERROR: $node no $secondary_section data for gponIndex=$gponIndex");					
							}
							else {
								$nmisng->log->debug("INFO: $node, $secondary_section data for hwExtSrvFlowDescInfo=$INV->{$idx}{hwExtSrvFlowDescInfo} gponIndex=$gponIndex",2);					
							}
							
							foreach my $heading (@{$secondary_headers}) {
								$INV->{$idx}{$heading} = $gponDevice->{$gponIndex}{$heading};
							}
							
							# now we do the tertiary table join
							my $gponIpIndex = "$gponIndex.0";
							if ( not defined $gponDeviceIp->{$gponIpIndex} ) {
								$nmisng->log->info("ERROR: $node no $tertiary_section data for hwExtSrvFlowDescInfo=$INV->{$idx}{hwExtSrvFlowDescInfo} gponIpIndex=$gponIpIndex");
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
						foreach my $header (@invHeaders) {
							my $data = undef;
							if ( defined $INV->{$idx}{$header} ) {
								$data = $INV->{$idx}{$header};
							}
							else {
								$data = "";
							}
		
							$data = "" if $data eq "noSuchInstance";
								
							$data = changeCellSep($data);
							push(@columns,"\"$data\"");
						}
						my $row = join($sep,@columns);
						print $EXPORT "$row\n";
					}
				} 
				
			} else {
					$nmisng->log->error("ERROR: $node no $section MIB Data available, check the model contains it and run an update on the node.");
					next;
			}
	  }
	}
}

sub exportAdslPortsCsv {
	my (%args) = @_;
	
	my $myHeaders = $args{headers};
	my $goodModels = $args{models};
	my $useIfStack = NMISNG::Util::getbool($args{useIfStack});
	my $exportType = $args{exportType};
	my $EXPORT = $args{exportHandle};
		
	my $NODES = Compat::NMIS::loadLocalNodeTable();

	my $section = $args{section};
	die "I must know which section!" if not defined $args{section};

	my $model_section_top = "systemHealth";
	$model_section_top = $args{model_section_top} if defined $args{model_section_top};

	my $model_section = $section;
	$model_section = $args{model_section} if defined $args{model_section};
	
	$nmisng->log->info("Exporting model_section_top=$model_section_top model_section=$model_section section=$section");
		
	my $C = NMISNG::Util::loadConfTable();
				
	# declare some vars for filling in later.
	my @invHeaders;
	my %invAlias;
		
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
			print "[exportAdslPortsCsv] Checking node $node model " .$nodemodel . " for $goodModels \n" if ($debug);
			
			# TODO: Verify
			if ( $nodemodel =~ /$goodModels/ ) {
# TODO: Verify				
#print "Processing $goodModels ".$NODES->{$node}{name}."\n";
#print "Section $section \n";
#print Dumper($S->{info});
				# Get inventory by section
				my $sectionIds = $S->nmisng_node->get_inventory_ids(
					concept => {'$in' => [$section]},
					filter => { historic => 0 });
				
				if (@$sectionIds)
				{	
					my %gponDeviceIndex;
					
					for my $sectionId (@$sectionIds)
					{
						my ($section, $error) = $S->nmisng_node->inventory(_id => $sectionId);
						if ($error)
						{
							$nmisng->log->error("Failed to get inventory $sectionId: $error");
							next;
						}
						my $data = $section->data();
						
						if ( time() - $lastUpdateTime > 86400 ) {
							$nmisng->log->warn("WARNING, Last Update Data collection was more than 1 day ago: $lastUpdatePoll");
						}
						
						$INV->{$data->{index}} = ($INV->{$data->{index}}) ? merge_hash($data, $INV->{$data->{index}}) : $data;
					}
				}
				else {
					$nmisng->log->info("ERROR: $node no $section MIB Data available, check the model contains it and run an update on the node.");
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
							$nmisng->log->error("Failed to get inventory $sectionId: $error");
							next;
						}
						my $data = $section->data();
						
						if ( time() - $lastUpdateTime > 86400 ) {
							$nmisng->log->warn("WARNING, Last Update Data collection was more than 1 day ago: $lastUpdatePoll");
						}
						
						# TODO: Indexed by other field??? 
						$adslChannel->{$data->{index}} = $data;
					}
				}
				else {
					$nmisng->log->info("ERROR: $node no $section MIB Data available, check the model contains it and run an update on the node.");
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
					$invAlias{sysUpTime} = 'Ultimo_Sincronismo';
					$invAlias{last_update} = 'Ultimo_Datos_Actualizar';

					$invAlias{ifIndex} = 'Index of port';
					$invAlias{ifDescr} = 'Port';

					$invAlias{ifLastChange} = 'Ultima_Bajada';
					$invAlias{ifOperStatus} = 'Condicion_Operativa';
					$invAlias{ifAdminStatus} = 'Condicion_Administrativa';

					$invAlias{adslAtucChanCurrTxRate} = 'Velocidad_Puerto_DN';
					$invAlias{adslAturChanCurrTxRate} = 'Velocidad_Puerto_UP';

					$invAlias{xdslFarEndLineLoopAttenuationDownstream} = 'Loop_Atenuacion_Bajada';
					$invAlias{xdslLineLoopAttenuationUpstream} = 'Loop_Atenuacion_Subida';
					$invAlias{xdslLineServiceProfileNbr} = 'Numero_Profile';
					$invAlias{xdslLinkUpActualBitrateDownstream} = 'Velocidad_Actual_DN';
					$invAlias{xdslLinkUpActualBitrateUpstream} = 'Velocidad_Actual_UP';
					$invAlias{xdslLineOutputPowerDownstream} = 'Potencia_Dslam';
					$invAlias{xdslFarEndLineOutputPowerUpstream} = 'Potencia_Moden';
					$invAlias{xdslXturInvSystemSerialNumber} = 'Serial_Modem';
					$invAlias{xdslLineServiceProfileName} = 'Nombre_Profile';
					
					# create a header
					my @aliases;
					foreach my $header (@invHeaders) {
						my $alias = $header;
						$alias = $invAlias{$header} if $invAlias{$header};
						push(@aliases,"\"$alias\"");
					}
					if ( not $headerDone{$exportType} ) {
						my $row = join($sep,@aliases);
						print $EXPORT "$row\n";
						$headerDone{$exportType} = 1;
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
							$nmisng->log->debug("DEBUG: $idx $INV->{$idx}{ifDescr} ifStackHigherLayer=$ifStackHigherLayer $adslChannel->{$ifStackHigherLayer}{ifDescr}",2);
							$INV->{$idx}{adslAtucChanCurrTxRate} = $adslChannel->{$ifStackHigherLayer}{adslAtucChanCurrTxRate};
							$INV->{$idx}{adslAturChanCurrTxRate} = $adslChannel->{$ifStackHigherLayer}{adslAturChanCurrTxRate};							
						}
						else {
							$nmisng->log->info("ERROR: $idx $INV->{$idx}{ifDescr} has no ifStackHigherLayer");
						}
						
				    my @columns;
				    foreach my $header (@invHeaders) {
				    	my $data = undef;

				    	if ( defined $INV->{$idx}{$header} ) {
				    		$data = $INV->{$idx}{$header};
				    	}
				    	else {
				    		$data = "";
				    	}

						$data = "" if $data eq "noSuchInstance";
							
				    	$data = changeCellSep($data);
				    	push(@columns,"\"$data\"");
				    }
					my $row = join($sep,@columns);
					print $EXPORT "$row\n";
			  	}
			  }
			}
	  }
	}
}


sub exportAsamDslamPortsCsv {
	my (%args) = @_;

	my $myHeaders = $args{headers};
	my $goodModels = $args{models};
	my $exportType = $args{exportType};
	my $EXPORT = $args{exportHandle};
	
	my $section = $args{section};
	die "I must know which section!" if not defined $args{section};

	my $NODES = Compat::NMIS::loadLocalNodeTable();

	my $model_section_top = "systemHealth";
	$model_section_top = $args{model_section_top} if defined $args{model_section_top};

	my $model_section = $section;
	$model_section = $args{model_section} if defined $args{model_section};
	
	$nmisng->log->info("Exporting model_section_top=$model_section_top model_section=$model_section section=$section");
		
	my $C = NMISNG::Util::loadConfTable();
				
	# declare some vars for filling in later.
	my @invHeaders;
	my %invAlias;
	my %portIndex;
		
	foreach my $node (sort keys %{$NODES}) {
	  if ( $NODES->{$node}{active} eq "true" ) {
		
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
						
			if ( $nodemodel =~ /$goodModels/ ) {
				
				my $sectionIds = $S->nmisng_node->get_inventory_ids(
					concept => {'$in' => [$section]},
					filter => { historic => 0 });
	
				if (@$sectionIds)
				{	
					for my $sectionId (@$sectionIds)
					{
						my ($section, $error) = $S->nmisng_node->inventory(_id => $sectionId);
						if ($error)
						{
							$nmisng->log->error("Failed to get inventory $sectionId: $error");
							next;
						}
						my $data = $section->data();
		
						if ( time() - $lastUpdateTime > 86400 ) {
							$nmisng->log->warn("WARNING, Last Update Data collection was more than 1 day ago: $lastUpdatePoll");
						}

						$INV->{$data->{index}} = $data;
					}
				}
				else {
					$nmisng->log->info("ERROR: $node no $section MIB Data available, check the model contains it and run an update on the node.");
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
					$invAlias{sysUpTime} = 'Ultimo_Sincronismo';
					$invAlias{last_update} = 'Ultimo_Datos_Actualizar';
					$invAlias{xdslLineServiceProfileName} = 'Nombre_Profile';
					
					# create a header
					my @aliases;
					foreach my $header (@invHeaders) {
						my $alias = $header;
						$alias = $invAlias{$header} if $invAlias{$header};
						push(@aliases,"\"$alias\"");
					}
					if ( not $headerDone{$exportType} ) {
						my $row = join($sep,@aliases);
						print $EXPORT "$row\n";
						$headerDone{$exportType} = 1;
					}
				}	else {
					print "invHeaders defined";
				}
#print Dumper($INV);
#print Dumper(@invHeaders);
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
					    foreach my $header (@invHeaders) {
					    	my $data = undef;
							
					    	if ( defined $INV->{$idx}{$header} ) {
					    		$data = $INV->{$idx}{$header};
					    	}
					    	else {
					    		$data = "";
					    	}
	
							$data = "" if $data eq "noSuchInstance";

					    	$data = changeCellSep($data);
					    	push(@columns,"\"$data\"");
					    }
							my $row = join($sep,@columns);
							print $EXPORT "$row\n";								
						}
						else {
							$nmisng->log->info("INFO: skipping $idx as ifIndex $ifIndex has already been seen with atmVclVci $portIndex{$ifIndex}");
						}
			  	}
				}
			}
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
	my $type = shift;
	my $servername = shift;
	my $time = time();
	return POSIX::strftime("$type%Y%m%d%H%M%S$servername.csv", localtime($time));
}

sub getFileHandle {
	my $file = shift;
	my $time = time();
	
	open(EXPORT,">$file") or $nmisng->log->error("Problem with file $file: $!");
	
	# return the file handle, its a star!
	return *EXPORT;
}

sub ftpExportFile {
	my (%args) = @_;

	my $file = $args{file};
	my $server = $args{server};
	my $user = $args{user};
	my $password = $args{password};
	my $directory = $args{directory};
	my $nmisng = $args{nmisng};
		
	my $sftp = Net::SFTP::Foreign->new(
		$server, 
		user => $user,
		password => $password
	);
	print "Unable to establish SFTP connection: " . $sftp->error . "\n" if $sftp->error;
	$nmisng->log->error("Unable to establish SFTP connection: " . $sftp->error) if $sftp->error;
	
	if ( $sftp ) {
		if (!$sftp->setcwd($directory)) {
			$nmisng->log->error("unable to change cwd: " . $sftp->error);
			print "unable to change cwd: " . $sftp->error . "\n";
		}
		if (!$sftp->put($file)) {
			$nmisng->log->error("put failed: " . $sftp->error);
			print "put failed: " . $sftp->error . "\n";
			return;
		}
		
		print "Export file $file put to $server:$directory \n";
		$nmisng->log->info("Export file $file put to $server:$directory");
	}	
}

1;
