# a small update plugin for converting the mac addresses in ciscorouter addresstables 
# into a more human-friendly form
package addressTable;
our $VERSION = "1.0.0";

use strict;
use func;												# for the conf table extras, and beautify_physaddress

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C) = @args{qw(node sys config)};

	my $NI = $S->ndinfo;
	# anything to do?
	return (0,undef) if (ref($NI->{addressTable}) ne "HASH");
	my $changesweremade = 0;

	info("Working on $node addressTable");

	my $IF = $S->ifinfo;

	for my $mackey (keys %{$NI->{addressTable}})
	{
		my $macentry = $NI->{addressTable}->{$mackey};
		my $macaddress = 	$macentry->{ipNetToMediaPhysAddress};
		
		my $nice = beautify_physaddress($macaddress);
		if ($nice ne $macaddress)
		{
			$macentry->{ipNetToMediaPhysAddress} = $nice;
			$changesweremade = 1;
		}

		if ( defined $IF->{$macentry->{ipNetToMediaIfIndex}}{ifDescr} ) {
			$macentry->{ifDescr} = $IF->{$macentry->{ipNetToMediaIfIndex}}{ifDescr};
			$changesweremade = 1;
		}

	}
	return ($changesweremade,undef); # report if we changed anything
}

1;
