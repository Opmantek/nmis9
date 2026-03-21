package NMISCGI::Snmp;
our $VERSION = "9.6.5";
use strict;
use Compat::NMIS;
use NMISNG::Util;
use NMISNG::Sys;
use NMISNG::MIB;
use NMISNG::Snmp;
use Net::SNMP qw(oid_lex_sort);
use CGI qw(:standard *table *Tr *td *form *Select *div);

our ($q, $Q, $C, $AU, $headeropts, $nmisng, $widget, $wantwidget);

sub runcgi {
	my ($args) = @_;
	($q, $Q, $C, $AU) = @{$args}{qw(q Q C AU)};
	$headeropts = $args->{headeropts};
	$nmisng = $args->{nmisng};

	$widget = (!defined $ENV{HTTP_X_REQUESTED_WITH})? 'false' :
			NMISNG::Util::getbool( $Q->{widget}, "invert" ) ? 'false' : 'true';
	$wantwidget = ($widget eq 'true');

	#======================================================================

	# select function

	if ($Q->{act} eq 'snmp_var_menu') {	menuSNMP();
	} else { notfound(); }

	return;
}

sub notfound {
	print header($headeropts);
	print "SNMP: ERROR, act=$Q->{act}<br>\n";
	print "Request not found\n";
}

#===================

sub menuSNMP
{
	print header($headeropts);
	Compat::NMIS::pageStartJscript( title => "NMIS SNMP Tool", refresh => $Q->{refresh} )
			if ( !$wantwidget );

	my $node = $Q->{node};
	my $pnode = $Q->{pnode};
	my $var = $Q->{var};
	my $pvar = $Q->{pvar};
	my $oid = $Q->{oid};
	my $go = $Q->{go};

	my $xoid;
	my $NT = Compat::NMIS::loadLocalNodeTable(); # node table

	my ($OIDS,$NAMES) = NMISNG::MIB::loadoid($nmisng);

  # the get() code doesn't work without a query param, nor does it work with all params present
	# conversely the non-widget mode needs post inputs as query params are ignored
	print start_form(-id=>"nmisSnmp", -href=>url(-absolute=>1)."?");
	print hidden(-override => 1, -name => "act", -value => "snmp_var_menu")
			. hidden(-override => 1, -name => "widget", -value => $widget);

	print start_table;

	if ($node eq 'other') {
		if ($Q->{community} ne '' and $Q->{community} ne '*****') {
			$Q->{pcommunity} = $Q->{community};
			$Q->{community} = '*****';
		}
		print td({class=>'header', colspan=>'1'},
				"IP address ",textfield(-name=>"host",-size=>'25',-override=>1,-value=>"$Q->{host}"));
		print td({class=>'header', colspan=>'1'},
				"version ",popup_menu(-name=>"version",-override=>1,
					-values=>['snmpv2c','snmpv1'],-default=>"$Q->{version}"));
		print td({class=>'header', colspan=>'1'},
				"community ",textfield(-name=>"community",-size=>'15',-override=>1,-value=>"$Q->{community}"));
		print hidden(-name=>'pcommunity', -default=>"$Q->{pcommunity}",-override=>'1');
		print hidden(-name=>'node', -default=>"other",-override=>'1');
	} else {
		my @nodes = (sort {lc($a) cmp lc($b)} keys %{$NT});
		@nodes = ('','other',grep { $AU->InGroup($NT->{$_}{group})} @nodes);
		print start_Tr;
		print td({class=>'header', colspan=>'1'},
				"Select node ".
					popup_menu(-name=>'node', -override=>'1',
						-values=>\@nodes,
						-default=>$node,
										 -onChange => $wantwidget ? "if(this.value=='other')get('nmisSnmp'); else return false;"
										 : "if(this.value=='other') submit(); else return false;"));
	}

	# the calling Models program is using name+numbers
	if ($var ne '') {
		$var =~ /^(\w+)(.*)$/;
		$var = $1;
		$xoid = $2;
	}

	if ($var ne $pvar) {
		$oid = $OIDS->{$var}.$xoid;
	} else {
		if ($oid ne '' and $oid ne $OIDS->{$var}) {
			$var = $NAMES->{$oid};
		} else {
			$oid = $OIDS->{$var};
		}
	}
	my @vars = sort keys %{$OIDS};
	print td({class=>'header', colspan=>'1'},
			"Select name ".
				popup_menu(-name=>'var', -override=>'1',
					-values=>\@vars,
					-default=>$var,
					-onChange=> $wantwidget? "get('nmisSnmp');" : "return false;"));



	print td({class=>'header', colspan=>'1'},
			"oid ",	textfield(-name=>"oid",-size=>'35',-override=>1,-value=>"$oid"));

	print hidden(-name=>'go', -default=> 'false', -override=>'1', id => 'goinput')
			if (!$wantwidget);
	print td(button(-name=>'button',
									onclick => ($wantwidget? "get('nmisSnmp','go');" : '$("#goinput").val("true"); submit();'),
									-value=>"Go"));

	print end_Tr;
	if ($node ne '' and $oid ne '' and NMISNG::Util::getbool($go)) { viewSNMP(oid=>$oid); }

	print end_table;
	print hidden(-name=>'pnode', -default=>"$node",-override=>'1');
	print hidden(-name=>'pvar', -default=>"$var",-override=>'1');

	print end_form;

	Compat::NMIS::pageEnd() if ( !$wantwidget );

}

sub viewSNMP
{
	my %args = @_;
	my $oid = $args{oid};

	my $node = $Q->{node};
	my ($OIDS,$NAMES) = NMISNG::MIB::loadoid($nmisng);
	my $result;
	my $SNMP;

	my $community = $Q->{community} eq '*****' ? $Q->{pcommunity} : $Q->{community};

	print start_Tr,start_td({colspan=>'3'}),start_table;

	if ($node eq 'other') {
		my $version = $Q->{version} ne '' ? $Q->{version} : 'snmpv2c';
##		my $community = $Q->{community} eq '*****' ? $Q->{pcommunity} : $Q->{community};
		my $host = $Q->{host};
		my $port = 161;
		if ($host eq '') {
			print Tr(td({class=>'error'},"Error, no IP address specified"));
			return;
		}

		$SNMP = NMISNG::Snmp->new(nmisng => $nmisng);
		if (!$SNMP->open( host => NMISNG::Util::stripSpaces($host),
											version => NMISNG::Util::stripSpaces($version),
											community => NMISNG::Util::stripSpaces($community),
											port => $port,
											max_msg_size => $C->{snmp_max_msg_size},
											debug => $Q->{debug})) {
			print Tr(td({class=>'error'},$SNMP->error));
			return;
		}
	} else {
		my $S = NMISNG::Sys->new(nmisng => $nmisng); # get system object
		if ($S->init(name=>$node)) { # open snmp
			$SNMP = $S->snmp;
			if (!$S->open()) {
				print Tr(td({class=>'error'},$SNMP->error));
				return;
			}
		} else {
			print Tr(td({class=>'error'},"Error on initialize node object $node"));
			return;
		}
	}
	# get it
	if (($result = $SNMP->gettable($oid))) {
		my $msg = (scalar keys %{$result} > 99) ? ', max entries of 100 reached' : '';
		print Tr(td({class=>'header',colspan=>'3'},'result of query'.$msg));
		for my $k (oid_lex_sort(keys %{$result})) {
			print Tr(
				td({class=>'header'},escapeHTML(NMISNG::MIB::oid2name($nmisng, $k))),
				td({class=>'header'},$k),td({class=>'info'},escapeHTML($result->{$k})));
		}
	} else {
		# table empty, try single entry
		if ((($result) = $SNMP->getarray($oid))) {
			print Tr(td({class=>'header',colspan=>'3'},'result of query'));
			print Tr(
				td({class=>'header'},escapeHTML(NMISNG::MIB::oid2name($nmisng, $oid))),
				td({class=>'header'},$oid),td({class=>'info'},escapeHTML($result)));
			} else {
			print Tr(td({class=>'error'},$SNMP->error));
		}
	}

	print end_table,end_td,end_Tr;
	$SNMP->close();
}

1;
