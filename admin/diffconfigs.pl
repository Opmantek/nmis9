#!/usr/bin/perl
#
## $Id: diffconfigs.pl,v 8.4 2012/08/14 12:38:53 keiths Exp $
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

# Auto configure to the <nmis-base>/lib
use FindBin;
use lib "$FindBin::Bin/../lib";

# 
use strict;
use func;

print "This script will perform a contextual diff on two NMIS Config files.\n";

if ( $ARGV[0] eq "" ) {
	print <<EO_TEXT;
ERROR: $0 needs to know the NMIS config files to compare
usage: $0 <CONFIG_1> <CONFIG_2>
eg: $0 /usr/local/nmis8/install/Config.nmis /usr/local/nmis8/conf/Config.nmis

EO_TEXT
	exit 1;
}

print "The first config file is: $ARGV[0]\n";
print "The second config file is: $ARGV[1]\n";

my $conf1;
my $conf2; 

# load configuration table
if ( -f $ARGV[0] ) {
	$conf1 = readFiletoHash(file=>$ARGV[0]);
}
else {
	print "ERROR: something wrong with config file 1: $ARGV[0]\n";
	exit 1;
}

if ( -f $ARGV[1] ) {
	$conf2 = readFiletoHash(file=>$ARGV[1]);
}
else {
	print "ERROR: something wrong with config file 2: $ARGV[1]\n";
	exit 1;
}

my %diffs;

&compare("Config1","Config2",$conf1,$conf2);
print "\n";
&compare("Config2","Config1",$conf2,$conf1);

print "Difference Summary:\n";
foreach my $diff (sort keys(%diffs)) {
	my @diffbits = split("--",$diff);
	my $diffstring = join("\\",@diffbits);
	print "$diffs{$diff}\\$diffstring\n";
}

### 2012-08-14 keiths, making compare recursive to handle complex comparisions like with Models.
sub compare {
	my $which1 = shift;
	my $which2 = shift;
	my $thing1 = shift;
	my $thing2 = shift;
	
	my $gotdiff = 0;
	
	#Recurse over the first Config Hash and compare results
	print "Using $which1 as the base for comparison\n";
	# Processing the $first level
	foreach my $first (sort keys %{$thing1}) {
		#print "  Working on Config Section: $first\n";
		if ( ref($thing1->{$first}) eq "HASH" ) {

			# Processing the $second level
			foreach my $second (sort keys %{$thing1->{$first}}) {
				if ( ref($thing1->{$first}{$second}) eq "HASH" ) {

					# Processing the $third level
					foreach my $third (sort keys %{$thing1->{$first}{$second}}) {
						if ( ref($thing1->{$first}{$second}{$third}) eq "HASH" ) {

							# Processing the $fourth level
							foreach my $fourth (sort keys %{$thing1->{$first}{$second}{$third}}) {
								if ( ref($thing1->{$first}{$second}{$third}{$fourth}) eq "HASH" ) {

									# Processing the $fifth level
									foreach my $fifth (sort keys %{$thing1->{$first}{$second}{$third}{$fourth}}) {
										if ( ref($thing1->{$first}{$second}{$third}{$fourth}{$fifth}) eq "HASH" ) {

											# Processing the $sixth level
											foreach my $sixth (sort keys %{$thing1->{$first}{$second}{$third}{$fourth}{$fifth}}) {
												if ( ref($thing1->{$first}{$second}{$third}{$fourth}{$fifth}{$sixth}) eq "HASH" ) {

													# Processing the $sixth level
													foreach my $seventh (sort keys %{$thing1->{$first}{$second}{$third}{$fourth}{$fifth}{$sixth}}) {
														my $diffkey = "$first--$second--$third--$fourth--$fifth--$sixth--$seventh";
														my $diffstr1 = "$which2/$first/$second/$third/$fourth/$fifth/$sixth/$seventh";
														my $diffstr2 = "$which1/$first/$second/$third/$fourth/$fifth/$sixth/$seventh";
														if ( not defined $thing2->{$first}{$second}{$third}{$fourth}{$fifth}{$sixth}{$seventh} ) {
															$diffs{$diffkey} = $which2;
															$gotdiff = 1;
															print "  Null: $diffstr1, $diffstr2=$thing1->{$first}{$second}{$third}{$fourth}{$fifth}{$sixth}{$seventh}\n";
														}
														elsif ( $thing1->{$first}{$second}{$third}{$fourth}{$fifth}{$sixth}{$seventh} ne $thing2->{$first}{$second}{$third}{$fourth}{$fifth}{$sixth}{$seventh} and not $diffs{$diffkey} ) { 
															$diffs{$diffkey} = $which1;
															$gotdiff = 1;
															print "  Diff: $diffstr2=$thing1->{$first}{$second}{$third}{$fourth}{$fifth}{$sixth}{$seventh}, $diffstr1=$thing2->{$first}{$second}{$third}{$fourth}{$fifth}{$sixth}{$seventh}\n";
														}
													}
												}
												else {
													my $diffkey = "$first--$second--$third--$fourth--$fifth--$sixth";
													my $diffstr1 = "$which2/$first/$second/$third/$fourth/$fifth/$sixth";
													my $diffstr2 = "$which1/$first/$second/$third/$fourth/$fifth/$sixth";
													if ( not defined $thing2->{$first}{$second}{$third}{$fourth}{$fifth}{$sixth} ) {
														$diffs{$diffkey} = $which2;
														$gotdiff = 1;
														print "  Null: $diffstr1, $diffstr2=$thing1->{$first}{$second}{$third}{$fourth}{$fifth}{$sixth}\n";		
													}
													elsif ( $thing1->{$first}{$second}{$third}{$fourth}{$fifth}{$sixth} ne $thing2->{$first}{$second}{$third}{$fourth}{$fifth}{$sixth} and not $diffs{$diffkey} ) { 
														$diffs{$diffkey} = $which1;
														$gotdiff = 1;
														print "  Diff: $diffstr2=$thing1->{$first}{$second}{$third}{$fourth}{$fifth}{$sixth}, $diffstr1=$thing2->{$first}{$second}{$third}{$fourth}{$fifth}{$sixth}\n";
													}
												}
											}

										}
										else {
											my $diffkey = "$first--$second--$third--$fourth--$fifth";
											my $diffstr1 = "$which2/$first/$second/$third/$fourth/$fifth";
											my $diffstr2 = "$which1/$first/$second/$third/$fourth/$fifth";
											if ( not defined $thing2->{$first}{$second}{$third}{$fourth}{$fifth} ) {
												$diffs{$diffkey} = $which2;
												$gotdiff = 1;
												print "  Null: $diffstr1, $diffstr2=$thing1->{$first}{$second}{$third}{$fourth}{$fifth}\n";		
											}
											elsif ( $thing1->{$first}{$second}{$third}{$fourth}{$fifth} ne $thing2->{$first}{$second}{$third}{$fourth}{$fifth} and not $diffs{$diffkey} ) { 
												$diffs{$diffkey} = $which1;
												$gotdiff = 1;
												print "  Diff: $diffstr2=$thing1->{$first}{$second}{$third}{$fourth}{$fifth}, $diffstr1=$thing2->{$first}{$second}{$third}{$fourth}{$fifth}\n";
											}					
										}
									}
								}
								else {
									my $diffkey = "$first--$second--$third--$fourth";
									my $diffstr1 = "$which2/$first/$second/$third/$fourth";
									my $diffstr2 = "$which1/$first/$second/$third/$fourth";
									if ( not defined $thing2->{$first}{$second}{$third}{$fourth} ) {
										$diffs{$diffkey} = $which2;
										$gotdiff = 1;
										print "  Null: $diffstr1, $diffstr2=$thing1->{$first}{$second}{$third}{$fourth}\n";		
									}
									elsif ( $thing1->{$first}{$second}{$third}{$fourth} ne $thing2->{$first}{$second}{$third}{$fourth} and not $diffs{$diffkey} ) { 
										$diffs{$diffkey} = $which1;
										$gotdiff = 1;
										print "  Diff: $diffstr2=$thing1->{$first}{$second}{$third}{$fourth}, $diffstr1=$thing2->{$first}{$second}{$third}{$fourth}\n";
									}					
								}	
							}
						}
						else {
							my $diffkey = "$first--$second--$third";
							my $diffstr1 = "$which2/$first/$second/$third";
							my $diffstr2 = "$which1/$first/$second/$third";
							if ( not defined $thing2->{$first}{$second}{$third} ) { 
								$diffs{$diffkey} = $which2;
								$gotdiff = 1;
								print "  Null: $diffstr1, $diffstr2=$thing1->{$first}{$second}{$third}\n";		
							}
							elsif ( $thing1->{$first}{$second}{$third} ne $thing2->{$first}{$second}{$third} and not $diffs{$diffkey} ) { 
								$diffs{$diffkey} = $which1;
								$gotdiff = 1;
								print "  Diff: $diffstr2=$thing1->{$first}{$second}{$third}, $diffstr1=$thing2->{$first}{$second}{$third}\n";
							}
						}
					}
				}
				else {
					my $diffkey = "$first--$second";
					my $diffstr1 = "$which2/$first/$second";
					my $diffstr2 = "$which1/$first/$second";
					if ( not defined $thing2->{$first}{$second} ) { 
						$diffs{$diffkey} = $which2;
						$gotdiff = 1;
						print "  Null: $diffstr1, $diffstr2=$thing1->{$first}{$second}\n";		
					}
					elsif ( $thing1->{$first}{$second} ne $thing2->{$first}{$second} and not $diffs{$diffkey} ) { 
						$diffs{$diffkey} = $which1;
						$gotdiff = 1;
						print "  Diff: $diffstr2=$thing1->{$first}{$second}, $diffstr1=$thing2->{$first}{$second}\n";
					}
				}
			}
		}
	}
	if ( not $gotdiff ) {
		print "No new diffs found with $which1 to $which2\n\n";
	}
}
