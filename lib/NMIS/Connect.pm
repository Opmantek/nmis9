#
## $Id: Connect.pm,v 1.2 2012/01/06 07:09:38 keiths Exp $
#
#  Copyright 1999-2011 Opmantek Limited (www.opmantek.com)
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
#
package NMIS::Connect;

$VERSION = "2.0.0";

use strict;
use lib "../../lib";

use CGI qw(:standard escape);

use Data::Dumper;
$Data::Dumper::Indent = 1;
use Time::HiRes qw(sleep);
use func;

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION);

use Exporter;

#! this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX)
use Fcntl qw(:DEFAULT :flock);

@ISA = qw(Exporter );

@EXPORT = qw(	
		curlDataFromRemote
		getFileFromRemote
	);

#============================================================

# create object
sub new {
	my $class = shift;
	my $self  = bless {
		requests => {}
    }, $class;

    return $self;
}

sub curlDataFromRemote {
	my %args = @_;
	my $server = $args{server};
	my $func = $args{func};
	my $format = $args{format};
	my $data;
	#sumnodetable
	
	my $ST = loadTable(dir=>'conf',name=>'Servers');
	
	if ( $ST->{$server}{name} eq $server and $ST->{$server}{community} ne "" ) {
		my $curlcmd = "curl -k -d com=$ST->{$server}{community} -d func=$func  -d format=$format -d type=send --user $ST->{$server}{user}:$ST->{$server}{passwd}  $ST->{$server}{protocol}://$ST->{$server}{host}:$ST->{$server}{port}/$ST->{$server}{cgi_url_base}/connect.pl";
		#open(IN, "$curlcmd  2>&1 |");
		open(IN, "$curlcmd 2>/dev/null |");
		#open(IN, "$curlcmd 2>/tmp/curl.err |");
		while (<IN>) {
			$data .= $_;
		}
		close(IN);
		return $data;
	}
	else {
		logMsg("ERROR issue with slave $server name or community, check Servers.nmis");
	}
}

sub getFileFromRemote {
	my %args = @_;
	my $file = $args{file};

	my $data = curlDataFromRemote(server => $args{server}, func => $args{func}, format => $args{format});
	if ( $data and $data !~ /SERVER ERROR|500 Internal Server Error/ ) {
		open(OUT, ">",$file) or logMsg("Could not create $file: $!");
		flock(OUT, LOCK_EX);
		print OUT $data or logMsg("Could not write: $!"); 
		close(OUT);
		setFileProt($file);
		return 1;
	}
	elsif ( $data =~ /SERVER ERROR|500 Internal Server Error/ ) {
		logMsg("ERROR, $args{server} responded with ERROR");
		return 0;		
	}
	else {
		logMsg("ERROR, no node data received from $args{server}");
		return 0;
	}
}

1;
