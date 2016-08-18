#!/usr/bin/perl
#
# THIS SOFTWARE IS NOT PART OF NMIS AND IS COPYRIGHTED, PROTECTED AND LICENSED 
# BY OPMANTEK.  
# 
# YOU MUST NOT MODIFY OR DISTRIBUTE THIS CODE
# 
# This code is NOT Open Source
# 
# IT IS IMPORTANT THAT YOU HAVE READ CAREFULLY AND UNDERSTOOD THE END USER 
# LICENSE AGREEMENT THAT WAS SUPPLIED WITH THIS SOFTWARE.   BY USING THE 
# SOFTWARE  YOU ACKNOWLEDGE THAT (1) YOU HAVE READ AND REVIEWED THE LICENSE 
# AGREEMENT IN ITS ENTIRETY, (2) YOU AGREE TO BE BOUND BY THE AGREEMENT, (3) 
# THE INDIVIDUAL USING THE SOFTWARE HAS THE POWER, AUTHORITY AND LEGAL RIGHT 
# TO ENTER INTO THIS AGREEMENT ON BEHALF OF YOU (AS AN INDIVIDUAL IF ON YOUR 
# OWN BEHALF OR FOR THE ENTITY THAT EMPLOYS YOU )) AND, (4) BY SUCH USE, THIS 
# AGREEMENT CONSTITUTES BINDING AND ENFORCEABLE OBLIGATION BETWEEN YOU AND 
# OPMANTEK LTD. 
# 
# Opmantek is a passionate, committed open source software company - we really 
# are.  This particular piece of code was taken from a commercial module and 
# thus we can't legally supply under GPL. It is supplied in good faith as 
# source code so you can get more out of NMIS.  According to the license 
# agreement you can not modify or distribute this code, but please let us know 
# if you want to and we will certainly help -  in most cases just by emailing 
# you a different agreement that better suits what you want to do but covers 
# Opmantek legally too. 
# 
# contact opmantek by emailing code@opmantek.com
# 
# All licenses for all software obtained from Opmantek (GPL and commercial) 
# are viewable at http://opmantek.com/licensing
#   
# *****************************************************************************
use strict;
our $VERSION = "1.0.0";

use File::Find;

use FindBin;
use lib "$FindBin::Bin/../lib";

use func;
use NMIS;

die "Usage: $0 [simulate=t/f] [info=t/f] [debug=t/f]\nsimulate: exit code 0 if no upgradables detected, 1 otherwise\n" 
		if (@ARGV == 1 && $ARGV[0] =~ /^(-h|--h(elp)?|-\?)$/);
my %args = getArguements(@ARGV);

my $simulate = getbool($args{simulate});

my $C = loadConfTable(conf => $args{conf},
											debug=> setDebug($args{debug}),
											info => $args{info});

my $lockoutfile = $C->{'<nmis_conf>'}."/NMIS_IS_LOCKED";

# first check if a lock exist, if not: make one
my $waslocked = (-f $lockoutfile);
if (!$waslocked && !$simulate)
{
	open(F, ">$lockoutfile") or die "cannot open $lockoutfile: $!\n";
	close(F);
}

# then find the files in question
my @candidates;
File::Find::find({ follow => 1,
									 wanted => sub {
										 my $localname = $_;
										 # don't need it at the moment my $dir = $File::Find::dir;
										 my $fn = $File::Find::name;

										 dbg("checking file $fn");
										 next if ($localname !~ /\.nmis$/ 
															or $localname =~ /nmis-ldap-debug/ # must ignore badly named/located file
															or ($localname eq "nmis-event.nmis" # nmis-event is special, convert only ONCE
																	and -f "nmis-event.json.disabled")); # i.e. NOT if this exists
										 dbg("file $fn needs work");
										 push @candidates, $fn;
									 },
								 },
								 $C->{'<nmis_var>'});


# unfortunately readfiletohash does NOT handle overriding args properly, 
# if the config says use_json...so we fudge this, in memory only.
$C->{use_json} = 'false';

my $actualcandidates;
for my $fn (@candidates)
{
	my ($jsonfile,undef) = getFileName(file => $fn, json => 1);
	if (-f $jsonfile)
	{
		info("Skipping $fn: JSON file already exists.");
		next;
	}
	
	if ($simulate)
	{
		info("Would convert $fn but in simulate mode");
		++$actualcandidates;
	}
	else
	{
		info("starting conversion of $fn");
		# unfortunately readfiletohash does NOT handle overriding args properly, if the config says use_json...
		# hence the ugly fudgery above
		my $data = readFiletoHash(file => $fn, json => 0);
		die "file $fn unparseable!\n" if (!defined $data);
		
		writeHashtoFile(data => $data, file => $fn, json => 1);
		info("done with $jsonfile");
	}
}

# now update nmis to actually use the json files
if (!$simulate)
{
	my $cfgfn = $C->{'<nmis_conf>'}."/".$C->{conf}.".nmis";
	my $unflattened = readFiletoHash(file => $cfgfn);
				
	$unflattened->{system}->{"use_json"} = 'true';
	$unflattened->{system}->{"use_json_pretty"} = 'false' if (!exists $C->{system}->{"use_json_pretty"});

	writeHashtoFile(data => $unflattened, file => $cfgfn);

	# finally remove the lock file (if it wasn't already present!)
	if (!$waslocked)
	{
		unlink $lockoutfile or die "cannot remove $lockoutfile: $!\n";
	}
}
if (!$simulate)
{
	info("conversion complete");
}
else
{
	info("simulate run complete, found ".($actualcandidates || "no")." files to convert");
}
		

# report back to the installer if in simulation mode
exit ($simulate && $actualcandidates? 1 : 0);
