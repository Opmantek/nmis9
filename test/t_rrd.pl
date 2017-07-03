#!/usr/bin/perl

use strict;

use FindBin;
use lib "$FindBin::Bin/../lib";

use NMIS;
use NMIS::Timing;
use func;
use rrdfunc;
use Sys;
use Data::Dumper; 
$Data::Dumper::Indent = 1;

my $t = NMIS::Timing->new();

print $t->elapTime(). " Begin\n";

print $t->elapTime(). " loadConfTable\n";
my $C = loadConfTable();
rrdfunc::require_RRDs(config=>$C);

#my $rrd = "/usr/local/nmis8/database/interface/router/wanedge1/wanedge1-fastethernet0-1.rrd";
##/interface/router/wanedge1/wanedge1-fastethernet0-0-pkts.rrd
#
#my $in =    2788716;
#my $out =   4367792;
##           307200000 
##my $out =  10793487714;
#
#$in = $in + 1307200000 * 2;
#$out = $out + 1307200000 * 2;
#
#my $ds = "ifOperStatus:ifInOctets:ifOutOctets";
#my $value = "N:100:$in:$out";
#
#my @options;
#push @options,("-t",$ds,$value);
#
#print "RRD Update: $ds, $value\n";
#RRDs::update($rrd, @options);
#
#my $ERROR = RRDs::error;
#if ($ERROR) {
#	print STDERR "ERROR RRD Update for $rrd has an error: $ERROR\n";
#}
#else {
#	# All GOOD!
#	print "RRD Update Successful\n";
#}
#
#my $last = RRDs::last($rrd);
#print Dumper($last);
#
#my $hash = RRDs::info($rrd);
#foreach my $key (sort keys %$hash){
# print "$key = $hash->{$key}\n";
#}

my $M = Sys::->new(); # load base model
$M->init;

my $DB;
if (exists $M->{mdl}{database}{db}{size}{interface}) {
	$DB = $M->{mdl}{database}{db}{size}{interface};
} elsif (exists $M->{mdl}{database}{db}{size}{default}) {
	$DB = $M->{mdl}{database}{db}{size}{default};
	dbg("INFO, using database format \'default\'");
}


#print $t->markTime(). " loadNodeTable\n";
#print "  done in ".$t->deltaTime() ."\n";

# Create an empty RRD
my $database = "$FindBin::Bin/t_rrd.rrd";
my $csv = "$FindBin::Bin/t_rrd.csv";
my $graph = "$FindBin::Bin/t_rrd.png";

my @options;

my $RRD_poll;
my $RRD_hbeat;
if (!($RRD_poll = $M->{mdl}{database}{db}{poll})) { $RRD_poll = 300;}
if (!($RRD_hbeat = $M->{mdl}{database}{db}{hbeat})) { $RRD_hbeat = $RRD_poll * 3;}

my $now = time;
my $START = $now - 86400;

@options = ("-b", $START, "-s", $RRD_poll);

my $source = "GAUGE";
my $range = "U:U";

# Toggle these to see different results.
my $ifSpeed =  10000000;
my $maxOctets = $ifSpeed / 8;

push @options,"DS:ifOperStatus:GAUGE:$RRD_hbeat:0:100";
push @options,"DS:ifInOctets:COUNTER:$RRD_hbeat:0:U";
push @options,"DS:ifOutOctets:COUNTER:$RRD_hbeat:0:$maxOctets";

push @options,"RRA:AVERAGE:0.5:$DB->{step_day}:$DB->{rows_day}";
push @options,"RRA:AVERAGE:0.5:$DB->{step_week}:$DB->{rows_week}";
push @options,"RRA:AVERAGE:0.5:$DB->{step_month}:$DB->{rows_month}";
push @options,"RRA:AVERAGE:0.5:$DB->{step_year}:$DB->{rows_year}";
push @options,"RRA:MAX:0.5:$DB->{step_day}:$DB->{rows_day}";
push @options,"RRA:MAX:0.5:$DB->{step_week}:$DB->{rows_week}";
push @options,"RRA:MAX:0.5:$DB->{step_month}:$DB->{rows_month}";
push @options,"RRA:MAX:0.5:$DB->{step_year}:$DB->{rows_year}";
push @options,"RRA:MIN:0.5:$DB->{step_day}:$DB->{rows_day}";
push @options,"RRA:MIN:0.5:$DB->{step_week}:$DB->{rows_week}";
push @options,"RRA:MIN:0.5:$DB->{step_month}:$DB->{rows_month}";
push @options,"RRA:MIN:0.5:$DB->{step_year}:$DB->{rows_year}";

print $t->markTime(). " RRDs::create maxOctets=$maxOctets $database\n";
RRDs::create("$database",@options);
my $ERROR = RRDs::error;
if ($ERROR) {
	print("ERROR unable to create $database: $ERROR\n");
	exit 0;
}
print "  done in ".$t->deltaTime() ."\n";

my $ds = "ifOperStatus:ifInOctets:ifOutOctets";

my $in = 4294900000 - 1500000;
my $out = 1500000;
my $inc = 75000;
my $max32 = 4294967295;
my $simwrap = 1;
my $interval = 300;

my $datarate = $inc / $RRD_poll;
print qq{
Incrementing at $inc octets each $RRD_poll seconds = $datarate octets/second.
Max Octets used for ifOutOctets only, set to $maxOctets.
DS=$ds
	
};
my $max = 40;
for (my $i = 1; $i <= $max; ++$i ) {
	$in = $in + $inc;
	$out = $out + $inc;
	my $time = $now - ( ($max - $i) * $interval );

	# Reset the counters.
	if ( $i == $max * 0.75 ) {
		#print $t->elapTime(). " Simulating Counter Reset with maxOctets=$maxOctets\n";
		#$in = 0;
		#$out = 0;
	}

	# Handle a simulated counter wrap
	if ( $in > $max32 ) {
		$in = -1 + ($in - $max32);
		if ($simwrap) {
			print $t->elapTime(). " Simulating Counter Wrap \@ $max32\n";
			$simwrap = 0;
		}
	}
	
	my $vin = $in;
	my $vout = $out;
	# Store an unknown value.
	if ( $i == $max / 4 ) {
		print $t->elapTime(). " Simulating Inserting Unknown Value\n";
		$vin = "U";
		$vout = "U";
	}

	my $value = "$time:100:$vin:$vout";

	print $t->elapTime(). " $i $time RRDs::update $vin:$vout, $in:$out\n";
	my @options = ("-t",$ds,$value);
	RRDs::update($database, @options);
	my $ERROR = RRDs::error;
	if ($ERROR) {
		print("ERROR unable to update $database: $ERROR\n");
		exit 0;
	}
}

print $t->markTime(). " RRD::graph to $graph\n";
my $graph_split = "true";
my $split = $graph_split eq 'true' ? -1 : 1 ;
my $GLINE = $graph_split eq 'true' ? "AREA" : "LINE1" ;

my @graphopt = (
	"--start", time - $max * 300,
	"--end", time,
	"--width", 600,
	"--height", 400,
	"--imgformat", "PNG",
	"DEF:input=$database:ifInOctets:AVERAGE",
	"DEF:output=$database:ifOutOctets:AVERAGE",
	#"DEF:intmp=$database:ifInOctets:AVERAGE",
	#"DEF:outtmp=$database:ifOutOctets:AVERAGE",
	#"CDEF:input=intmp,UN,PREV,intmp,IF",
	#"CDEF:output=outtmp,UN,PREV,outtmp,IF",
	"CDEF:inputUtil=input,8,*,$ifSpeed,/,100,*",
	"CDEF:inputSplitUtil=input,8,*,$ifSpeed,/,100,*,$split,*",
	"CDEF:outputUtil=output,8,*,$ifSpeed,/,100,*",
	"$GLINE:inputSplitUtil#0000ff:In",
	"GPRINT:inputUtil:AVERAGE:Avg %1.2lf %% \\n",
	"$GLINE:outputUtil#00ff00:Out",
	'GPRINT:outputUtil:AVERAGE:Avg %1.2lf %% \\n',
	"COMMENT:\tInterface Speed $ifSpeed\\n"
);


my ($graphret,$xs,$ys) = RRDs::graph($graph, @graphopt);

if ($ERROR = RRDs::error) {
	print("ERROR: $database Graphing Error: $ERROR\n");

}
print "  done in ".$t->deltaTime() ."\n";

print $t->markTime(). " exportRRD\n";
my ($statval,$head) = exportRRD(db=>$database,mode=>"AVERAGE",start=>$START,end=>$now);
print "  done in ".$t->deltaTime() ."\n";

print $t->elapTime(). " Saving RRD as CSV $csv\n";
open(OUT, ">$csv") or die "ERROR with $csv, $!\n";
my $f = 1;
my @line;
my $row;
my $content;
foreach my $m (sort keys %{$statval}) {
	if ($f) {
		$f = 0;
		foreach my $h (@$head) {
			push(@line,$h);
			#print STDERR "@line\n";
		}
		#print STDERR "@line\n";
		$row = join("\t",@line);
		print OUT "$row\n";
		@line = ();
	}
	$content = 0;
	foreach my $h (@$head) {
		if ( defined $statval->{$m}{$h}) {
			$content = 1;
		}
		push(@line,$statval->{$m}{$h});
	}
	if ( $content ) {
		$row = join("\t",@line);
		print OUT "$row\n";
	}
	@line = ();
}
close(OUT);

print $t->elapTime(). " END\n";


sub exportRRD {
	my %args = @_;
	my $db = $args{db};
	my ($begin,$step,$name,$data) = RRDs::fetch($db,$args{mode},"--start",$args{start},"--end",$args{end});
	my %s;
	my @h;
	my $f = 1;
	my $date;
	my $d;
	my $time = $begin;
	for(my $a = 0; $a <= $#{$data}; ++$a) {
		$d = 0;
		for(my $b = 0; $b <= $#{$data->[$a]}; ++$b) {
			if ($f) { push(@h,$name->[$b]) }
			$s{$time}{$name->[$b]} = $data->[$a][$b];
			if ( defined $data->[$a][$b] ) { $d = 1; }
		}
		if ($d) {
			$date = returnDateStamp($time);
			$s{$time}{time} = $time;
			$s{$time}{date} = $date;
		}
		if ($f) { 
			push(@h,"time");
			push(@h,"date");
		}
		$f = 0;
		$time = $time + $step;
	}
	return (\%s,\@h);
}	