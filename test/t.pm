#
# THIS SOFTWARE IS NOT PART OF NMIS AND IS COPYRIGHTED, PROTECTED AND LICENSED
# BY OPMANTEK.
#
# YOU MUST NOT MODIFY OR DISTRIBUTE THIS CODE
#
# This code is NOT Open Source
#
# IT IS IMPORTANT THAT YOU HAVE READ CAREFULLY AND UNDERSTOOD THE END USER
# LICENSE AGREEMENT THAT WAS SUPPLIED WITH THIS SOFTWARE.   BY USING THE
# SOFTWARE  YOU ACKNOWLEDGE THAT (1) YOU HAVE READ AND REVIEWED THE LICENSE
# AGREEMENT IN ITS ENTIRETY, (2) YOU AGREE TO BE BOUND BY THE AGREEMENT, (3)
# THE INDIVIDUAL USING THE SOFTWARE HAS THE POWER, AUTHORITY AND LEGAL RIGHT
# TO ENTER INTO THIS AGREEMENT ON BEHALF OF YOU (AS AN INDIVIDUAL IF ON YOUR
# OWN BEHALF OR FOR THE ENTITY THAT EMPLOYS YOU )) AND, (4) BY SUCH USE, THIS
# AGREEMENT CONSTITUTES BINDING AND ENFORCEABLE OBLIGATION BETWEEN YOU AND
# OPMANTEK LTD.
#
# Opmantek is a passionate, committed open source software company - we really
# are.  This particular piece of code was taken from a commercial module and
# thus we can't legally supply under GPL. It is supplied in good faith as
# source code so you can get more out of NMIS.  According to the license
# agreement you can not modify or distribute this code, but please let us know
# if you want to and we will certainly help -  in most cases just by emailing
# you a different agreement that better suits what you want to do but covers
# Opmantek legally too.
#
# contact opmantek by emailing code@opmantek.com
#
# All licenses for all software obtained from Opmantek (GPL and commercial)
# are viewable at http://opmantek.com/licensing
#
#*****************************************************************************
package t;
our $VERSION = "2.0.0";

use Data::Dumper;

use vars qw(@ISA @EXPORT);
use Exporter;

@ISA = qw(Exporter);

@EXPORT = qw(
	prime_nodes
);

# primes a number of nodes and groups
# args: hash of
#	 synth_nr: number of routers to synth per group (each with four ifs)
#  synth_gr: number of groups: default 1
#	extras: name=>ipaddress pairs of extra hosts to synthesise
# returns: nothing
sub prime_nodes
{
	my (%arg)=@_;

	# actual node creation we leave to admin/opnode_admin.pl,
	# easier than coding this again here...
	my $nmisng = $arg{nmisng};
	die "nmisng required to prime nodes" if(!$nmisng);

	my $nrgroups= $arg{synth_gr} // 1;
	my $nrnodes = $arg{synth_nr} // 1;

	my (@nodeslist, @statelist);

	for my $group (1..$nrgroups)
	{
		my $groupname="group$group";

		for my $node (1..$nrnodes)
		{
			my $rname = "router${group}_$node";
			push @nodeslist, {
				cluster_id => $nmisng->config->{cluster_id},
				name => $rname ,
				host => "10.10.$group.$node",

				group => $groupname,
				roleType => "core",			# must be known one
				nodeType => "router",   # must be known one
				netType => "wan",				# must be known one

				# frills
				location => "located in group $groupname",
				sysName => $rname,
				customer => "testsuite",

				threshold => 1,
				collect => "true"
				# uuid is automatic - on create
			};
		}
	}

	# insert any extra nodes as well
	for my $x (keys %{$arg{extras}})
	{
		push @nodeslist, {
			cluster_id =>$nmisng->config->{cluster_id},
			name => $x,
			host => $arg{extras}->{$x},

			group => "default",				# likely nonexistent
			roleType => "access",			# must be known one
			nodeType => "server",   # must be known one
			netType => "lan",				# must be known one

			# frills
			location => "located in group default",
			sysName => $x,
			customer => "testsuite extra",

			threshold => 1,
			collect => "true"
			# uuid is automatic - on create
		};
	}

	foreach my $node_config (@nodeslist)
	{
		my $node = $nmisng->node( uuid => NMISNG::Util::getUUID(), create => 1 );
		$node->cluster_id($node_config->{cluster_id});
		$node->name($node_config->{name});
		$node->activated({"NMIS"=>1});
		delete @{$node_config}{"cluster_id name"};
		$node->configuration($node_config);

		my ($success,$error_msg) = $node->save();
		die "Error saving node: $error_msg" if($success < 0);

		# create a catchall for the node
		my $catchall_data = {
			"name" => $node->configuration->{name},
			"nodeType" => $node->configuration->{nodeType}
		};
		my ($catchall, $error) = $node->inventory(
			concept => "catchall", path_keys => [], data => $catchall_data, create => 1);
		$catchall->save( node => $node );
	}
}
