#!/usr/bin/perl
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
# *****************************************************************************

our $VERSION="1.0.0";

if (@ARGV == 1 && $ARGV[0] eq "--version")
{
	print "version=$VERSION\n";
	exit 0;
}

use FindBin;
use lib "$FindBin::RealBin/../lib";

use strict;
use Mojo::UserAgent;
use Getopt::Std;
use File::Basename;
use JSON::XS;
use Data::Dumper;

use NMISNG;
use NMISNG::Log;
use NMISNG::Util;
use Compat::NMIS;

my $cmdline = NMISNG::Util::get_args_multi(@ARGV);

# first we need a config object
my $customconfdir = $cmdline->{dir}? $cmdline->{dir}."/conf" : undef;
my $config = NMISNG::Util::loadConfTable( dir => $customconfdir,
																					debug => $cmdline->{debug});

# log to stderr if debug is given
my $logfile = $config->{'<nmis_logs>'} . "/cli.log"; # shared by nmis-cli and this one
my $error = NMISNG::Util::setFileProtDiag(file => $logfile) if (-f $logfile);
warn "failed to set permissions: $error\n" if ($error);

# use debug or configured log_level
my $logger = NMISNG::Log->new( level => NMISNG::Log::parse_debug_level(
																 debug => $cmdline->{debug}) // $config->{log_level},
															 path  => (defined $cmdline->{debug})? undef : $logfile);

# now get us an nmisng object, which has a database handle and all the goods
my $nmisng = NMISNG->new(config => $config, log  => $logger);

my $outputfile = $cmdline->{output} // "nmisNodeMatchInfo.json";
my $toRet;

my $nodelist = $nmisng->get_nodes_model(fields_hash => { name => 1, uuid => 1, cluster_id => 1});
if (!$nodelist or !$nodelist->count)
{
	print STDERR "No matching nodes exist.\n" # but not an error, so let's not die
			if (!$cmdline->{quiet});
	exit 1;
}
else
{
	foreach my $node (@{$nodelist->data}) {
		my $node_name = $node->{name};
		my $node_id = $node->{uuid};
		
		my $md = $nmisng->get_inventory_model(node_uuid => $node->{uuid}, concept => 'interface');
		if (my $error = $md->error)
		{
			print "failed to lookup inventory records for $node_name: $error \n";
		}
		for my $oneinv (@{$md->data})
		{
			my $key = $oneinv->{'data'}->{'ifIndex'};
			#print "Interface=\"".$oneinv->{'data'}->{'Description'}. "\" ifDescr=\"" .
			#  $oneinv->{'data'}->{'ifDescr'} ."\" ifIndex=" . $oneinv->{'data'}->{'ifIndex'} . "\n";
			  
			$toRet->{$node_name}->{interfaces}->{$key}->{description} = ($oneinv->{'data'}->{Description} ne ""? $oneinv->{'data'}->{Description} : 'NOT_FOUND_BY_GET_NODE_DETAILS');
            $toRet->{$node_name}->{interfaces}->{$key}->{name} = $oneinv->{'data'}->{ifDescr} // 'NOT_FOUND_BY_GET_NODE_DETAILS';
            $toRet->{$node_name}->{interfaces}->{$key}->{snmpIndex} = $oneinv->{'data'}->{ifIndex} // 'NOT_FOUND_BY_GET_NODE_DETAILS';
		}
		if (@{$md->data} > 0 and $node_id) {
            $toRet->{$node_name}->{id} = $node_id;
        }
	}
	
	my $jsonResult = JSON::XS::encode_json($toRet);
	#print "Output file: " . $outputfile ."\n";
	
	# Sep 3: Write to file
	open(FH, '>>', $outputfile) or die $!;
	print FH $jsonResult;
	close(FH);
	
}

exit 0;

