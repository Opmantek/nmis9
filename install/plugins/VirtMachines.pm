# a small update plugin for converting the mac addresses in ciscorouter addresstables 
# into a more human-friendly form
package VirtMachines;
our $VERSION = "1.0.0";

use strict;
use func;												# for the conf table extras
use NMIS;

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C) = @args{qw(node sys config)};

	my $NI = $S->ndinfo;
	# anything to do?
	return (0,undef) if (ref($NI->{VirtMachines}) ne "HASH");
	my $changesweremade = 0;

	info("Working on $node VirtMachines");
	
	
	my $LNT = loadLocalNodeTable();


	for my $vm (keys %{$NI->{VirtMachines}})
	{
		my $entry = $NI->{VirtMachines}{$vm};
		my $vmName = 	$entry->{vmwVmDisplayName};
		
		#http://nmisdev64.dev.opmantek.com/cgi-nmis8/network.pl?conf=Config.nmis&act=network_node_view&refresh=180&widget=true&node=nmisdev64
		
		if ( defined $LNT->{$vmName}{name} and $LNT->{$vmName}{name} eq $vmName ) {
			$changesweremade = 1;
			$entry->{vmwVmDisplayName_url} = "/cgi-nmis8/network.pl?conf=$C->{conf}&act=network_node_view&node=$vmName";
			$entry->{vmwVmDisplayName_id} = "node_view_$vmName";
		}

	}
	return ($changesweremade,undef); # report if we changed anything
}

1;
