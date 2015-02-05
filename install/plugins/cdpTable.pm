# a small update plugin for converting the mac addresses in dot1q dot1qTpFdbs 
# into a more human-friendly form
package cdpTable;
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

	return (0,undef) if (ref($NI->{cdp}) ne "HASH");
	
	info("Working on $node cdpTable");

	my $changesweremade = 0;

	for my $key (keys %{$NI->{cdp}})
	{
		my $entry = $NI->{cdp}->{$key};
		my @parts;
		
		if ( @parts = split(/\./,$entry->{index}) ) {
			$entry->{cdpCacheIfIndex} = shift(@parts);
			$entry->{cdpCacheDeviceIndex} = shift(@parts);
			if ( defined $IF->{$entry->{cdpCacheIfIndex}}{ifDescr} ) {
				$entry->{ifDescr} = $IF->{$entry->{cdpCacheIfIndex}}{ifDescr};
			}
			$changesweremade = 1;
		}
	}
	return ($changesweremade,undef); # report if we changed anything
}

1;
