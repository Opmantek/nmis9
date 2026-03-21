package NMISCGI::Rrddraw;
our $VERSION = "9.6.5";
use strict;
use NMISNG::Util;
use NMISNG::rrdfunc;
use NMISNG::Sys;
use Compat::NMIS;
use Data::Dumper;
use CGI qw(:standard *table *Tr *td *form *Select *div);

our ($q, $Q, $C, $AU, $headeropts, $nmisng);

sub runcgi {
	my ($args) = @_;
	($q, $Q, $C, $AU, $nmisng) = @{$args}{qw(q Q C AU nmisng)};
	$headeropts = $args->{headeropts};

	&NMISNG::rrdfunc::require_RRDs;

	# select function
	if ($Q->{act} eq 'draw_graph_view')
	{
		rrdDraw();
	}
	else
	{
		print header($headeropts), start_html, "ERROR: Command unknown act=$Q->{act}", end_html;
	}
	return;
}

#============================================================================

sub error {
	print header($headeropts);
	print start_html();
	print "Network: ERROR on getting graph<br>\n";
	print "Request not found\n";
	print end_html;
}


# produce one graph
# args: pretty much all coming from a global $Q object
# returns: nothing
sub rrdDraw
{
	my %args = @_;

	# Break the query up for the names
	my $type = $Q->{obj};
	my $nodename = $Q->{node};
	my $debug = $Q->{debug};
	my $grp = $Q->{group};
	my $graphtype = $Q->{graphtype};
	my $graphstart = $Q->{graphstart};
	my $width = $Q->{width};
	my $height = $Q->{height};
	my $start = $Q->{start};
	my $end = $Q->{end};
	my $intf = $Q->{intf};
	my $item = $Q->{item};
	my $filename = $Q->{filename};
	my $when = $Q->{time};

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
		error("rrddraw failed: $result->{error}");
		$nmisng->log->error("rrddraw failed: $result->{error}");
		return;
	}
	return $result->{graph};
}

1;
