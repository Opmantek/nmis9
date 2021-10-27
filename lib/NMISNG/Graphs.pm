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

# Package giving access to functions in NMIS::Graph but saving the graph data
# Allows reuseobjects and nmisng
# TODO: Add other functions
package NMISNG::Graphs;
our $VERSION = "1.0.0";

use strict;
use Data::Dumper;
use URI::Escape;

use NMISNG::Sys;
use NMISNG::Util;
use NMISNG::Outage;
use Compat::Timing;

# params:
#  log - NMISNG::Log object to log to, required.
#  nmisng - nmisng object, required.
sub new
{
	my ( $class, %args ) = @_;

	#die "Log required" if ( !$args{log} );
    #die "Nmisng object required" if ( $args{nmisng} ne "NMISNG" );

	my $self = bless(
		{
			_log     => $args{log},
			_nmisng  => $args{nmisng},           # sub plugins populates that on the go
		},
		$class
			);

	# weaken the reference to nmisx to avoid circular reference problems
	# not sure if the check for isweak is required
	Scalar::Util::weaken $self->{_nmisng} if ( $self->{_nmisng} && !Scalar::Util::isweak( $self->{_nmisng} ) );

    my $cachedir = $self->{_nmisng}->config->{'web_root'}."/cache";
	NMISNG::Util::createDir($cachedir) if (!-d $cachedir);
	# do we want to reuse an existing, 'new enough' graph?
	opendir(D, $cachedir);
	$self->{recyclables} = readdir(D);
	closedir(D);
    
	return $self;
}

# Return nmisng
sub nmisng
{
	my ( $self, %args ) = @_;
	return $self->{_nmisng};
}

# Return log
sub log
{
	my ( $self, %args ) = @_;
	return $self->{_log};
}

# Return nmis conf
sub nmis_conf
{
	my ( $self, %args ) = @_;
	unless (defined($self->{_nmis_conf})) {
		$self->{_nmis_conf} = $self->nmisng->config // NMISNG::Util::loadConfTable();
	}
	return $self->{_nmis_conf};
}

# REPLACE Compat::NMIS::htmlGraph
# produce clickable graph and return html that can be pasted onto a page
# rrd graph is created by this function and cached on disk
#
# args: node/group OR sys, intf/item, cluster_id, graphtype, width, height (all required),
#  start, end (optional),
#  only_link (optional, default: 0, if set ONLY the href for the graph is returned),
# returns: html or link/href value
sub htmlGraph
{
	my ($self, %args) = @_;

	my $C = $self->nmis_conf();

	my $graphtype = $args{graphtype};
	my $group = $args{group};
	my $node = $args{node};
	my $intf = $args{intf};
	my $item  = $args{item};
	my $parent = $args{cluster_id} || $C->{cluster_id}; # default: ours
	my $width = $args{width}; # graph size
	my $height = $args{height};
	my $inventory = $args{inventory};
	my $omit_fluff = NMISNG::Util::getbool($args{only_link}); # return wrapped <a> etc. or just the href?
	
	my $sys = $args{sys};
	if (ref($sys) eq "NMISNG::Sys" && ref($sys->nmisng_node))
	{
		$node = $sys->nmisng_node->name;
		if (!$inventory) {
			$self->nmisng->log->debug($graphtype . " index " . $intf);
			$inventory = $sys->inventory(concept => $graphtype, index => $intf);
		}
	}
	my $urlsafenode = uri_escape($node);
	my $urlsafegroup = uri_escape($group);
	my $urlsafeintf = uri_escape($intf);
	my $urlsafeitem = uri_escape($item);

	my $target = $node || $group; # only used for js/widget linkage
	my $clickurl = "$C->{'node'}?act=network_graph_view&graphtype=$graphtype&group=$urlsafegroup&intf=$urlsafeintf&item=$urlsafeitem&cluster_id=$parent&node=$urlsafenode";

	my $time = time();
	my $graphlength = ( $C->{graph_unit} eq "days" )?
			86400 * $C->{graph_amount} : 3600 * $C->{graph_amount};
	my $start = $args{start} || time-$graphlength;
	my $end = $args{end} || $time;

	# where to put the graph file? let's use htdocs/cache, that's web-accessible
	my $cachedir = $C->{'web_root'}."/cache";
	#NMISNG::Util::createDir($cachedir) if (!-d $cachedir);

	# we need a time-invariant, short and safe file name component,
	# which also must incorporate a server-specific bit of secret sauce
	# that an external party does not have access to (to eliminate guessing)
	my $graphfile_prefix = Digest::MD5::md5_hex(
		join("__",
				 $C->{auth_web_key},
				 $group, $node, $intf, $item,
				 $graphtype,
				 $parent,
				 $width, $height));

	# do we want to reuse an existing, 'new enough' graph?
	#opendir(D, $cachedir);
    my @recyclables = grep(/^$graphfile_prefix/, $self->{recyclables});
	#my @recyclables = grep(/^$graphfile_prefix/, readdir(D));
	#closedir(D);

	my $graphfilename;
	my $cachefilemaxage = $C->{graph_cache_maxage} // 60;

	for my $maybe (sort { $b cmp $a } @recyclables)
	{
		next if ($maybe !~ /^\S+_(\d+)_(\d+)\.png$/); # should be impossible
		my ($otherstart, $otherend) = ($1,$2);

		# let's accept anything newer than 60 seconds as good enough
		my $deltastart = $start - $otherstart;
		$deltastart *= -1 if ($deltastart < 0);
		my $deltaend = $end - $otherend;
		$deltaend *= -1 if ($deltaend < 0);

		if ($deltastart <= $cachefilemaxage && $deltaend <= $cachefilemaxage)
		{
			$graphfilename = $maybe;
			$sys->nmisng->log->debug2("reusing cached graph $maybe for $graphtype, node $node: requested period off by "
																.($start-$otherstart)." seconds")
					if ($sys);

			last;
		}
	}

	# nothing useful in the cache? then generate a new graph
	if (!$graphfilename)
	{
		$graphfilename = $graphfile_prefix."_${start}_${end}.png";
		$sys->nmisng->log->debug2("graphing args for new graph: node=$node, group=$group, graphtype=$graphtype, intf=$intf, item=$item, cluster_id=$parent, start=$start, end=$end, width=$width, height=$height, filename=$cachedir/$graphfilename")
				if ($sys);

		my $target = "$cachedir/$graphfilename";
		my $result = NMISNG::rrdfunc::draw(sys => $sys,
																			 node => $node,
																			 group => $group,
																			 graphtype => $graphtype,
																			 intf => $intf,
																			 item => $item,
																			 start => $start,
																			 end =>  $end,
																			 width => $width,
																			 height => $height,
																			 filename => $target,
																			 inventory => $inventory);
		return qq|<p>Error: $result->{error}</p>| if (!$result->{success});
		NMISNG::Util::setFileProtDiag($target);	# to make the selftest happy...
	}

	# return just the href? or html?
	return $omit_fluff? "$C->{'<url_base>'}/cache/$graphfilename"
			: qq|<a target="Graph-$target" onClick="viewwndw(\'$target\',\'$clickurl\',$C->{win_width},$C->{win_height})"><img alt='Network Info' src="$C->{'<url_base>'}/cache/$graphfilename"></img></a>|;
}

1;
