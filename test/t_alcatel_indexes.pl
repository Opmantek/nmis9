#!/usr/bin/perl
use strict;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Data::Dumper;
use func;

# Variables for command line munging
my %args = getArguements(@ARGV);


###############################################
#
# 4.1
#
# â¢	Level = 
# â¢	0000b for XDSL line, SHDSL Line, Ethernet Line, VoiceFXS Line or IsdnU Line 
# â¢	0001b for XDSL Channel  

###############################################
sub decode_interface_index_41 {
	my %args = @_;

	my $oid_value 		= 285409280;	
	if( defined $args{oid_value} ) {
		$oid_value = $args{oid_value};
	}
	my $rack_mask 		= 0x70000000;
	my $shelf_mask 		= 0x07000000;
	my $slot_mask 		= 0x00FF0000;
	my $level_mask 		= 0x0000F000;
	my $circuit_mask 	= 0x00000FFF;
	
	my $slot_bitshift = 16;

	print "4.1 Oid value=$oid_value\n";

	my $rack 		= ($oid_value & $rack_mask) 		>> 28;
	my $shelf 	= ($oid_value & $shelf_mask) 		>> 24;
	my $slot 		= ($oid_value & $slot_mask) 		>> $slot_bitshift;
	my $level 	= ($oid_value & $level_mask) 		>> 12;
	my $circuit = ($oid_value & $circuit_mask);

	printf( "\t rack=0x%x, %d\n", $rack, $rack);
	printf( "\t shelf=0x%x, %d\n", $shelf, $shelf);
	printf( "\t slot=0x%x, %d\n", $slot, $slot);
	printf( "\t level=0x%x, %d\n", $level, $level);
	printf( "\t circuit=0x%x, %d\n", $circuit, $circuit);
	
	#print "rack=X, shelf=Y, slot=Z, level=A, circuit=B"

	if( $level == 0xb ) {
		print "XDSL Line\n";
	}
	if( $level == 0x1b ) {
		print "XDSL Channel\n";
	}

}


##################################################
####
#### 4.1
####
#### •	Level = 
#### •	0000b for XDSL line, SHDSL Line, Ethernet Line, VoiceFXS Line or IsdnU Line 
#### •	0001b for XDSL Channel  
###
##################################################
###sub decode_interface_index_41 {
###	my %args = @_;
###
###	my $oid_value 		= 285409280;	
###	if( defined $args{oid_value} ) {
###		$oid_value = $args{oid_value};
###	}
###	my $rack_mask 		= 0x70000000;
###	my $shelf_mask 		= 0x07000000;
###	my $slot_mask 		= 0x00FF0000;
###	my $level_mask 		= 0x0000F000;
###	my $circuit_mask 	= 0x00000FFF;
###
###	my $rack 		= ($oid_value & $rack_mask) 		>> 28;
###	my $shelf 	= ($oid_value & $shelf_mask) 		>> 24;
###	my $slot 		= ($oid_value & $slot_mask) 		>> 16;
###	my $level 	= ($oid_value & $level_mask) 		>> 12;
###	my $circuit = ($oid_value & $circuit_mask);
###
###	print "4.1 Oid value=$oid_value\n";
###	printf( "\t rack=0x%x, %d\n", $rack, $rack);
###	printf( "\t shelf=0x%x, %d\n", $shelf, $shelf);
###	printf( "\t slot=0x%x, %d\n", $slot, $slot);
###	printf( "\t level=0x%x, %d\n", $level, $level);
###	printf( "\t circuit=0x%x, %d\n", $circuit, $circuit);
###	
###	if( $level == 0xb ) {
###		print "XDSL Line\n";
###	}
###	if( $level == 0x1b ) {
###		print "XDSL Channel\n";
###	}
###
###}  

sub generate_interface_index_41 {
	my %args = @_;
	my $rack = $args{rack};
	my $shelf = $args{shelf};
	my $slot = $args{slot};
	my $level = $args{level};
	my $circuit = $args{circuit};

	my $index = 0;
	$index = ($rack << 28) | ($shelf << 24) | ($slot << 16) | ($level << 12) | ($circuit);
	return $index;
}

###############################################
#
# 4.2
#	XDSL/SHDSL line, voiceFXS, IsdnU, XDSL channel, bonding/IMA interface, ATM/EFM interface, LAG interface
# â¢	Level=0000bâ¦.0100b, see Table 1
###############################################
sub decode_interface_index_42 {
	my %args = @_;
	my $oid_value 		= 67108864;
	if( $args{oid_value} ne '' ) {
		$oid_value = $args{oid_value};
	}
	
	my $slot_mask 		= 0x7E000000;
	my $level_mask 		= 0x01E00000;	
	my $circuit_mask 	= 0x001FE000;
	
	my $slot 		= ($oid_value & $slot_mask) 		>> 25;
	my $level 	= ($oid_value & $level_mask) 		>> 21;
	my $circuit = ($oid_value & $circuit_mask) 	>> 13;

	printf("4.2 Oid value=%d, 0x%x, %b\n", $oid_value, $oid_value, $oid_value);
	printf( "\t slot=0x%x, %d\n", $slot, $slot);
	printf( "\t level/card=0x%x, %d\n", $level, $level);
	printf( "\t circuit/port=0x%x, %d\n", $circuit, $circuit);
	if( $level >= 0xB && $level <= 0x100B) {
		print "XDSL/SHDSL line, voiceFXS, IsdnU, XDSL channel, bonding/IMA interface, ATM/EFM interface, LAG interface\n";
	}
}

##################################################
####
#### 4.2
####	XDSL/SHDSL line, voiceFXS, IsdnU, XDSL channel, bonding/IMA interface, ATM/EFM interface, LAG interface
#### •	Level=0000b….0100b, see Table 1
##################################################
###sub decode_interface_index_42 {
###	my %args = @_;
###	my $oid_value 		= 67108864;
###	if( $args{oid_value} ne '' ) {
###		$oid_value = $args{oid_value};
###	}
###	
###	my $slot_mask 		= 0xFC000000;
###	my $level_mask 		= 0x03C00000;	
###	my $circuit_mask 	= 0x001FE000;
###	
###
###	my $slot 		= ($oid_value & $slot_mask) 		>> 25;
###	my $level 	= ($oid_value & $level_mask) 		>> 21;
###	my $circuit = ($oid_value & $circuit_mask) 	>> 13;
###
###	printf("4.2 Oid value=%d, 0x%x, %b\n", $oid_value, $oid_value, $oid_value);
###	printf( "\t slot=0x%x, %d\n", $slot, $slot);
###	printf( "\t level/card=0x%x, %d\n", $level, $level);
###	printf( "\t circuit/port=0x%x, %d\n", $circuit, $circuit);
###	if( $level >= 0xB && $level <= 0x100B) {
###		print "XDSL/SHDSL line, voiceFXS, IsdnU, XDSL channel, bonding/IMA interface, ATM/EFM interface, LAG interface\n";
###	}
###}

sub generate_interface_index_42 {
	my %args = @_;
	my $slot = $args{slot};
	my $level = $args{level};
	my $circuit = $args{circuit};

	my $index = 0;
	$index = ($slot << 25) | ($level << 21) | ($circuit << 13);
	return $index;
}

sub build_41_interface_indexes {
	my $rack = 1;
	my $shelf = 1;
	my $level = 0;

	my @slots = (3..19);
	my @circuits = (0..47);
	foreach my $slot (@slots) {
		foreach my $circuit (@circuits) {
			my $index = generate_interface_index_41 ( rack => $rack, shelf => $shelf, slot => $slot, level => $level, circuit => $circuit);
			print "$index,";
		}
		print "\n";
	}
}

sub build_42_interface_indexes {
	
	my $level = 0;

	my @slots = (2..16);
	my @circuits = (0..47);
	foreach my $slot (@slots) {
		foreach my $circuit (@circuits) {
			my $index = generate_interface_index_42 ( slot => $slot, level => $level, circuit => $circuit);
			print "$index,";
		}
		print "\n";
		#  generate extra indexes at level 16, these are the XDSL channel ones
		if( $slot == 16 ) {
			$level = 16;
			foreach my $circuit (@circuits) {
				my $index = generate_interface_index_42 ( slot => $slot, level => $level, circuit => $circuit);
				print "$index,";
			}	
			print "\n";
		}
	}

}

my $decodes_41 = [
	285409280,
	285409281,
	285409282,
	285409283,
	285409284,
	285409285,
	285409286,
	285409287,
	285409288,
	285409289,
	285409290,
	285409291,
	285409292,
	285409293,
	285409294,
	285409295,
	285409296,
	285409297,
	285409298,
	285409299,
	285409300,
	285409301,
	285409302,
	285409303,
	285409304,
	285409305,
	285409306,
	285409307,
	285409308,
	285409309,
	285409310,
	285409311,
	285409312,
	285409313,
	285409314,
	285409315,
	285409316,
	285409317,
	285409318,
	285409319,
	285409320,
	285409321,
	285409322,
	285409323,
	285409324,
	285409325,
	285409326,
	285409327
	,

	285474816,
	285474817,
	285474818,
	285474819,
	285474820,
	285474821,
	285474822,
	285474823,
	285474824,
	285474825,
	285474826,
	285474827,
	285474828,
	285474829,
	285474830,
	285474831,
	285474832,
	285474833,
	285474834,
	285474835,
	285474836,
	285474837,
	285474838,
	285474839,
	285474840,
	285474841,
	285474842,
	285474843,
	285474844,
	285474845,
	285474846,
	285474847,
	285474848,
	285474849,
	285474850,
	285474851,
	285474852,
	285474853,
	285474854,
	285474855,
	285474856,
	285474857,
	285474858,
	285474859,
	285474860,
	285474861,
	285474862,
	285474863,

	286457856,
	286457857,
	286457858,
	286457859,
	286457860,
	286457861,
	286457862,
	286457863,
	286457864,
	286457865,
	286457866,
	286457867,
	286457868,
	286457869,
	286457870,
	286457871,
	286457872,
	286457873,
	286457874,
	286457875,
	286457876,
	286457877,
	286457878,
	286457879,
	286457880,
	286457881,
	286457882,
	286457883,
	286457884,
	286457885,
	286457886,
	286457887,
	286457888,
	286457889,
	286457890,
	286457891,
	286457892,
	286457893,
	286457894,
	286457895,
	286457896,
	286457897,
	286457898,
	286457899,
	286457900,
	286457901,
	286457902,
	286457903
	];

my $decodes_42 = [
	67108864,
	67117056,
	67125248,
	67133440,
	67141632,
	67149824,
	67158016,
	67166208,
	67174400,
	67182592,
	67190784,
	67198976,
	67207168,
	67215360,
	67223552,
	67231744,
	67239936,
	67248128,
	67256320,
	67264512,
	67272704,
	67280896,
	67289088,
	67297280,
	67305472,
	67313664,
	67321856,
	67330048,
	67338240,
	67346432,
	67354624,
	67362816,
	67371008,
	67379200,
	67387392,
	67395584,
	67403776,
	67411968,
	67420160,
	67428352,
	67436544,
	67444736,
	67452928,
	67461120,
	67469312,
	67477504,
	67485696,
	67493888
	# ,
	# 134217728,
	# 134225920,
	# 134234112,
	# 134242304,
	# 134250496,
	# 134258688,
	# 134266880,
	# 134275072,
	# 134283264,
	# 134291456,
	# 134299648,
	# 134307840,
	# 134316032,
	# 134324224,
	# 134332416,
	# 134340608,
	# 134348800,
	# 134356992,
	# 134365184,
	# 134373376,
	# 134381568,
	# 134389760,
	# 134397952,
	# 134406144,
	# 134414336,
	# 134422528,
	# 134430720,
	# 134438912,
	# 134447104,
	# 134455296,
	# 134463488,
	# 134471680,
	# 134479872,
	# 134488064,
	# 134496256,
	# 134504448,
	# 134512640,
	# 134520832,
	# 134529024,
	# 134537216,
	# 134545408,
	# 134553600,
	# 134561792,
	# 134569984,
	# 134578176,
	# 134586368,
	# 134594560,
	# 134602752
	,
		536870912,
		536879104,
		536887296,
		536895488,
		536903680,
		536911872,
		536920064,
		536928256,
		536936448,
		536944640,
		536952832,
		536961024,
		536969216,
		536977408,
		536985600,
		536993792,
		537001984,
		537010176,
		537018368,
		537026560,
		537034752,
		537042944,
		537051136,
		537059328,
		537067520,
		537075712,
		537083904,
		537092096,
		537100288,
		537108480,
		537116672,
		537124864,
		537133056,
		537141248,
		537149440,
		537157632,
		537165824,
		537174016,
		537182208,
		537190400,
		537198592,
		537206784,
		537214976,
		537223168,
		537231360,
		537239552,
		537247744,
		537255936
	,
	570425344,
	570433536,
	570441728,
	570449920,
	570458112,
	570466304,
	570474496,
	570482688,
	570490880,
	570499072,
	570507264,
	570515456,
	570523648,
	570531840,
	570540032,
	570548224,
	570556416,
	570564608,
	570572800,
	570580992,
	570589184,
	570597376,
	570605568,
	570613760,
	570621952,
	570630144,
	570638336,
	570646528,
	570654720,
	570662912,
	570671104,
	570679296,
	570687488,
	570695680,
	570703872,
	570712064,
	570720256,
	570728448,
	570736640,
	570744832,
	570753024,
	570761216,
	570769408,
	570777600,
	570785792,
	570793984,
	570802176,
	570810368
];

my @decodes_unknown = qw(
285413376
285413377
285413378
285413379
285413380
285413381
285413382
285413383
285413384
285413385
285413386
285413387
285413388
285413389
285413390
285413391
285413392
285413393
285413394
285413395
285413396
285413397
285413398
285413399
285413400
285413401
285413402
285413403
285413404
285413405
285413406
285413407
285413408
285413409
285413410
285413411
285413412
285413413
285413414
285413415
285413416
285413417
285413418
285413419
285413420
285413421
285413422
285413423

285478912
285478913
285478914
285478915
285478916
285478917
285478918
285478919
285478920
285478921
285478922
285478923
285478924
285478925
285478926
285478927
285478928
285478929
285478930
285478931
285478932
285478933
285478934
285478935
285478936
285478937
285478938
285478939
285478940
285478941
285478942
285478943
285478944
285478945
285478946
285478947
285478948
285478949
285478950
285478951
285478952
285478953
285478954
285478955
285478956
285478957
285478958
285478959

570818560
570818561
570818562
570818563
570818564
570818565
570818566
570818567
570818568
570818569
570818570
570818571
570818572
570818573
570818574
570818575
570818576
570818577
570818578
570818579
570818580
570818581
570818582
570818583
570818584
570818585
570818586
570818587
570818588
570818589
570818590
570818591
570818592
570818593
570818594
570818595
570818596
570818597
570818598
570818599
570818600
570818601
570818602
570818603
570818604
570818605
570818606
570818607);

sub decode_41_array {
	# print Dumper(\@decodes_unknown);
	foreach my $oid_value ( @decodes_unknown ) {
		decode_interface_index_41(oid_value => $oid_value);
	}	
}
sub decode_42_array {
	foreach my $oid_value ( @{$decodes_42} ) {
		decode_interface_index_42(oid_value => $oid_value);
	}	
}

if( $args{act} eq "decode_41_array" ) {
	# decode one of the arrays above
	decode_41_array();	
}
elsif( $args{act} eq "decode_42_array" ) {
	# decode one of the arrays above
	decode_42_array();
}
elsif( $args{act} eq "build_41_interface_indexes" ) {
	build_41_interface_indexes();
}
elsif( $args{act} eq "build_42_interface_indexes" ) {
	build_42_interface_indexes();
}
elsif( $args{act} eq "decode_interface_index_41" ) {
	if( defined( $args{values} ) ) {
		my @values = split( ",", $args{values} );		
		foreach my $value (@values) {
			decode_interface_index_41( oid_value => $value );		
		}
	}
	else {
		decode_interface_index_41( oid_value => $args{value} );	
	}
}
elsif( $args{act} eq "decode_interface_index_42" ) {
	if( defined( $args{values} ) ) {
		my @values = split( ",", $args{values} );		
		foreach my $value (@values) {
			decode_interface_index_42( oid_value => $value );			
		}
	}
	else {
		decode_interface_index_42( oid_value => $args{value} );
	}
}
