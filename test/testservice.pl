#!/usr/bin/perl
use strict;

my $want = "random";

if ($want eq "random")
{
	print "the testservice is DELIBERATELY random (and runs only once an hour).\n";
	my $state = int(rand(101));
	print "firstmetric=".rand(150)
			."\nsecondmetric="
			.int(rand(101))
			."\nC:\\ %=".rand(100)."\n";
	exit $state;
}
elsif ($want eq "degraded")
{
    print "this service is somewhat sick\n";
    exit 42;
}
elsif ($want eq "up")
{
    print "the testservice is happy\n";

		print "firstmetric=".rand(150)
				."\nsecondmetric=".int(rand(101))
				."\nC:\\ %=".rand(100)."\n";

    exit 100;
}
else  #down
{
    print "this is an ex-parrot\n";
    exit 0;
}
    
