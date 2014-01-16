#
## $Id: Mib.pm,v 8.3 2012/08/27 21:59:11 keiths Exp $
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

package Mib;

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION);

use Exporter;

$VERSION = "1.0.1";

@ISA = qw(Exporter);

@EXPORT = qw(loadoids_file name2oid oid2name add_mapping);

#
use func; # common functions

#
my $oid_cache_loaded = 0;
my $oid_config_loaded = 0;

my %ENUMS;
my %TYPES;

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


#===================================================================================
### Partial created by:  Alan Nichols <alan.nichols@sun.com>
###
### Based on work by:
### Simon Leinen  <simon@switch.ch>
### Mike Mitchell <mcm@unx.sas.com> (MIB parsing)
#===================================================================================
#
# subroutine to load in a list of SNM .oid file, into the package 
# associatve arrays OIDS and NAMES.
#
sub loadoids_file {
    my($dir, @mibs) = @_;
    my($mib);
    return logMsg("Directory $dir does not exist") unless (-d $dir);
    foreach $mib (@mibs) {
        my($mibfile) = "$dir/$mib";
        if ( -f $mibfile) {
            open(MIBFILE, "<$mibfile");
            my($line);
            while(defined($line = <MIBFILE>)) {
                if (!($line =~ /^\#/)) {
                    my ($name, $oid) = ($line =~ /\"(.*)\".*\"(.*)\"/);
                    add_mapping($oid, $name, undef);
                }
            }
            close(MIBFILE);
        } else {
            logMsg("ERROR mibfile $mibfile does not exist");
        }
    }
}

#
# Add an entry into the NAMES <=> OIDS <=> TYPES lookup table.

sub add_mapping($$$) {
    my($oid, $name, $type) = @_;
    if (defined($OIDS{$name}) && $OIDS{$name} ne $oid) {
		my $msg = "Name Conflict: $name refers to OID $oid as well as $OIDS{$name}";
		logMsg($msg);
		dbg($msg);
    } elsif (defined($NAMES{$oid}) && $NAMES{$oid} ne $name) {
		my $msg = "OID Conflict: $oid has name $name as well as $NAMES{$oid}";
		logMsg($msg);
		dbg($msg);
    } else {
	$OIDS{$name} = $oid;
	$NAMES{$oid} = $name;
	$TYPES{$oid} = $type if defined($type);
	dbg("$name -> $oid, $type",4) ;
    }
}

# Take a name and return the unencoded OID for that name.  If the OID
# is not found, undef is returned.

sub name2oid{
    my($name) = @_; 
	my $tmpname;
	my $tail; 
    if ($name =~ /\./) {
		($tmpname, $tail) = split(/\./, $name, 2);
	} else {
		$tmpname = $name;
	}
	$tail = ".$tail" if $tail ne "";

	if (!$oid_config_loaded) {
		loadoid();
	}
 	return "$OIDS{$tmpname}$tail" if (exists $OIDS{$tmpname});
	return undef;
}

# Take an OID and return a name.  If there is no hit the first time,
# trim off the last component and try again.  Repeat until found.  If
# no name is found, undef is returned.

sub oid2name {
    my($tmpoid) = @_;
    return $NAMES{$tmpoid} if (exists $NAMES{$tmpoid});

    my($tail, $tailoid);
    ($tmpoid, $tail) = ($tmpoid =~ /(.*)\.(\d+)/ );
    while (($tmpoid ne "") && (!defined($NAMES{$tmpoid}))) {
		($tmpoid, $tailoid) = ($tmpoid =~ /(.*)\.(\d+)/ );
		$tail = "$tailoid.$tail";
    }
	$tail = "" if $tail == 0;
	$tail =~ s/(.*)\.0$/$1/ ; # remove trailing zero
	return "$NAMES{$tmpoid}.$tail" if ($tmpoid ne "" and $tail ne "");
	return "$NAMES{$tmpoid}" if ($tmpoid ne "");
	return undef;
}

sub loadoid {
	if (!$oid_config_loaded) {
		my $C = loadConfTable();
		foreach ( split /,/ , $C->{full_mib} ) {
			if ( ! -r "$C->{mib_root}/$_" ) { 
				 logMsg("mib file $C->{mib_root}/$_ not found");
			}
			else {
				loadoids_file( $C->{mib_root}, $_ );
			}
		}
		$oid_config_loaded = 1;
	}
	return \%OIDS,\%NAMES;
}

#sub writeCache {
#	my $name = shift;
#	my $oid = shift;
#	print ">> write oid cache ,$NMIS::config{mib_root}/nmis-oid-cache.oid, $name $oid\n";
#	open(CACHE, ">>","$NMIS::config{mib_root}/nmis-oid-cache.oid") || warn "cant open oid cache file: $!";
#	print CACHE "\"$name\"\t\"$oid\"\n" || warn "cant write to oid cache: $!";
#	close(CACHE);
#}
#=============
