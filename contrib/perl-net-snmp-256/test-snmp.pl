#!/usr/bin/perl
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
our $VERSION="1.1.0";
use strict;

use FindBin;
if ( -d "$FindBin::Bin/../lib" ) {
    use lib "$FindBin::Bin/../lib";
}
if ( -d "$FindBin::Bin/../../lib" ) {
    use lib "$FindBin::Bin/../../lib";
}

use Cwd 'abs_path';

use Data::Dumper;
use Compat::NMIS;
use NMISNG;
use NMISNG::Util;
use NMISNG::rrdfunc;
use RRDs 1.000.490; # from Tobias

my $cmdline = NMISNG::Util::get_args_multi(@ARGV);

my $debug = 0;
$debug = $cmdline->{debug} if defined $cmdline->{debug};

my $defaultConf = "$FindBin::Bin/../../conf";
$defaultConf = "$FindBin::Bin/../conf" if (! -d $defaultConf);
$defaultConf = abs_path($defaultConf);
print "Default Configuration directory is '$defaultConf'\n" if $debug;

# get an NMIS config and create an NMISNG object ready for use.
if ( not defined $cmdline->{conf}) {
    $cmdline->{conf} = $defaultConf;
}
else {
    $cmdline->{conf} = abs_path($cmdline->{conf});
}

print "Configuration Directory = '$cmdline->{conf}'\n" if ($debug);
# load configuration table
our $config = NMISNG::Util::loadConfTable(dir=>$cmdline->{conf}, debug=>$debug);

# use debug, or info arg, or configured log_level
# not wanting this level of debug for debug = 1.
my $nmisDebug = $debug > 1 ? $debug : 0;
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level( debug => $nmisDebug, info => $cmdline->{info}), path  => undef );

my $nmisng = NMISNG->new(config => $config, log => $logger);

sub usage {
	print qq{
Usage: $0 node=NODENAME debug=(1|2|3|4)

  I need a node name, then I will test your SNMP for you.
  node=NODENAME, to only process a single node.
  debug, if you don't know what it means don't use it.

};
	exit 1;
}

if ( defined $cmdline->{node} ) {
	processNode($nmisng,$cmdline->{node});
}
else {
	usage();
}

sub processNode {
	my $nmisng = shift;
	my $node = shift;

	my $nodeobj = $nmisng->node(name => $node);
	if ($nodeobj) {

        print "SNMP test results for $node:\n";

        my $NC = $nodeobj->configuration;
        my $sysDescr = "1.3.6.1.2.1.1.1.0";
        my $sysObjectID = "1.3.6.1.2.1.1.2.0";

        # NMISNG::Snmp doesn't fall back to global config
        my $max_repetitions         = $NC->{node}->{max_repetitions} || $config->{snmp_max_repetitions};

        # Get the SNMP Session going.
        my $snmp = NMISNG::Snmp->new(name => $node, nmisng => $nmisng);
        # configuration now contains  all snmp needs to know

        print "  Open SNMP session to $node\n";
        if ( $NC->{version} eq "snmpv3" ) {
            print "    Username: $NC->{username}, Auth Protocol: $NC->{authprotocol}, Priv Protocol: $NC->{privprotocol}\n";
        }

        if (!$snmp->open(config => $NC))
        {
            my $error = $snmp->error;
            undef $snmp;
            print STDERR "ERROR: Could not open SNMP session to node $node: ".$error ."\n";
            exit 1;
        }

        print "  Testing SNMP session\n";
        if (!$snmp->testsession)
        {
            my $error = $snmp->error;
            $snmp->close;
            print STDERR "ERROR: Could not retrieve SNMP vars from node $node: ".$error ."\n";
            exit 1;
        }

        print "  Performing SNMP get of $sysDescr and $sysObjectID\n";
        my @oids = (
            "$sysDescr",
            "$sysObjectID"
        );
            
        # Store them straight into the results
        my $snmpData = $snmp->get(@oids);
        if ($snmp->error)
        {
            $snmp->close;
            print STDERR "ERROR: Failed to retrieve SNMP variables for OIDs $sysDescr and $sysObjectID.\n";
            exit 1;

        }

        if (ref($snmpData) ne "HASH")
        {
            $snmp->close;
            print STDERR "ERROR: Failed to retrieve SNMP variables for OIDs $sysDescr and $sysObjectID.\n";
            exit 1;
        }

        print qq{    sysDescr: $snmpData->{$sysDescr}
    sysObjectID: $snmpData->{$sysObjectID}

SNMP PASSED
};
    }
    else {
        print STDERR "problem with node $node\n";

    }
}



