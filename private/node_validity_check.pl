#!/usr/bin/perl
#
## $Id: nodes_scratch.pl,v 1.1 2012/08/13 05:09:17 keiths Exp $
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

# 
use strict;
use File::Basename;
use Compat::NMIS;
use NMISNG::Util;
use Data::Dumper;
use NMIS::Integration;
use Compat::Timing;

my $t = Compat::Timing->new();

my $bn = basename($0);
my $usage = "Usage: $bn act=(which action to take)

\t$bn act=(run|monkey|banana)
\t$bn simulate=(true|false)
\t$bn opevents=(true|false) will enable or disable the node in opevents
\t$bn omkbin=(path to omk binaries if not /usr/local/omk/bin)

\t$bn debug=(true|false)

e.g. $bn act=run

\n";

die $usage if (!@ARGV or ( @ARGV == 1 and $ARGV[0] =~ /^--?[h?]/));
my %arg = getArguements(@ARGV);

# load configuration table
my $C = loadConfTable(conf=>"",debug=>0);

my $debug = $arg{debug} ? $arg{debug} : 0;
my $simulate = $arg{simulate} ? getbool($arg{simulate}) : 0;
my $opevents = $arg{opevents} ? getbool($arg{opevents}) : 0;
my $omkbin = $arg{omkbin} || "/usr/local/omk/bin";

# using $omkBin from NMIS::Integration
$omkBin = $omkbin;

printSum("This script will load the NMIS Nodes file and validate the nodes being managed.");
printSum("  opEvents update is set to $opevents (0 = disabled, 1 = enabled)");

my $cmdbCache = "";

my $xlsFile = "Node_Admin_Report.xlsx";
my $xlsPath = "$C->{'<nmis_var>'}/$xlsFile";

my $nodesFile = "$C->{'<nmis_conf>'}/Nodes.nmis";

my %nodeIndex;
my @SUMMARY;

processNodes($nodesFile);
nodeAdminReport(xls_file_name => $xlsPath);

if ( defined $arg{email} and $arg{email} ne "" ) {
	my $from_address = $C->{mail_from_reports} || $C->{mail_from};

	emailSummary(subject => "$C->{server_name} :: Node Validity Check Results and Spreadsheet", C => $C, email => $arg{email}, summary => \@SUMMARY, from_address => $from_address, file_name => $xlsFile, file_path_name => $xlsPath);
}

exit 0;

sub processNodes {
	my $nodesFile = shift;
	my $LNT;
	
	my $omkNodes;
	
	if ( $opevents ) {
		$omkNodes = getNodeList();
	}
	
	if ( -r $nodesFile ) {
		$LNT = readFiletoHash(file=>$nodesFile);
		printSum("Loaded $nodesFile");
	}
	else {
		print "ERROR, could not find or read $nodesFile\n";
		exit 0;
	}
	
	# make a node index
	foreach my $node (sort keys %{$LNT}) {
		my $lcnode = lc($node);
		#printSum("adding $lcnode to index\n";
		if ( $nodeIndex{$lcnode} ne "" ) {
			printSum("DUPLICATE NODE: node $node with $node exists as $nodeIndex{$lcnode}");
		}
		else {
			$nodeIndex{$lcnode} = $node;
		}
	}

	# Load the old CSV first for upgrading to NMIS8 format
	# copy what we need
	my @pingBad;
	my @snmpBad;

	my @updates;
	my @nameCorrections;

	foreach my $node (sort keys %{$LNT}) {	
		my $S = NMISNG::Sys->new; # get system object
		$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
		my $NI = $S->ndinfo;
		
		printSum($t->elapTime(). " Processing $node active=$LNT->{$node}{active} ping=$LNT->{$node}{ping} collect=$LNT->{$node}{collect}") if $debug;
		
		my $pingDesired = getbool($LNT->{$node}{ping});
		my $snmpDesired = getbool($LNT->{$node}{collect});
		
		my $nodePingable = 1;
		my $nodeSnmp = 1;

		if ( $LNT->{$node}{active} eq "true" ) {
			# Node has never responded to PING!
			if ( $pingDesired and $NI->{system}{nodedown} eq "true" and not exists($NI->{system}{lastCollectPoll}) ) {
				$LNT->{$node}{active} = "false";
				push(@pingBad,"$node,$LNT->{$node}{host}");
				$nodePingable = 0;
				# clear any Node Down events attached to the node.
				my $result = Compat::NMIS::checkEvent(sys=>$S,event=>"Node Down",level=>"Normal",element=>"",details=>"");
			}
	
			# Node has never responded to SNMP!
			if ( $snmpDesired and $NI->{system}{snmpdown} eq "true" and $NI->{system}{sysDescr} eq "" ) {
				push(@snmpBad,"$node,$LNT->{$node}{host}");
				$LNT->{$node}{collect} = "false";
				$nodeSnmp = 0;
				# clear any SNMP Down events attached to the node.
				my $result = Compat::NMIS::checkEvent(sys=>$S,event=>"SNMP Down",level=>"Normal",element=>"",details=>"");
			}
		}
		
		# update opEvents if desired
		if ( $opevents ) {
			my $details;
			
			my $nodeInOpNodes = 0;
			if ( grep { $_ eq $node } (@{$omkNodes} ) ) {
				$nodeInOpNodes = 1;
			}
			
			# is the node in opevents at all?
			if ( $LNT->{$node}{active} eq "true" and not $nodeInOpNodes ) {
				printSum("Node not in opEvents, importing node \"$node\" now");
				importNodeFromNmis(node => $node);
			}
			
			# what is the current state of this thing.
			$details = getNodeDetails($node) if $nodeInOpNodes;
			
			# is the node NOT active and enabled for opEvents!
			if ( $LNT->{$node}{active} ne "true" and $nodeInOpNodes and ( not exists($details->{activated}{opEvents}) or $details->{activated}{opEvents} == 1 ) ) {
				# yes, so disable the node in opEvents
				printSum("DISABLE node in opEvents: $node") if $debug;
				opEventsXable(node => $node, desired => 0, simulate => $simulate, debug => $debug);
			}
			elsif ( $pingDesired and $nodePingable and $LNT->{$node}{active} eq "true" and ( not exists($details->{activated}{opEvents}) or $details->{activated}{opEvents} == 0 ) ) {
				# yes, so enable the node in opEvents
				printSum("ENABLE node in opEvents: $node") if $debug;
				opEventsXable(node => $node, desired => 1, simulate => $simulate, debug => $debug);
			}
			elsif ( $snmpDesired and $nodeSnmp and $LNT->{$node}{active} eq "true" and ( not exists($details->{activated}{opEvents}) or $details->{activated}{opEvents} == 0 ) ) {
				# yes, so enable the node in opEvents
				printSum("ENABLE node in opEvents: $node") if $debug;
				opEventsXable(node => $node, desired => 1, simulate => $simulate, debug => $debug);
			}
		}
	}

	printSum("\n");

	printSum("There are ". @pingBad . " nodes NOT Responding to POLLS EVER:");
	printSum("Active has been set to false:") if not $simulate;
	my $badnoderising = join("\n",@pingBad);
	printSum($badnoderising);

	printSum("\n");

	printSum("There are ". @snmpBad . " nodes with SNMP Not Working");
	printSum("Collect has been set to false:") if not $simulate;
	my $snmpNodes = join("\n",@snmpBad);
	printSum($snmpNodes);

	printSum("\n");

	if ( not $simulate ) {
		my $backupFile = $nodesFile .".". time();
		my $backup = backupFile(file => $nodesFile, backup => $backupFile);
		setFileProt($backupFile);
		if ( $backup ) {
			printSum("$nodesFile backup'ed up to $backupFile");
			writeHashtoFile(file => $nodesFile, data => $LNT);
			printSum("NMIS Nodes file $nodesFile saved");	
		}
		else {
			printSum("SKIPPING save: $nodesFile could not be backup'ed");
		}				
	}
}

sub printSum {
	my $message = shift;
	print "$message\n";
	push(@SUMMARY,$message);
}

sub nodeAdminReport {
	my %args = @_;
	
	my $xls_file_name = $args{xls_file_name};

	my $xls;
	if ($xlsPath) {
		$xls = start_xlsx(file => $xlsPath);
	}

	# for group filtering
	my $group = $args{group} || "";
	
	# for exception filtering
	my $filter = $args{filter} || "";
	
	my $noExceptions = 1;
	my $LNT = Compat::NMIS::loadLocalNodeTable();
	
	#print qq|"name","group","version","active","collect","last updated","icmp working","snmp working","nodeModel","nodeVendor","nodeType","roleType","netType","sysObjectID","sysObjectName","sysDescr","intCount","intCollect"\n|;
	my @headings = (
				"name",
				"group",
				"summary",
				"active",
				"last collect poll",
				"last update poll",
				"ping (icmp)",
				"icmp working",
				"collect (snmp)",
				"snmp working",
				"community",
				"version",
				"nodeVendor",
				"nodeModel",
				"nodeType",
				"sysObjectID",
				"sysDescr",
				"Int. Collect of Total",
			);

	my $sheet = add_worksheet(xls => $xls, title => "Node Admin Report", columns => \@headings);
	my $currow = 1;

	my $extra = " for $group" if $group ne "";
	my $cols = @headings;

	foreach my $node (sort keys %{$LNT}) {
		#if ( $LNT->{$node}{active} eq "true" ) {
		if ( 1 ) {
			if ( $group eq "" or $group eq $LNT->{$node}{group} ) {
				my $intCollect = 0;
				my $intCount = 0;
				my $S = NMISNG::Sys->new; # get system object
				$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
				my $NI = $S->ndinfo;
				my $IF = $S->ifinfo;
				my $exception = 0;
				my @issueList;

				# Is the node active and are we doing stats on it.
				if ( getbool($LNT->{$node}{active}) and getbool($LNT->{$node}{collect}) ) {
					for my $ifIndex (keys %{$IF}) {
						++$intCount;
						if ( $IF->{$ifIndex}{collect} eq "true") {
							++$intCollect;
						}
					}
				}
				my $sysDescr = $NI->{system}{sysDescr};
				$sysDescr =~ s/[\x0A\x0D]/\\n/g;
				$sysDescr =~ s/,/;/g;

				my $community = "OK";
				my $commClass = "info Plain";

				my $lastCollectPoll = defined $NI->{system}{lastCollectPoll} ? returnDateStamp($NI->{system}{lastCollectPoll}) : "N/A";
				my $lastCollectClass = "info Plain";

				my $lastUpdatePoll = defined $NI->{system}{lastUpdatePoll} ? returnDateStamp($NI->{system}{lastUpdatePoll}) : "N/A";
				my $lastUpdateClass = "info Plain";

				my $pingable = "unknown";
				my $pingClass = "info Plain";

				my $snmpable = "unknown";
				my $snmpClass = "info Plain";

				my $moduleClass = "info Plain";

				my $actClass = "info Plain Minor";
				if ( $LNT->{$node}{active} eq "false" ) {
					push(@issueList,"Node is not active");
				}
				else {
					$actClass = "info Plain";
					
					if ( $LNT->{$node}{active} eq "false" ) {
						$lastCollectPoll = "N/A";
					}	
					elsif ( not defined $NI->{system}{lastCollectPoll} or $LNT->{$node}{active} eq "false") {
						$lastCollectPoll = "unknown";
						$lastCollectClass = "info Plain Minor";
						$exception = 1;
						push(@issueList,"Last collect poll is unknown");
					}
					elsif ( $NI->{system}{lastCollectPoll} < (time - 60*15) ) {
						$lastCollectClass = "info Plain Major";
						$exception = 1;
						push(@issueList,"Last collect poll was over 5 minutes ago");
					}

					if ( $LNT->{$node}{active} eq "false" ) {
						$lastUpdatePoll = "N/A";
					}	
					elsif ( not defined $NI->{system}{lastUpdatePoll} ) {
						$lastUpdatePoll = "unknown";
						$lastUpdateClass = "info Plain Minor";
						$exception = 1;
						push(@issueList,"Last update poll is unknown");
					}
					elsif ( $NI->{system}{lastUpdatePoll} < (time - 86400) ) {
						$lastUpdateClass = "info Plain Major";
						$exception = 1;
						push(@issueList,"Last update poll was over 1 day ago");
					}

					$pingable = "true";
					$pingClass = "info Plain";
					if ( not defined $NI->{system}{nodedown} ) {
						$pingable = "unknown";
						$pingClass = "info Plain Minor";
						$exception = 1;
						push(@issueList,"Node state is unknown");
					}
					elsif ( $NI->{system}{nodedown} eq "true" ) {
						$pingable = "false";
						$pingClass = "info Plain Major";
						$exception = 1;
						push(@issueList,"Node is currently unreachable");
					}

					if ( $LNT->{$node}{collect} eq "false" ) {
						$snmpable = "N/A";
						$community = "N/A";
					}
					else {
						$snmpable = "true";

						if ( not defined $NI->{system}{snmpdown} ) {
							$snmpable = "unknown";
							$snmpClass = "info Plain Minor";
							$exception = 1;
							push(@issueList,"SNMP state is unknown");
						}
						elsif ( $NI->{system}{snmpdown} eq "true" ) {
							$snmpable = "false";
							$snmpClass = "info Plain Major";
							$exception = 1;
							push(@issueList,"SNMP access is currently down");
						}

						if ( $LNT->{$node}{community} eq "" ) {
							$community = "BLANK";
							$commClass = "info Plain Major";
							$exception = 1;
							push(@issueList,"SNMP Community is blank");
						}

						if ( $LNT->{$node}{community} eq "public" ) {
							$community = "DEFAULT";
							$commClass = "info Plain Minor";
							$exception = 1;
							push(@issueList,"SNMP Community is default (public)");
						}

						if ( $LNT->{$node}{model} ne "automatic"  ) {
							$moduleClass = "info Plain Minor";
							$exception = 1;
							push(@issueList,"Not using automatic model discovery");
						}

					}
				}

				my $wd = 850;
				my $ht = 700;

				my $idsafenode = $node;
				$idsafenode = (split(/\./,$idsafenode))[0];
				$idsafenode =~ s/[^a-zA-Z0-9_:\.-]//g;

				my $issues = join(":: ",@issueList);

				my $sysObject = "$NI->{system}{sysObjectName} $NI->{system}{sysObjectID}";
				my $intNums = "$intCollect/$intCount";

				if ( not $filter or ( $filter eq "exceptions" and $exception ) ) {
					$noExceptions = 0;
					my @columns;
					push(@columns,$LNT->{$node}{name});
					push(@columns,$LNT->{$node}{group});
					push(@columns,$issues);
					#$actClass
					push(@columns,$LNT->{$node}{active});
					#$lastCollectClass
					push(@columns,$lastCollectPoll);
					#lastUpdateClass
					push(@columns,$lastUpdatePoll);
					push(@columns,$LNT->{$node}{ping});
					push(@columns,$pingable);
					push(@columns,$LNT->{$node}{collect});
					# $snmpClass
					push(@columns,$snmpable);
					# commClass
					push(@columns,$community);
					push(@columns,$LNT->{$node}{version});
					push(@columns,$NI->{system}{nodeVendor});
					#$moduleClass
					push(@columns,"$NI->{system}{nodeModel} ($LNT->{$node}{model})");
					push(@columns,$NI->{system}{nodeType});
					push(@columns,$sysObject);
					push(@columns,$sysDescr);
					push(@columns,$intNums);

					if ($sheet) {
						$sheet->write($currow, 0, [ @columns[0..$#columns] ]);
						++$currow;
					}
					
				}
			}
		}
	}
	end_xlsx(xls => $xls);
	setFileProt($xlsPath);


}  # end sub nodeAdminSummary
