#
## $Id: Connect.pm,v 1.2 2012/01/06 07:09:38 keiths Exp $
#
# THIS SOFTWARE IS NOT PART OF NMIS AND IS COPYRIGHTED, PROTECTED AND
# LICENSED BY OPMANTEK.  
# YOU MUST NOT MODIFY OR DISTRIBUTE THIS CODE
# 
# This code is NOT Open Source
# IT IS IMPORTANT THAT YOU HAVE READ CAREFULLY AND UNDERSTOOD THE END USER
# LICENSE AGREEMENT THAT WAS SUPPLIED WITH THIS SOFTWARE.   BY USING THE
# SOFTWARE  YOU ACKNOWLEDGE THAT (1) YOU HAVE READ AND REVIEWED THE LICENSE
# AGREEMENT IN ITS ENTIRETY, (2) YOU AGREE TO BE BOUND BY THE AGREEMENT, (3)
# THE INDIVIDUAL USING THE SOFTWARE HAS THE POWER, AUTHORITY AND LEGAL RIGHT
# TO ENTER INTO THIS AGREEMENT ON BEHALF OF YOU (AS AN INDIVIDUAL IF ON YOUR
# OWN BEHALF OR FOR THE ENTITY THAT EMPLOYS YOU )) AND, (4) BY SUCH USE,
# THIS AGREEMENT CONSTITUTES BINDING AND ENFORCEABLE OBLIGATION BETWEEN YOU
# AND OPMANTEK LTD. 
# Opmantek is a passionate, committed open source software company - we
# really are.  This particular piece of code was taken from a commercial
# module and thus we can't legally supply under GPL. It is supplied in good
# faith as source code so you can get more out of NMIS.  According to the
# license agreement you can not modify or distribute this code, but please
# let us know if you want to and we will certainly help -  in most cases
# just by emailing you a different agreement that better suits what you want
# to do but covers Opmantek legally too. 
# 
# contact Opmantek by emailing code@opmantek.com
# 
# 
# All licenses for all software obtained from Opmantek (GPL and commercial)
# are viewable at http://opmantek.com/licensing
#  
# *****************************************************************************
package NMIS::Connect;

$VERSION = "2.0.0";

use strict;
use lib "../../lib";

use CGI qw(:standard escape);

use Data::Dumper;
$Data::Dumper::Indent = 1;
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
	my $group = $args{group};
	my $data;
	#sumnodetable
	
	my $ST = loadTable(dir=>'conf',name=>'Servers');
	
	if ( lc($ST->{$server}{name}) eq lc($server) and $ST->{$server}{community} ne "" ) {
		my $curlcmd = "curl -k -d com=$ST->{$server}{community} -d func=$func -d group=\"$group\" -d conf=$ST->{$server}{config} -d format=$format -d type=send --user $ST->{$server}{user}:$ST->{$server}{passwd}  $ST->{$server}{protocol}://$ST->{$server}{host}:$ST->{$server}{port}/$ST->{$server}{cgi_url_base}/connect.pl";
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
		my $ext = getExtension(dir=>'conf');
		logMsg("ERROR issue with slave $server name or community, check Servers.$ext");
	}
}

sub getFileFromRemote {
	my %args = @_;
	my $file = $args{file};

	my $data = curlDataFromRemote(server => $args{server}, group => $args{group}, func => $args{func}, format => $args{format});
	if ( $data and $data !~ /SERVER ERROR|504 Gateway Time-out/ ) {
		open(OUT, ">",$file) or logMsg("Could not create $file: $!");
		flock(OUT, LOCK_EX);
		print OUT $data or logMsg("Could not write: $!"); 
		close(OUT);
		setFileProt($file);
		return 1;
	}
	elsif ( $data =~ /SERVER ERROR/ ) {
		logMsg("ERROR, $args{server} responded with ERROR: $data");
		return 0;		
	}
	else {
		logMsg("ERROR, no node data received from $args{server}");
		return 0;
	}
}

1;
