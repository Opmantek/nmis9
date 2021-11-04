#!/usr/bin/perl
#
## $Id: modelcheck.pl,v 1.1 2011/11/16 01:59:35 keiths Exp $
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

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";
 
use strict;
use NMISNG::Util;
use Compat::NMIS; 	
use NMISNG::Sys;
use Compat::Timing;
use NMISNG::Snmp;

#use snmp 1.1.0;									# for snmp-related access
use Data::Dumper;

my $modelTemplate = "$FindBin::Bin/../models-default/Model-Default-HC.nmis";
my $schemaFile = "$FindBin::Bin/../conf/Model-Schema.nmis";

if ( $ARGV[0] eq "" ) {
	usage();
	exit 1;
}

my $t = Compat::Timing->new();

print $t->elapTime(). " Begin\n";

# Variables for command line munging
my $arg = NMISNG::Util::get_args_multi(@ARGV);

if ( not defined $arg->{node} and not defined $arg->{check} and not defined $arg->{schema} and not defined $arg->{nodes} ) {
	print "ERROR: need a node to discover or check things\n";
	usage();
	exit 1;
}

my $node = $arg->{node};
my $file = $arg->{file};
my $check = $arg->{check};
my $nodes = $arg->{nodes};
my $schema = $arg->{schema} ? NMISNG::Util::getbool($arg->{schema}) : 1;
my $make_schema = $arg->{make_schema} ? NMISNG::Util::getbool($arg->{make_schema}) : 0;
my $models_dir = $arg->{models_dir} ? $arg->{models_dir} : "models-default";
my $newModelName = $arg->{model};
my $common_exclude = $arg->{common_exclude};
my $errors = $arg->{errors} ? NMISNG::Log::parse_debug_level(debug => $arg->{errors}) : 1;

# lets not check the schema while making one.
$schema = 0 if $make_schema;

# Set debugging level.
my $debug = $arg->{debug} ? $arg->{debug} : 0;

my $C = NMISNG::Util::loadConfTable( dir => $arg->{conf}, debug => $arg->{debug});

print $t->elapTime(). " What Existing Modelling Applies to $node\n" if debug();

my $pass = 0;
my $dirpass = 1;
my $dirlevel = 0;
my $maxrecurse = 200;
my $maxlevel = 10;

my $bad_file;
my $bad_dir;
my $file_count;
my $mib_count;
my $extension = "nmis";

my $indent = 0;
my @path;
my $rrdlen = 19;

my $curModel;
my $models;
my $vendors;
my $modLevel;
my @topSections;
my @oidList;
my $schemaErrors = 0;

# needs feature to match enterprise, e.g. only do standard mibs and my vendor mibs.

# in the structure, which things are allowed to have children?
my @topLevel = qw(
	alerts
	custom
	hrsmpcpu
	threshold
	-common-
	summary
	system
	heading
	database
	stats
	event
	systemHealth
	interface
	port
	hrwincpu
	hrdisk
	hrmem
	environment
	calls
	device
	cbqos-in
	cbqos-out
	storage
);


# these keywords should only live in these locations.
# keyword points to the one or more masks it can be used in.
my $schemaMasks = {
	'alert' => [ 20, 21 ],
	'calculate' => [ 3, 24 ],

	'check' => [ 3 ],
	'common-model' => [ 41 ],
	'control' => [ 1, 23, 25, 26 ],
	'control_regex' => [ 27 ],
	'element' => [ 23 ],
	'event' => [ 23, 27 ],
	'field' => [ 3, 30 ],
	'format' => [ 3 ],
	'graphtype' => [ 1, 25 ],
	'headers' => [ 1 ],
	'index_headers' => [ 1 ],
	'index_oid' => [ 1 ],
	'index_regex' => [ 1 ],
	'indexed' => [ 1, 24, 25 ],
	'info' => [ 3 ],
	'item' => [ 27 ],
	'level' => [ 23, 50 ],
	'logging' => [ 50 ],
	'nocollect' => [ 1 ],
	'oid' => [ 3, 20, 22, 24 ],
	'option' => [ 3, 24 ],
	'query' => [ 3, 30 ],
	'replace' => [ 3, 24 ],	
	'snmp' => [ 1, 22, 25 ],
	'snmpObject' => [ 3, 20, 23, 24 ],
	'snmpObjectName' => [ 1, 3, 20, 23 ],
	'sysObjectName' => [ 3, 20, 23 ],
	'syslog' => [ 50 ],

	'sections' => [ 10 ],
	'select' => [ 27 ],
	'stsname' => [ 45 ],
	'sumname' => [ 45 ],
	'test' => [ 23 ],
	'title' => [ 3, 20, 23, 24, 27 ],	
	'title_export' => [ 3, 20, 23, 24 ],	
	'threshold' => [ 1, 23, 25 ],
	'type' => [ 23 ],	
	'unit' => [ 3, 23, 27 ],	
	'value' => [ 23, 26 ],	
	'wmi' => [ 1, 22, 25 ],
};

my $keywordSchemaMasks = {
	#systemHealth/sys/QoSOut/snmp/QosName
	0 => qr/./,
	1 => qr/^(interface|system|systemHealth)\/(rrd|sys)\/[\w\-]+$/,
	3 => qr/^(interface|system|systemHealth)\/(rrd|sys)\/[\w\-]+\/(snmp|wmi)\/[\w\-]+$/,
	4 => qr/^(system|interface)\/(rrd|sys)\/[\w\-]+\/snmp$/,

	10 => qr/^systemHealth$/,
	12 => qr/^systemHealth$/,

	#system/sys/alerts/snmp/banana
	20 => qr/^system\/sys\/alerts\/(snmp|wmi)\/[\w\-]+$/,
	21 => qr/^event\/event$/,
	22 => qr/^(device|storage)\/(sys)\/[\w\-]+$/,
	23 => qr/^alerts\/[\w\-]+\/[\w\-]+$/,
	24 => qr/^(port|hrwincpu|hrdisk|hrmem|environment|calls|device|cbqos-in|cbqos-out|storage)\/(rrd|sys)\/[\w\-]+\/snmp\/[\w\-]+$/,
	25 => qr/^(port|hrwincpu|hrdisk|hrmem|environment|calls|device|cbqos-in|cbqos-out|storage)\/(rrd|sys)\/[\w\-]+$/,
	26 => qr/^threshold\/name\/[\w\-]+\/select\/[\w\-]+$/,
	27 => qr/^threshold\/name\/[\w\-]+$/,

	30 => qr/^system\/sys\/[\w\-]+\/wmi\/[\w\-]+$/,

	41 => qr/^\-common\-\/class\/[\w\-]+$/,
	#summary/statstype/nodehealth
	#summary/statstype/health/sumname/reachable
	45 => qr/^(summary\/statstype\/[\w\-]+|summary\/statstype\/[\w\-]+\/sumname\/[\w\-]+)$/,
	#event/event/service down/core
	50 => qr/^event\/event\/[\w\ ]+\/(core|distribution|access)$/,
};

# these classes can have user defined terms
my $genericSchemaMasks = {
	# systemHealth/sys/QoSOut/snmp/QosName
	5 => qr/^(system|systemHealth|interface)\/(rrd|sys)$/,
	10 => qr/^(system|systemHealth|interface)\/(rrd|sys)\/[\w\-]+\/(snmp|wmi)$/,
	15 => qr/^(system|systemHealth|interface)\/(rrd|sys)\/[\w\-]+\/(snmp|wmi)\/[\w\-]+\/replace$/,

	20 => qr/^(port|hrwincpu|hrdisk|hrmem|environment|calls|device|cbqos-in|cbqos-out|storage)\/(rrd|sys)$/,
	25 => qr/^(port|hrwincpu|hrdisk|hrmem|environment|calls|device|cbqos-in|cbqos-out|storage)\/(rrd|sys)\/[\w\-]+\/(snmp|wmi)$/,
	30 => qr/^(port|hrwincpu|hrdisk|hrmem|environment|calls|device|cbqos-in|cbqos-out|storage)\/(rrd|sys)\/[\w\-]+\/(snmp|wmi)\/[\w\-]+\/replace$/,
	
	40 => qr/^\-common\-\/class$/,

	# anything under event/event/[event name] is allowed, needs context checking.
	41 => qr/^event\/event\/[\w\-\ ]+$/,

	# summary/statstype
	# summary/statstype/[\w\-]+/sumname
	# summary/statstype/[\w\-]+/sumname/[\w\-]+/stsname
	45 => qr/^(summary\/statstype|summary\/statstype\/[\w\-]+\/sumname|summary\/statstype\/[\w\-]+\/sumname\/[\w\-]+\/stsname)$/,
	
	# -common-/class
	# threshold/name
	# heading/graphtype
	# database/type
	# stats/type
	# event/event
	50 => qr/^(threshold\/name|heading\/graphtype|database\/type|stats\/type|event\/event|\-common\-\/class)$/,
	60 => qr/^(alerts|alerts\/[\w\-]+)$/,
	70 => qr/^(\d+|\-\d+)$/,
};

my $includeSchemaMasks = {
	# systemHealth/sys/QoSOut/snmp/QosName
	1 => qr/^(systemHealth|interface)\/(sys)\/[\w\-]+$/,
	2 => qr/^(systemHealth|interface)\/(rrd)\/[\w\-]+$/,
	3 => qr/^(systemHealth|interface)\/(rrd|sys)\/[\w\-]+\/snmp\/[\w\-]+$/,
	4 => qr/^(system|interface)\/(rrd|sys)\/[\w\-]+\/snmp$/,
	10 => qr/^(system|systemHealth|interface|port|hrwincpu|hrdisk|hrmem|environment|calls|device|cbqos-in|cbqos-out|storage)\/(rrd|sys)$/,
	20 => qr/^(system|systemHealth|interface|port|hrwincpu|hrdisk|hrmem|environment|calls|device|cbqos-in|cbqos-out|storage)\/(rrd|sys)\/[\w\-]+\/(snmp|wmi)\/[\w\-]+$/,
	30 => qr/^(system|systemHealth|interface|port|hrwincpu|hrdisk|hrmem|environment|calls|device|cbqos-in|cbqos-out|storage)\/(rrd|sys)\/[\w\-]+\/(snmp|wmi)\/[\w\-]+\/replace$/,
	
	# summary/statstype
	# summary/statstype/[\w\-]+/sumname
	# summary/statstype/[\w\-]+/sumname/[\w\-]+/stsname
	40 => qr/^(summary\/statstype|summary\/statstype\/[\w\-]+\/sumname|summary\/statstype\/[\w\-]+\/sumname\/[\w\-]+\/stsname)$/,
	
	# -common-/class
	# threshold/name
	# heading/graphtype
	# database/type
	# stats/type
	# event/event
	50 => qr/^(threshold\/name|heading\/graphtype|database\/type|stats\/type|event\/event|\-common\-\/class)$/,
	60 => qr/^(alerts|alerts\/[\w\-]+)$/,
	70 => qr/^(\d+|\-\d+)$/,
};

my @schema;
my @discoverList;
my $discoveryResults;
my %graphTypes;
my %nodeSummary;

my $mibs = loadMibs($C);
my $modelSchema;

if ( $schema and -r $schemaFile ) {
	$modelSchema = NMISNG::Util::readFiletoHash(file => $schemaFile);	
}
else {
	$schema = 0;
}

if ($nodes) {
	checkNodes();
	exit 0;
}

print $t->elapTime(). " Load all the NMIS models from $C->{'<nmis_base>'}/$models_dir\n";
processDir(dir => "$C->{'<nmis_base>'}/$models_dir");
print $t->elapTime(). " Done with Models.  Processed $file_count NMIS Model files.\n";

checkGraphTypes("$C->{'<nmis_base>'}/$models_dir");

if ( defined $node ) {
	print $t->elapTime(). " Processing MIBS on node $node.\n" if debug();
	processNode($node);
	print $t->elapTime(). " Done with node.  Tried $mib_count SNMP MIBS.\n" if debug();	
	print Dumper $discoveryResults if debug2();

	printDiscoverySummary();

	printDiscoveryResults($file) if defined $file;
}

saveSchema($schemaFile);

if (debug3()) {
	print Dumper \@discoverList;
	print Dumper \%graphTypes;
	print Dumper $modelSchema;
}

if ( $schema ) {
	printSchemaSummary();
	print "$schemaErrors model schema errors were found.\n";
}

sub printSchemaSummary {
	foreach my $keyword ( sort {$a cmp $b} keys (%{$modelSchema->{keywords}}) ) {
		my $parents = "@{$modelSchema->{keywords}{$keyword}{parents}}" if defined $modelSchema->{keywords}{$keyword}{parents};
		#print "$keyword :: parents:$parents\n";
		foreach my $parent (@{$modelSchema->{keywords}{$keyword}{parents}}) {
			if ( not defined $modelSchema->{keywords}{$parent} ) {
				print "$keyword, has parent $parent which is not a keyword\n";
			}
		}
	}
}

sub checkGraphTypes {
	my $models_dir = shift;

	foreach my $section (sort {$a cmp $b} (keys %graphTypes)) {
		print "Checking section $section graphtypes: $graphTypes{$section}{graphtype}\n" if debug2();
		my @graphtypes = split(",",$graphTypes{$section}{graphtype});
		foreach my $graphtype (sort {$a cmp $b} (@graphtypes)) {
			my $graph_file = "$models_dir/Graph-$graphtype.nmis";
			if ( not -f $graph_file ) {
				print "MODEL ERROR: missing file for graph type $graphtype: $graph_file\n" if errors();
			}
			else {
				print "  Graph file found for graph type $graphtype: $graph_file\n" if debug2();
			}

		}
	}
}

sub processNode {
	my $node = shift;

	my $LNT = Compat::NMIS::loadLocalNodeTable();
    my $nmisng = Compat::NMIS::new_nmisng();
    my $nodeobj = $nmisng->node(name => $node);
    
	if ( not NMISNG::Util::getbool($LNT->{$node}{active})) {
		die "Node $node is not active, will die now.\n";
	}
	else {
		print $t->elapTime(). " Working on SNMP Discovery for $node\n" if debug();
	}

	my %doneIt;
	# initialise the node.
	my $S = NMISNG::Sys->new; # get system object
	$S->init(name=>$node,snmp=>'true'); # load node info and Model if name exists
	my $NI = $nodeobj->{configuration};
	my $IF = $nodeobj->ifinfo;
	my $NC = $nodeobj->{configuration};
	my $max_repetitions = $NC->{node}->{max_repetitions} || $C->{snmp_max_repetitions};
	my ($inventory, $error) =  $nodeobj->inventory( concept => "catchall" );
	my $catchall = $inventory->data();

	$nodeSummary{node} = $node;
	$nodeSummary{sysDescr} = $catchall->{sysDescr};
	$nodeSummary{sysObjectID} = $catchall->{sysObjectID};
	$nodeSummary{nodeVendor} = $catchall->{nodeVendor};
	$nodeSummary{nodeModel} = $catchall->{nodeModel};

	my %nodeconfig = %{$NC->{node}}; # copy required because we modify it...
	$nodeconfig{host_addr} = $NI->{system}{host};

	#my $snmp = snmp->new(name => $node);
    my $snmp = NMISNG::Snmp->new(name => $node, nmisng => $nmisng);
	print Dumper $snmp if debug2();

	if (!$snmp->open(config => \%nodeconfig ))
	{
		print "ERROR: Could not open SNMP session to node $node: ".$snmp->error;
	}
	else
	{
		if (!$snmp->testsession)
		{
			print "ERROR: Could not retrieve SNMP vars from node $node: ".$snmp->error;
		}
		else
		{
			my $count = 0;
			foreach my $thing (@discoverList) {
				my $works = undef;
				
				if ( $thing->{type} eq "systemHealth" and not defined $doneIt{$thing->{index_oid}}) {
					++$count;
					print $t->elapTime(). " $count System Health Discovery on $node of MIB in $thing->{file}::$thing->{path}\n" if debug();
					++$mib_count;
					my $result = $snmp->gettable($thing->{index_oid},$max_repetitions);
					$doneIt{$thing->{index_oid}} = 1;
					if ( defined $result ) {
						$works = "YES";
						print $t->elapTime(). " MIB SUPPORTED: $thing->{indexed} $thing->{index_oid}\n" if debug();
						print Dumper $thing if debug2();
						print Dumper $result if debug2();
					}
					else {
						$works = "NO";
						print $t->elapTime(). " MIB NOT SUPPORTED: $thing->{indexed} $thing->{index_oid}\n" if debug();
					}
					print "\n" if debug();
					
					$discoveryResults->{$thing->{index_oid}}{node} = $node;
					#$discoveryResults->{$thing->{index_oid}}{sysDescr} = $NI->{system}{sysDescr};
					$discoveryResults->{$thing->{index_oid}}{nodeModel} = $NI->{system}{nodeModel};
					$discoveryResults->{$thing->{index_oid}}{Type} = $thing->{type};
					$discoveryResults->{$thing->{index_oid}}{File} = $thing->{file};
					$discoveryResults->{$thing->{index_oid}}{Path} = $thing->{path};
					$discoveryResults->{$thing->{index_oid}}{Section} = $thing->{section};
					$discoveryResults->{$thing->{index_oid}}{Supported} = $works;
					$discoveryResults->{$thing->{index_oid}}{SNMP_Object} = $thing->{indexed};
					$discoveryResults->{$thing->{index_oid}}{SNMP_OID} = $thing->{index_oid};
					$discoveryResults->{$thing->{index_oid}}{OID_Used} = $thing->{index_oid};
					$discoveryResults->{$thing->{index_oid}}{result} = Dumper $result;
					$discoveryResults->{$thing->{index_oid}}{result}
				}
				elsif ( $thing->{type} eq "system" and not defined $doneIt{$thing->{snmpoid}} ) {
					++$count;
					print "  $count System Discovery on $node of MIB in $thing->{file}::$thing->{path}\n" if debug();
					my $getoid = $thing->{snmpoid};
					# does the oid in the model finish in a number?
					if ( $thing->{oid} !~ /\.\d+/ ) {
						$getoid .= ".0";
					}
					# does the actual snmpoid finish in a number?
					elsif ( $getoid !~ /\.0/ ) {
						$getoid .= ".0";
					}
					++$mib_count;
					my $result = $snmp->get($getoid);
					$doneIt{$thing->{snmpoid}} = 1;

					if ( defined $result and $result->{$getoid} !~ /(noSuchObject|noSuchInstance)/ ) {
						$works = "YES";
						print $t->elapTime(). " MIB SUPPORTED: $thing->{oid} $thing->{snmpoid}\n" if debug();
						print Dumper $thing if debug2();
						print Dumper $result if debug2();
					}
					else {
						$works = "NO";
						print $t->elapTime(). " MIB NOT SUPPORTED: $thing->{oid} $thing->{snmpoid}\n" if debug();
					}
					print "\n" if debug();
					$discoveryResults->{$thing->{snmpoid}}{node} = $node;
					#$discoveryResults->{$thing->{snmpoid}}{sysDescr} = $NI->{system}{sysDescr};
					$discoveryResults->{$thing->{snmpoid}}{nodeModel} = $NI->{system}{nodeModel};
					$discoveryResults->{$thing->{snmpoid}}{Type} = $thing->{type};
					$discoveryResults->{$thing->{snmpoid}}{File} = $thing->{file};
					$discoveryResults->{$thing->{snmpoid}}{Path} = $thing->{path};
					$discoveryResults->{$thing->{snmpoid}}{Section} = $thing->{section};
					$discoveryResults->{$thing->{snmpoid}}{Supported} = $works;
					$discoveryResults->{$thing->{snmpoid}}{SNMP_Object} = $thing->{oid};
					$discoveryResults->{$thing->{snmpoid}}{SNMP_OID} = $thing->{snmpoid};
					$discoveryResults->{$thing->{snmpoid}}{OID_Used} = $thing->{snmpoid};
					$discoveryResults->{$thing->{snmpoid}}{result} = $result->{$getoid};
				}
				last if $count >= 10000;
			}


		}
	}
}

sub printDiscoverySummary {

	my $newModel = NMISNG::Util::readFiletoHash(file => $modelTemplate) if defined $newModelName;

	# do some basic model changes
	if ( defined $newModelName ) {
		$newModel->{'system'}{'nodeModel'} = $newModelName;
		$newModel->{'system'}{'nodeModelComment'} = "Auto Generated Model by model_discovery.pl";
	}

	my %graphTypeSupported;

	$nodeSummary{sysDescr} =~ s/\r\n/\\n/g;
	print "node:\t$nodeSummary{node}\n";
	print "sysDescr:\t$nodeSummary{sysDescr}\n";
	print "sysObjectID:\t$nodeSummary{sysObjectID}\n";
	print "nodeVendor:\t$nodeSummary{nodeVendor}\n";
	print "nodeModel:\t$nodeSummary{nodeModel}\n";
	print "\n";

	my $useVendor = "YOU NEED TO GET THE NAME FROM IANA";

	if ( $nodeSummary{nodeVendor} eq "Universal" ) {
		# get the Enterprise ID
		my @x = split(/\./,$nodeSummary{sysObjectID});
		my $i = $x[6];

		print <<EOT
No Enterprise was found for sysObjectID $nodeSummary{sysObjectID}

conf/Enterprise.nmis will need to be updated with an entry for Enterprise ID $i
IANA https://www.iana.org/assignments/enterprise-numbers/enterprise-numbers
e.g. 

  '$i' => {
    'Enterprise' => '$useVendor',
    'OID' => '$i'
  },

EOT
	}
	else {
		$useVendor = $nodeSummary{nodeVendor};
	}

	if ( $nodeSummary{nodeModel} eq "Default" ) {
		print <<EOT
Node using the default Model, you might need some autodiscovery.

models/Model.nmis will need to updated for autodiscovery for example:

    '$useVendor' => {
      'order' => {
        '10' => {
          '$newModelName' => '$nodeSummary{sysDescr}'
        },
      }
    },

Likely you will need to refine the regular expression used in the model discovery.    
EOT
	}

#	#Does an enterprise exist for this node?
#	loadEnterpriseTable();
#	my $enterpriseTable = loadEnterpriseTable();
#
#
#	# Special handling for devices with bad sysObjectID, e.g. Trango
#	if ( not $i ) {
#		$i = $NI->{system}{sysObjectID};
#	}
#
#( $enterpriseTable->{$i}{Enterprise} ne "" )
#1895:					$NI->{system}{nodeVendor} = $enterpriseTable->{$i}{Enterprise};
#
	my @sections = ();
	my @common_things = ();
	# loop through the data
	foreach my $key ( sort { $discoveryResults->{$a}{Type} cmp $discoveryResults->{$b}{Type} } (keys %$discoveryResults) ) {
		if ( $discoveryResults->{$key}{Supported} eq "YES" ) {
			if ( $discoveryResults->{$key}{Type} eq "systemHealth" ) {
				my $section_name = $discoveryResults->{$key}{Path};
				$section_name =~ s|\w+/systemHealth/sys/(\w+)|$1|;
				if ( not grep ($_ eq $section_name, @sections) ) {
					push(@sections,$section_name);
				}
			}

			if ( $discoveryResults->{$key}{File} =~ /Common/ ) {
				print "Found a common model to include $discoveryResults->{$key}{File}\n";
				my $common_name = $discoveryResults->{$key}{File};
				$common_name =~ s|^Common-([\w\-]+)\.nmis$|$1|;
				if ( not grep ($_ eq $common_name, @common_things) ) {
					push(@common_things,$common_name);	
				}
			}

			# what graphtypes does this section have?
			my $section = $discoveryResults->{$key}{Section};
			$graphTypeSupported{$section}{graphtype} = $graphTypes{$section}{graphtype} if defined $graphTypes{$section}{graphtype};
			$graphTypeSupported{$section}{path} = $discoveryResults->{$key}{Path} if defined $graphTypes{$section}{graphtype};

			# make this a little more pretty.
			$discoveryResults->{$key}{result} =~ s/\r\n/\\n/g;
			$discoveryResults->{$key}{result} =~ s/\n/  /g;
			print "DISCOVERED: $discoveryResults->{$key}{Type} $discoveryResults->{$key}{File} $discoveryResults->{$key}{Path} $discoveryResults->{$key}{SNMP_OID} $discoveryResults->{$key}{result}\n" if debug2();
		}
	}

	print "Common Things to Include: \n\n" if debug2();
	foreach my $common_name (@common_things) {
		# save the new common sections if common_exclude is null or if it is defined and does not match.
		if (( defined $newModelName and not defined $common_exclude )
		 	or ( defined $newModelName and defined $common_exclude and $common_name !~ /$common_exclude/ )
		) {
			print "Adding common model $common_name to model\n";
			$newModel->{'-common-'}{'class'}{$common_name}{'common-model'} = $common_name;
		}
		elsif ( defined $common_exclude and $common_name =~ /$common_exclude/ ) {
			print "Excluding from common models: $common_name\n";
		}

		print <<EO_TEXT if debug2();
      '$common_name' => {
        'common-model' => '$common_name'
      },
EO_TEXT
	}
	print "\n";

	print "System Health Sections:\n";
	my @short_sections;
	foreach my $section (@sections) {
		my @parts = split("\/",$section);
		push(@short_sections,$parts[$#parts]);
	}

	@short_sections = sort { $a cmp $b } (@short_sections);
	my $sections_list = join(",",@short_sections);
	print "'sections' => '$sections_list',\n";

    $newModel->{'systemHealth'}{'sections'} = $sections_list if defined $newModelName;

	if ( defined $newModelName ) {
		my $model_file_name = "$C->{'<nmis_models>'}/Model-$newModelName.nmis";
		NMISNG::Util::writeHashtoFile( file => $model_file_name, data=>$newModel);
		print "New Auto Model $newModelName saved to $model_file_name\n";
	}

	# fixme, not currently right, needs more time.
	#print "List of Graph Types found and their path:\n";
	#foreach my $section ( sort { $a cmp $b } (keys %graphTypeSupported) ) {
	#	print "$section ($graphTypeSupported{$section}{path}) has graph type: $graphTypeSupported{$section}{graphtype}\n";
	#}
	#print Dumper \%graphTypes;

}

sub printDiscoveryResults {
	my $file = shift;

	open(OUT,">$file") or die "ERROR with file $file: $!\n";

	# make a header and print it out
	my @header = qw(
		node
		nodeModel
		Type
		File
		Path
		Supported
		SNMP_Object
		SNMP_OID
		OID_Used
		result
	);

	$nodeSummary{sysDescr} =~ s/\r\n/\\n/g;
	print OUT "node:\t$nodeSummary{node}\n";
	print OUT "sysDescr:\t$nodeSummary{sysDescr}\n";
	print OUT "nodeModel:\t$nodeSummary{nodeModel}\n";

	print OUT "\n";
	my $printit = join("\t",@header);
	print OUT "$printit\n";

	# loop through the data
	foreach my $key ( keys %$discoveryResults ) {
		my @data;
		$discoveryResults->{$key}{result} =~ s/\r\n/\\n/g;
		$discoveryResults->{$key}{result} =~ s/\n/  /g;
		# now use the previously defined header to print out the data.
		foreach my $head (@header) {
			push(@data,$discoveryResults->{$key}{$head});
		}
		my $printit = join("\t",@data);
		print OUT "$printit\n";
	}
	close(OUT);
}
#print Dumper($models);

#@oidList = sort @oidList;
#my $out = join(",",@oidList);
#print "OIDS:$out\n";
#
#my %summary;
#foreach my $model (keys %$models) {
#	foreach my $section (@{$models->{$model}{sections}}) {
#		$summary{$model}{$section} = "YES";
#		if ( not grep {$section eq $_} @topSections ) {
#			print "ADDING $section to TopSections\n";
#			push(@topSections,$section);
#		}
#	}
#}
#
#@topSections = sort @topSections;
#my $out = join(",",@topSections);
#print "Model,$out\n";
#
#foreach my $model (sort keys %summary) {
#	my @line;
#	push(@line,$model);
#	foreach my $section (@topSections) {
#		if ( $summary{$model}{$section} eq "YES" ) {
#			push(@line,$summary{$model}{$section});
#		}
#		else {
#			push(@line,"NO");
#		}
#	}
#	my $out = join(",",@line);
#	print "$out\n";
#}


sub indent {
	for (1..$indent) {
		print " ";
	}
}

sub processDir {
	my %args = @_;
	# Starting point
	my $dir = $args{dir};
	my @dirlist;
	my $index;
	++$dirlevel;
	my @filename;
	my $key;

	if ( -d $dir ) {
		print "\nProcessing Directory $dir pass=$dirpass level=$dirlevel\n" if debug2();
	}
	else {
		print "\n$dir is not a directory\n" if debug2();
		exit -1;
	}

	#sleep 1;
	if ( $dirpass >= 1 and $dirpass < $maxrecurse and $dirlevel <= $maxlevel ) {
		++$dirpass;
		opendir (DIR, "$dir");
		@dirlist = readdir DIR;
		closedir DIR;

		if (debug2()) { print "\tFound $#dirlist entries\n"; }

		foreach my $file (sort {$a cmp $b} (@dirlist)) {
			print "Process Model file $file \n" if (debug());
		#for ( $index = 0; $index <= $#dirlist; ++$index ) {
			@filename = split(/\./,"$dir/$file");
			if ( -f "$dir/$file"
				and $extension =~ /$filename[$#filename]/i
				and $bad_file !~ /$file/i
			) {
				if (debug2()) { print "\t\t$index file $dir/$file\n"; }
			
				&processModelFile(dir => $dir, file => $file)
			}
			elsif ( -d "$dir/$file"
				and $file !~ /^\.|CVS/
				and $bad_dir !~ /$file/i
			) {
				# directory recursion disabled.
				#if (!$debug) { print "."; }
				#&processDir(dir => "$dir/$file");
				#--$dirlevel;
			}
		}
	}
} # processDir

sub processModelFile {
	my %args = @_;
	my $dir = $args{dir};
	my $file = $args{file};
	$indent = 2;
	++$file_count;
	
	if ( $file !~ /^Graph|^Model.nmis$/ ) {
		$curModel = $file;
		$curModel =~ s/Model\-|\.nmis//g;

		my $modelType = "Model";
		$modelType = "Common" if ( $file =~ /Common/ );
	
		print &indent . "Processing $curModel: $file\n" if debug();
		my $model = NMISNG::Util::readFiletoHash(file=>"$dir/$file");		
		#Recurse into structure, handing off anything which is a HASH to be handled?
		# track the modelType not using the path.
		#push(@path,$modelType);
		$modLevel = 0;
		if ( $model ) {
			processData($model,$modelType,$file);
		}
		else {
			print indent(). "MODEL ERROR: Could not load $file\n";
		}
		pop(@path);

	}	
}

sub schemaError {
	my $error = shift;
	print "$error\n" if errors();
	++$schemaErrors;
}

sub processData {
	my $data = shift;
	my $modelType = shift;
	my $file = shift;
	$indent += 2;
	++$modLevel;
	
	if ( ref($data) eq "HASH" ) {
		my $indexed = undef;
		my $index_oid = undef;

		foreach my $section (sort keys %{$data}) {
			my $curpath = join("/",@path);

			# check the schema if I have a valid parent
			if ( $schema )	{
				# who is my parent.
				my $parent = $path[-1];

				my $validSchema = 0;
				if ( not @path ) {
					if ( not grep ($_ eq $section, @topLevel) ) {
						schemaError("SCHEMA ERROR: Keyword $section incorrect Top Level: $file");
					}
					else {
						$validSchema = 1;
					}
				}

				if ( not $validSchema and defined $modelSchema->{keywords}{$section} and defined $modelSchema->{keywords}{$section}{parents} ) {
					if ( grep ($_ eq $parent, @{$modelSchema->{keywords}{$section}{parents}}) ) {
						$validSchema = 1;
						print "SCHEMA INFO: Keyword $section has parent $parent\n" if debug3();
					}
				}

				# is this a keyword we care about?
				
				if ( not $validSchema ) {
					#else {
						# lets check this a little more.
						# is this a special variable?
						print "SCHEMA INFO: Keyword $section is a Special Variable\n" if debug3();

						# when numbers or blanks are used for ordering
						if ( $section =~ /(\ |[\d\-]+)/ and $parent =~ /(select|replace)/ ) {
							$validSchema = 1;
						}
						# comments can be used, e.g. comment or control_comment are allowed anywhere.
						elsif ( $section =~ /(example|comment)$/ ) {
							$validSchema = 1;
						}

						# check the variable against our known masks, if it matches it is OK.
						if ( defined $schemaMasks->{$section} ) {
							foreach my $mask ( @{$schemaMasks->{$section}} ) {
								if ( $curpath =~ /$keywordSchemaMasks->{$mask}/ ) {
									$validSchema = 1;
								}									
							}
						}
						
						if ( not $validSchema ) {
							# check the section name against the generic masks
							# these ones can be almost anything.
							foreach my $mask ( sort {$a <=> $b} (keys %$genericSchemaMasks) ) {
								if ( $curpath =~ /$genericSchemaMasks->{$mask}/ ) {
									$validSchema = 1;
									last();
								}
							}								
						}

						if ( not $validSchema ) {
							schemaError("SCHEMA ERROR: Keyword $section incorrect path: $file $curpath");
						}

						#}
						#else {
						#	print "SCHEMA ERROR: Keyword $section incorrect parent $parent: $file $curpath\n" if errors();
						#}
					#}
				}
			}

			if ( ref($data->{$section}) =~ /HASH|ARRAY/ ) {
				print &indent . "$modelType:$curpath -> $section\n" if debug2();
				
				# if this section is an RRD/snmp variable, check its length
				if ( $curpath =~ /rrd\/\w+\/snmp$/ ) {
					print indent()."Found RRD Variable $section \@ $modelType:$curpath\n" if debug2();
					if ( checkRrdLength($section) > $rrdlen ) {
						print "MODEL ERROR: RRD variable $section found longer than $rrdlen: $file $curpath\n" if errors();
					}
				}
				
				addToSchema(section => $section, location => \@schema, ref => ref($data->{$section}));
				push(@path,$section);
				push(@schema,$section);

				if ( $modLevel <= 1 and $section !~ /-common-|class/ ) {
					push(@{$models->{$curModel}{sections}},$section);
					if ( not grep {$section eq $_} @path ) {
						push(@topSections,$section);
					}
				}
				elsif ( grep {"-common-" eq $_} @path and $section !~ /-common-|class/ ) {
					push(@{$models->{$curModel}{sections}},"Common-$section");
					if ( not grep {$section eq $_} @path ) {
						push(@topSections,$section);
					}				
				}

				#recurse baby!
				processData($data->{$section},$modelType,$file);
				
				pop(@path);
				pop(@schema);
			}
			else {

				addToSchema(section => $section, location => \@schema, value => $data->{$section});
				# what are the index variables.
				# looking at these variabled globally in the model
				if ( $section eq "indexed" and $curpath =~ /\/sys\// and $data->{$section} ne "true" ) {
					#print "    $curpath/$section: $data->{$section}\n";
					$indexed = $data->{$section};
				}	
				elsif ( $section eq "index_oid" and $curpath =~ /\/sys\// and $data->{$section} =~ /\.\d+\.\d+\.\d+\.\d+/ ) {
					#print "    $curpath/$section: $data->{$section}\n";
					$index_oid = $data->{$section};
				}
				elsif ( $section eq "graphtype" and $curpath =~ /\/rrd\// ) {
					#print "    $curpath/$section: $data->{$section}\n";
					if ( $modelType =~ /^(Common|Model)/ and $curpath =~ /^(\w+)\/rrd\/(\w+)/ ) {
						my $type = $2; 
						my $stat_section = $3; 
						$graphTypes{$stat_section}{type} = $type;
						$graphTypes{$stat_section}{section} = $stat_section;
						$graphTypes{$stat_section}{graphtype} = $data->{graphtype};
					}
				}

				# only diving deeper into the variables for the system.
				if ( $modelType =~ /^(Common|Model)/ and $curpath =~ /system\/(sys|rrd)\/(\w+)\/snmp\/(\w+)/ and $section eq "oid" ) {
					my $snmpoid = $mibs->{$data->{oid}};
					if ( not defined $snmpoid and $data->{oid} =~ /1\.3\.6\.1/ ) {
						$snmpoid = $data->{oid};
					}
					# this is a bad one like ciscoMemoryPoolUsed.2?
					elsif ( $data->{oid} =~ /[a-zA-Z]+\.[\d\.]+/ ) {
						print indent()."FIXING bad Model OID $file :: $modelType:$curpath $data->{oid}\n" if debug();
						my ($mib,$index) = split(/\./,$data->{oid});
						
						if ( defined $mibs->{$mib} ) {
							$snmpoid = $mibs->{$mib};
							$snmpoid .= ".$index";							
						}
					}

					if ( not defined $snmpoid ) {
						print "MODEL ERROR: with Model OID $file :: $modelType:$curpath $data->{oid}\n" if errors();
					}

					push(@discoverList,{
						type => "system",
						stat_type => $2,
						section => $3,
						metric => $4,
						file => $file,
						path => $curpath,
						oid => $data->{$section},
						snmpoid => $snmpoid
					});					
					#print "Processing $file: $curpath/$section\n";
				}


				#elsif ( $section eq "oid" ) {
				#	print "    $curpath/$section: $data->{$section}\n";
				#	
				#	if ( not grep {$data->{$section} eq $_} @oidList ) {
				#		print "ADDING $data->{$section} to oidList\n" if debug2();
				#		push(@oidList,$data->{$section});
				#	}
				#}
				print &indent . "$modelType:$curpath -> $section = $data->{$section}\n" if debug2();
			}
		}
		if ( defined $indexed ) {
			my $curpath = join("/",@path);
			my $section = $path[-1];
			print "$modelType:$curpath :: section=$section indexed=$indexed index_oid=$index_oid\n" if debug2();
			# convert indexed into an oid if index_oid is blank
			if ( not defined $index_oid ) {
				$index_oid = $mibs->{$indexed};
			}
			push(@discoverList,{
				type => "systemHealth",
				file => $file,
				path => "$modelType:$curpath",
				section => $section,
				indexed => $indexed,
				index_oid => $index_oid
			});
		}
	}
	elsif ( ref($data) eq "ARRAY" ) {
		foreach my $element (@{$data}) {
			my $curpath = join("/",@path);
			print indent."$modelType:$curpath: $element\n" if debug2();
			#Is this an RRD DEF?
			if ( $element =~ /DEF:/ ) {
				my @DEF = split(":",$element);
				#DEF:avgBusy1=$database:avgBusy1:AVERAGE
				if ( checkRrdLength($DEF[2]) > $rrdlen ) {
					print "MODEL ERROR: RRD variable $DEF[2] found longer than $rrdlen: $file $curpath\n" if errors();
				}
			}
		}
	}
	$indent -= 2;
	--$modLevel;
}

sub checkRrdLength {
	my $string = shift;
	my $len = length($string);
	return $len
}

sub addToSchema {
	my %args = @_;
	my $section = $args{section};
	my $ref = $args{ref};
	my $value = $args{value};
	my $location = $args{location};

	if ( $make_schema ) {
		my $parent = @$location[-1];
		my $route = join("/",@$location);  

		# which things are structural in the schema and which are variables.
		# things are allowed at certain levels in the schema
		# these can be represented by a mask
		# if the thing is a reserved word and it is one of the masks, it is all good.
		my $save = 1;
		foreach my $mask ( sort {$a <=> $b} (keys %$genericSchemaMasks) ) {
			if ( $route =~ /$genericSchemaMasks->{$mask}/ ) {
				$save = 0;
				last();
			}
		}

		# exceptions to the masks.
		if ( $route =~ /^(system\/sys\/alerts)$/ ) {
			$save = 1;
		}	
		elsif ( $section =~ /^(\d+|\-\d+)$/ ) {
			$save = 0;
		}

		#elsif ( $route =~ /^(system|systemHealth|interface|port|hrwincpu|hrdisk|hrmem|environment|calls|device|cbqos-in|cbqos-out|storage)\/(rrd|sys)$/ ) {
		#	$save = 0;
		#}
		#elsif ( $route =~ /^(system|systemHealth|interface|port|hrwincpu|hrdisk|hrmem|environment|calls|device|cbqos-in|cbqos-out|storage)\/(rrd|sys)\/[\w\-]+\/(snmp|wmi)$/ ) {
		#	$save = 0;
		#}
		#elsif ( $route =~ /^(system|systemHealth|interface|port|hrwincpu|hrdisk|hrmem|environment|calls|device|cbqos-in|cbqos-out|storage)\/(rrd|sys)\/[\w\-]+\/(snmp|wmi)\/[\w\-]+\/replace$/ ) {
		#	$save = 0;
		#}
		##summary/statstype
		##summary/statstype/[\w\-]+/sumname
		##summary/statstype/[\w\-]+/sumname/[\w\-]+/stsname
		#elsif ( $route =~ /^(summary\/statstype|summary\/statstype\/[\w\-]+\/sumname|summary\/statstype\/[\w\-]+\/sumname\/[\w\-]+\/stsname)$/ ) {
		#	$save = 0;
		#}
		## -common-/class
		## threshold/name
		## heading/graphtype
		## database/type
		## stats/type
		## event/event
#
		#elsif ( $route =~ /^(threshold\/name|heading\/graphtype|database\/type|stats\/type|event\/event|\-common\-\/class)$/ ) {
		#	$save = 0;
		#}
		#elsif ( $route =~ /^(alerts|alerts\/[\w\-]+)$/ ) {
		#	$save = 0;
		#}

		if ($save) {
			print indent()."MODEL SCHEMA: Saving $section with $route\n" if debug3();

			if ( defined $section and not grep ($_ eq $section, @{$modelSchema->{reserved}}) ) {
				push(@{$modelSchema->{reserved}},$section);
			}
		}
		else {
			print indent()."MODEL SCHEMA: NOT saving $section with $route\n" if debug3();

			# BUT is this a variable which is also a reserved variable.
			# if so then it get special clasification.
			if (grep ($_ eq $section, @{$modelSchema->{reserved}})) {
				$modelSchema->{keywords}{$section}{special} = 1;
			}

			return;			
		}

		# is the name of the section a reserved word or not?
		# is the name of the parent a reserved word or not?

		$modelSchema->{keywords}{$section}{name} = $section;

		# we are only interested in structure of the model, not the variables.
		if ( defined $section and not grep ($_ eq $route, @{$modelSchema->{keywords}{$section}{locations}}) ) {
			push(@{$modelSchema->{keywords}{$section}{locations}},$route);
		}

		if ( defined $parent and not grep ($_ eq $parent, @{$modelSchema->{keywords}{$section}{parents}}) ) {
			push(@{$modelSchema->{keywords}{$section}{parents}},$parent);
		}		
		
		if ( defined $ref and not grep ($_ eq $ref, @{$modelSchema->{keywords}{$section}{refs}}) ) {
			push(@{$modelSchema->{keywords}{$section}{refs}},$ref);
		}

		if ( defined $value and not grep ($_ eq $value, @{$modelSchema->{keywords}{$section}{values}}) ) {
			push(@{$modelSchema->{keywords}{$section}{values}},$value);
		}

		my $type = schemaDataType($value);
		if ( defined $value and not grep ($_ eq $type, @{$modelSchema->{keywords}{$section}{types}}) ) {
			push(@{$modelSchema->{keywords}{$section}{types}},$type);
		}

	}
}

sub schemaDataType {
	my $value = shift;

	if ( $value =~ /(^\d+$|^\-\d+$)/ ) {
		return "integer";
	}
	elsif ( $value =~ /(^\d+\.\d+$|^\-\d+\.\d+$)/ ) {
		return "real";
	}
	elsif ( $value =~ /(^\d+\.\d+\.\d+\.|^\.\d+\.\d+\.\d+\.)/ ) {
		return "dotted-decimal";
	}
	else {
		return "string";
	}
}

sub checkNodes {
	my $LNT = Compat::NMIS::loadLocalNodeTable();
	
	my $nmisng = Compat::NMIS::new_nmisng();
	my $S = NMISNG::Sys->new(nmisng => $nmisng);
		
	foreach my $node (sort keys %{$LNT})
	{
		print "Processing node $node \n";
		my $S = NMISNG::Sys->new(nmisng => $nmisng);
		my $nodeobj = $nmisng->node(name => $node);
		$S->init(node => $nodeobj, snmp => 0);
		$S->loadModel(model => $curModel);
	}
	
	return;	
}

sub saveSchema {
	my $schemaFile = shift;

	@{$modelSchema->{reserved}} = sort({$a cmp $b} (@{$modelSchema->{reserved}})) if (ref($modelSchema->{reserved}) eq "HASH");

	# whip through the parents of each keyword and remove parents which are not keywords.
	foreach my $keyword ( sort {$a cmp $b} keys (%{$modelSchema->{keywords}}) ) {
		my @parents;
		foreach my $parent (@{$modelSchema->{keywords}{$keyword}{parents}}) {
			if ( defined $modelSchema->{keywords}{$parent} ) {
				push(@parents,$parent);
			}
			else {
				print "SCHEMA CLEAN: $keyword, has parent $parent which is not a keyword\n" if debug3();	
			}
		}
		$modelSchema->{keywords}{$keyword}{parents} = \@parents;
	}

	if ( $make_schema ) {
		NMISNG::Util::writeHashtoFile( file => $schemaFile, data => $modelSchema );
	}	
}

sub loadMibs {
	my $C = shift;

	my $oids = "$C->{mib_root}/nmis_mibs.oid";
	my $mibs;

	print "Loading Vendor OIDs from $oids \n";

	open(OIDS,$oids) or warn "ERROR could not load $oids: $!\n";

	my $match = qr/\"([\w\-\.]+)\"\s+\"([\d+\.]+)\"/;

	while (<OIDS>) {
		if ( $_ =~ /$match/ ) {
			$mibs->{$1} = $2;
		}
		elsif ( $_ =~ /^#|^\s+#/ ) {
			#all good comment
		}
		else {
			info("ERROR: no match $_");
		}
	}
	close(OIDS);

	return ($mibs);
}

sub errors {
        if ( $errors >= 1 ) {
                return 1
        }
        else {
                return 0
        }
}

sub debug {
        if ( $debug >= 1 ) {
                return 1
        }
        else {
                return 0
        }
}

sub debug2 {
        if ( $debug >= 2 ) {
                return 1
        }
        else {
                return 0
        }
}

sub debug3 {
        if ( $debug >= 3 ) {
                return 1
        }
        else {
                return 0
        }
}

sub usage {
	print <<EO_TEXT;
$0 will check existing NMIS models and determine which models apply to a node in NMIS.

* Discover a node:
\t usage: $0 node=<nodename> [model=name for new model]
\t 	 	  [file=/path/to/file_for_details.txt] [debug=true|false]
\t eg: $0 [node=nodename] [debug=(true|false|1|2|3|4)]
\t		  [errors=(true|false)]

\t 		  [models_dir=models|models-default]

* Check the models:
\t usage: $0 check=true [errors=(true|false)]
\t        [debug=(true|false|1|2|3|4)]

* Create the Model Schema File for checking syntax:
\t usage: $0 schema=true [errors=(true|false)]
\t        [debug=(true|false|1|2|3|4)]

* Params: 
\t node: NMIS nodename
\t check: (true|false), check the models structure and for errors
\t model: Name of new model and the result file to be generated.
\t common_exclude: A regular expression for the Common models
\t          to exclude in the auto geneated model.
\t file: Where to save the results to, TAB delimited CSV.
\t errors: Display models errors found or not.
\t schema: Check the models structure against the schema.
\t make_schema: Make the model schema file.

* Check nodes:
\t usage: $0 nodes=true 
\t        Loads all the local nodes and loads their models

EO_TEXT
}

