#!/usr/bin/perl
use strict;
use Test::More;

use FindBin;
use lib "$FindBin::Bin/../lib";

use NMISNG::Log;
use Mojo::File;

# check general stderr output
my $output_string;
{
	open(DUMMY, ">>", \$output_string);
	local *STDERR = *DUMMY;

	my $logger = NMISNG::Log->new(level => "info");

	$logger->debug("1 this is debug");
	$logger->info("2 this is info");
	$logger->reopen;							# nop in this case
	$logger->warn("3 this is warn");
	$logger->debug5("4 this is debug5");
}

isnt($output_string, '', "logging to stderr works");
unlike($output_string, qr/this is debug/, "debug suppressed by level info");
like($output_string, qr/this is info/, "info reaches info");

my $targetfile = "/tmp/loggertest.$$";
# check the extra level logic and prints, with cutoffs
# note: code leaves standard levels (warn error fatal) to mojo's tests.
for my $minlevel (qw(info debug),1..9,'y','t','YES','verbose')
{
	my $minlevelnumeric = ($minlevel =~ /^(debug|y|t)/i? 1 :
												 lc($minlevel) eq "verbose"? 9 :
												 $minlevel eq "info"? 0 : $minlevel);
#	diag("$minlevel translates to numeric $minlevelnumeric");
	my $logger = NMISNG::Log->new(level => $minlevel,
																path => $targetfile);

	my %levelprints;
	# check the is_level logic, then the print
	for my $level (qw(info debug 1 2 3 4 5 6 7 8 9))
	{
		my $willprint  = $logger->is_level($level)?1:0;
		my $levelnumeric = ($level eq "info"? 0 :
												$level eq "debug"? 1 : $level);
#		diag("level $level translates to numeric $levelnumeric");
		my $expected = $levelnumeric <= $minlevelnumeric? 1 :0;
		$levelprints{$level} = $expected;

		is($willprint, $expected,
			 "is_level says $level "
			 .($expected?"would":"would not")." print for $minlevel logger");
	}

	$logger->warn("this ensures we have some output");
	for my $level (1..9)
	{
		my $funcname = "debug$level";
		$logger->$funcname("logging debug$level, $minlevel logger");
	}

	my $logoutput = Mojo::File->new($targetfile)->slurp;
	isnt($logoutput, '', "logger created file output");

	for my $level (1..9)
	{
		if ($levelprints{$level})
		{
			like($logoutput, qr/logging debug$level, $minlevel logger/, "level $level printed for $minlevel logger");
		}
		else
		{
			unlike($logoutput, qr/logging debug$level, $minlevel logger/, "level $level suppressed for $minlevel logger");
		}
	}

	unlink $targetfile;
}

# check reopening of file
my $logger = NMISNG::Log->new(level => 2, # why not
															path => $targetfile);
$logger->info("normal output");
$logger->debug("also normal");

my $rotated =  "$targetfile.rotated";
rename($targetfile,$rotated);
$logger->info("goes into the wrong file");
$logger->reopen;
$logger->info("post-reopen should go into the new file");

my $olddata = Mojo::File->new($rotated)->slurp;
my $newdata = Mojo::File->new($targetfile)->slurp;

like($olddata, qr/normal output/, "logger works");
like($olddata, qr/into the wrong file/, "logger continues writing to old file after renaming");
unlike($olddata, qr/post-reopen/, "logger reopen does reopen (old file is ok)")
		or diag("old file: $olddata");
like($newdata, qr/post-reopen/, "logger reopen does reopen (new file receives data)")
		or diag("new file: $newdata");

unlink($targetfile, $rotated);


# check changing to different levels
$logger = NMISNG::Log->new(level => "info");

# new, response, level, details
for (['4','info', 'debug',4],
		 ['verbose', 4, 'debug','9' ],
		 [ 'warn', 9, 'warn', 0 ],
		 [ 'info', 'warn', 'info', 0 ],
		 [ 'true', 'info', 'debug', 1 ])
{
	my ($input, $expected, $newlevel, $newdetail) = @$_;

	my $got = $logger->new_level($input);
	is($got, $expected, "changing to '$input' returns expected previous level '$expected'");
	is($logger->level,$newlevel, "changing to '$input' sets level to $newlevel");
	is($logger->detaillevel, $newdetail, "changing to '$input' sets details to $newdetail");
}

done_testing;
