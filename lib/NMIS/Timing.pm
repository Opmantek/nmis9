#
#
## $Id: Timing.pm,v 8.3 2012/01/04 04:57:42 keiths Exp $
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

package NMIS::Timing;

require 5;

use strict;
use Time::HiRes;

# Create the class and bless the vars you want to "share"
sub new {
	my $class = shift;
	my $self = {
	   	time => Time::HiRes::time(),
	   	mark => undef
   	};
   	bless $self,$class;
}

sub elapTime {
	my ($self) = @_;
	return sprintf("%.2f", Time::HiRes::tv_interval([$self->{time}]))
}

sub resetTime {
	my ($self) = @_;
	$self->{time} = Time::HiRes::time();
}

sub markTime {
	my ($self) = @_;
	$self->{mark} = Time::HiRes::time();
	return sprintf("%.2f", Time::HiRes::tv_interval([$self->{time}]))
}

sub deltaTime {
	my ($self) = @_;
	return sprintf("%.2f", Time::HiRes::tv_interval([$self->{mark}]))
}

1;
