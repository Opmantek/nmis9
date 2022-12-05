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

my $VERSION = 1.0;

use File::Basename;
use Compat::NMIS;
use NMISNG::Util;
use NMISNG::rrdfunc;
use MIME::Entity;

use Data::Dumper;
use Cwd 'abs_path';

#use NMIS::Integration;
use Compat::Timing;

my $defaultConf = "$FindBin::Bin/../../conf";
$defaultConf = "$FindBin::Bin/../conf" if (! -d $defaultConf);
$defaultConf = abs_path($defaultConf);
print "Default Configuration directory is '$defaultConf'\n";

my $t = Compat::Timing->new();

my $bn = basename($0);
my $usage = "Usage: $bn act=(which action to take)

\t$bn act=(run|monkey|banana)
\t$bn email=(comma seperated list of email addresses to get the Excel spreadsheet)
\t$bn exceptions=(true|false) if true, spreadsheet will only include exceptions.

\t$bn debug=(true|false)

e.g. $bn act=run

\n";

die $usage if (!@ARGV or ( @ARGV == 1 and $ARGV[0] =~ /^--?[h?]/));

# handle the command line arguments.
my $cmdline = NMISNG::Util::get_args_multi(@ARGV);

# debug me or not.
my $debug = 0;
$debug = $cmdline->{debug} if defined $cmdline->{debug};

# setup the NMIS logger and use debug, or info arg, or configured log_level
my $nmisDebug = $debug > 1 ? $debug : 0;
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level( debug => $nmisDebug, info => $cmdline->{info}), path  => undef );

# get an NMIS config and create an NMISNG object ready for use.
if ( not defined $cmdline->{conf}) {
    $cmdline->{conf} = $defaultConf;
}
else {
    $cmdline->{conf} = abs_path($cmdline->{conf});
}


print "Configuration Directory = '$cmdline->{conf}'\n" if ($debug);
# load configuration table
our $C = NMISNG::Util::loadConfTable(dir=>$cmdline->{conf}, debug=>$debug);
my $nmisng = NMISNG->new(config => $C, log  => $logger);

#rrdfunc::require_RRDs(config=>$C);

my $debug = $cmdline->{debug} ? $cmdline->{debug} : 0;
my $exceptions = $cmdline->{exceptions} ? getbool($cmdline->{exceptions}) : 0;
my $opevents = $cmdline->{opevents} ? getbool($cmdline->{opevents}) : 0;

printSum("Server Performance Reports, version $VERSION");

my $cmdbCache = "";

my $xlsFile = "Server_Performance.xlsx";
my $xlsPath = "$C->{'<nmis_var>'}/$xlsFile";

my $nodesFile = "$C->{'<nmis_conf>'}/Nodes.nmis";

# set 24 hour stats
my $from = "00";
my $to = "24";

my $now = time();


my %nodeIndex;
my %nodeData;
my @SUMMARY;

processNodes($nodesFile);
print Dumper \%nodeData if $debug;
serverReport(xls_file_name => $xlsPath);

if ( defined $cmdline->{email} and $cmdline->{email} ne "" ) {
	my $from_address = $C->{mail_from_reports} || $C->{mail_from};

	emailSummary(subject => "$C->{server_name} :: Server Performance Report and Spreadsheet", C => $C, email => $cmdline->{email}, summary => \@SUMMARY, from_address => $from_address, file_name => $xlsFile, file_path_name => $xlsPath);
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
		printSum("Loaded $nodesFile") if $debug;
	}
	else {
		print "ERROR, could not find or read $nodesFile\n";
		exit 0;
	}
		
	foreach my $node (sort keys %{$LNT}) {	
		my $S = NMISNG::Sys->new; # get system object
		$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
		my $NI = $S->ndinfo;
		my $M = $S->mdl;
		
		printSum($t->elapTime(). " Processing $node active=$LNT->{$node}{active} ping=$LNT->{$node}{ping} collect=$LNT->{$node}{collect}") if $debug;
				
		# update opEvents if desired
		my $details;

		if ( $LNT->{$node}{active} eq "true" ) {
				
			my $isServer = 0;
			if ( defined $NI->{storage} ) {
				printSum("$node has storage") if $debug;
				$isServer = 1;
				
			#"39" : {
	    #   "hrStorageUnits" : "4096",
	    #   "hrStorageUsed" : "68472271",
	    #   "hrStorageDescr" : "/data",
	    #   "hrStorageType" : "Fixed Disk",
	    #   "hrStorageSize" : "129014382",
	    #   "hrStorageGraph" : "hrdisk",
	    #   "index" : "39",
	    #   "hrStorageIndex" : "39"
	    #},
	
				my $maxDisk = undef;
				my $maxDiskIndex = undef;
				foreach my $disk ( keys %{$NI->{storage}} ) {
					if ( $NI->{storage}{$disk}{hrStorageType} eq "Fixed Disk" and $NI->{storage}{$disk}{hrStorageDescr} !~ /^\/dev$/ ) {
						my $diskUsed = sprintf("%.2f", $NI->{storage}{$disk}{hrStorageUsed} / $NI->{storage}{$disk}{hrStorageSize} * 100);
						print "$node $disk=$NI->{storage}{$disk}{hrStorageDescr} $diskUsed%\n" if $debug;
						if ( $diskUsed > $maxDisk ) {
							print "disk $NI->{storage}{$disk}{hrStorageDescr} is more used than $NI->{storage}{$maxDiskIndex}{hrStorageDescr}\n" if $debug;
							$maxDiskIndex = $disk;
							$maxDisk = $diskUsed;
						}

						
					}
					elsif ( $NI->{storage}{$disk}{hrStorageType} eq "Swap space" ) {
						# first we want the last 24 hours.
						my $start = $now - 2 * 86400;
						my $end = $now;
						my $swap = NMISNG::rrdfunc::getRRDStats(sys=>$S, graphtype=>"hrswapmem", mode=>"AVERAGE", start => $start, end => $end,
																		hour_from => $from, hour_to => $to, index=>$disk, item=> undef, truncate => -1);
						print Dumper $swap if $debug;

						$nodeData{$node}{swapSize} = scaledbytes($NI->{storage}{$disk}{hrStorageSize} * $NI->{storage}{$disk}{hrStorageUnits});
						$nodeData{$node}{swapUsed} = sprintf("%.2f", $NI->{storage}{$disk}{hrStorageUsed} / $NI->{storage}{$disk}{hrStorageSize} * 100);
						$nodeData{$node}{swapUsedAvg} = sprintf("%.2f", $swap->{hrSwapMemUsed}{mean} / $swap->{hrSwapMemSize}{mean} * 100);
						$nodeData{$node}{swapUsedMax} = sprintf("%.2f", $swap->{hrSwapMemUsed}{max} / $swap->{hrSwapMemSize}{max} * 100);
						$nodeData{$node}{swapUsedStdDev} = sprintf("%.2f", $swap->{hrSwapMemUsed}{stddev} / $swap->{hrSwapMemSize}{mean} * 100);
						
						# calculate the 95th percentile.
						my $ninetyFifth = int(@{$swap->{hrSwapMemUsed}{values}} * 0.95);
						$nodeData{$node}{swapUsed95Per} = sprintf("%.2f", $swap->{hrSwapMemUsed}{values}->[$ninetyFifth] / $swap->{hrSwapMemSize}{mean} * 100);
						print "$node swapUsedStdDev=$nodeData{$node}{swapUsedStdDev} ninetyFifth=$ninetyFifth swapUsed95Per=$nodeData{$node}{swapUsed95Per}\n";
						
					}
					# if it is swap, get the stats and is the 95% over my threshold, which for interfaces is 75%
				}
				$nodeData{$node}{maxDiskCapacity} = scaledbytes($NI->{storage}{$maxDiskIndex}{hrStorageSize} * $NI->{storage}{$maxDiskIndex}{hrStorageUnits});
				$nodeData{$node}{maxDiskUsed} = $maxDisk;
				$nodeData{$node}{maxDiskIndex} = $maxDiskIndex;
				$nodeData{$node}{maxDiskDescr} = $NI->{storage}{$maxDiskIndex}{hrStorageDescr};
				# get some trend here, e.g. disk calcs for last 3 weeks and show a trend.
				if ( $maxDisk and $maxDiskIndex ) {
					my $diskStats = getDiskStats($node,$S,$maxDiskIndex);
					$nodeData{$node}{diskTrend} = $diskStats->{summary};
					
					$nodeData{$node}{diskTrend_5days} = $diskStats->{diskTrend_5days};
					$nodeData{$node}{diskTrend_3days} = $diskStats->{diskTrend_3days};
					$nodeData{$node}{diskTrend_today} = $diskStats->{diskTrend_today};
					
					$nodeData{$node}{diskGrowth} = $diskStats->{growth};
					$nodeData{$node}{diskOverall} = $diskStats->{overall};
				}

			}
			else {
				printSum("$node NO storage") if $debug;
			}
			
			# true linux memory exhaustion, 
			# hrmem -> "Memory"
			# hrcachemem -> "Memory"
			#or alert on phys mem free minus cache minus buffers getting low (ditto)
      #"1" : {
      #   "hrStorageSize" : "16269240",
      #   "hrStorageUnits" : "1024",
      #   "hrStorageGraph" : "hrmem",
      #   "index" : "1",
      #   "hrStorageUsed" : "15844736",
      #   "hrStorageDescr" : "Physical memory",
      #   "hrStorageType" : "Memory"
      #},
      #"7" : {
      #   "hrStorageSize" : "10047060",
      #   "hrStorageUnits" : "1024",
      #   "hrStorageGraph" : "hrcachemem",
      #   "index" : "7",
      #   "hrStorageUsed" : "10047060",
      #   "hrStorageDescr" : "Cached memory",
      #   "hrStorageType" : "Other Memory"
      #},
      #"6" : {
      #   "hrStorageSize" : "16269240",
      #   "hrStorageUnits" : "1024",
      #   "hrStorageGraph" : "hrbufmem",
      #   "index" : "6",
      #   "hrStorageUsed" : "367572",
      #   "hrStorageDescr" : "Memory buffers",
      #   "hrStorageType" : "Other Memory"
      #},
			
			#net-snmp -> nodehealth -> hrSystemProcesses
			#Windows -> hrProcesses -> hrwin
			#tcp -> tcpCurrEstab
			
			$nodeData{$node}{isServer} = $isServer;
		}
									
	}
}

sub printSum {
	my $message = shift;
	print "$message\n";
	push(@SUMMARY,$message);
}

sub serverReport {
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
	
	my @badNodes;

	my $LNT = Compat::NMIS::loadLocalNodeTable();
	
	#print qq|"name","group","version","active","collect","last updated","icmp working","snmp working","nodeModel","nodeVendor","nodeType","roleType","netType","sysObjectID","sysObjectName","sysDescr","intCount","intCollect"\n|;
	my @headings = (
				"name",
				"group",
				"summary",
				"active",

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
				"sysDescr",
			);

	my $sheet = add_worksheet(xls => $xls, title => "Server Performance", columns => \@headings);
	my $currow = 1;

	my $extra = " for $group" if $group ne "";
	my $cols = @headings;

	foreach my $node (sort keys %{$LNT}) {
		if ( $LNT->{$node}{active} eq "true" and $nodeData{$node}{isServer} ) {
			if ( $group eq "" or $group eq $LNT->{$node}{group} ) {
				my $nodeException = 0;
				my $intCollect = 0;
				my $intCount = 0;
				my $S = NMISNG::Sys->new; # get system object
				$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
				my $NI = $S->ndinfo;
				my $IF = $S->ifinfo;
				my $nodeException = 0;
				my @issueList;

				my $sysDescr = $NI->{system}{sysDescr};
				$sysDescr =~ s/[\x0A\x0D]/\\n/g;
				$sysDescr =~ s/,/;/g;

				# Is the node active and are we doing stats on it.
				if ( $nodeData{$node}{maxDiskUsed} > 95 ) {
					$nodeException = 1;
					push(@issueList,"Very high disk usage");
				}
				elsif ( $nodeData{$node}{maxDiskUsed} > 80 ) {
					$nodeException = 1;
					push(@issueList,"High disk usage");
				}

				if ( $nodeData{$node}{swapUsedAvg} > 40 ) {
					$nodeException = 1;
					push(@issueList,"High swap space usage");
				}
				elsif ( $nodeData{$node}{swapUsedStdDev} > 5 ) {
					$nodeException = 1;
					push(@issueList,"High swap variation");
				}
				elsif ( $nodeData{$node}{swapUsedStdDev} > 1 ) {
					$nodeException = 1;
					push(@issueList,"Moderate swap variation");
				}

				$nodeData{$node}{nodeException} = $nodeException;

				my $wd = 850;
				my $ht = 700;

				my $idsafenode = $node;
				$idsafenode = (split(/\./,$idsafenode))[0];
				$idsafenode =~ s/[^a-zA-Z0-9_:\.-]//g;

				$LNT->{$node}{issues} = join(":: ",@issueList);

				if ( not $exceptions or ( $exceptions and $nodeException ) ) {
					my @columns;
					
					push(@badNodes,$node) if @issueList;
					
					push(@columns,$LNT->{$node}{name});
					push(@columns,$LNT->{$node}{group});
					push(@columns,$LNT->{$node}{issues});
					push(@columns,$LNT->{$node}{active});

					push(@columns,$nodeData{$node}{swapSize});
					#push(@columns,$nodeData{$node}{swapUsed});
					push(@columns,$nodeData{$node}{swapUsedAvg});
					push(@columns,$nodeData{$node}{swapUsedMax});
					push(@columns,$nodeData{$node}{swapUsedStdDev});
					push(@columns,$nodeData{$node}{swapUsed95Per});
					
					push(@columns,$nodeData{$node}{maxDiskDescr});
					push(@columns,$nodeData{$node}{maxDiskCapacity});
					
					push(@columns,$nodeData{$node}{maxDiskUsed});
					push(@columns,$nodeData{$node}{diskOverall});
					push(@columns,$nodeData{$node}{diskGrowth});
					#push(@columns,$nodeData{$node}{diskTrend});
					push(@columns,$nodeData{$node}{diskTrend_5days});
					push(@columns,$nodeData{$node}{diskTrend_3days});
					push(@columns,$nodeData{$node}{diskTrend_today});

					push(@columns,$NI->{system}{nodeVendor});
					#$moduleClass
					push(@columns,"$NI->{system}{nodeModel} ($LNT->{$node}{model})");
					push(@columns,$NI->{system}{nodeType});
					push(@columns,$sysDescr);

					if ($sheet) {
						$sheet->write($currow, 0, [ @columns[0..$#columns] ]);
						++$currow;
					}
				}
			}
		}
	}
	end_xlsx(xls => $xls);
	setFileProtDiag(file =>$xlsPath);
	
	printSum("\n");

	printSum("There are ". @badNodes . " nodes with issues detected:");
	my $badnoderising = join("\n",@badNodes);
	printSum($badnoderising);

	printSum("\n");
	
	foreach my $node (@badNodes) {
			printSum("$node issues:");	
			$LNT->{$node}{issues} =~ s/:: /\n/g;
			printSum("$LNT->{$node}{issues}\n");	
	}




}  # end sub nodeAdminSummary

sub getDiskStats {
	my $node = shift;
	my $S = shift;
	my $disk = shift;
	
	if ( not $node or not $S or not $disk ) {
		print "ERROR: need to know node, S and disk\n";   
		return undef;
	}
	
	my $diskStats;
	
	printSum($t->elapTime(). " getDiskStats $node $disk") if $debug;

	my $start = undef;
	my $end = undef;
	my $lastDay = undef;
	my $threeDays = undef;
	my $fiveDays = undef;

	# first we want the last 24 hours.
	$start = $now - 86400;
	$end = $now;
	$lastDay = NMISNG::rrdfunc::getRRDStats(sys=>$S, graphtype=>"hrdisk", mode=>"AVERAGE", start => $start, end => $end,
													hour_from => $from, hour_to => $to, index=>$disk, item=> undef, truncate => -1);

	printSum($t->elapTime(). " getDiskStats $node $disk lastDay done") if $debug;

	# now we want 3 days ago
	$start = $now - 3 * 86400;
	$end = $now - 2 * 86400;;
	$threeDays = NMISNG::rrdfunc::getRRDStats(sys=>$S, graphtype=>"hrdisk", mode=>"AVERAGE", start => $start, end => $end,
													hour_from => $from, hour_to => $to, index=>$disk, item=> undef, truncate => -1);

	printSum($t->elapTime(). " getDiskStats $node $disk threeDays done") if $debug;

	# now we want 5 days ago
	$start = $now - 5 * 86400;
	$end = $now - 4 * 86400;;
	$fiveDays = NMISNG::rrdfunc::getRRDStats(sys=>$S, graphtype=>"hrdisk", mode=>"AVERAGE", start => $start, end => $end,
										hour_from => $from, hour_to => $to, index=>$disk, item=> undef, truncate => -1);

	printSum($t->elapTime(). " getDiskStats $node $disk fiveDays done") if $debug;

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
	  $overall = "no change in disk usage";
	  $growth = "flat";	
	}
	# disk usage increasing
	elsif ( $lastDayUsage > $fiveDaysUsage ) {
	  $overall = "overall disk usage increasing";
		if ( int($deltaOne) == int($deltaTwo) ) {
			# this means basically liner growth
			$growth = "linear trend";
		}
		elsif ( int($deltaOne) > int($deltaTwo) ) {
			# this means basically liner growth
			$growth = "increasing trend";
		}
		elsif ( int($deltaOne) < int($deltaTwo) ) {
			# this means basically liner growth
			$growth = "decreasing trend";
		}
	}
	elsif ( $lastDayUsage < $fiveDaysUsage ) {
	  $overall = "overall disk usage decreasing";
	  $growth = "negative";
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
	
	print Dumper $diskStats if $debug;
	#
	#	$inutil = $statval->{ifInOctets}{mean} * 8 / $ifSpeedIn * 100;
	#	$oututil = $statval->{ifOutOctets}{mean} * 8 / $ifSpeedOut * 100;

	return $diskStats;
}

sub scaledbytes {
   (sort { length $a <=> length $b }
   map { sprintf '%.3g%s', $_[0]/1024**$_->[1], $_->[0] }
   [" bytes"=>0],[KB=>1],[MB=>2],[GB=>3],[TB=>4],[PB=>5],[EB=>6])[0]
}

sub emailSummary {
	my (%args) = @_;

	die "Need to know NMIS Config using \$C\n" if not defined $args{C};
	my $C = $args{C};

	my $from_address = $args{from_address} || $C->{mail_from};

	my $subject = $args{subject} . " " . NMISNG::Util::returnDateStamp() || "Email Summary ". NMISNG::Util::returnDateStamp();

	my $SUMMARY = $args{summary};

	my $email = $args{email};
	my $file_name = $args{file_name};
	my $file_path_name = $args{file_path_name};

	my @recipients = split(/\,/,$email);


	my $entity = MIME::Entity->build(From=>$C->{mail_from},
																	To=>$email,
																	Subject=> $subject,
																	Type=>"multipart/mixed");

	my @lines;
	push @lines, $subject;
	#insert some blank lines (a join later adds \n
	push @lines, ("","");

	if ( defined $SUMMARY ) {
		push (@lines, @{$SUMMARY});
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

	my ($status, $code, $errmsg) = sendEmail(
	  # params for connection and sending
		sender => $from_address,
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
		print "Summary Email sent to $email\n";
	}
}

sub start_xlsx {
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

sub add_worksheet {
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

sub end_xlsx {
	# closes the spreadsheet, returns 1 if ok.
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