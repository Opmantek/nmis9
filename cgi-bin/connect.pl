#!/usr/bin/perl
#
## $Id: connect.pl,v 8.13 2012/08/16 07:26:00 keiths Exp $
#
# THIS SOFTWARE IS NOT PART OF NMIS AND IS COPYRIGHTED, PROTECTED AND LICENSED 
# BY OPMANTEK.  
# 
# YOU MUST NOT MODIFY OR DISTRIBUTE THIS CODE
# 
# This code is NOT Open Source
# 
# IT IS IMPORTANT THAT YOU HAVE READ CAREFULLY AND UNDERSTOOD THE END USER 
# LICENSE AGREEMENT THAT WAS SUPPLIED WITH THIS SOFTWARE.   BY USING THE 
# SOFTWARE  YOU ACKNOWLEDGE THAT (1) YOU HAVE READ AND REVIEWED THE LICENSE 
# AGREEMENT IN ITS ENTIRETY, (2) YOU AGREE TO BE BOUND BY THE AGREEMENT, (3) 
# THE INDIVIDUAL USING THE SOFTWARE HAS THE POWER, AUTHORITY AND LEGAL RIGHT 
# TO ENTER INTO THIS AGREEMENT ON BEHALF OF YOU (AS AN INDIVIDUAL IF ON YOUR 
# OWN BEHALF OR FOR THE ENTITY THAT EMPLOYS YOU )) AND, (4) BY SUCH USE, THIS 
# AGREEMENT CONSTITUTES BINDING AND ENFORCEABLE OBLIGATION BETWEEN YOU AND 
# OPMANTEK LTD. 
# 
# Opmantek is a passionate, committed open source software company - we really 
# are.  This particular piece of code was taken from a commercial module and 
# thus we can't legally supply under GPL. It is supplied in good faith as 
# source code so you can get more out of NMIS.  According to the license 
# agreement you can not modify or distribute this code, but please let us know 
# if you want to and we will certainly help -  in most cases just by emailing 
# you a different agreement that better suits what you want to do but covers 
# Opmantek legally too. 
# 
# contact opmantek by emailing code@opmantek.com
# 
# All licenses for all software obtained from Opmantek (GPL and commercial) 
# are viewable at http://opmantek.com/licensing
#   
# *****************************************************************************
# Auto configure to the <nmis-base>/lib 
use FindBin;
use lib "$FindBin::Bin/../lib";

use JSON::XS;

# 
use strict;
use NMIS;
use func;
use Fcntl qw(:DEFAULT :flock);

use Data::Dumper;
$Data::Dumper::Indent = 1;

# Prefer to use CGI::Pretty for html processing
use CGI::Pretty qw(:standard *table *Tr *td *form *Select *div);
$CGI::Pretty::INDENT = "  ";
$CGI::Pretty::LINEBREAK = "\n";
push @CGI::Pretty::AS_IS, qw(p h1 h2 center b comment option span);
#use CGI::Debug;

# declare holder for CGI objects
use vars qw($q $Q $C);
$q = new CGI; # This processes all parameters passed via GET and POST
$Q = $q->Vars; # values in hash

# load NMIS configuration table
$C = loadConfTable(conf=>$Q->{conf},debug=>$Q->{debug});


####################################

# check privilege
my $validUser = 0;
if ( $ENV{'REMOTE_USER'} ne "" and $ENV{'REMOTE_USER'} eq $C->{'server_user'} ) {
	$validUser = 1;
}
elsif ( $ENV{'REMOTE_USER'} eq "" ) {
	$validUser = 1;
}

#print STDERR "DEBUG validUser=$validUser REMOTE_USER=$ENV{'REMOTE_USER'} server_user=$C->{'server_user'}\n";

if ( $C->{'server_community'} ne $Q->{com} or not $validUser) {
	typeError("no privilege for attempted operation");
} else {
	# oke
	if ($Q->{type} eq "send" ) { 
		doSend();
	} elsif ($Q->{type} =~ /collect|update/i ) {
		doExec();
	} else { typeError("unknown type ($Q->{type}) value"); }
}

exit 0;

####################################

sub printTextHead {
print <<EOHTML;
Content-type: text/plain\n
EOHTML
}

sub printHead {
print <<EOHTML;
Content-type: text/html\n
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">
<html>
<head>
</head>
<body><pre>
EOHTML
}

sub printTail {
	print "</body></html>\n";
}

sub typeError {
	my $msg = shift;
	my $format = $Q->{format};
	
	printTextHead if ($format eq "text");
	printHead if ($format eq "html");
	print <<EOHTML;
SERVER ERROR: $msg

Input values are

type  = $Q->{type}
func  = $Q->{func}
node  = $Q->{node}
group = $Q->{group}
format = $Q->{format}
par0  = $Q->{par0}
par1  = $Q->{par1}
par2  = $Q->{par2}
par3  = $Q->{par3}
par4  = $Q->{par4}
par5  = $Q->{par5}

EOHTML
	printTail if ($format eq "html");

	logMsg("ERROR $msg\n") if $C->{debug};
}

###################################

sub doSend{

	my $func = lc $Q->{func};
	my $node  = $Q->{node};
	my $group = $Q->{group};
	my $format = $Q->{format};
	my $par0  = $Q->{par0};
	my $par1  = $Q->{par1};
	my $par2  = $Q->{par2};
	my $par3  = $Q->{par3};
	my $par4  = $Q->{par4};
	my $par5  = $Q->{par5};
	my $data  = $Q->{data};
	my %hash;
	
	$format = "html" if not $format;
	
	if ($data) {
		# convert
		logMsg("DATA $data") if $C->{debug};
		%hash = eval $data;
		if ($@) {
			logMsg("ERROR convert data to hash, $@");
			typeError("ERROR convert data to hash, $@");
			return;
		}
	}

	my $NT = loadLocalNodeTable();
	my $S = Sys::->new; # get system object

	if ($func eq "loadsystemfile" ) {
		if ($node eq "") { typeError("missing node name"); exit 1; }
		printTextHead if ($format eq "text");
		printHead if ($format eq "html");
		my $NI = loadNodeInfoTable($node);
		my %ni;
		foreach (keys %{$NI->{system}}) {
			$ni{$_} = $NI->{system}{$_};
		}	

		if ( $C->{use_json} eq 'true' and $C->{use_json_pretty} eq 'true' ) {
			print JSON::XS->new->pretty(1)->encode(\%ni);
		}	
		elsif ( $C->{use_json} eq 'true' ) {
			print encode_json(\%ni);
		}	
		else {
			print Data::Dumper->Dump([\%ni], [qw(*hash)]);
		}
		
		printTail if ($format eq "html");

	} elsif ($func eq "loadnodedetails") {
		foreach my $nd (keys %{$NT}) { 
			$NT->{$nd}{'community'} = "";
			if ( $group ne "" and $NT->{$nd}{group} !~ /$group/  ) {
				delete $NT->{$nd};
			}
		}
		printTextHead if ($format eq "text");
		printHead if ($format eq "html");

		if ( $C->{use_json} eq 'true' and $C->{use_json_pretty} eq 'true' ) {
			print JSON::XS->new->pretty(1)->encode($NT);
		}	
		elsif ( $C->{use_json} eq 'true' ) {
			print encode_json($NT);
		}	
		else {
			print Data::Dumper->Dump([$NT], [qw(*hash)]);
		}

		printTail if ($format eq "html");

	} elsif ($func eq "sumnodetable") {
		
		my $NS = getNodeSummary(C => $C, group => $group);

		printTextHead if ($format eq "text");
		printHead if ($format eq "html");

		if ( $C->{use_json} eq 'true' and $C->{use_json_pretty} eq 'true' ) {
			print JSON::XS->new->pretty(1)->encode($NS);
		}	
		elsif ( $C->{use_json} eq 'true' ) {
			print encode_json($NS);
		}	
		else {
			print Data::Dumper->Dump([$NS], [qw(*hash)]);
		}

		printTail if ($format eq "html");

	} elsif ($func eq "eventtable") {
		my $ET = loadEventStateNoLock();
		printTextHead if ($format eq "text");
		printHead if ($format eq "html");

		if ( $C->{use_json} eq 'true' and $C->{use_json_pretty} eq 'true' ) {
			print JSON::XS->new->pretty(1)->encode($ET);
		}	
		elsif ( $C->{use_json} eq 'true' ) {
			print encode_json($ET);
		}	
		else {
			print Data::Dumper->Dump([$ET], [qw(*hash)]);
		}

		printTail if ($format eq "html");

	} elsif ($func eq "summary") {
		my %summaryHash = ();
		my $reportStats;
		my @tmparray;
		my @tmpsplit;

		foreach my $nd ( keys %{$NT})  {
			if ( $NT->{$nd}{group} =~ /$group/ or $group eq "") {
				$S->init(name=>$nd,snmp=>'false'); # load node info and Model if name exists
				# 
				$summaryHash{$nd}{reachable} = 0;
				$summaryHash{$nd}{response} = 0;
				$summaryHash{$nd}{loss} = 0;
				$summaryHash{$nd}{health} = 0;
				$summaryHash{$nd}{available} = 0;
				my $stats;
				if (($stats = getSummaryStats(sys=>$S,type=>"health",start=>$par1,end=>$par2,index=>$nd))) {
					%summaryHash = (%summaryHash,%{$stats});
				}
			}
		}
		#
		printTextHead if ($format eq "text");
		printHead if ($format eq "html");

		if ( $C->{use_json} eq 'true' and $C->{use_json_pretty} eq 'true' ) {
			print JSON::XS->new->pretty(1)->encode(\%summaryHash);
		}	
		elsif ( $C->{use_json} eq 'true' ) {
			print encode_json(\%summaryHash);
		}	
		else {
			print Data::Dumper->Dump([\%summaryHash], [qw(*hash)]);
		}

		printTail if ($format eq "html");

	} elsif ($func eq "summary8" or $func eq "summary16") {
		# get the file
		my $datafile = getFileName(file => "$C->{'<nmis_var>'}/nmis-${func}h");
		if ( -r $datafile ) {
			my $summaryHash;
			if ( $group eq "" ) {
				$summaryHash = readFiletoHash(file=>$datafile);
			}
			else {
				my $SH = readFiletoHash(file=>$datafile);
				foreach my $nd ( keys %{$SH})  {
					if ( $NT->{$nd}{group} =~ /$group/ ) {
						$summaryHash->{$nd} = $SH->{$nd};
					}
				}
			}
			printTextHead if ($format eq "text");
			printHead if ($format eq "html");

			if ( $C->{use_json} eq 'true' and $C->{use_json_pretty} eq 'true' ) {
				print JSON::XS->new->pretty(1)->encode($summaryHash);
			}	
			elsif ( $C->{use_json} eq 'true' ) {
				print encode_json($summaryHash);
			}	
			else {
				print Data::Dumper->Dump([$summaryHash], [qw(*hash)]);
			}

			printTail if ($format eq "html");
		} else {
			typeError("file $datafile not found");
		}

	} elsif ($func eq "summarystats") {
		$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
		my $stats = getSummaryStats(sys=>$S,type=>$par0,start=>$par1,end=>$par2,index=>$par5);
		printTextHead if ($format eq "text");
		printHead if ($format eq "html");

		if ( $C->{use_json} eq 'true' and $C->{use_json_pretty} eq 'true' ) {
			print JSON::XS->new->pretty(1)->encode($stats);
		}	
		elsif ( $C->{use_json} eq 'true' ) {
			print encode_json($stats);
		}	
		else {
			print Data::Dumper->Dump([$stats], [qw(*hash)]);
		}

		printTail if ($format eq "html");

	} elsif ($func eq "interfacetable") {
		if ($node eq "") { typeError("missing node name"); exit 1; }
		$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
		my $IF = $S->ifinfo;
		printTextHead if ($format eq "text");
		printHead if ($format eq "html");

		if ( $C->{use_json} eq 'true' and $C->{use_json_pretty} eq 'true' ) {
			print JSON::XS->new->pretty(1)->encode($IF);
		}	
		elsif ( $C->{use_json} eq 'true' ) {
			print encode_json($IF);
		}	
		else {
			print Data::Dumper->Dump([$IF], [qw(*hash)]);
		}

		printTail if ($format eq "html");

	} elsif ($func eq "loadinterfaceinfo") {
		my $II = loadInterfaceInfo();
		printTextHead if ($format eq "text");
		printHead if ($format eq "html");

		if ( $C->{use_json} eq 'true' and $C->{use_json_pretty} eq 'true' ) {
			print JSON::XS->new->pretty(1)->encode($II);
		}	
		elsif ( $C->{use_json} eq 'true' ) {
			print encode_json($II);
		}	
		else {
			print Data::Dumper->Dump([$II], [qw(*hash)]);
		}

		printTail if ($format eq "html");

	} elsif ($func eq "report_reporttable") {
		my %reportTable;
		foreach my $nd ( keys %{$NT}) {
			if ( $NT->{$nd}{active} eq "true") {
				$S->init(name=>$nd,snmp=>'false'); # load node info and Model if name exists
				my $stats;
				if (($stats = getSummaryStats(sys=>$S,type=>"health",start=>$par1,end=>$par2,index=>$nd))) {
					%reportTable = (%reportTable,%{$stats});
				}
			}
		}
		printTextHead if ($format eq "text");
		printHead if ($format eq "html");

		if ( $C->{use_json} eq 'true' and $C->{use_json_pretty} eq 'true' ) {
			print JSON::XS->new->pretty(1)->encode(\%reportTable);
		}	
		elsif ( $C->{use_json} eq 'true' ) {
			print encode_json(\%reportTable);
		}	
		else {
			print Data::Dumper->Dump([\%reportTable], [qw(*hash)]);
		}

		printTail if ($format eq "html");

	} elsif ($func eq "report_cputable") {
		my %cpuTable;
		foreach my $nd ( keys %{$NT} ) {
			if ( $NT->{$nd}{active} eq "true") {
				$S->init(name=>$nd,snmp=>'false'); # load node info and Model if name exists
				my $stats;
				if (($stats = getSummaryStats(sys=>$S,type=>"nodehealth",start=>$par1,end=>$par2,index=>$nd))) {
					%cpuTable = (%cpuTable,%{$stats});
				}
			}
		}
		printTextHead if ($format eq "text");
		printHead if ($format eq "html");

		if ( $C->{use_json} eq 'true' and $C->{use_json_pretty} eq 'true' ) {
			print JSON::XS->new->pretty(1)->encode(\%cpuTable);
		}	
		elsif ( $C->{use_json} eq 'true' ) {
			print encode_json(\%cpuTable);
		}	
		else {
			print Data::Dumper->Dump([\%cpuTable], [qw(*hash)]);
		}

		printTail if ($format eq "html");

	} elsif ($func eq "report_linktable") {
		my $prev_loadsystemfile;
		my %linkTable;
		my $II = loadInterfaceInfo();
		foreach my $int ( sortall($II,'node','fwd')) {
			if ( $II->{$int}{collect} eq "true" ) {
				# availability, inputUtil, outputUtil, totalUtil
				my $intf = $II->{$int}{ifIndex};
				# we need the nodeType for summary stats to get the right directory
				if ($II->{$int}{node} ne $prev_loadsystemfile) {
					$S->init(name=>$II->{$int}{node},snmp=>'false'); # load node info and Model if name exists
					$prev_loadsystemfile = $II->{$int}{node};
				}
				my $stats;
				if (($stats = getSummaryStats(sys=>$S,type=>"interface",start=>$par1,end=>$par2,index=>$intf))) {
					foreach my $k (keys %{$stats->{$intf}}) {
						$linkTable{$int}{$k} = $stats->{$intf}{$k};
						$linkTable{$int}{$k} =~ s/NaN/0/ ;
						$linkTable{$int}{$k} ||= 0 ;
					}
					$linkTable{$int}{node} = $II->{$int}{node} ;
					$linkTable{$int}{ifDescr} = $II->{$int}{ifDescr} ;
					$linkTable{$int}{Description} = $II->{$int}{Description} ;
				}
				$linkTable{$int}{totalBits} = ($linkTable{$int}{inputBits} + $linkTable{$int}{outputBits} ) / 2 ;

			#	# Availability, inputBits, outputBits
			#	if (($stats = getSummaryStats(sys=>$S,type=>"bits",start=>$par1,end=>$par2,index=>$intf))) {
			#		foreach my $k (keys %{$stats->{$int}}) {
			#			$linkTable{$int}{$k} = $stats->{$int}{$k};
			#		}
			#	}
			}
		}
		printTextHead if ($format eq "text");
		printHead if ($format eq "html");

		if ( $C->{use_json} eq 'true' and $C->{use_json_pretty} eq 'true' ) {
			print JSON::XS->new->pretty(1)->encode(\%linkTable);
		}	
		elsif ( $C->{use_json} eq 'true' ) {
			print encode_json(\%linkTable);
		}	
		else {
			print Data::Dumper->Dump([\%linkTable], [qw(*hash)]);
		}

		printTail if ($format eq "html");

	} elsif ($func eq "report_pktstable") {
		my $prev_loadsystemfile;
		my %pktsTable;
		my $II = loadInterfaceInfo();
		foreach my $int ( sortall($II,'node','fwd') ) {
			if ( $II->{$int}{collect} eq "true" ) {
				my $intf = $II->{$int}{ifIndex};
				# availability, inputUtil, outputUtil, totalUtil
				# we need the nodeType for summary stats to get the right directory
				if ($II->{$int}{node} ne $prev_loadsystemfile) {
					$S->init(name=>$II->{$int}{node},snmp=>'false'); # load node info and Model if name exists
					$prev_loadsystemfile = $II->{$int}{node};
				}
				# only report these if pkts rrd available to us.
				if (($S->getTypeName(type=>'pkts',check=>'true'))) {
					# ifInUcastPkts, ifInNUcastPkts, ifInDiscards, ifInErrors, ifOutUcastPkts, ifOutNUcastPkts, ifOutDiscards, ifOutErrors
				    my $hash = getSummaryStats(sys=>$S,type=>"pkts",start=>$par1,end=>$par2,index=>$intf);
					foreach my $k (keys %{$hash->{$intf}}) {
						$pktsTable{$int}{$k} = $hash->{$intf}{$k};
						$pktsTable{$int}{$k} =~ s/NaN/0/ ;
						$pktsTable{$int}{$k} ||= 0 ;
					}
		
					$pktsTable{$int}{node} = $II->{$int}{node} ;
					$pktsTable{$int}{ifDescr} = $II->{$int}{ifDescr} ;
					$pktsTable{$int}{Description} = $II->{$int}{Description} ;
					$pktsTable{$int}{totalDiscardsErrors} = ($pktsTable{$int}{ifInDiscards} + $pktsTable{$int}{ifOutDiscards} 
						+ $pktsTable{$int}{ifInErrors} + $pktsTable{$int}{ifOutErrors} ) / 4 ;
				}
			}
		}
		printTextHead if ($format eq "text");
		printHead if ($format eq "html");

		if ( $C->{use_json} eq 'true' and $C->{use_json_pretty} eq 'true' ) {
			print JSON::XS->new->pretty(1)->encode(\%pktsTable);
		}	
		elsif ( $C->{use_json} eq 'true' ) {
			print encode_json(\%pktsTable);
		}	
		else {
			print Data::Dumper->Dump([\%pktsTable], [qw(*hash)]);
		}

		printTail if ($format eq "html");

	} elsif ($func eq "report_pvctable") {
		my $prev_loadsystemfile;
		my %pvcTable;
		my $II = loadInterfaceInfo();
		my $PVC;
		foreach my $int (sortall($II,'node','fwd')) {
			if ( $II->{$int}{collect} eq "true" ) {
				my $intf = $II->{$int}{ifIndex};
				# availability, inputUtil, outputUtil, totalUtil
				if ($II->{$int}{node} ne $prev_loadsystemfile) {
					$S->init(name=>$II->{$int}{node},snmp=>'false'); # load node info and Model if name exists
					$PVC->pvcinfo;
					$prev_loadsystemfile = $II->{$int}{node};
				}

				# check if this interface is a frame
				if ( $II->{$int}{ifType} =~ /frame-relay/ ) {
					if ( $PVC ne "") {
						foreach my $p (keys %{$PVC}) {
							my $hash = getSummaryStats(sys=>$S,type=>"pvc",start=>$par1,end=>$par2,index=>$intf);
							foreach my $k (keys %{$pvcTable{$intf}}) {
								$pvcTable{$int}{$k} = $hash->{$intf}{$k};
								$pvcTable{$int}{$k} =~ s/NaN/0/ ;
							}
							$pvcTable{$int}{totalECNS} = $pvcTable{$int}{ReceivedBECNs} + $pvcTable{$int}{ReceivedFECNs} ;
							$pvcTable{$int}{pvc} = $p ;
							$pvcTable{$int}{node} = $II->{$int}{node} ;
						}
					}
				}
			}
		}
		printTextHead if ($format eq "text");
		printHead if ($format eq "html");

		if ( $C->{use_json} eq 'true' and $C->{use_json_pretty} eq 'true' ) {
			print JSON::XS->new->pretty(1)->encode(\%pvcTable);
		}	
		elsif ( $C->{use_json} eq 'true' ) {
			print encode_json(\%pvcTable);
		}	
		else {
			print Data::Dumper->Dump([\%pvcTable], [qw(*hash)]);
		}

		printTail if ($format eq "html");

	} elsif ($func eq "report_outagetable") {
		my %logreport;
		# ??
		printTextHead if ($format eq "text");
		printHead if ($format eq "html");

		if ( $C->{use_json} eq 'true' and $C->{use_json_pretty} eq 'true' ) {
			print JSON::XS->new->pretty(1)->encode(\%logreport);
		}	
		elsif ( $C->{use_json} eq 'true' ) {
			print encode_json(\%logreport);
		}	
		else {
			print Data::Dumper->Dump([\%logreport], [qw(*hash)]);
		}

		printTail if ($format eq "html");

	} elsif ($func eq 'readvartohash') {
		my $datafile = getFileName(file => "$C->{'<nmis_var>'}/$Q->{name}");
		if ( -r $datafile ) {
			my $hash = readFiletoHash(file=>$datafile);
			printTextHead if ($format eq "text");
			printHead if ($format eq "html");

			if ( $C->{use_json} eq 'true' and $C->{use_json_pretty} eq 'true' ) {
				print JSON::XS->new->pretty(1)->encode($hash);
			}	
			elsif ( $C->{use_json} eq 'true' ) {
				print encode_json($hash);
			}	
			else {
				print Data::Dumper->Dump([$hash], [qw(*hash)]);
			}

			printTail if ($format eq "html");
		} else {
			typeError("$datafile not found");
		}

	} elsif ($func eq "eventackdata") {
		logMsg("eventackdata received");
		for (keys %hash) {
			logMsg("EVENT $_ ack $hash{$_}{ack} node $hash{$_}{node} event $hash{$_}{event} element $hash{$_}{elmnt}") if $C->{debug};
			eventAck(ack=>$hash{$_}{ack},node=>$hash{$_}{node},event=>$hash{$_}{event},element=>$hash{$_}{elmnt});
		}
		printTextHead if ($format eq "text");
		printHead if ($format eq "html");

		if ( $C->{use_json} eq 'true' and $C->{use_json_pretty} eq 'true' ) {
			print JSON::XS->new->pretty(1)->encode(\%hash);
		}	
		elsif ( $C->{use_json} eq 'true' ) {
			print encode_json(\%hash);
		}	
		else {
			print Data::Dumper->Dump([\%hash], [qw(*hash)]);
		}

		printTail if ($format eq "html");

	} elsif ($func eq 'readconftohash') {
		if ( -r getFileName(file => "$C->{'<nmis_conf>'}/$Q->{name}")) {
			my $hash = loadTable(dir=>'conf',name=>$Q->{name});
			printTextHead if ($format eq "text");
			printHead if ($format eq "html");

			if ( $C->{use_json} eq 'true' and $C->{use_json_pretty} eq 'true' ) {
				print JSON::XS->new->pretty(1)->encode($hash);
			}	
			elsif ( $C->{use_json} eq 'true' ) {
				print encode_json($hash);
			}	
			else {
				print Data::Dumper->Dump([$hash], [qw(*hash)]);
			}

			printTail if ($format eq "html");
		} else {
			my $ext = getExtension(dir=>'conf');
			typeError("file $C->{'<nmis_conf>'}/$Q->{name}.$ext not found");
		}

	} elsif ($func eq 'readflatfile') {
		my $data;
		my $handle;
		my $dir = $C->{'<nmis_var>'};
		if ( $Q->{file} =~ /Nodes/ ) {
			$dir = $C->{'<nmis_conf>'};
		}
		my $flatfile = getFileName(file => "$dir/$Q->{file}");
		if ( -r $flatfile ) {
			if (open($handle, "<$flatfile")) {
				flock($handle,LOCK_SH);
				while (<$handle>) { $data .= $_;}
				close $handle;

				printTextHead if ($format eq "text");
				printHead if ($format eq "html");
				print $data;
				printTail if ($format eq "html");
			} else {
				typeError("cannot open file $Q->{file}, $!");
			}
		} else {
			typeError("file $Q->{file} expanded to $flatfile not found, $!");
		}

	} elsif ($func eq 'getsummarystats') {
		$S->init(name=>$Q->{node},snmp=>'false'); # load node info and Model if name exists

		my $hash;
		if (($hash = getSummaryStats(sys=>$S,type=>$Q->{gtype},start=>$Q->{start},end=>$Q->{end},index=>$Q->{index},item=>$Q->{item})) ) {
			printTextHead if ($format eq "text");
			printHead if ($format eq "html");

			if ( $C->{use_json} eq 'true' and $C->{use_json_pretty} eq 'true' ) {
				print JSON::XS->new->pretty(1)->encode($hash);
			}	
			elsif ( $C->{use_json} eq 'true' ) {
				print encode_json($hash);
			}	
			else {
				print Data::Dumper->Dump([$hash], [qw(*hash)]);
			}

			printTail if ($format eq "html");
		} else {
			typeError("ERROR with calculating SummaryStats");
		}

	} elsif ($func eq 'getfilesmodified') {
		# send hash of modified files with modified time > $Q->{mtime}
		my $hash = {};
		my $H = loadTable(dir=>'var',name=>'nmis-files-modified');
		for (keys %{$H}) {
			if ($H->{$_} >= $Q->{mtime}) {
				$hash->{$_} = $H->{$_};
			}
		}
		printTextHead if ($format eq "text");
		printHead if ($format eq "html");

		if ( $C->{use_json} eq 'true' and $C->{use_json_pretty} eq 'true' ) {
			print JSON::XS->new->pretty(1)->encode($hash);
		}	
		elsif ( $C->{use_json} eq 'true' ) {
			print encode_json($hash);
		}	
		else {
			print Data::Dumper->Dump([$hash], [qw(*hash)]);
		}

		printTail if ($format eq "html");

	} elsif ($func eq 'addoutage') {
		my $outageHash = "$Q->{start}-$Q->{end}-$Q->{node}"; # key
		my ($OT,$handle) = loadTable(dir=>'conf',name=>'Outage',lock=>'true');
	
		$OT->{$outageHash}{node} = $Q->{node};
		$OT->{$outageHash}{start} = $Q->{start};
		$OT->{$outageHash}{end} = $Q->{end};
		$OT->{$outageHash}{change} = $Q->{change};
		writeTable(dir=>'conf',name=>'Outage',data=>$OT,handle=>$handle);

		printTextHead if ($format eq "text");
		printHead if ($format eq "html");

		if ( $C->{use_json} eq 'true' and $C->{use_json_pretty} eq 'true' ) {
			print JSON::XS->new->pretty(1)->encode($OT);
		}	
		elsif ( $C->{use_json} eq 'true' ) {
			print encode_json($OT);
		}	
		else {
			print Data::Dumper->Dump([$OT], [qw(*hash)]);
		}

		printTail if ($format eq "html");

	} elsif ($func eq 'deleteoutage') {
		my $hash = $Q->{hash};
		my ($OT,$handle) = loadTable(dir=>'conf',name=>'Outage',lock=>'true');
		delete $OT->{$hash};
		writeTable(dir=>'conf',name=>'Outage',data=>$OT,handle=>$handle);

		printTextHead if ($format eq "text");
		printHead if ($format eq "html");

		if ( $C->{use_json} eq 'true' and $C->{use_json_pretty} eq 'true' ) {
			print JSON::XS->new->pretty(1)->encode($OT);
		}	
		elsif ( $C->{use_json} eq 'true' ) {
			print encode_json($OT);
		}	
		else {
			print Data::Dumper->Dump([$OT], [qw(*hash)]);
		}

		printTail if ($format eq "html");

	} elsif ($func eq 'timestamps') {
		my $tm;
		my $NI;

		$tm->{timestamps}{now} = time();

		# get start and end time of nmis runtime
		my $systemfile = getFileName(file => "$C->{'<nmis_var>'}/nmis-system");
		if (($NI = readFiletoHash(file=>$systemfile))) {
			$tm->{timestamps}{start} = $NI->{timestamps}{start};
			$tm->{timestamps}{end} = $NI->{timestamps}{end};
		}

		printTextHead if ($format eq "text");
		printHead if ($format eq "html");

		if ( $C->{use_json} eq 'true' and $C->{use_json_pretty} eq 'true' ) {
			print JSON::XS->new->pretty(1)->encode($tm);
		}	
		elsif ( $C->{use_json} eq 'true' ) {
			print encode_json($tm);
		}	
		else {
			print Data::Dumper->Dump([$tm], [qw(*hash)]);
		}

		printTail if ($format eq "html");

		# more ??
		if ($Q->{check} eq 'rsync') {
			# check config parameter on rsync is true
			if ($C->{daemon_rsync} ne 'true') {
				# switch on
				my ($CC,undef) = readConfData(conf=>$Q->{conf});	
				$CC->{daemons}{daemon_rsync} = 'true';
				$CC->{daemons}{daemon_rsync_port} = $Q->{port} if $Q->{port} ne '';
				my $remote = remote_addr();
				if ($CC->{daemons}{daemon_rsync_host_allow} !~ /$remote/) { 
					$CC->{daemons}{daemon_rsync_host_allow} .= " $remote";
				}
				$CC->{system}{server_remote} = 'false'; # switch off the http option
				writeConfData(data=>$CC);
			}
		} elsif ($Q->{check} eq 'http') {
			if ($C->{server_remote} ne 'true') {
				# switch on
				my ($CC,undef) = readConfData(conf=>$Q->{conf});	
				$CC->{system}{server_remote} = 'true';
				$CC->{daemons}{daemon_rsync} = 'false'; # switch off the rsync option
				writeConfData(data=>$CC);
			}
		}


	} else {
		typeError("Unknown func ($func)");
		return;
	}

}

sub doExec{
	my $format = $Q->{format};
	
	printTextHead if ($format eq "text");
	printHead if ($format eq "html");
	my @buffer = qx{$C->{'<nmis_bin>'}/nmis.pl type=$Q->{type} debug=$C->{debug} node=$Q->{node}} ;
	print @buffer;
	printTail if ($format eq "html");
}

#=======================================================================================

