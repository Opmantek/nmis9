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
our $VERSION = "2.0.0";

# note that we need mojo 6.47 or newer: older api lacks is_level
# unfortunately there are no versions declared on any of the mojo packages,
# so we can't enforce that here...nor can we cleanly distinguish between 7.x and 8.x :-(
use Mojo::Base 'Mojo::Log';
use strict;
use List::MoreUtils;
use File::Basename;
use Carp;
use feature 'state';

# extra attribute to distinguish between debug levels 1 to 9
__PACKAGE__->attr('detaillevel');
# and extra attribute for logprefix
__PACKAGE__->attr('logprefix');
# and an extra attribute to track the required argument order for _log :-(
__PACKAGE__->attr('bottomsup');

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

	# _log in 7.x takes level, message(s), but 8.x wants messages, level. meh!
	# 'thanks' to no versions in any Mojo module whatsoever we've got
	# to guess what vintage super is. we also must do that guesswork
	# before modifying the format callback, as it relies on checking
	# if super uses the yyyy-mm-dd time format
	#$self->bottomsup(&{$self->SUPER::format()}(0,"debug","message")
	#								 =~ /^\[1970-/? 1 : 0);
	
	## now overload the standard format function to avoid the undesirable
	## mojo 8.x format. basically a clone of _default from 7.61.
	$self->format(sub {
		'[' . localtime(shift) . '] [' . shift() . '] ' . join "\n", @_, '';
								});

	return $self;
}

# overloaded log function
# that adds logprefix to the first line if needed, and then delegates
# to the correct superclass function - which depends on mojo versions :-/
# for mojo 8.x it also enforces the level logic as that was moved to the
# front end methods...
sub _log
{
	my ($self, $level, @lines) = @_;

	# logic was in _message before 8.x
	return unless $self->is_level($level);

	my $prefix = $self->logprefix;
	if ($prefix)
	{
		# can be coderef, at this point we know that we're going to be logging
		# so we can execute the coderef 
		if( ref($lines[0]) eq 'CODE' ) {
			$lines[0] = $lines[0]();
		}
		$lines[0] = $prefix.$lines[0];
	}

	push @lines, $level;
	# at some point mojo::log moved from log() to _log()
	return Mojo::Log->can("log")?
			$self->SUPER::log(@lines) # definitely pre-7.61
			: $self->SUPER::_log($self->bottomsup? (@lines) : (@lines)); # confuse a cat!
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

# small package-function helper (replaces nmisng::util::setDebug())
# which translates given info and/or debug arguments
# into ONE log_level (== debug, info, warn, error, fatal, or 1..9.
# debug is the same as 1 but for compat-purposes we return 1
#
# args: debug (optional), info (optional, ignored if debug is present, fixme9: no longer supported/passed in)
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

# combine level and detaillevel into an acceptable input for parse_debug_level
# args: none
# returns: string (== debug, info, warn, error, fatal, or 1..9)
sub unparse_debug_level
{
	my ($self) = @_;
	my $curlevel  = $self->level;
	my $curdetail = $self->detaillevel;

	if ($curlevel eq "debug")
	{
		return ($curdetail > 0? $curdetail : "debug");
	}
	else
	{
		return $curlevel;
	}
}


# helper method that changes to a new level
# args: level (anything that parse_debug_level understands)
# returns: previous level
sub new_level
{
	my ($self,$unparsed) = @_;
	my $previous = $self->unparse_debug_level; # for future calls

	my $newlevel = my $curlevel = $self->level;	# that's the mojo level, no detaillevel
	my $newdetail = my  $curdetail = $self->detaillevel; # that's our extra

	if (defined(my $parsed = parse_debug_level(debug => $unparsed)))
	{
		if ($parsed =~ /^[1-9]$/)
		{
			$self->level('debug');
			$self->detaillevel($parsed);
		}
		elsif ($parsed eq "debug")
		{
			$self->level('debug');
			$self->detaillevel(1);
		}
		else
		{
			$self->level($parsed);
			$self->detaillevel(0);
		}
	}
	return $previous;
}

# helper method that changes verbosity up or down
# also returns the next more or less verbose setting,
# jumping levels where applicable.
#
# args: positive or negative number (value is ignored, sign counts)
# returns: nothing
sub change_level
{
	my ($self,$wantmorenoise) = @_;
	my $curlevel = $self->level;	# that's the mojo level, no detaillevel
	my $curdetail = $self->detaillevel; # that's our extra

	return if (!$wantmorenoise); # want neg or pos, we bail on undef or zero

	my @knownlevels = (qw(debug info warn error fatal));
	my $curidx  = List::MoreUtils::first_index { $curlevel eq $knownlevels[$_] } (0..$#knownlevels);
	# dud?
	return if ($curidx < 0);

	if ($wantmorenoise > 0)
	{
		if ($curidx == 0)
		{
			# level already debug, cannot be more noisy
			# but debug detail can go up
			$self->detaillevel($curdetail+1) if ($curdetail < 9);
		}
		else
		{
			# new noisier level...
			$self->level($knownlevels[$curidx-1]);
			# ...and if we've reached debug land, set the detail level
			$self->detaillevel( $curidx == 1? 1 : 0);
		}
	}
	else
	{
		# already on fatal? cannot be less noisy, debug details unchangable too
		# inbetween? one level up, debug details unchanged
		# level debug and details > 1? stay there, change details,
		# level debug, details 1, switch to info
		if ($curidx == 0 && $curdetail > 1)
		{
			$self->detaillevel($curdetail-1);
		}
		elsif (($curidx == 0 && $curdetail == 1)
					 || ($curidx < $#knownlevels))
		{
			$self->level($knownlevels[$curidx+1]);
			$self->detaillevel(0);
		}
	}
}

# this function produces a simple trace of the stack trace
# args: none
# returns: string with trailing whitespace
#
# string format: filename#lineno!function#lineno!...
# filename is basename'd, functions have their main:: removed
sub trace
{
	my (%args) = @_;

	# look at up to 10 frames
	my @frames;
	for my $i (0..10) # 0 is this function but we need the line nr for frame 1
	{
		my @oneframe = caller($i);
		last if (!@oneframe);

		my ($filename,$lineno,$subname) = @oneframe[1,2,3];

		$subname =~ s/^main:://;			# not useful
		# keep the try invocation, but not "try {...}", ditto for catch
		$subname =~ s/^(try|catch)\s+\{\.{3}\}\s*$/$1/;
		$frames[$i]->{subname} = $subname;

		$frames[$i+1]->{lineno} = $lineno; # save in outer frame
		$frames[$i+1]->{filename} = $filename;
	}
	shift @frames;								# ditch empty zeroth frame

	for my $i (0..$#frames)
	{
		# ditch eval and try::tiny related wrapping frames
		# also ditch the one frame you get at the end of try/catch
		$frames[$i]->{skip}=1 if (
			( $frames[$i]->{subname}
				&& $frames[$i]->{subname} =~ /^(\(eval\)|Try::Tiny::try|Try::Tiny::catch)/)
			|| ($i > 0
					&& $frames[$i-1]->{subname}
					&& $frames[$i-1]->{subname} =~ "Try::Tiny::(try|catch)"));
	}

	return join("!", map {
		$_->{skip}? () :
				($_->{subname}||basename($_->{filename})).'#'.$_->{lineno} }
							(reverse @frames)) . " ";
}

1;
