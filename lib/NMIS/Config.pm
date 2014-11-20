#
## $Id: Config.pm,v 8.2 2011/08/28 15:11:06 nmisdev Exp $
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

package NMIS::Config;

use strict;
use Fcntl qw(:DEFAULT :flock);
use File::stat;

#  private data
# cache table
my $C_cache = undef; # configuration table cache
my $C_modtime = undef;
my %Table_cache = ();

# nmisdev 16Nov2010
# conf => identifier , could run multiple configs, default 'nmis'
# conf =>'nmis' for standard install, if you require to run another config or two..
# conf=>'clientA', dir=>'path to clientA config, file=>'name of clientA config file' 
# Create the class and bless the vars you want to "share"
 
sub new {
	my ($class,%arg) = @_;

	my $debug = $arg{debug} || 0;
	my $conf = $arg{conf} || 'nmis';			# default config name is 'nmis'
	my $file = $arg{file} || 'Config.$ext' if $conf eq 'nmis';
	my $dir = $arg{dir} || "$FindBin::Bin/../conf" if $conf eq 'nmis';

 my $ext = getExtension(dir=>'conf');
 $conf = 'nmis';			# default config name is 'nmis'
 $file = "Config.$ext" ;
 $dir =  '/usr/local/nmis8/conf';
	
	# check that config file exist and is readable.
	# 
	my $configfile = $dir.'/'.$file;
	if (not -e $configfile or not -f $configfile or not -r $configfile ) {
			die "Can't access configuration file $configfile: $!\n";					# return nothing and set error 
			return undef;
	}

	my $self = {
	   	conf => $conf,
	   	configfile => $configfile,
	   	debug => $debug
	};
	bless($self,$class);
	return	$self->loadConfTable();				# return a ref to the TableCache{$conf){config keys}=>config values
}

#!! nmisdev - changed config file format
# <> stripped on keys, as a key does not require to be subbed
# use <> on values to indicate that this value references a key
# and remove <> to look up replacment value by key ( this.value)

# $Table_cache{conf}{...} - all config cached here, indexed by hash key 'conf'
# return a ref to the config hash by config name ($conf) 

sub loadConfTable {
	my $self=shift;
	my $debug = $self->{debug};
	my $conf = $self->{conf};
	my $name;
	my $value;
	my $key;
	my $modtime;
	my $configfile = $self->{configfile};
	my $CC;

	# check cache is still valid. we stored mtime of file in cache

	if ($Table_cache{$conf}{mtime} ne '' and $Table_cache{$conf}{mtime} eq stat($configfile)->mtime) {
		$Table_cache{$conf}{isConfigCached} = 'true';
		$Table_cache{$conf}{CallCount}++;
		$C_cache = $Table_cache{$conf};
		return $C_cache;
	}

	# read fresh config file
	if ($CC = readConfigFile($self) ) {
		# create new table
		delete $Table_cache{$conf};
		# convert to single level
		for my $k (keys %{$CC}) {
			for my $kk (keys %{$CC->{$k}}) {
				$Table_cache{$conf}{$kk} = $CC->{$k}{$kk};
			}
		}
		# check for config variables and process each config element again, x2 to fix all back references
		foreach my $k ( keys %{$Table_cache{$conf}} ) {
			if ( $Table_cache{$conf}{$k} =~ m/<(.*)>/ ) {
			$Table_cache{$conf}{$k} = $` . $Table_cache{$conf}{$1} . $' ;
			}
		}
		foreach my $k ( keys %{$Table_cache{$conf}} ) {
			if ( $Table_cache{$conf}{$k} =~ m/<(.*)>/ ) {
			$Table_cache{$conf}{$k} = $` . $Table_cache{$conf}{$1} . $' ;
			}
		}
	
		$Table_cache{$conf}{debug} = $debug; # include debug setting in conf table
		$Table_cache{$conf}{conf} = $conf;
		$Table_cache{$conf}{configfile} = $configfile;
		$Table_cache{$conf}{auth_require} = (!getbool($Table_cache{$conf}{auth_require})) ? 0 : 1; # default true in Auth
		$Table_cache{$conf}{starttime} = scalar localtime();
		$Table_cache{$conf}{isConfigCached} = 'false';
		$Table_cache{$conf}{mtime} = stat($configfile)->mtime; # remember modified time
		$Table_cache{$conf}{fileLastModified} = scalar localtime($Table_cache{$conf}{mtime});

		$C_cache = $Table_cache{$conf};
		return $C_cache;
	}
	return undef; # failed
}
	

sub readConfigFile {
	my $self = shift;
	
	my $line;
	my %hash;

	my $configfile = $self->{configfile};

	if ( -r $configfile) {
		sysopen(FH, "$configfile", O_RDONLY )
			or warn " NMIS::Config readConfigFile: cannot open $configfile, $!\n";
		flock(FH, LOCK_SH) or warn " NMIS::Config readConfigFile cant lock file $configfile, $!\n";
		while (<FH>) { $line .= $_; }
		close FH;
		# convert data to hash
		%hash = eval $line;
	} else {
		warn "  NMIS::Config readConfigFile: Could not read $configfile content \n";
		return undef;
	}
# print "  NMIS::Config readConfigFile: read @{[ scalar keys %hash ]} records from $configfile\n";

	return \%hash;
}

1;
