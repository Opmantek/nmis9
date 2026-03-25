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

sub runcgi {
	my ($args) = @_;
	my ($q, $Q, $C, $AU) = @{$args}{qw(q Q C AU)};
	my $headeropts = $args->{headeropts};
	my $nmisng = $args->{nmisng};

	my $widget = (!defined $ENV{HTTP_X_REQUESTED_WITH})? 'false' :
			NMISNG::Util::getbool( $Q->{widget}, "invert" ) ? 'false' : 'true';
	my $wantwidget = ($widget eq 'true');

	my %common = (q => $q, C => $C, AU => $AU, headeropts => $headeropts,
		nmisng => $nmisng, widget => $widget, wantwidget => $wantwidget);

	#======================================================================

	# select function

	if ($Q->{act} eq 'snmp_var_menu') {
		menuSNMP(%common, refresh => $Q->{refresh},
			node => $Q->{node}, pnode => $Q->{pnode},
			var => $Q->{var}, pvar => $Q->{pvar},
			oid => $Q->{oid}, go => $Q->{go},
			community => $Q->{community}, pcommunity => $Q->{pcommunity},
			host => $Q->{host}, version => $Q->{version}, debug => $Q->{debug});
	} else {
		notfound(headeropts => $headeropts, act => $Q->{act});
	}

	return;
}

# args: headeropts, act
sub notfound {
	my (%args) = @_;
	print header($args{headeropts});
	print "SNMP: ERROR, act=$args{act}<br>\n";
	print "Request not found\n";
}

#===================

# args: q, C, AU, headeropts, nmisng, widget, wantwidget, refresh,
#       node, pnode, var, pvar, oid, go, community, pcommunity, host, version, debug
sub menuSNMP
{
	my (%args) = @_;
	my ($q, $C, $AU, $nmisng) = @args{qw(q C AU nmisng)};
	my $widget = $args{widget};
	my $wantwidget = $args{wantwidget};

	print header($args{headeropts});
	Compat::NMIS::pageStartJscript( title => "NMIS SNMP Tool", refresh => $args{refresh} )
			if ( !$wantwidget );

	my $node = $args{node};
	my $pnode = $args{pnode};
	my $var = $args{var};
	my $pvar = $args{pvar};
	my $oid = $args{oid};
	my $go = $args{go};
	my $community = $args{community};
	my $pcommunity = $args{pcommunity};

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
		if ($community ne '' and $community ne '*****') {
			$pcommunity = $community;
			$community = '*****';
		}
		print td({class=>'header', colspan=>'1'},
				"IP address ",textfield(-name=>"host",-size=>'25',-override=>1,-value=>"$args{host}"));
		print td({class=>'header', colspan=>'1'},
				"version ",popup_menu(-name=>"version",-override=>1,
					-values=>['snmpv2c','snmpv1'],-default=>"$args{version}"));
		print td({class=>'header', colspan=>'1'},
				"community ",textfield(-name=>"community",-size=>'15',-override=>1,-value=>"$community"));
		print hidden(-name=>'pcommunity', -default=>"$pcommunity",-override=>'1');
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
	if ($node ne '' and $oid ne '' and NMISNG::Util::getbool($go)) {
		viewSNMP(q => $q, C => $C, nmisng => $nmisng, wantwidget => $wantwidget,
			oid => $oid, node => $node, community => $community,
			pcommunity => $pcommunity, version => $args{version},
			host => $args{host}, debug => $args{debug});
	}

	print end_table;
	print hidden(-name=>'pnode', -default=>"$node",-override=>'1');
	print hidden(-name=>'pvar', -default=>"$var",-override=>'1');

	print end_form;

	Compat::NMIS::pageEnd() if ( !$wantwidget );

}

# args: q, C, nmisng, wantwidget, oid, node, community, pcommunity, version, host, debug
sub viewSNMP
{
	my (%args) = @_;
	my ($q, $C, $nmisng) = @args{qw(q C nmisng)};
	my $oid = $args{oid};

	my $node = $args{node};
	my ($OIDS,$NAMES) = NMISNG::MIB::loadoid($nmisng);
	my $result;
	my $SNMP;

	my $community = $args{community} eq '*****' ? $args{pcommunity} : $args{community};

	print start_Tr,start_td({colspan=>'3'}),start_table;

	if ($node eq 'other') {
		my $version = $args{version} ne '' ? $args{version} : 'snmpv2c';
		my $host = $args{host};
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
											debug => $args{debug})) {
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
