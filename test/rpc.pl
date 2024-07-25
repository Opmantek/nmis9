#!/usr/bin/perl
# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin";

#
use strict;
use Carp;
use Test::More;
use Test::Deep;
use Data::Dumper;
use NMISNG;
use NMISNG::Log;
use NMISNG::Util;
use Compat::Timing;

# Load the RPC module
use NMISNG::Engine::SnmpRPC;

my $C = NMISNG::Util::loadConfTable();

# log to stderr
my $logger = NMISNG::Log->new( level => 'debug' );

my $nmisng = NMISNG->new(
	config => $C,
	log    => $logger,
);

die "NMISNG object required" if ( !$nmisng );


my $snmp = NMISNG::Snmp->new(name => 'mordor', nmisng => $nmisng);

my $t = Compat::Timing->new();

my %nodeconfig = 
(
    host => 'test.example.net',
    community => 'example',
    version => 'snmpv2c',
    port =>    161,
);

#static net-snmp data
my @oids = (
    # System Information
    "1.3.6.1.2.1.1.1.0",  # sysDescr
    "1.3.6.1.2.1.1.2.0",  # sysObjectID
    # "1.3.6.1.2.1.1.3.0",  # sysUpTime
    "1.3.6.1.2.1.1.4.0",  # sysContact
    "1.3.6.1.2.1.1.5.0",  # sysName
    "1.3.6.1.2.1.1.6.0",  # sysLocation
);


my $open = $snmp->open(config => \%nodeconfig);
is($open, 1, "Open net-snmp session");

my $test = $snmp->testsession;
is($test,1, "Test net-snmp session");

print $t->markTime(). " SNMP Get system\n";
my $result = $snmp->get(@oids);
print "  done in ".$t->deltaTime() ."\n";

print $t->markTime(). " SNMP Walk interfaces\n";
my $resultWalk = $snmp->gettable("1.3.6.1.2.1.2.2");
print "  done in ".$t->deltaTime() ."\n";

$snmp->close;


my $rpc = NMISNG::Engine::SnmpRPC->new(name => 'mordor', nmisng => $nmisng);

my $open = $rpc->open(config => \%nodeconfig);
is($open, 1, "Open snmp-rpc  session");


my $test = $rpc->testsession;
is($test,1, "Test snmp-rpc session");

print $t->markTime(). " SNMP-RPC Get system\n";
my $resultrpc = $rpc->get(@oids);
print "  done in ".$t->deltaTime() ."\n";


print $t->markTime(). " SNMP-RPC Walk interfaces\n";
my $resultRpcWalk = $rpc->gettable("1.3.6.1.2.1.2.2");
print "  done in ".$t->deltaTime() ."\n";


#compare the hashes from snmp result and rpcresult
cmp_deeply($result,$resultrpc, "Compare ->get results from net-snmp and snmp-rpc");

cmp_deeply($resultWalk, $resultRpcWalk, "Compare ->results from net-snmp and snmp-rpc");

$rpc->close;

done_testing();