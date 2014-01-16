#
## $Id: ip.pm,v 8.2 2011/08/28 15:11:05 nmisdev Exp $
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#  
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#  
#  This file is part of Network Management Information System (“NMIS”).
#  
#  NMIS is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#  
#  NMIS is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#  
#  You should have received a copy of the GNU General Public License
#  along with NMIS (most likely in a file named LICENSE).  
#  If not, see <http://www.gnu.org/licenses/>
#  
#  For further information on NMIS or for a license other than GPL please see
#  www.opmantek.com or email contact@opmantek.com 
#  
#  User group details:
#  http://support.opmantek.com/users/
#  
# *****************************************************************************

package ip;

require 5;

use strict;

use vars qw(@ISA @EXPORT @EXPORT_OK %EXPORT_TAGS $VERSION);

use Exporter;

$VERSION = 1.00;

@ISA = qw(Exporter);

@EXPORT = qw(	
		ipSubnet
		ipBitsToMask
		ipBroadcast
		ipWildcard
		ipHosts
		ipNumSubnets
		ipNextSubnet
		ipContainsAddr

	);

@EXPORT_OK = qw(	);

# check if host ip address is contained within address space in CIDR notation x.x.x.x/x
# ipContainsAddr( ipaddr => "x.x.x.x" , cidr => "x.x.x.x/x" )

sub ipContainsAddr {
	
	my %arg = @_;
	my $subnet;
	my $mask;
	my %masks;
	my $pip;
	my $psn;
	my $max;
	my $i;

	($subnet,$mask) = split( /\//, $arg{cidr} ); 


	# IP address/subnet packed into 32 bits 
	$pip = ip32( $arg{ipaddr} ); 
	$psn = ip32( $subnet ); 

	$max = 2**31; 
	for ($i=0; $i<32; $i++) { 
	    $masks{32-$i} = $max - 2**$i; 
	} 

	if ( ($pip & $masks{$mask}) == ($psn & $masks{$mask}) ) { 
	    return 1;		# true !!
	} else { 
	    return 0;		# false !!
	} 

	sub ip32 { 
	    my ($o1,$o2,$o3,$o4) = split(/\./, $_[0]); 
	    ($o1 << 24) + ($o2 << 16) + ($o3 << 8) + $o4; 
	} 
}

sub ipSubnet {
        my %args = @_;
        my $address = $args{address};
        my $mask = $args{mask};

	my $subnet = "";
	my $subnetBits = 0;
	my $subnetByte;
	my $i;
	my $b;
	my @addressBits;
	my @maskBits;
	
	my @addressOctets = split (/\./,$address);
	my @maskOctets  = split (/\./,$mask);

	for ( $i = 0; $i <= $#maskOctets; ++$i ) {
		#if ( $maskOctets[$i] == 1255 ) { 
		#	$subnet = $subnet.".".$addressOctets[$i];
		#	$subnetBits = $subnetBits + 8;
		#}
		#elsif ( $maskOctets[$i] == 1000 ) { 
		#	$subnet = $subnet.".".$maskOctets[$i];
		#	$subnetBits = $subnetBits + 0;
		#}
		#else { 
			$subnetByte = "";
			@addressBits = split (//,&dec2bin($addressOctets[$i]));
			@maskBits = split (//,&dec2bin($maskOctets[$i]));
			#print "mask ".&dec2bin($maskOctets[$i])." add ".&dec2bin($addressOctets[$i])."\n";
			#Do a binary addition
			for ( $b = 23; $b <= $#maskBits; ++$b ) {
				$subnetBits = $subnetBits + $maskBits[$b];
				if    ( $maskBits[$b] == 1 and $addressBits[$b] == 1 ) { $subnetByte = $subnetByte."1"; }
				elsif ( $maskBits[$b] == 0 and $addressBits[$b] == 0 ) { $subnetByte = $subnetByte."0"; }
				elsif ( $maskBits[$b] == 1 and $addressBits[$b] == 0 ) { $subnetByte = $subnetByte."0"; }
				elsif ( $maskBits[$b] == 0 and $addressBits[$b] == 1 ) { $subnetByte = $subnetByte."0"; }
			}
			$subnetByte = &bin2dec($subnetByte);
			$subnet = $subnet.".".$subnetByte;
		#}
	}
	$subnet =~ s/^\.//;
	return($subnet,$subnetBits);
}

sub ipBroadcast {
        my %args = @_;
        my $subnet = $args{subnet};
        my $mask = $args{mask};

	my @broadcastOctets;
	my @addressOctets = split (/\./,$subnet);
	my @maskOctets  = split (/\./,$mask);
	my $i;

	for ( $i = 0; $i <= $#maskOctets; ++$i ) {
		$broadcastOctets[$i] = $addressOctets[$i] + 255 - $maskOctets[$i];
	}
	return("$broadcastOctets[0].$broadcastOctets[1].$broadcastOctets[2].$broadcastOctets[3]");
}

sub ipNextSubnet {
        my %args = @_;
        my $subnet = $args{subnet};
        my $mask = $args{mask};

	my @nextOctets;
	my @subnetOctets = split (/\./,$subnet);
	my @maskOctets  = split (/\./,$mask);
	my $i;
	my $found = "false";

	for ( $i = 0; $i <= $#maskOctets; ++$i ) {
		$nextOctets[$i] = $subnetOctets[$i] + 255 - $maskOctets[$i];
		if ( $nextOctets[$i] != $subnetOctets[$i] ) {
			++$nextOctets[$i];
			if ( $nextOctets[$i] > 255 ) { 
				++$nextOctets[$i - 1]; 
				$nextOctets[$i] = 0; 
			}
		}
	}
	return("$nextOctets[0].$nextOctets[1].$nextOctets[2].$nextOctets[3]");
}

sub ipWildcard {
        my %args = @_;
        my $mask = $args{mask};

	my @wildOctets;
	my @maskOctets  = split (/\./,$mask);
	my $i;

	for ( $i = 0; $i <= $#maskOctets; ++$i ) {
		$wildOctets[$i] = 255 - $maskOctets[$i];
	}
	return("$wildOctets[0].$wildOctets[1].$wildOctets[2].$wildOctets[3]");
}

sub ipNumSubnets {
        my %args = @_;
        my $wildcard = $args{wildcard};
	my $numsubnets;
	my @octets  = split (/\./,$wildcard);
	my $i;
	for ( $i = 0; $i <= $#octets; ++$i ) {
		if ( $octets[$i] != 0 and $octets[$i] != 255 ) {
			if ( $i == 3 ) { $numsubnets = $octets[$i] + 1; }
			elsif ( $i == 2 ) { $numsubnets = ( $octets[$i] + 1 ) * 256; }
			elsif ( $i == 1 ) { $numsubnets = ( $octets[$i] + 1 ) * 256 * 256; }
			elsif ( $i == 0 ) { $numsubnets = ( $octets[$i] + 1 ) * 256 * 256 * 256; }
		} 
	}
	if ( $numsubnets eq "" ) {
		$numsubnets = 1; 
		for ( $i = 0; $i <= $#octets; ++$i ) {
			if ( $octets[$i] != 0 ) {
				$numsubnets = $numsubnets * $octets[$i];
			} 
		}
	} 
	return($numsubnets)
}

sub ipHosts {
        my %args = @_;
        my $mask = $args{mask};

	my $hosts;
	my @wildOctets;
	my @maskOctets  = split (/\./,$mask);
	my $i;

	for ( $i = 0; $i <= $#maskOctets; ++$i ) {
		$wildOctets[$i] = 255 - $maskOctets[$i];
	}
	$hosts = 	( $wildOctets[0] * 256 * 256 * 256 ) + 
			( $wildOctets[1] * 256 * 256 ) + 
			( $wildOctets[2] * 256 ) + 
			( $wildOctets[3] );
	return($hosts - 1);
}

sub ipBitsToMask {
        my %args = @_;
        my $bits = $args{bits};

	my $mask;
	
	#Lets cludge it for now!  Would like to calculate in Binary!!
	if ( $bits == 24 ) 	{ $mask = "255.255.255.0"; }
	elsif ( $bits == 16 ) 	{ $mask = "255.255.0.0"; }
	elsif ( $bits == 8 ) 	{ $mask = "255.0.0.0"; }
	elsif ( $bits == 30 ) 	{ $mask = "255.255.255.252"; }
	elsif ( $bits == 32 ) 	{ $mask = "255.255.255.255"; }
	elsif ( $bits == 23 ) 	{ $mask = "255.255.254.0"; }
	elsif ( $bits == 25 ) 	{ $mask = "255.255.255.128"; }
	elsif ( $bits == 26 ) 	{ $mask = "255.255.255.192"; }
	elsif ( $bits == 27 ) 	{ $mask = "255.255.255.224"; }
	elsif ( $bits == 28 ) 	{ $mask = "255.255.255.240"; }
	elsif ( $bits == 29 ) 	{ $mask = "255.255.255.248"; }
	elsif ( $bits == 22 ) 	{ $mask = "255.255.252.0"; }
	elsif ( $bits == 21 ) 	{ $mask = "255.255.248.0"; }
	elsif ( $bits == 20 ) 	{ $mask = "255.255.240.0"; }
	elsif ( $bits == 19 ) 	{ $mask = "255.255.224.0"; }
	elsif ( $bits == 18 ) 	{ $mask = "255.255.192.0"; }
	elsif ( $bits == 17 ) 	{ $mask = "255.255.128.0"; }
	elsif ( $bits == 15 ) 	{ $mask = "255.252.0.0"; }
	elsif ( $bits == 14 ) 	{ $mask = "255.248.0.0"; }
	elsif ( $bits == 13 ) 	{ $mask = "255.240.0.0"; }
	elsif ( $bits == 12 ) 	{ $mask = "255.224.0.0"; }
	elsif ( $bits == 10 ) 	{ $mask = "255.192.0.0"; }
	elsif ( $bits == 9 ) 	{ $mask = "255.128.0.0"; }
	
	# Take bits devide by 8 take whole number for each whole
	# number put 255, in mask 
	# Take bits mod by 8 take remainder convert to bin then to mask
	# I think the if statement is faster!!!!!!!!

	return($mask);
}

sub dec2bin {
    my $str = unpack("B32", pack("N", shift));
    #Might be inefficies here with handling long strings
    #$str =~ s/^0+(?=\d)//;   # otherwise you'll get leading zeros
    #$str = substr($str, 24);
    return $str;
}

sub bin2dec {
    return unpack("N", pack("B32", substr("0" x 32 . shift, -32)));
}

1;
