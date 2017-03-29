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
#
# NMISNG log: adds extra functionality on top of Mojo log
# supports mojo's log levels (debug, info, warn, error and fatal)
# plus our more fine-grained debug1==debug, and debug2 to debug9
package NMISNG::Log;
use Mojo::Base 'Mojo::Log';
use strict;


# extra attribute to distinguish between debug levels 1 to 9
__PACKAGE__->attr('detaillevel');

# args: all attributes from mojo::log (i.e. path, level, format, handle),
# also extra level values.
# level: debug, info, warn, error, fatal, or 1..9.
# also accepts t(rue),  y(es) - both meaning debug==1, and verbose == 9
#
# to log to stderr: pass no path and no handle argument
# to log to stdout: pass no path but \*STDOUT as handle.
sub new
{
	my ($class, %args) = @_;
	my $level = $args{level};
	my $detaillevel = 0;

	# transform extra level arguments into extra knowledge
	# our default is 'info', not 'debug'
	if (!defined($level) or $level eq '')
	{
		$args{level} = 'info';
	}
	elsif ($level eq 'verbose')
	{
		$args{level} = 'debug';
		$detaillevel = 9;
	}
	elsif ($level =~ /^[1-9]$/)
	{
		$args{level} = 'debug';
		$detaillevel = $level;
	}
	elsif ($level =~ /^(debug|y|yes|t|true)$/i)
	{
		$args{level} = 'debug';
		$detaillevel = 1;
	}

	my $self = bless($class->SUPER::new(%args), $class);
	$self->detaillevel($detaillevel);
	return $self;
}

# our extra detaillevels for debug
sub debug9 { my $self = shift; $self->log( debug => @_ ) if ($self->detaillevel >= 9); }
sub debug8 { my $self = shift; $self->log( debug => @_ ) if ($self->detaillevel >= 8); }
sub debug7 { my $self = shift; $self->log( debug => @_ ) if ($self->detaillevel >= 7); }
sub debug6 { my $self = shift; $self->log( debug => @_ ) if ($self->detaillevel >= 6); }
sub debug5 { my $self = shift; $self->log( debug => @_ ) if ($self->detaillevel >= 5); }
sub debug4 { my $self = shift; $self->log( debug => @_ ) if ($self->detaillevel >= 4); }
sub debug3 { my $self = shift; $self->log( debug => @_ ) if ($self->detaillevel >= 3); }
sub debug2 { my $self = shift; $self->log( debug => @_ ) if ($self->detaillevel >= 2); }
sub debug1 { shift->log(debug => @_); };

# wrapper arount super's is_level
# understands: debug,info,warn,error,fatal, plus numeric 1..9
# returns true if the given level is same or higher than logger's configured level
# higher means here: verbosity. ie. debug3 includes debug2, debug, info, and all above.
sub is_level
{
	my ($self, $level) = @_;
	if ($level =~ /^[1-9]$/)
	{
		return ($level <= $self->detaillevel && $self->SUPER::is_level('debug'));
	}
	else
	{
		return $self->SUPER::is_level($level);
	}
}

# this method forces the log handle to be reopened
sub reopen
{
	my ($self) = @_;
	return if (!$self->SUPER::path); # is it using an unnamed handle? can't reopen anything in this case

	# depending on what version of mojo::log you're using, it may or may not 
	# support closing/reopening handles at all.
	my $oldhandle = $self->SUPER::handle;
	close $oldhandle if ($oldhandle);
	# this is a workaround borrowed from Mojo::Log::Clearable
	delete $self->{handle};	 # ugly, but using the accessor to blank this DOES NOT WORK. (ie. $self->SUPER::handle(undef);)
	# reason: mojo::base runs the has/attr callback only if there is NO value. undef is a value.
	return;
}


1;
