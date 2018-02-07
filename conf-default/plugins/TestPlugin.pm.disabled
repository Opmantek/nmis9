# this is a small example plugin, which doesn't do
# anything useful but demonstrate the concept.
package TestPlugin;
our $VERSION = "2.0.0";
use strict;

sub after_update_plugin
{
	my (%args) = @_;
	my ($nodes, $S, $C, $NG) = @args{qw(nodes sys config nmisng)};

	$NG->log->debug("The test plugin was run in the after_update phase");
	$NG->log->debug("Nodes that this update handled: ".join(", ",@$nodes))
			if (ref($nodes) eq "ARRAY");

	return (0,undef);
}

sub after_collect_plugin
{
	my (%args) = @_;
	my ($nodes, $S, $C, $NG) = @args{qw(nodes sys config nmisng)};

	$NG->log->debug("The test plugin was run in the after_collect phase");
	$NG->log->debug("Nodes that this collect handled: ".join(", ",@$nodes))
			if (ref($nodes) eq "ARRAY");

	return (0,undef);
}

sub update_plugin
{
	my (%args) = @_;
	my ($node, $S, $C, $NG) = @args{qw(node sys config nmisng)};

	$NG->log->debug("The test plugin was run in the per-node update phase for node $node");

	return (0,undef);
}

sub collect_plugin
{
	my (%args) = @_;
	my ($node, $S, $C, $NG) = @args{qw(node sys config nmisng)};


	$NG->log->debug("The test plugin was run in the per-node collect phase for node $node");

	return (0,undef);
}

1;
