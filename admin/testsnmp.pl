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
our $VERSION="9.1.1";
use strict;

use FindBin;
use lib "$FindBin::RealBin/../lib";

use Data::Dumper;
use NMISNG;
use NMISNG::Util;
use NMISNG::rrdfunc;
use NMISNG::Sys;

my $cmdline = NMISNG::Util::get_args_multi(@ARGV);
my $config = NMISNG::Util::loadConfTable( dir => undef, debug => undef, info => undef);
my $debug = $cmdline->{debug};

# use debug, or info arg, or configured log_level
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level( debug => $cmdline->{debug}, info => $cmdline->{info}), path  => undef );

my $nmisng = NMISNG->new(config => $config, log  => $logger);

if ( defined $cmdline->{node} ) {
    my $node = $cmdline->{node};
    my $nodeobj = $nmisng->node(name => $node);
        if ($nodeobj) {
            my $nodeconfig = $nodeobj->configuration;
            my $exe;
            my $testoid = "1.3.6.1.2.1.1.1.0"; # This is the sysDescr
            # SNMP v3
            if ($nodeconfig->{version} eq "snmpv3") {
                print "*** Testing snmp with snmpget ". $nodeconfig->{version} . "\n";
                $exe = "    snmpget -v 3 -u ".$nodeconfig->{username}." -l authNoPriv -a ".$nodeconfig->{authprotocol}." -A ".$nodeconfig->{authpassword}." ".$nodeconfig->{host}." ". $testoid;
                my $exeoutput = $exe;
                my $pass = $nodeconfig->{authpassword};
                $exeoutput =~ s/$pass/\*\*\*\*/;
                print " Running... $exeoutput \n";
                my $output = `$exe`;
                print " Result: ". $output . "\n";
                
            }
            # SNMP v2c
            elsif ($nodeconfig->{version} eq "snmpv2c") {
                print "*** Testing snmp with snmpget ". $nodeconfig->{version} . "\n";
                $exe = "    snmpget -v 2c -c ".$nodeconfig->{community}." ".$nodeconfig->{host}." ". $testoid;
                my $exeoutput = $exe;
                my $pass = $nodeconfig->{community};
                $exeoutput =~ s/$pass/\*\*\*\*/;
                print " Running... $exeoutput \n";
                my $output = `$exe`;
                print " Result: ". $output . "\n";                
            }
            # Now, test Sys with NET::SNMP
            print "\n\n*** Testing snmp with internal NMIS API \n";
            my $S = NMISNG::Sys->new(nmisng => $nmisng); # get system object
            eval {
                $S->init(name=>$node);
            }; if ($@) # load node info and Model if name exists
            {
                print " Error init for $node\n";
                die;
            }
            my $candosnmp = $S->open(
				timeout      => $config->{snmp_timeout},
				retries      => $config->{snmp_retries},
				max_msg_size => $config->{snmp_max_msg_size},
				max_repetitions => $config->{snmp_max_repetitions} || undef,
				oidpkt => $config->{max_repetitions} || 10,
			);
            
            if (!$candosnmp or $S->status->{snmp_error} )
			{
				print(" SNMP session open to $node failed: " . $S->status->{snmp_error} ."\n\n");
			} else
			{
				print(" SNMP session open to $node success \n\n" );
                my ( $result, $status ) = $S->getValues(
                    class   => $S->{mdl}{system}{sys},
                    section => "standard"
                );
                if (!$status->{error}) {
                    print ("    Result: " . $result->{'standard'}->{'sysDescr'}->{'value'});
                } else {
                    print(" SNMP get values failed: ".Dumper($status) );
                }
                $S->close;
			}
            print "\n\n** Model: " . $S->{mdl}->{'system'}->{'nodeModel'} ."\n";
            #print Dumper($nodeobj->configuration);
        } else {
            print " Error, no node was found \n";
        }
}
else {
    print "Error, need a node to run: node=NODENAME \n";
}
