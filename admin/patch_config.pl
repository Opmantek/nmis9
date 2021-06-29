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
our $VERSION = "1.2.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use Data::Dumper;
use File::Basename;
use Getopt::Std;
use File::Copy;

use NMISNG::Util;
use Compat::NMIS; 								# for nmisng::util::dbg, fixme9

if (@ARGV == 1 && $ARGV[0] eq "--version")
{
	print "version=$VERSION\n";
	exit 0;
}

# fixme: maybe add capability for making an empty hash, empty array?
my $usage = "Usage: ".basename($0)." [-fb] [-n] [-j] <configfile.nmis> <key=newvalue ...>

key is either 'confkeyname' or '/section/sub1/sub2/keyname'

operation is = for overwriting scalar,
or += for adding to array (only if missing)
or ,= for adding to comma-separated list (only if missing)
or -a for set to empty array
newvalue is value to set or \"undef\".

-f: forces conversion of config sections to match key path structure.
-j: use json files
-b: backup old file as <filename>.prepatch before modification.
-n: forces ALL changes to produce numeric data (default: string)
-r: just read and print the value of the one given key
exit codes for -r: 0 ok, 1 key doesn't exist, 2 value is undef,
3 value is not printable, 4 invalid key

-R: show all existing config entries

E.g. Create empty array: patch_config.pl -a Config.nmis /new/key=
E.g. Add element to array: patch_config.pl Config.nmis /new/key+=value
E.g. Set empty existing array: patch_config.pl -af Config.nmis /new/key=
\n\n";

my %opts;
die $usage if (!getopts("jfbnrRa",\%opts) or !@ARGV or !-f $ARGV[0]);

my $config_file = shift(@ARGV);
die "Config file \"$config_file\" does not exist or isn't readable!\n"
		if (!-e $config_file or !-r $config_file);

NMISNG::Util::loadConfTable();	# or else writeHashtoFile will fail, as it calls
# setfileprot which then has no config values for perms and uid/gid.
my $json = 0;
if ($opts{j}) {
	$json = 1;
}

if ($config_file =~ /\.json$/) {
	$json = 1;
}

print "Operating on config file: $config_file\n\n";
my ($cfg, $fh) = NMISNG::Util::readFiletoHash(file => $config_file, lock => 1, json => $json);

die "Config file \"$config_file\" was not parseable or is empty: $cfg\n"
		if (ref($cfg) ne "HASH");

# show eveRything
if ($opts{R})
{
	# this produces a.b.4.x, not /a/b[4]/x...
	my ($error, %flatearth) = NMISNG::Util::flatten_dotfields($cfg);
	die "invalid input: $error\n" if $error;
	for my $k (sort keys %flatearth)
	{
		my $displayk = "/".$k;
		$displayk =~ s!\.(\d+)\.!\[$1\]!g;
		$displayk =~ s!\.!/!g;

		print "$displayk=". ($flatearth{$k} =~ /\s/?
									"\"$flatearth{$k}\"": $flatearth{$k})."\n";
	}
	exit 0;
}

my @patches;
for my $token (@ARGV)
{
	if ($opts{r})
	{
		if ($token =~ m!^[a-zA-Z0-9_/\[\]\. -]+$!)
		{
			# follow dotted wants a.b.c and x.4.y, not x[4]/y
			$token =~ s/\[(-?\d+)\]/\.$1/g; $token =~ s!/!.!g; $token=~ s/^\.//;
			# no error, 1 is nonex, 2 is type mismatch
			my ($value,$error) = NMISNG::Util::follow_dotted_diag($cfg, $token);

			if ($error == 1) {
				# this produces a.b.4.x, not /a/b[4]/x...
				my ($error, %flatearth) = NMISNG::Util::flatten_dotfields($cfg);
				die "invalid input: $error\n" if $error;
				
				for my $k (sort keys %flatearth)
				{
					my $displayk = "/".$k;
					$displayk =~ s!\.(\d+)\.!\[$1\]!g;
					$displayk =~ s!\.!/!g;
					if ( $displayk =~ /$token/ ) {
						print ($flatearth{$k} =~ /\s/?
												"\"$flatearth{$k}\"": $flatearth{$k})."\n";
					}
				}
				print "\n";
				exit 0;
			}
			
			exit 4 if ($error == 2);	# couldn't reach the leaf at all
			exit 1 if ($error == 1);	# leaf nonexistent - that's not undef!
			exit 2 if (!$error && !defined $value); # present but undef

			if (ref($value) eq "ARRAY")
			{
				exit 3 if List::Util::any { ref($_) } (@$value);
				print join("\n", @$value)."\n";
			}
			elsif (ref($value) eq "HASH")
			{
				exit 3 if List::Util::any { ref($_) } (values %$value);
				print map { "$_=$value->{$_}\n" } (sort keys %$value);
			}
			elsif (defined($value))
			{
				print "$value\n";
			}
			exit 0;
		}
		else
		{
			die "cannot parse key \"$token\" for read operation!\n";
		}
	}
	else {
		if ($token =~ /^\s*([^\+,=]+)(=|\+=|,=)(.*)$/)
		{
			my ($key,$op,$value) = ($1,$2,$3);

			if ($opts{a})
			{
				my @value = ();
				push @patches, [ $key,  $op, \@value ];
			}
			elsif ($value eq "undef")
			{
				$value = undef;
				push @patches, [ $key,  $op, $value ];
			}
			elsif ($opts{n})
			{
				# force this into numeric form if the value is number-like
				$value = 0 + $value;
				push @patches, [ $key,  $op, $value ];
			} else {
				push @patches, [ $key,  $op, $value ];
			}
		} 
		else
		{
			die "cannot parse patch expression \"$token\"!\n";
		}
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
	$errmsg = &add_new();
	die "Adding of new entries failed: $errmsg\n" if ($errmsg);
}

if ($opts{b})
{
	File::Copy::cp($config_file,"$config_file.prepatch") or die "cannot backup $config_file: $!\n";
}
NMISNG::Util::writeHashtoFile(file => $config_file, data => $cfg, handle => $fh, json => $json, pretty => 1);

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
		if ($opts{a}) {
			$curloc = ();
		} else {
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
				# deal with comma-sep lists
				if ($op eq ",=")
				{
					my @commasep = split(/,/, $$curloc);
					push @commasep, $value if (!grep($_ eq $value, @commasep));
					$$curloc = join(",", @commasep);
				}
				elsif ($op eq "=")
				{
					$$curloc = $value;
				}
				else
				{
						die "op $op not supported for element $curpath!\n";
				}

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