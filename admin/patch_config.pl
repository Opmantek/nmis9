#!/usr/bin/perl
#
#
#  Copyright 1999-2015 Opmantek Limited (www.opmantek.com)
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
# this is a small helper that modifies X.nmis-style config file entries
our $VERSION = "1.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use Data::Dumper;
use File::Basename;
use Getopt::Std;
use func;

if (@ARGV == 1 && $ARGV[0] eq "--version")
{
	print "version=$VERSION\n";
	exit 0;
}

# fixme: maybe add capability for making an empty hash, empty array? 
my $usage = "Usage: ".basename($0)." [-fb] [-n] <configfile.nmis> <key=newvalue ...>

key is either 'confkeyname' or '/section/sub1/sub2/keyname'

operation is either = for overwriting scalar, or += for adding to array
newvalue is value to set or \"undef\".

-f: forces conversion of config sections to match key path structure.
-b: backup old file as <filename>.prepatch before modification.
-n: forces ALL changes to produce numeric data (default: string)
\n\n";

my %opts;
die $usage if (!getopts("fbn",\%opts) or !@ARGV or !-f $ARGV[0]);

my $config_file = shift(@ARGV);
die "Config file \"$config_file\" does not exist or isn't readable!\n"
		if (!-e $config_file or !-r $config_file);

loadConfTable;	# or else writeHashtoFile will fail, as it calls 
# setfileprot which then has no config values for perms and uid/gid. 

print "Operating on config file: $config_file\n\n";
my $cfg = readFiletoHash(file => $config_file);

die "Config file \"$config_file\" was not parseable or is empty!\n" 
		if (!$cfg);

my @patches;
for my $token (@ARGV)
{
	if ($token =~ /^\s*([^\+=]+)(=|\+=)(.*)$/)
	{
		my ($key,$op,$value) = ($1,$2,$3);
		if ($value eq "undef")
		{
			$value = undef;
		}
		elsif ($opts{n})
		{
			# force this into numeric form if the value is number-like
			$value = 0 + $value;
		}
		push @patches, [ $key,  $op, $value ];
	}
	else
	{
		die "cannot parse patch expression \"$token\"!\n";
	}
}
die "No patches given!\n" if (!@patches);
print "Patching values for keys ".join(", ",map { $_->[0] } (@patches))."\n";

# as long as we have patches to apply:
while (grep(defined $_, @patches))
{
	# handle mods to fully existing keys
	my $errmsg = patch_config($cfg, undef, undef);
	die "Patching failed: $errmsg\n" if ($errmsg);
	
	# but there might be new stuff, too
	# this function only applies ONE patch, as afterwards we might 
	# have to go back to the existing key case
	$errmsg = &add_new;
	die "Adding of new entries failed: $errmsg\n" if ($errmsg);
}

if ($opts{b})
{
	rename($config_file,"$config_file.prepatch") or die "cannot rename $config_file: $!\n";
}
writeHashtoFile(file => $config_file, data => $cfg);

# args: current location in cfg tree, path name, elem name (if any)
# uses global %patches, updates the cfg tree
# returns undef if successful, error message otherwise
sub patch_config 
{
	my ($curloc, $curpath, $curelem) = @_;

	# recurse down into hash elements
	if (ref($curloc) eq "HASH")
	{
		for my $subkey (sort keys %$curloc)
		{
			my $error = patch_config(ref($curloc->{$subkey})? $curloc->{$subkey} 
															 : \$curloc->{$subkey} ,"$curpath/$subkey",$subkey);
			return $error if $error;
		}
	}
	# append to arrays, and recurse down into arrays
	elsif (ref($curloc) eq "ARRAY")
	{
		# check if a += op defined for here
		for my $pidx (0..$#patches)
		{
			next if (!$patches[$pidx]);
			my ($patchpath,$op,$value) = @{$patches[$pidx]};

			if ($curpath eq $patchpath
					or $curelem eq $patchpath)
			{
				print "Patching array $curpath, patch $patchpath\n";
				# fixme maybe add capability for changing list to hash or scalar, with -f
				die "op $op not supported for element $curpath!\n"
						if ($op ne '+=');

				# ensure that the value isn't in that list already
				$curloc = add_to_list_unique($curloc, $value);

				# patch applied, no longer needed, delete 
				$patches[$pidx] = undef;
			}
		}
		
		# now recurse into array
		for my $idx (0..$#$curloc)
		{
			my $error = patch_config(ref($curloc->[$idx])? $curloc->[$idx] : \$curloc->[$idx],
															 $curpath."[$idx]","[$idx]");
			return $error if $error;
		}
	}
	# scalar ref, so we check our patch key names and apply
	elsif (ref($curloc))
	{
		for my $pidx (0..$#patches)
		{
			next if (!$patches[$pidx]);
			my ($patchpath,$op,$value) = @{$patches[$pidx]};

			if ($curpath eq $patchpath # full path matches
					or $curelem eq $patchpath) # or the 'relative' element name matches
			{
				print "Patching element $curpath, patch $patchpath\n";
				# fixme maybe add capability to transmogrify scalar into array/hash, with -f
				die "op $op not supported for element $curpath!\n"
						if ($op ne '=');
				
				$$curloc = $value;

				# patch applied, no longer needed, forget it
				$patches[$pidx] = undef;
			}
		}
	}
	else
	{
		die "Unexpected element encountered in $curpath!\n";
	}			

  return undef;
}

# adds a value to a list if not present yet
# ignores ref is not listref, and makes a new one

# args: ref to list, new elem
# returns: list ref 
sub add_to_list_unique
{
	my ($listref, $newelem) = @_;
	if (ref($listref) ne "ARRAY")
	{
		$listref = [$newelem];
	}
	else
	{
		push @$listref, $newelem if (!grep($_ eq $newelem, @$listref));
	}
	return $listref;
}

# adds new patch material, from ONE patch only!
# returns undef if ok, error message otherwise
sub add_new
{
	# now deal with the FIRST of the remaining patches, which clearly 
	# must be related to nonexistent data
	for my $pidx (0..$#patches)
	{
		next if (!$patches[$pidx]);
		my ($patchpath,$op,$value) = @{$patches[$pidx]};

		die "cannot set nonexistent variable \"$patchpath\" without explicit section location!\n"
				if ($patchpath !~ m!^/!);

		my $parent = $cfg;
		# /this/and/key[5]/subkey[7]/thingy = whatever
		# make the bla[x] steps an easier to parse /bla/[x]
		my $consume = $patchpath;
		$consume =~ s!\[!/[!g;		

		my @elems = (split(m!/!, $consume));
		for my $pathidx (1..$#elems)
		{
			my $elem = $elems[$pathidx];
			my $needarray = ($elem =~ s/[\[\]]//g);

			# fill in missing hierarchy bit if not at leaf yet, or replace if incompat structure
			if ($pathidx != $#elems)
			{
				my $nextblank = ($elems[$pathidx+1] =~ /^\[-?\d+\]$/)? [] : {};

				if ($needarray)
				{
					die "cannot convert existing object $elem in $patchpath to ".ref($nextblank)
							." without -f\n" 
							if (!$opts{f} &&  exists $parent->[$elem] && ref($parent->[$elem]) ne ref($nextblank));

					$parent->[$elem] = $nextblank
							if (!exists $parent->[$elem] or ref($parent->[$elem]) ne ref($nextblank)); 

					$parent = $parent->[$elem];
				}
				else
				{
					die "cannot convert existing object $elem in $patchpath to ".ref($nextblank)
							." without -f\n" 
							if (!$opts{f} &&  exists $parent->{$elem} && ref($parent->{$elem}) ne ref($nextblank));

					$parent->{$elem} = $nextblank
							if (!exists $parent->{$elem} or ref($parent->{$elem}) ne ref($nextblank));
					$parent = $parent->{$elem};
				}
			}
			else	# at the final leaf elem, += supported
			{
				if ($needarray)
				{
					if ($op eq "+=")
					{
						die "cannot convert structure at $elem to ARRAY without -f\n" 
								if (ref($parent->[$elem]) && ref($parent->[$elem]) ne "ARRAY" && !$opts{f});
						
						print "Adding to new array $patchpath\n";
						$parent->[$elem] = [];
						add_to_list_unique($parent->[$elem], $value);
					}
					else
					{
						die "cannot overwrite deep structure at $elem without -f\n" 
								if (ref($parent->[$elem]) && !$opts{f});
						
						print "Creating new element $patchpath\n";
						$parent->[$elem] = $value;
					}
				}
				else
				{
					if ($op eq "+=")
					{
						die "cannot convert structure at $elem to ARRAY without -f\n" 
								if (ref($parent->{$elem}) && ref($parent->{$elem}) ne "ARRAY" && !$opts{f});
						
						print "Adding to new array $patchpath\n";
						$parent->{$elem} = [];
						add_to_list_unique($parent->{$elem}, $value);
					}
					else
					{
						die "cannot overwrite deep structure at $elem without -f\n" 
								if (ref($parent->{$elem})  && !$opts{f});
						
						print "Creating new element $patchpath\n";
						$parent->{$elem} = $value;
					}
				}
		 
			}
		}
		# patch applied, no longer needed, forget it
		$patches[$pidx] = undef;
		last;
	}
	return undef;
}
