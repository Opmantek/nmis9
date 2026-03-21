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
package NMISCGI;
our $VERSION = "9.6.5";

use strict;
use CGI qw(:standard *table *Tr *td *form *Select *div);
use NMISNG::Util;
use NMISNG::Auth;

sub initialise {
	my (%opts) = @_;

	my $q = new CGI;
	my $Q = $q->Vars;
	$Q = NMISNG::Util::filter_params($Q) unless $opts{skip_filter};

	my $C = NMISNG::Util::loadConfTable(debug => $Q->{debug});
	return undef unless $C;

	my $headeropts = {type => 'text/html', expires => 'now'};

	return { q => $q, Q => $Q, C => $C, headeropts => $headeropts };
}

sub authenticate {
	my ($args, %opts) = @_;

	my ($C, $headeropts) = @{$args}{qw(C headeropts)};

	$C->{auth_require} = 0 if ($opts{allow_cli} && @ARGV);

	my $AU = NMISNG::Auth->new(conf => $C);

	if ($AU->Require) {
		unless ($AU->loginout(
			type       => $opts{auth_type},
			username   => $opts{auth_username},
			password   => $opts{auth_password},
			headeropts => $headeropts
		)) {
			return undef;
		}
	}

	if ($opts{set_user} && !$AU->Require) {
		$AU->SetUser($opts{set_user});
	}

	if (defined($opts{cluster_id}) && $opts{cluster_id} ne $C->{cluster_id}) {
		return undef;
	}

	$args->{AU} = $AU;
	return $args;
}

1;
