#!/usr/bin/perl
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
our $VERSION = "9.5.1";
use strict;
use warnings;

use FindBin;
use lib "$FindBin::RealBin/../lib";

use List::Util;

use Data::Dumper;
use NMISNG;
use NMISNG::Util;
use NMISNG::rrdfunc;
use Compat::NMIS;

my $cmdline = NMISNG::Util::get_args_multi(@ARGV);
my $config = NMISNG::Util::loadConfTable( dir => undef, debug => undef, info => undef);
my $debug = $cmdline->{debug} // 0;

# use debug, or info arg, or configured log_level
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level( debug => $cmdline->{debug}, info => $cmdline->{info}), path  => undef );

my $nmisng = NMISNG->new(config => $config, log  => $logger);
my $workers = $config->{nmisd_max_workers};

if ( defined $cmdline->{node} ) {
	oneNode($cmdline->{node});
}
else {
	my $nodes = $nmisng->get_node_names(filter => { cluster_id => $config->{cluster_id} });
    my $PP = NMISNG::Util::loadTable(dir=>'conf',name=>"Polling-Policy");
    my $totalNodes = 0;
    my $totalnodeswithremotes = 0;
	my $totalPoll = 0;
	my $goodPoll = 0;
	my $pingDown = 0;
	my $snmpDown = 0;
	my $pingOnly = 0;
	my $noSnmp = 0;
	my $badSnmp = 0;
	my $demoted = 0;
	my $latePoll5m = 0;
	my $latePoll15m = 0;
	my $latePoll1h = 0;
	my $latePoll12h = 0;
    my $report;
	my @output;
	my %seen;
    
    my @polltimes;
    
    # define the output heading and the print format
	my @heading = ("node", "attempt", "status", "ping", "snmp", "policy", "delta", "snmp", "avgdel", "poll", "update", "pollmessage");	
    
    my $allstats = {
        "period" => [],
        "collect" => { max => undef, avg =>undef, alltimes =>[], usedworkers => [], period => 300 },
        "update" => { max => undef, avg =>undef, alltimes =>[], usedworkers => [], period => 86400 }
    };
	foreach my $node (sort @$nodes) {
		#oneNode($node);
			next if ($seen{$node});
			$seen{$node} = 1;
			
            $totalnodeswithremotes++;
            my $nodeobj = $nmisng->node(name => $node);
            if ($nodeobj) {
            
				my ($configuration,$error) = $nodeobj->configuration();
				my $active = $configuration->{active};
			
				# Only locals and active nodes
				if ($active and $nodeobj->cluster_id eq $config->{cluster_id} ) {
                
					++$totalNodes;
					++$totalPoll;
					my $S = NMISNG::Sys->new(nmisng => $nmisng); # get system object
					eval {
						$S->init(name=>$node);
					}; if ($@) # load node info and Model if name exists
					{
						print "Error init for $node";
						next;
					}
					my $inv = $S->inventory(concept => 'catchall');
					my $catchall_inventory = $inv->data();
            
					my $polling_policy = $nodeobj->configuration->{polling_policy} ? $nodeobj->configuration->{polling_policy} : "default";
					     
                    # get seconds value for snmp and update from PP
                    foreach my $name ('snmp','update') {
                        my $period;                        
                        if ( defined $PP->{$polling_policy}{$name} ) {
                            $period = $PP->{$polling_policy}{$name};
                            if ( $period =~ /(\d+)m/ ) {
                                $period = $1 * 60;
                            }
                            elsif ( $period =~ /(\d+)h/ ) {
                                $period = $1 * 3600;
                            }
                            elsif ( $period =~ /(\d+)d/ ) {
                                $period = $1 * 86400;
                            }
                            else {
                                $period = "ERROR";
                                print STDERR "ERROR polling_policy=$polling_policy snmp=$PP->{$polling_policy}{$name}\n";
                            }
                            $name = "collect" if ($name eq 'snmp');
                            $allstats->{$name}{period} = $period if($period);
                            print "DONE: name: $name, period:$period\n"  if( $debug > 2);;
                        }
                        
                    }
                    my $snmp = $allstats->{collect}{period};
                    my $updateperiod = $allstats->{update}{period};
                    
					my $polldelta = "NaN";
					my $polltime = "NaN";
					my $updatetime = "NaN";
					if (-f (my $rrdfilename = $S->makeRRDname(type => "health")))
					{
					    my $string;
					    my @results;
					    my $stats = NMISNG::rrdfunc::getRRDStats(database => $rrdfilename, graphtype => "health", index => undef, item => undef, start => time() - 86400,  end => time() );
               
						$polldelta = sprintf("%.2f",$stats->{polldelta}->{mean}) if( $stats->{polldelta}->{mean} );
                        $polldelta = "---" if ($polldelta > 864000);
						$polltime = sprintf("%.2f",$stats->{polltime}->{mean}) if( $stats->{polltime}->{mean} );
						$updatetime = sprintf("%.2f",$stats->{updatetime}->{mean}) if( $stats->{updatetime}->{mean} );

                         if( $polltime ne 'NaN') {
                            push @{$allstats->{collect}{alltimes}}, $polltime;
                            push @{$allstats->{collect}{usedworkers}}, ($polltime/$snmp);
                            print "Collect Added $polltime which is ".($polltime/$snmp)."\n" if( $debug > 2);
                        }
                        if( $updatetime ne 'NaN') {
                            push @{$allstats->{update}{alltimes}}, $updatetime;
                            push @{$allstats->{update}{usedworkers}}, ($updatetime/$updateperiod);
                            print "Update Added $updatetime which is ".($updatetime/$updateperiod)."\n" if( $debug > 2);
                        }
                        
					}

                    my $lastAttempt = $catchall_inventory->{last_poll_attempt} ? NMISNG::Util::returnTime($catchall_inventory->{last_poll_attempt}) : "--:--:--";
                    my $lastPollAgo = time() - $catchall_inventory->{last_poll} if $catchall_inventory->{last_poll};
                    my $delta = $catchall_inventory->{clockDelta};

                    if (not $delta and $lastPollAgo) {
                        $delta = $lastPollAgo;
                    }
                    elsif ( not $delta ) {
                        $delta = "---";
                    }
        
                    $delta = sprintf("%.2f",$delta) if( $delta ne '---');

                    my %status;
                    # Default values
                    my $ping_enabled = "no";
                    my $ping_status = "down";
                    my $snmp_enabled = "no";
                    my $snmp_status = "down";
                        
                    eval {
                        %status = $nodeobj->precise_status();
                    }; if ($@) {
                        print "Error getting precise status $@";
                    } else {
                        print Dumper \%status if $debug > 5;
                        
                        $ping_enabled = $status{'ping_enabled'} ? "yes" : "no";
                        $ping_status = $status{'ping_status'} ? "up" : "down";
                        ++$pingDown if $ping_status eq "down";
            
                        $snmp_enabled = $status{'snmp_enabled'} ? "yes" : "no";
                        $snmp_status = $status{'snmp_status'} ? "up" : "down";
                        ++$snmpDown if $snmp_status eq "down";
                    }

                    my $collect_snmp = 1;

                    if ( (defined($nodeobj->configuration->{collect}) &&  $nodeobj->configuration->{collect} == 0 )
                        or (defined($nodeobj->configuration->{collect_snmp}) && $nodeobj->configuration->{collect_snmp} == 0) )
                    {
                        $collect_snmp = 0;
                    }
        
                    my $message = "";
                    my $pollstatus = "ontime";
                    if ( not $collect_snmp ) {
                        $message = "no snmp collect";
                        $pollstatus = "pingonly";
                        ++$pingOnly;
                    }
                    elsif ( NMISNG::Util::getbool($config->{demote_faulty_nodes}) and defined $catchall_inventory->{demote_grace} and $catchall_inventory->{demote_grace} > 0 ) {
                        $message = "snmp polling demoted";
                        $pollstatus = "demoted";
                        ++$demoted;
                        --$totalPoll;
                    }
                    elsif ( $catchall_inventory->{nodeModel} eq "Model" and $collect_snmp ) {
                        $message = "snmp never successful";
                        $pollstatus = "bad_snmp";
                        ++$badSnmp;
                        --$totalPoll;
                    }
                    elsif ( $collect_snmp and not defined $catchall_inventory->{last_poll_snmp} ) {
                        $message = "snmp never successful";
                        $pollstatus = "bad_snmp";
                        ++$badSnmp;
                        --$totalPoll;
                    }
                    elsif ( not defined $catchall_inventory->{last_poll_snmp} ) {
                        $message = "snmp not enabled";
                        $pollstatus = "no_snmp";
                        ++$noSnmp;
                    }
                    elsif ( $delta > $snmp * 1.1 * 144 ) {
                        $message = "144x late poll";
                        $pollstatus = "late";
                        ++$latePoll12h;
                    }
                    elsif ( $delta > $snmp * 1.1 * 12 ) {
                        $message = "12x late poll";
                        $pollstatus = "late";
                        ++$latePoll1h;
                    }
                    elsif ( $delta > $snmp * 1.1 * 3 ) {
                        $message = "3x late poll";
                        $pollstatus = "late";
                        ++$latePoll15m;
                    }
                    elsif ( $delta > $snmp * 1.1 ) {
                        $message = "1x late poll";
                        $pollstatus = "late";
                        ++$latePoll5m;
                    }
                    else {
                        ++$goodPoll;
                    }
        
                    if ( $catchall_inventory->{last_poll_attempt} and $catchall_inventory->{last_poll} 
                        and $catchall_inventory->{last_poll_attempt} > $catchall_inventory->{last_poll} ) {
                        $message .= "Last poll attempt failed";
                    }
                    $report .= "$node \t $lastAttempt\t $pollstatus\t $ping_status\t $snmp_status\t $polling_policy\t $delta\t $snmp\t $polldelta\t $polltime\t $updatetime\t $message \n";
					my @nodelist = ($node, $lastAttempt, $pollstatus, $ping_status, $snmp_status, $polling_policy, $delta, $snmp, $polldelta, $polltime, $updatetime, $message);
					push @output, \@nodelist;
					#printf "%-24s %-9s %-9s %-5s %-5s %-10s %-6s %-4s %-7s %-6s %-7s %-16s\n", $node, $lastAttempt, $pollstatus, $ping_status, $snmp_status, $polling_policy, $delta, $snmp, $polldelta, $polltime, $updatetime, $message;
                
            }
        }
			
	}
    my $now = NMISNG::Util::returnTime(time());
    my @heading2 = ("----", "----", "----", "----", "----", "----", "----", "----", "----", "----", "----", "----");	
	printf "\n\n\n%-40s %-9s %-9s %-5s %-5s %-10s %-12s %-4s %-12s %-6s %-7s %-16s\n", @heading;
	printf "%-40s %-9s %-9s %-5s %-5s %-10s %-12s %-4s %-12s %-6s %-7s %-16s\n", @heading2;
	foreach my $n (@output) {
		printf "%-40s %-9s %-9s %-5s %-5s %-10s %-12s %-4s %-12s %-6s %-7s %-16s\n", @$n;
	}
	
	print "\ntotalNodes=$totalNodes totalPoll=$totalPoll ontime=$goodPoll pingOnly=$pingOnly 1x_late=$latePoll5m 3x_late=$latePoll15m 12x_late=$latePoll1h 144x_late=$latePoll12h\n";
	print "time=$now pingDown=$pingDown snmpDown=$snmpDown badSnmp=$badSnmp noSnmp=$noSnmp demoted=$demoted\n";
    print "\ntotalNodesIncludingRemotes=$totalnodeswithremotes\n";

    $allstats->{collect}{sum} = List::Util::sum @{$allstats->{collect}{alltimes}};
    $allstats->{collect}{avg} = $allstats->{collect}{sum} / scalar @{$allstats->{collect}{alltimes}} if( scalar @{$allstats->{collect}{alltimes}} > 0 );
    $allstats->{update}{sum} = List::Util::sum @{$allstats->{update}{alltimes}};
    $allstats->{update}{avg} = $allstats->{update}{sum} / scalar @{$allstats->{update}{alltimes}} if( scalar @{$allstats->{update}{alltimes}} > 0 );
    $allstats->{collect}{max} = List::Util::max @{$allstats->{collect}{alltimes}};
    $allstats->{update}{max} = List::Util::max @{$allstats->{update}{alltimes}};
    $allstats->{collect}{usedworkers_sum} = List::Util::sum @{$allstats->{collect}{usedworkers}};
    $allstats->{update}{usedworkers_sum} = List::Util::sum @{$allstats->{update}{usedworkers}};

    print "Collect:\tAverage\t".sprintf("%.2f",$allstats->{collect}{avg})."\tMax\t".sprintf("%.2f",$allstats->{collect}{max})."\tSum\t".sprintf("%.2f",$allstats->{collect}{sum})."\n";
    print "Update:\t\tAverage\t".sprintf("%.2f",$allstats->{update}{avg})."\tMax\t".sprintf("%.2f",$allstats->{update}{max})."\tSum\t".sprintf("%.2f",$allstats->{update}{sum})."\n\n";

    print "Sum of workers used Collect:\t".sprintf("%.2f",$allstats->{collect}{usedworkers_sum})."\n";
    print "Sum of workers used Update:\t".sprintf("%.2f",$allstats->{update}{usedworkers_sum})."\n";
    my $total_used_time = $allstats->{collect}{usedworkers_sum}+$allstats->{update}{usedworkers_sum};
    my $suggestion = $total_used_time * 1.3;
    print "Total worker time used\t".sprintf("%.2f",$total_used_time)."\tMinimum suggested workers (30% more):\t".sprintf("%.2f",$suggestion)."\n";
    print "Current workers setting:\t$workers\n";
}

sub oneNode {
	my $node = shift;
	my $nodeobj = $nmisng->node(name => $node);

	if (!$nodeobj) {
		warn "Node $node does not exist.\n";
		return 0;
	}

	my ($configuration,$error) = $nodeobj->configuration();
	print $error if ($error);

	my $active = $configuration->{active};
	if ( NMISNG::Util::getbool($active) ) {
		my ($inventory,$error) = $nodeobj->inventory(concept => 'catchall');
		print $error if ($error);

		my $catchall_data = $inventory->data(); # r/o copy good enough
		
		my $last_poll_ago = sprintf("%.0f",time() - $catchall_data->{last_poll});
		my $last_update_ago = sprintf("%.0f",time() - $catchall_data->{last_update});
		my $last_poll = scalar localtime $catchall_data->{last_poll};
		my $last_update = scalar localtime $catchall_data->{last_update};
		
		print "$node active=$active poll_ago=$last_poll_ago update_ago=$last_update_ago last_poll=$last_poll last_update=$last_update\n";
		#print "$node poll_ago=$last_poll_ago update_ago=$last_update_ago last_poll=$catchall_data->{last_poll} last_poll_attempt=$catchall_data->{last_poll_attempt} last_update=$catchall_data->{last_update} last_update_attempt=$catchall_data->{last_update_attempt}\n";
	}
	else {
		print "$node active=$active\n";
	}
}
