#!/usr/bin/perl
# fixme: this thing should be changed over to use test::more and test::deep.

use FindBin;
use lib "$FindBin::Bin/../lib";


use strict;
use NMISNG::Util;
use Compat::NMIS;
use NMISNG::Sys;
use Compat::Timing;
use NMIS::Connect;
use rrdfunc;
use Data::Dumper;

my %nvp = getArguements(@ARGV);
my $C = loadConfTable(debug => $nvp{debug}, info=> $nvp{info});
rrdfunc::require_RRDs(config=>$C);

print "testing parse_dateandtime...\n";

# this helps: snmpget -mAll  -v2c -c ... -Ih somenode HOST-RESOURCES-MIB::hrSystemDate.0
for (["0x07E00909102B3A002B0A00", 1473403438],
		 ["0x07E00909062D1300", 1473403519],
		 ["0x07E0090910340B05", 1473439931.5 ],	# mani: with decisecs but clock in local zone and no knowledge thereof
		)
{
	my ($hexstring, $expected) = @$_;
	my $res = NMISNG::Util::parse_dateandtime($hexstring);
	die "NMISNG::Util::parse_dateandtime failed: $hexstring should have translated to $expected, but got $res\n"
			if ($res != $expected);
	print "had $hexstring, got $res or gmtime ".gmtime($res)."\n";
}

exit 0;
		

print "testing sort with NMISNG::Util::alpha...\n";
# fwd, ie. expect 1 if left side is greater
for ([0+"nan", 47, 1],					# nan greater than any X
		 [0+"nan", 1+"nan", 0],			# same
		 [3456, 0+"nan", -1],				# any X less than nan
		 ['123.45.40.100','123.044.40.139', 1] ,
		 [ 'ticket4', 'ticket20', -1],
		 ['dodgy12/5/9', 'dodgy3/78/9plusgunk', 1],
		 ['x45junk', 'junk456', 1],
		 )
		
		
{
	my ($first, $second, $expected) = @{$_};
	my $res = NMISNG::Util::alpha('fwd',$first, $second);
	die("NMISNG::Util::alpha failed: $first cmp $second, expected $expected but got $res\n") if ($res != $expected);
}

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

print "returndate: " . NMISNG::Util::returnDate(time)."\n";
print "datestamp: " . NMISNG::Util::returnDateStamp(time)."\n";
print "time: " . NMISNG::Util::returnTime(time)."\n";

print "secs to hours: " . NMISNG::Util::convertSecsHours(3*3600 + 10*60 + 15)."\n";

my $S=NMISNG::Sys->new;
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
my $hash = NMISNG::Util::readFiletoHash(file => "testdata/latin1.json", json => 1);
print Dumper($hash);

# and again, but with correct utf8 encoding
$hash = NMISNG::Util::readFiletoHash(file => "testdata/utf8.json", json => 1);
print Dumper($hash);


