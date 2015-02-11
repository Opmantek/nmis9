# a small update plugin for converting the mac addresses in ciscorouter addresstables 
# into a more human-friendly form
package addressTable;
our $VERSION = "1.0.0";

use strict;
use func;												# for the conf table extras

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
		my @bytes;

		if (length($macaddress) == 6) # if it's raw binary, convert it on the go
		{
			@bytes = unpack("(C2)6",$macaddress);
		}
		# nope, nice 0xlonghex -> split into bytes 
		elsif ($macaddress =~ /^0x[0-9a-fA-F]+$/) 
		{
			$macaddress =~ s/^0x//i;
			@bytes = unpack("C*", pack("H*", $macaddress));
		}
		# do nothing if they're already NN:MM:...

		if (@bytes)
		{
			$macentry->{ipNetToMediaPhysAddress} = 
					sprintf("%02x:%02x:%02x:%02x:%02x:%02x", @bytes);
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
