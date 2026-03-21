package NMISCGI::Ip;
our $VERSION = "9.6.5";
use strict;
use NMISNG::Util;
use Compat::NMIS;
use Compat::IP;
use NMISNG::Auth;
use CGI qw(:standard *table *Tr *td *form *Select *div);

our ($q, $Q, $C, $AU, $headeropts, $wantwidget);

sub runcgi {
	my ($args) = @_;
	($q, $Q, $C, $AU) = @{$args}{qw(q Q C AU)};
	$headeropts = $args->{headeropts};

	# this cgi script defaults to widget mode ON
	$wantwidget = !NMISNG::Util::getbool($Q->{widget},"invert");

	print header($headeropts);
	Compat::NMIS::pageStart(title => "NMIS IP Calc") if (!$wantwidget);

	#======================================================================

	# select function

	if ($Q->{act} =~ /tool_ip_menu/) {	menuIP();
	} else { notfound(); }

	Compat::NMIS::pageEnd if (!$wantwidget);
	return;
}

sub notfound {
	print "IP: ERROR, act=$Q->{act}, node=$Q->{node}<br>\n";
	print "Request not found\n";
}

#===================

sub menuIP {

		print start_form(-id=>"nmis", -href=> url(-absolute => 1)."?")
				.hidden(-override => 1, -name => "conf", -value => $Q->{conf})
				. hidden(-override => 1, -name => "act", -value => "tool_ip_menu")
				. hidden(-override => 1, -name => "widget", -value => ($wantwidget?"true":"false"));

	print start_table;
	print Tr(td({class=>'header',colspan=>'3'},"IP Subnet Calculator"));

	print Tr(td({class=>'header'},'IP Address'),
			td(textfield(-name=>"address",size=>'35',value=>$Q->{address})),
			td({class=>'header'},'IP address to base scheme on'));
	print Tr(td({class=>'header'},'Mask'),
			td(textfield(-name=>"mask1",size=>'35',value=>$Q->{mask1})),
			td({class=>'header'},'Basic IP Subnet Mask for scheme'));
	print Tr(td({class=>'header'},'Mask'),
			td(textfield(-name=>"mask2",size=>'35',value=>$Q->{mask2})),
			td({class=>'header'},'Extended subnet mask for full network'));

	print Tr(td('&nbsp;'),
				td(submit(-name=>"button",-onclick =>
									($wantwidget? "javascript:get('nmis');" : "submit()"),
									-value=>'GO')));

	ipDesc() if $Q->{address} eq '';

	ipCalc() if $Q->{address} ne '';

	ipSubnets() if $Q->{mask2} ne '' and $Q->{address} ne '';

}

sub ipDesc {

	print Tr(td({class=>'info',colspan=>'3'},<<EOHTML));
This is the IP Tool, you enter an IP address and a subnet mask and voil\x{e0} you will be<br>
provided with the IP Subnet Information like IP Subnet Address, Broadcast Address, <br>
Mask Bits for classless routing, Wildcard mask for access lists and OSPF routing <br>
configuration.
<p>
If you want to bigger subnet masking you can put a second mask in which will then<br>
produce a second table and a list of the subnets from the first mask which fit into<br>
the second mask.  This is handy when you are doing VLSM work, and handy for subnet<br>
breakpoints.
EOHTML
}

sub ipCalc {

	my $address = $Q->{address};
	my $mask = $Q->{mask1};
	my $mask2 = $Q->{mask2};

	my $subnet;
	my $bits;
	my $assume;
	my $broadcast;
	my $wildcard;
	my $hosts;

	if ( $mask eq "" ) {
		$mask = "255.255.255.0";
		$assume = "true";
	}
	elsif ( $mask !~ /\d+\.\d+\.\d+\.\d+/ ) {
		# Its a number bits mask
		$mask = Compat::IP::ipBitsToMask(bits => $mask);
	}

	($subnet,$bits) = Compat::IP::ipSubnet(address => $address, mask => $mask);
	$broadcast = Compat::IP::ipBroadcast(subnet => $subnet, mask => $mask);
	$wildcard = Compat::IP::ipWildcard(mask => $mask);
	$hosts = Compat::IP::ipHosts(mask => $mask);
	if ( NMISNG::Util::getbool($assume) ) {
		$mask = "No mask assuming 255.255.255.0";
	}

    print Tr(td({class=>'header',colspan=>'2'},"IP Subnet for IP address $address $mask"));
    print Tr(td({class=>'header',colspan=>'2'},"First Subnet Mask"));

	print Tr(td({class=>'header'},'IP Address'),td({class=>'info'},$address));
	print Tr(td({class=>'header'},'IP Subnet Mask'),td({class=>'info'},$mask));
	print Tr(td({class=>'header'},'Subnet Address'),td({class=>'info'},$subnet));
	print Tr(td({class=>'header'},'Broadcast Address'),td({class=>'info'},$broadcast));
	print Tr(td({class=>'header'},'Mask Bits'),td({class=>'info'},$bits));
	print Tr(td({class=>'header'},'Wildcard Mask'),td({class=>'info'},$wildcard));
	print Tr(td({class=>'header'},'Number Hosts'),td({class=>'info'},$hosts));

}

sub ipSubnets {

	my $address = $Q->{address};
	my $mask = $Q->{mask1};
	my $submask = $Q->{mask2};

	my $numsmallsubnets;
	my $numbigsubnets;
	my $bits;
	my $wildcard;
	my $broadcast;
	my $hosts;

	my $subnet;
	my $subbits;
	my $subbroadcast;
	my $subwildcard;
	my $subhosts;
	my $numsubnets;

	my $i;

	if ( $mask eq "" ) {
		$mask = "255.255.255.0";
	}
	elsif ( $mask !~ /\d+\.\d+\.\d+\.\d+/ ) {
		# Its a number bits mask
		$mask = Compat::IP::ipBitsToMask(bits => $mask);
	}

	if ( $submask !~ /\d+\.\d+\.\d+\.\d+/ ) {
		# Its a number bits mask
		$submask = Compat::IP::ipBitsToMask(bits => $submask);
	}

	$wildcard = Compat::IP::ipWildcard(mask => $mask);
	$numsmallsubnets = Compat::IP::ipNumSubnets(wildcard => $wildcard);

	# get the mask for the second subnet mask!
	($subnet,$subbits) = Compat::IP::ipSubnet(address => $address, mask => $submask);
	$subbroadcast = Compat::IP::ipBroadcast(subnet => $subnet, mask => $submask);
	$subwildcard = Compat::IP::ipWildcard(mask => $submask);
	$subhosts = Compat::IP::ipHosts(mask => $submask);
	$hosts = Compat::IP::ipHosts(mask => $mask);
	$numbigsubnets = Compat::IP::ipNumSubnets(wildcard => $subwildcard);

	$numsubnets = ( $numbigsubnets + 1 ) / ( $numsmallsubnets + 1 );
	$numsubnets = ( $subhosts + 2 ) / ( $hosts + 2 ) ;

    print Tr(td({class=>'header',colspan=>'2'},"Second Subnet Mask"));

	print Tr(td({class=>'header'},'IP Subnet Mask'),td({class=>'info'},$submask));
	print Tr(td({class=>'header'},'Subnet Address'),td({class=>'info'},$subnet));
	print Tr(td({class=>'header'},'Broadcast Address'),td({class=>'info'},$subbroadcast));
	print Tr(td({class=>'header'},'Mask Bits'),td({class=>'info'},$subbits));
	print Tr(td({class=>'header'},'Wildcard Mask'),td({class=>'info'},$subwildcard));
	print Tr(td({class=>'header'},'Number Hosts'),td({class=>'info'},$subhosts));
	print Tr(td({class=>'header'},"Number Subnets for $mask"),td({class=>'info'},$numsubnets));

    print Tr(td({class=>'header',colspan=>'2'},"Subnet Table for $mask into $submask"));
    print Tr(td({class=>'header'},"Starting Subnet"),td({class=>'info'},$subnet));
    print Tr(td({class=>'header'},"Last Address"),td({class=>'info'},$subbroadcast));
    print Tr(td({class=>'header'},"Mask"),td({class=>'info'},$mask));

	print Tr(td({class=>'header'},"Subnet"),td({class=>'header'},"Broadcast"));

	my $cnt = 0;
	for ( $i = 1; $i <= $numsubnets; ++$i ) {
		($subnet,$subbits) = Compat::IP::ipSubnet(address => $subnet, mask => $mask);
		$subbroadcast = Compat::IP::ipBroadcast(subnet => $subnet, mask => $mask);
		print Tr(td({class=>'info'},$subnet),td({class=>'info'},$subbroadcast));
		$subnet = Compat::IP::ipNextSubnet(subnet => $subnet, mask => $mask);
		last if $cnt++ > 1024;
	}

    print Tr(td({class=>'header',colspan=>'2'},"Etcetera...")) if $cnt > 1024;

}

1;
