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

# NMISNG log, adds extra functionality on top of Mojo log
package NMISNG::Log;
use Mojo::Base 'Mojo::Log';
use strict;

# Re-define Supported log levels
my $LEVEL = { debug9 => 1, debug8 => 2, debug7 => 3, debug6 => 4, debug5 => 5, debug4 => 6, debug3 => 7, debug2 => 8,
	debug => 9, info => 10, warn => 11, error => 12, fatal => 13 };

# Do any extra new stuff in here
# if debug=1-9 are set then level is set to debug[1-9] and output goes to stderr
# if info=X is set then output goes to stderr, level is set to info (for now, doesn't seem quite right)
sub new 
{
	my $class = shift;
	my (%args) = @_;
	my %callArgs = ();

	my $show_in_stdout = 0;
	my $level = $args{level};
	# caller doesn't set level but does set debug=1..9
	if( !$level && $args{debug} )
	{
		$show_in_stdout = 1;
		my $debug = $args{debug};
		$level = "debug";
		$level .= $debug if( $debug =~ /^[1-9]$/ );
	}
	elsif( !$level && $args{info} )
	{
		$show_in_stdout = 1;
		$level = "info";
	}

	$args{level} = $level;
	delete $args{path} if( $show_in_stdout );
	
	my $self = $class->SUPER::new( %args );
	
	return $self;
}
# add in our new extra debug levels
sub debug9 { shift->_log(debug9 => @_) }
sub debug8 { shift->_log(debug8 => @_) }
sub debug7 { shift->_log(debug7 => @_) }
sub debug6 { shift->_log(debug6 => @_) }
sub debug5 { shift->_log(debug5 => @_) }
sub debug4 { shift->_log(debug4 => @_) }
sub debug3 { shift->_log(debug3 => @_) }
sub debug2 { shift->_log(debug2 => @_) }

# similar to is_* or is_level (in the newer mojo), $module not used yet
# TODO: add in module level checks via config or cli, so that NMISNG::Node could be set to a higher level?
#  note: to make that work more overloading will have to be done as _message checks the current level
sub check_level 
{
	my ($self,$level,$module) = @_;
	return ($LEVEL->{$level} >= $self->level);
}

1;