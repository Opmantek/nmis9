#
## $Id: Toolbar.pm,v 8.2 2011/08/28 15:11:06 nmisdev Exp $
#
#    Toolbar.pm - Toolbar and button authorization libraries and methods
#
#    Copyright (C) 2005 Robert W. Smith
#        <rwsmith (at) bislink.net> http://www.bislink.net
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program; if not, write to the Free Software
#    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#
#    Enough of the legal stuff.
#
##############################################################################
#
#   Toolbar.pm
#   Toolbar.pm is a OO Perl module implementing a class module with methods
#   to read and parse the conf/toolset.csv file. The file and this class 
#   serves two purposes:
#     1. to display active and inactive buttons as defined by the privilege 
#        level, level0 through level5
#     2. to check user authorization to access buttons and functions
#        as defined by the privilege level
#
#   I originally wrote this modules for a client that needed user-level
#   authentication and authorization with the NMIS package to segregate the
#   server groups (engineers) from the router groups and then some.
#
#   This module is used in the first instance to display buttons:
#
#   use NMIS::Auth;
#   use NMIS::User;
#   use NMIS::Toolbar;
#
#   my $auth = NMIS::Auth->new();
#   my $user = NMIS::User->new();
#   my $tb   = NMIS::Toolbar->new();
#
#   if ( $auth->Required ) {
#      $tb->SetLevel($user->privlevel);
#      $tb->LoadButtons($NMIS::config{'nmis_conf'}."/toolset.csv");
#      $tb->DisplayButtons("action");
#   }
#
#   I added the ability to use simple Perl scalars in the conf/toolset.csv file.
#   It's not pretty but it does the trick--pass the scalars as a name-value hash
#   to the private attibute $tb->{_var} = { node => $node };
#   The DisplayButton routine will then bring the scalar $node into scope through
#   an eval trick.
#   This is the method and trick is used to create the ping and trace buttons, 
#   see nmiscgi.pl::printNodeType
#
#   if ( $auth->Required ) {
#      $tb->SetLevel($user->privlevel);
#      $tb->LoadButtons($NMIS::config{'nmis_conf'}."/toolset.csv");
#      $tb->{_var} = { node => $node };
#      $tb->DisplayButtons("tool");
#   }
#
#  In the second instance, we check for user authorization
#
#   if ( $auth->Require ) {
#      # CheckAccess will throw up a web page and stop if access is not allowed
#      $auth->CheckAccess($user, "nmisconf") or die "Attempted unauthorized access";
#   }
#
#
# update ehg 20jul2008 added bgroup 'disabled', keep button config in toolset.csv, but do not use.
#
package NMIS::Toolbar;

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION);

use Exporter;

$VERSION = "0.1.2";

@ISA = qw(Exporter);

@EXPORT = qw(
	SetLevel
	LoadButtons
	DisplayButtons
	CheckAccess
);

@EXPORT_OK = qw( );

#use strict;
use lib "../../lib";

#import CPAN modules
use CGI qw(:standard);

# import NMIS modules
use csv;

sub _init_toolbar;

#
# nauth constructor to create object to hold security and authentication
# attributes and methods
#

sub new {
	my $this = shift;
	my $class = ref($this) || $this;
	my $self = {
		buttons => undef,
		privlevel => undef,
		groups => undef,
		_print => undef,
		_vars => undef
	};
	bless $self, $class;
	&_init_toolbar($self);
	return $self;
}

# Initialize
# requires one parameter:
# @_[0] => Level -- the current privilege level of the user
# if level is not passed then they get the lowest level
#
sub _init_toolbar {
	my $self = shift;

	$self->{privlevel} = shift if @_;
	$self->{privlevel} = 5 unless defined $self->{privlevel} and $self->{privlevel};
	$self->{_print} = 1;
}

sub SetLevel {
	my $self = shift;
	return $self->{privlevel} = shift;
}


sub LoadButtons {
	my $self = shift;
	my $button_tab = shift; # filename of toolset
	my %buttons = ();

	# if bgroup=slaves, construct a toolbar from the slaves file
	if ( $button_tab =~ /slaves/ ) {
		my %st = loadCSV($button_tab, "Name", "\t") or warn "Cannot load buttons in LoadButtons";
		my $order=1;
		foreach my $n ( sort keys %st ) {
			$buttons{$n}{bgroup} = 'slaves';
			$buttons{$n}{button} = $n;
			$buttons{$n}{display} = uc($n);
			$buttons{$n}{level0} = 1;
			$buttons{$n}{level1} = 1;
			$buttons{$n}{level2} = 1;
			$buttons{$n}{level3} = 1;
			$buttons{$n}{level4} = 1;
			$buttons{$n}{level5} = 0;
			$buttons{$n}{needconfig} = 'no'; 
			$buttons{$n}{order} = $order++;
			$buttons{$n}{urlbase} = qq|$st{$n}{Protocol}://$st{$n}{Host}:$st{$n}{Port}$st{$n}{cgi_url_base}/nmiscgi.pl?file=$st{$n}{Conf}|;
			$buttons{$n}{urlquery} = '';
			$buttons{$n}{usetarget} = '_blank';
		}
	}
	else {
		%buttons = loadCSV($button_tab, "button", "\t") or warn "Cannot load buttons in LoadButtons";
	}

	%{$self->{buttons}} = %buttons if %buttons;
	$self->{button_tab} = $button_tab if %buttons;

	my $level = "level" . $self->{privlevel};
	foreach (keys %{$self->{buttons}} ) {

		next if $self->{buttons}{$_}{bgroup} eq 'disabled';			# ehg 20jul2008 ignore bgroup=disabled
		
		$self->{groups}{$self->{buttons}{$_}{bgroup}}++;

		$self->{buttons}{$_}{level0} = _setbool($self->{buttons}{$_}{level0});
		$self->{buttons}{$_}{level1} = _setbool($self->{buttons}{$_}{level1});
		$self->{buttons}{$_}{level2} = _setbool($self->{buttons}{$_}{level2});
		$self->{buttons}{$_}{level3} = _setbool($self->{buttons}{$_}{level3});
		$self->{buttons}{$_}{level4} = _setbool($self->{buttons}{$_}{level4});
		$self->{buttons}{$_}{level5} = _setbool($self->{buttons}{$_}{level5});
		$self->{buttons}{$_}{needconfig} = _setbool($self->{buttons}{$_}{needconfig});
		$self->{buttons}{$_}{urlquery} = "" if $self->{buttons}{$_}{urlquery} eq "null";
	}
	return 1;
}


sub DisplayButtons {
	my $self = shift;
	my $group = "";
	my $select = undef; # select buttons
	my $level = ""; # lowest level, ie. no access to buttons
	
	if ( @_ == 0 ) {
		1; # keep with defaults above
	} elsif ( @_ == 1 ) { 
		$group = shift;
	} elsif ( @_ == 2 ) { 
		$group = shift;
		$select = shift;
	} else {
		($group, $select, $level) = (@_);
	}

	$level = "level" . $level if $level;
	$level = "level" . $self->{privlevel} unless $level;

	my @output = ();
	my $myvars = "";
	my @groups = ();
	my $B = \%{$self->{buttons}};
	my $C = \%NMIS::config;
	my $urlbase = "";
	my $query = "";
	my $b_cnt = 0;
	push @groups, $group if ( $group );
	push @groups, (keys %{$self->{groups}}) unless $group;

	# Yuck! Some buttons (ping, trace) need variable extrapolation.
	# Pass in those variables as a NVP hash and create a series
	# of 'my $name=value;' declarations. This will be eval'ed in the
	# below loop to bring the variable into scope when performing
	# the urlquery extrapolation. rwsmith 050519.
	# Can anyone improve on this?
	#
	if ( defined $self->{_vars} ) {
		foreach (keys %{$self->{_vars}}) {
			$myvars .= "my \$".$_."=\"".$self->{_vars}{$_}."\";";
		}
	}
	foreach $g (@groups) {
		my %bord = ();
		foreach $b (keys %$B) {
			next unless $g eq $B->{$b}{bgroup};
			$bord{$B->{$b}{order}} = $b;
		}
		foreach $o (sort {$a <=> $b} keys %bord) {
			$b = $bord{$o};
			$urlbase = $query = "";
			next unless $g eq $B->{$b}{bgroup};
			next if ($select and not grep $b eq $_,@$select);
			next if $b eq "mtr" and getbool($C->{mtr},"invert");
			next if $b eq "lft" and getbool($C->{lft},"invert");
			if ( $B->{$b}{useconfig} ) {
				$urlbase = $C->{$B->{$b}{useconfig}}
			} else {
				if ( $B->{$b}{urlbase} =~ /^</ ) {
					$urlbase = $C->{$B->{$b}{urlbase}};
				} else {
					$urlbase = $B->{$b}{urlbase};
				}
				$urlbase .=  "/" . $B->{$b}{urlscript} if $B->{$b}{urlscript};
			}
			if ( $B->{$b}{needconfig} ) {
				$query = "file=".&main::conf ; # copy conf from main
			}
			if ( $B->{$b}{urlquery} ) {
				$query .= "&" if $query;
				$query .= $B->{$b}{urlquery};
			}
			# divide plugin buttons in multiple rows
			my $br = "";
			if ($group eq "plugin" and $b_cnt++ > 5) {$br = "</div><div class='as'>"; $b_cnt = 0;}
			# perform variable extrapolation on the query string
			# bring any variables into scope via the string $myvars
			#
			$query = eval $myvars . ' return "'.$query.'"';
			push @output, comment($@) if ($@ ne "");
			# fudge it for protocol handler
			if ($urlbase !~ /telnet|http/) {$query = "?$query" if $query;}
			if ( $B->{$b}{$level} ) {
				if ( $B->{$b}{usetarget} ne "") {
					push @output, a({href=>"$urlbase$query", class=>"b", target=>$B->{$b}{usetarget}},
						$B->{$b}{display}). "$br";
				} else {
					push @output, a({href=>"$urlbase$query", class=>"b"}, $B->{$b}{display})."$br";
				}
			} else {
				 
				push @output, span({class=>"inact"}, $B->{$b}{display}), "$br \n" 
						if ( getbool($C->{auth_buttons_visible}) );
				
			}
		}
	}
	return @output; # ready for print
}

sub CheckAccess {
	my $self = shift;
	my $cmd = shift;

	my $B = \%{$self->{buttons}};
	my $level = "level".$self->{privlevel};

	return $B->{$cmd}{$level} if defined $B->{$cmd}{$level};
	return 0;
}

# private routines here
 
sub _setbool {
	my $val = shift;
	return 1 if $val =~ /^[yt1].*/i;
	return 0; # otherwise
}

1;

