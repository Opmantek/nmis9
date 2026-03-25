package NMISCGI::Rrddraw;
our $VERSION = "9.6.5";
use strict;
use NMISNG::Util;
use NMISNG::rrdfunc;
use NMISNG::Sys;
use Compat::NMIS;
use Data::Dumper;
use CGI qw(:standard *table *Tr *td *form *Select *div);

sub runcgi {
	my ($args) = @_;
	my ($q, $Q, $C, $AU, $nmisng) = @{$args}{qw(q Q C AU nmisng)};
	my $headeropts = $args->{headeropts};

	&NMISNG::rrdfunc::require_RRDs;

	# select function
	if ($Q->{act} eq 'draw_graph_view')
	{
		rrdDraw(nmisng => $nmisng, headeropts => $headeropts,
			obj       => $Q->{obj},
			node      => $Q->{node},
			debug     => $Q->{debug},
			group     => $Q->{group},
			graphtype => $Q->{graphtype},
			graphstart => $Q->{graphstart},
			width     => $Q->{width},
			height    => $Q->{height},
			start     => $Q->{start},
			end       => $Q->{end},
			intf      => $Q->{intf},
			item      => $Q->{item},
			filename  => $Q->{filename},
			time      => $Q->{time},
		);
	}
	else
	{
		print header($headeropts), start_html, "ERROR: Command unknown act=$Q->{act}", end_html;
	}
	return;
}

#============================================================================

# args: headeropts
sub error {
	my (%args) = @_;
	print header($args{headeropts});
	print start_html();
	print "Network: ERROR on getting graph<br>\n";
	print "Request not found\n";
	print end_html;
}


# args: nmisng, headeropts, obj, node, debug, group, graphtype, graphstart,
#       width, height, start, end, intf, item, filename, time
sub rrdDraw
{
	my (%args) = @_;
	my $nmisng = $args{nmisng};

	# Break the query up for the names
	my $type = $args{obj};
	my $nodename = $args{node};
	my $debug = $args{debug};
	my $grp = $args{group};
	my $graphtype = $args{graphtype};
	my $graphstart = $args{graphstart};
	my $width = $args{width};
	my $height = $args{height};
	my $start = $args{start};
	my $end = $args{end};
	my $intf = $args{intf};
	my $item = $args{item};
	my $filename = $args{filename};
	my $when = $args{time};

	my $result = NMISNG::rrdfunc::draw(node => $nodename,
																		 group => $grp,
																		 graphtype => $graphtype,
																		 intf => $intf,
																		 item => $item,
																		 width => $width,
																		 height => $height,
																		 filename => $filename,
																		 start => $start,
																		 end => $end,
																		 debug => $debug,
																		 time => $when);
	if (!$result->{success})
	{
		error(headeropts => $args{headeropts});
		$nmisng->log->error("rrddraw failed: $result->{error}");
		return;
	}
	return $result->{graph};
}

1;
