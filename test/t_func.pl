#!/usr/bin/perl
# fixme: this thing should be changed over to use test::more and test::deep.

use FindBin;
use lib "$FindBin::Bin/../lib";


use strict;
use func;
use NMIS;
use Sys;
use NMIS::Timing;
use NMIS::Connect;
use rrdfunc;
use Data::Dumper;

my %nvp = getArguements(@ARGV);
my $C = loadConfTable(debug => $nvp{debug}, info=> $nvp{info});

info("a message at level undef");
for my $x (0..5)
{
	info("a message at level $x", $x);
}

if ($nvp{dir} or $nvp{file})
{
	my $result = getFileName(dir => $nvp{dir}, 
													 file => $nvp{file}, 
													 json => getbool($nvp{json}));
	print "getfilename for dir $nvp{dir}, file $nvp{file}, json $nvp{json} => $result\n";
	exit 0;
}

print "returndate: " . returnDate(time)."\n";
print "datestamp: " . returnDateStamp(time)."\n";
print "time: " . returnTime(time)."\n";

print "secs to hours: " . convertSecsHours(3*3600 + 10*60 + 15)."\n";

my $S=Sys->new;
$S->init(name => "ASGARD", snmp => 'false');

my ($data, $names, $meta) = getRRDasHash(sys => $S, graphtype => "cpu",
																				 mode => "AVERAGE",
																				 start => time-86400,
																				 end =>  time-6000,
																				 hour_from => 19,
																				 hour_to => 4);

print Dumper($meta, $names, $data);

# and now also check getrrdstats

my $statval = getRRDStats(sys => $S, graphtype => "cpu",
													mode => "AVERAGE",
													start => time-86400,
													end =>  time-6000,
													hour_from => 19,
													hour_to => 4);
print Dumper($statval);


# load a json file, invalid encoding
my $hash = func::readFiletoHash(file => "testdata/latin1.json", json => 1);
print Dumper($hash);

# and again, but with correct utf8 encoding
$hash = func::readFiletoHash(file => "testdata/utf8.json", json => 1);
print Dumper($hash);


