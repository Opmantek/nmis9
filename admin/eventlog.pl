#!/usr/bin/perl
#
## $Id: modelcheck.pl,v 1.1 2011/11/16 01:59:35 keiths Exp $
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

use FindBin;
use lib "$FindBin::Bin/../lib";
 
use strict;
use func;
use NMIS;

if ( $ARGV[0] eq "" ) {
	print <<EO_TEXT;
$0 Will search the nmis event log and display human readable timestamps

usage: $0 search=<search string> [logs=all]
search can be a partial string or regular expression.
logs all will look in all rotated event log files in the folder.

eg: $0 search="router1|router2|switch3" logs=all
eg: $0 search="Node Down|Node Up" logs=all

EO_TEXT
	exit 1;
}

my %arg = getArguements(@ARGV);

# Set debugging level.
my $debug = setDebug($arg{debug});
$debug = 1;

my $C = loadConfTable(conf=>$arg{conf},debug=>$arg{debug});

if ($arg{logs} eq "all") {
	opendir (DIR, $C->{log_root});
	my @dirlist = sort (readdir DIR);
	closedir DIR;

	for ( my $index = 0; $index <= $#dirlist; ++$index ) {
		if ( $dirlist[$index] =~ /^event\.log/ ) {
			processLogFile(file => "$C->{log_root}/$dirlist[$index]");
			print "\n";
		}
	}
}
else {
	processLogFile(file => "$C->{log_root}/event.log");
}

sub processLogFile {
	my %args = @_;
	my $file = $args{file};
	print "Processing $file\n";
	open(LOG,$file) or die "ERROR with $file: $!\n";
	while (<LOG>) {
		if ( $arg{search} eq "" or $_ =~ /$arg{search}/ ) {
			chomp;
			my @tokens = split(/,/,$_);
			print returnDateStamp($tokens[0]). ",$_\n";
		}
	}
}

