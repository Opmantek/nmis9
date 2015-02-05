# a small update plugin for converting the mac addresses in dot1q dot1qTpFdbs 
# into a more human-friendly form
package dot1qMacTable;
our $VERSION = "1.0.0";

use strict;

use func;												# for the conf table extras
use NMIS;

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C) = @args{qw(node sys config)};
	
	my $NI = $S->ndinfo;
	my $IF = $S->ifinfo;
	# anything to do?

	return (0,undef) if (ref($NI->{dot1qMacTable}) ne "HASH");
	
	info("Working on $node dot1qMacTable");

	my $changesweremade = 0;

	for my $key (keys %{$NI->{dot1qMacTable}})
	{
		my $entry = $NI->{dot1qMacTable}->{$key};
		my $ifIndex = $entry->{dot1qTpFdbPort};
				
		if ( defined $IF->{$ifIndex}{ifDescr} ) {
			$entry->{ifDescr} = $IF->{$ifIndex}{ifDescr};
			$changesweremade = 1;
		}
		
		my @octets;
		if ( @octets = split(/\./,$entry->{index}) ) {
			$entry->{vlan} = shift(@octets);
			my $macstring = join("",@octets);
			@octets = unpack("C*", pack("H*", $macstring));
			$entry->{dot1qTpFdbAddress} = sprintf("%02x:%02x:%02x:%02x:%02x:%02x", @octets);
			
			$changesweremade = 1;
		}		
	}
	return ($changesweremade,undef); # report if we changed anything
}

1;
