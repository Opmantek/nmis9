#
## $Id: License.pm,v 1.2 2011/11/25 08:50:01 keiths Exp $
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
package NMIS::License;

require 5;

use strict;
use Fcntl qw(:DEFAULT :flock);
use Time::ParseDate;
use func;

# Create the class and bless the vars you want to "share"
sub new {
	my ($class,%arg) = @_;

	my $debug = undef;
	if ( defined $arg{debug} ) { $debug = $arg{debug} }
	elsif ( not defined $debug ) { $debug = 0 }

	my $file = undef;
	if ( defined $arg{file} ) { $file = $arg{file} }
	elsif ( not defined $file ) { $file = "license.conf" }

	my $dir = undef;
	if ( defined $arg{dir} ) { $dir = $arg{dir} }
	elsif ( not defined $dir ) { $dir = "$FindBin::Bin/../../nmis8/conf" }

	my $self = {
	   	details => {},
	   	check => {},
	   	dir => $dir,
	   	file => $file,
	   	debug => $debug
	};
	bless($self,$class);

	$self->loadLicense();

	return $self;
}

sub checkLicense {
	my ($self,%arg) = @_;
	my $valid = 0;
	my $message;
	
	#Currently email and country are considered mandatory
	my @mandatory = qw(email country);
	
	foreach my $man (@mandatory) {
		if ( $self->{details}{$man} ne "" ) {
			$valid = 1;
			$message = "License $man is OK";
		}
		else {
			$valid = 0;
			$message = "License $man is NOT OK";		
		}		
	}
	
	return ($valid,$message);	
}

sub updateLicense {
	my $self = shift;
	my $dir = shift;
	my $file = shift;

	if ( $self->{details}{created} eq "" ) {
		$self->{details}{created} = returnDateStamp;
	}
	$self->{details}{updated} = returnDateStamp;
	writeTable(dir=>'conf',name=>"License",data=>$self->{details});

}


sub loadLicense {
	my $self = shift;
	my $dir = shift;
	my $file = shift;

	$self->{details} = loadTable(dir=>'conf',name=>"License");

}

1;
                                                                                                                                                                                                                                                        
