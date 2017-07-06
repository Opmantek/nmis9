# a small update plugin for converting the mac addresses in ciscorouter addresstables 
# into a more human-friendly form
package network;
our $VERSION = "1.0.0";

use strict;
use NMISNG::Util;												# for the conf table extras, and beautify_physaddress
use Compat::NMIS;												# for the conf table extras, and beautify_physaddress
use JSON::XS;

sub update_plugin
{
	my (%args) = @_;
	my ($node,$S,$C) = @args{qw(node sys config)};
	my $changesweremade = 0;
	
	extractNetwork($node,$S,$C);
	
	return ($changesweremade,undef); # report if we changed anything
}

sub collect_plugin
{
	my (%args) = @_;
	my ($node,$S,$C) = @args{qw(node sys config)};
	my $changesweremade = 0;
	
	extractNetwork($node,$S,$C);
	
	return ($changesweremade,undef); # report if we changed anything
}


sub extractNetwork {
	my $node = shift;
	my $S = shift;
	my $C = shift;
	
	my $nodeNet;
	my $gotOneIp = 0;
	
	my $NI = $S->ndinfo;
	# anything to do?
	return (0,undef) if (ref($NI->{interface}) ne "HASH");
	my $changesweremade = 0;

	info("Working on $node network");

	my $IF = $S->ifinfo;

	for my $ifIndex (keys %{$IF})
	{
		if ( $IF->{$ifIndex}{ifAdminStatus} eq "up" ) {
			my $cnt = 1;
			while (defined $IF->{$ifIndex}{"ipAdEntAddr$cnt"} ) { 				
				my $ifIdx = $ifIndex;
				$ifIdx = "$ifIndex.$cnt" if $cnt > 1;
				$nodeNet->{ip}{$ifIdx}{ipSubnet} = $IF->{$ifIndex}{"ipSubnet$cnt"};
				$nodeNet->{ip}{$ifIdx}{ipAdEntAddr} = $IF->{$ifIndex}{"ipAdEntAddr$cnt"};
				$nodeNet->{ip}{$ifIdx}{ipAdEntNetMask} = $IF->{$ifIndex}{"ipAdEntNetMask$cnt"};
				$nodeNet->{ip}{$ifIdx}{ifDescr} = $IF->{$ifIndex}{ifDescr};
				$nodeNet->{ip}{$ifIdx}{ifIndex} = $IF->{$ifIndex}{ifIndex};
				$nodeNet->{ip}{$ifIdx}{ifAdminStatus} = $IF->{$ifIndex}{ifAdminStatus};
				$nodeNet->{ip}{$ifIdx}{Description} = $IF->{$ifIndex}{Description};
				$nodeNet->{ip}{$ifIdx}{ifSpeed} = $IF->{$ifIndex}{ifSpeed};
				$nodeNet->{ip}{$ifIdx}{ifType} = $IF->{$ifIndex}{ifType};
				$nodeNet->{ip}{$ifIdx}{collect} = $IF->{$ifIndex}{collect};
				$gotOneIp = 1;
				$cnt++;
			}
		}
	}
	
	if ( not $gotOneIp ) {
		my $ip = $NI->{system}{host};
		# is the address a host name not a handy IP address
		if ( $ip !~ /\d+\.\d+\.\d+\.\d+/ )  {
			$ip = Compat::NMIS::resolveDNStoAddr($ip);
		}
		my $ifIndex = 0;
		$nodeNet->{ip}{$ifIndex}{ipSubnet} = undef;
		$nodeNet->{ip}{$ifIndex}{ipAdEntAddr} = $ip;
		$nodeNet->{ip}{$ifIndex}{ipAdEntNetMask} = undef;
		$nodeNet->{ip}{$ifIndex}{ifDescr} = "en0";
		$nodeNet->{ip}{$ifIndex}{ifIndex} = $ifIndex;
		$nodeNet->{ip}{$ifIndex}{ifAdminStatus} = "up";
		$nodeNet->{ip}{$ifIndex}{Description} = "Synthetic IP Interface";
		$nodeNet->{ip}{$ifIndex}{ifSpeed} = 1000000000;
		$nodeNet->{ip}{$ifIndex}{ifType} = "ethernetCsmacd";
		$gotOneIp = 1;		
	}	
	
	my $dir = "$C->{'<nmis_var>'}/network";
	if ( not -d "$C->{'<nmis_var>'}/network" ) {
		mkdir($dir);
		setFileProt($dir);
		if ( not -d "$C->{'<nmis_var>'}/network" ) {
			print "ERROR, could not make directory $dir\n";
			return(0,"BAD");
		}
	}

	my $file ="$dir/$node.json";
	
	my $json_node = encode_json( $nodeNet ); #, { pretty => 1 } );
	open(JSON,">$file") or logMsg("ERROR, can not write to $file");
	print JSON $json_node;
	close JSON;
	dbg("Saved $node $file",1);
	setFileProt($file);
	
}

1;

     #"12" : {
     #   "ipSubnetBits2" : 24,
     #   "ifOperStatus" : "up",
     #   "ifPhysAddress" : "0x588d09a4b008",
     #   "threshold" : "true",
     #   "ifDescr" : "Vlan1",
     #   "ifAdminStatus" : "up",
     #   "ipSubnet2" : "192.168.13.0",
     #   "ipSubnet1" : "192.168.1.0",
     #   "ifIndex" : "12",
     #   "nocollect" : "Collecting: Collection Policy",
     #   "ifLastChange" : "0:01:16",
     #   "ipSubnetBits1" : 24,
     #   "interface" : "vlan1",
     #   "collect" : "true",
     #   "ipAdEntAddr1" : "192.168.1.254",
     #   "ifLastChangeSec" : "76",
     #   "ifHighSpeed" : 100,
     #   "ifSpeed" : "100000000",
     #   "event" : "true",
     #   "ipAdEntNetMask2" : "255.255.255.0",
     #   "index" : "12",
     #   "ipAdEntAddr2" : "192.168.13.1",
     #   "ipAdEntNetMask1" : "255.255.255.0",
     #   "Description" : "PACKnet LAN",
     #   "ifType" : "propVirtual"
     #},

