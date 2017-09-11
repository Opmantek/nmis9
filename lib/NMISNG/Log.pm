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
# plus our more fine-grained debug1==debug, and debug2 to debug9,
# plus optional logprefix
package NMISNG::Log;
our $VERSION = "1.1.0";

# note that we need mojo 6.47 or newer: older api lacks is_level
# unfortunately there are no versions declared on any of the mojo packages,
# so we can't enforce that here
use Mojo::Base 'Mojo::Log';
use strict;

use Carp;

# extra attribute to distinguish between debug levels 1 to 9
__PACKAGE__->attr('detaillevel');
# and extra attribute for logprefix
__PACKAGE__->attr('logprefix');

# args: all attributes from mojo::log (i.e. path, level, format, handle),
# also extra level values,
# level: debug, info, warn, error, fatal, or 1..9.
# also accepts t(rue),  y(es) - both meaning debug==1,
# and verbose == 9
# and logprefix (default unset)
#
# to log to stderr: pass no path and no handle argument
# to log to stdout: pass no path but \*STDOUT as handle.
sub new
{
	my ($class, %args) = @_;
	my $detaillevel = 0;
	my $logprefix = $args{logprefix};

	# transform all nuances of the level argument
	my $parsed = parse_debug_level(debug => $args{level});

	# our default is 'info', not 'debug'
	if (!defined($parsed) or !$parsed)
	{
		$args{level} = 'info';
	}
	elsif ($parsed =~ /^[1-9]$/)
	{
		$args{level} = 'debug';
		$detaillevel = $parsed;
	}
	elsif ($parsed eq "debug")
	{
		$args{level} = 'debug';
		$detaillevel = 1;
	}
	else
	{
		$args{level} = $parsed;
	}

	my $self = bless($class->SUPER::new(%args), $class);
	$self->detaillevel($detaillevel);
	$self->logprefix($logprefix);

	return $self;
}


# (possibly overloaded) log function
# that adds logprefix to the first line if needed, and then delegates
# to the correct superclass function - which depends on mojo versions :-/
sub _log
{
	my ($self, $level, @lines) = @_;

	if (my $prefix = $self->logprefix)
	{
		$lines[0] = $prefix.$lines[0];
	}
	# at some point mojo::log moved from log() to _log()
	return Mojo::Log->can("log")?
			$self->SUPER::log($level => @lines)
			: $self->SUPER::_log($level => @lines);
}

# overloaded standard accessors
sub debug { return shift->_log(debug => @_); }
sub info { return shift->_log(info => @_); }
sub warn { return shift->_log(warn => @_); }
sub error { return shift->_log(error => @_); }
sub fatal { return shift->_log(fatal => @_); }

# plus our extra detaillevels for debug - bound to our log wrapper
sub debug9 { my $self = shift; $self->_log( debug => @_ ) if ($self->detaillevel >= 9); }
sub debug8 { my $self = shift; $self->_log( debug => @_ ) if ($self->detaillevel >= 8); }
sub debug7 { my $self = shift; $self->_log( debug => @_ ) if ($self->detaillevel >= 7); }
sub debug6 { my $self = shift; $self->_log( debug => @_ ) if ($self->detaillevel >= 6); }
sub debug5 { my $self = shift; $self->_log( debug => @_ ) if ($self->detaillevel >= 5); }
sub debug4 { my $self = shift; $self->_log( debug => @_ ) if ($self->detaillevel >= 4); }
sub debug3 { my $self = shift; $self->_log( debug => @_ ) if ($self->detaillevel >= 3); }
sub debug2 { my $self = shift; $self->_log( debug => @_ ) if ($self->detaillevel >= 2); }
sub debug1 { shift->_log(debug => @_); };

# wrapper around super's is_level
# understands: debug,info,warn,error,fatal, plus numeric 1..9
# returns true if the given level is same or higher than logger's configured level
# higher means here: verbosity. ie. debug3 includes debug2, debug, info, and all above.
sub is_level
{
	my ($self, $level) = @_;
	if (defined($level) && $level =~ /^[1-9]$/)
	{
		return ($level <= $self->detaillevel && $self->SUPER::is_level('debug'));
	}
	else
	{
		Carp::confess("dud level $level") if (!defined($level) or $level !~ /^(debug|info|warn|error|fatal)$/ );
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

# small package-function helper, replacement for the yucky setDebug thing
# translates given info and/or debug arguments
# into ONE log_level (== debug, info, warn, error, fatal, or 1..9.
# debug is the same as 1
# but fixme9: for compat-purposes we return 1, until everything stops comparing $C->{debug} numerically
#
# args: debug (optional), info (optional, ignored if debug is present)
# debug can be any of the known log_levels, or t(rue), y(es) - both meaning debug,
# and verbose - meaning 9.
# info can be t(rue), y(es), 1/0.
#
# returns: replacement or undef if nothing was recognised
sub parse_debug_level
{
	my (%args) = @_;
	my $level;

	if (defined (my $debug = $args{debug}))
	{
		if ($debug =~ /^\s*(yes|y|t|true|debug|1)\s*$/i)
		{
			# fixme9 see compat comment above			$level = 'debug';
			$level = 1;
		}
		elsif (lc($debug) eq "verbose")
		{
			$level = 9;
		}
		elsif ($debug =~ /^\s*([1-9]|info|warn|error|fatal)\s*$/i)
		{
			$level = lc($debug);
		}
	}
	# or info? can only switch level to info
	elsif (defined (my $info = $args{info}))
	{
		$level = "info" if ($info =~ /^\s*(1|t|true|y|yes)\s*$/i);
	}
	return $level;
}

1;
