#!/usr/bin/perl


my $r = "CW_VERSION\$15.1(1)T1\$";

my $runit = '$r =~ /CW_VERSION\$(.+)\$/; $r = $1';
$r = eval $runit;
print "RESULT of \"$runit\" is $r\n";


my $expression = "5 * 4 + 42";
my $result = eval $expression;
print "RESULT of \"$expression\" is $result\n";
