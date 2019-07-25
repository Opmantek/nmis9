#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System (“NMIS”).
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
package NMISNG::MIB;
our $VERSION = "1.0.1";

use strict;
use NMISNG::Util;

my $oid_config_loaded = 0;

# Load in a few base defs
my %OIDS  = ('iso' => '1',
	     'org' => '1.3',
	     'dod' => '1.3.6',
	     'internet' => '1.3.6.1',
	     'directory' => '1.3.6.1.1',
	     'mgmt' => '1.3.6.1.2',
	     'mib-2' => '1.3.6.1.2.1',
	     'experimental' => '1.3.6.1.3',
	     'private' => '1.3.6.1.4',
	     'enterprises' => '1.3.6.1.4.1'
	     );

my %NAMES = ('1' => 'iso',
	     '1.3' => 'org',
	     '1.3.6' => 'dod',
	     '1.3.6.1' => 'internet',
	     '1.3.6.1.2' => 'mgmt',
	     '1.3.6.1.2.1' => 'mib-2',
	     '1.3.6.1.3' => 'experimental',
	     '1.3.6.1.4' => 'private',
	     '1.3.6.1.4.1' => 'enterprises'
	     );


# args: nmisng object, base dir, list of relative mib paths
# returns: nothing
sub loadoids_file
{
	my ($nmisng, $dir, @mibs) = @_;

  my $mib;
	if (!-d $dir)
	{
		$nmisng->log->error("NMISNG::MIB: Directory $dir does not exist!");
		return;
	}

	foreach $mib (@mibs)
	{
		my $mibfile = "$dir/$mib";

		open(MIBFILE, "<$mibfile")
				or $nmisng->log->error("NMISNG::MIB: failed to read $mibfile: $!");
		while (defined(my $line = <MIBFILE>))
		{
			next if ($line =~ /^\#/);

			my ($name, $oid) = ($line =~ /\"(.*)\".*\"(.*)\"/);
			if (defined $name && defined $oid)
			{
				add_mapping($nmisng, $oid, $name);
			}
		}
		close(MIBFILE);
	}
}


# Add an entry into the NAMES <=> OIDS lookup table.
sub add_mapping
{
	my($nmisng, $oid, $name) = @_;

	if (defined($OIDS{$name}) && $OIDS{$name} ne $oid)
	{
		$nmisng->log->warn("NMISNG::MIB Name Conflict: $name refers to OID $oid as well as $OIDS{$name}");
	}
	elsif (defined($NAMES{$oid}) && $NAMES{$oid} ne $name)
	{
		$nmisng->log->warn("NMISNG::MIB OID Conflict: $oid has name $name as well as $NAMES{$oid}");
	}
	else
	{
		$OIDS{$name} = $oid;
		$NAMES{$oid} = $name;

		$nmisng->log->debug4("NMISNG::MIB added mapping $name -> $oid");
	}
}

# Take a name and return the unencoded OID for that name.  If the OID
# is not found, undef is returned.
# args: nmisng, name
sub name2oid
{
	my ($nmisng, $name) = @_;

	my $tmpname;
	my $tail;
	if ($name =~ /\./) {
		($tmpname, $tail) = split(/\./, $name, 2);
	} else {
		$tmpname = $name;
	}
	$tail = ".$tail" if $tail ne "";

	if (!$oid_config_loaded) {
		loadoid($nmisng);
	}
 	return "$OIDS{$tmpname}$tail" if (exists $OIDS{$tmpname});
	return undef;
}

# Take an OID and return a name.  If there is no hit the first time,
# trim off the last component and try again.  Repeat until found.  If
# no name is found, undef is returned.
# args: nmisng, oid
sub oid2name
{
	my ($nmisng, $tmpoid) = @_;

	if (!$oid_config_loaded) {
		loadoid($nmisng);
	}

	return $NAMES{$tmpoid} if (exists $NAMES{$tmpoid});

	my($tail, $tailoid);

	($tmpoid, $tail) = ($tmpoid =~ /(.*)\.(\d+)/ );
	while (($tmpoid ne "") && (!defined($NAMES{$tmpoid})))
	{
		($tmpoid, $tailoid) = ($tmpoid =~ /(.*)\.(\d+)/ );
		$tail = "$tailoid.$tail";
	}
	$tail = "" if $tail == 0;
	$tail =~ s/(.*)\.0$/$1/ ; # remove trailing zero
	return "$NAMES{$tmpoid}.$tail" if ($tmpoid ne "" and $tail ne "");
	return "$NAMES{$tmpoid}" if ($tmpoid ne "");
	return undef;
}

# arg: nmisng object
# returns hashref to oid->name, hashref to name->oid tables
sub loadoid
{
	my ($nmisng) = @_;

	if (!$oid_config_loaded)
	{
		my $C = $nmisng->config;
		foreach ( split /,/ , $C->{full_mib} )
		{
			loadoids_file($nmisng, $C->{mib_root}, $_ );
		}
		$oid_config_loaded = 1;
	}
	return (\%OIDS,\%NAMES);
}

1;
