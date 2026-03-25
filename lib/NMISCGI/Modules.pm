package NMISCGI::Modules;
our $VERSION = "9.6.5";
use strict;
use Compat::NMIS;
use NMISNG::Util;
use Data::Dumper;
$Data::Dumper::Indent = 1;
use CGI qw(:standard *table *Tr *td *form *Select *div);

sub runcgi {
	my ($args) = @_;
	my ($q, $Q, $C) = @{$args}{qw(q Q C)};
	my $headeropts = $args->{headeropts};

	# this cgi script defaults to widget mode ON
	my $widget = NMISNG::Util::getbool($Q->{widget},"invert")? "false" : "true";
	my $wantwidget = $widget eq "true";

	moduleMenu(q => $q, C => $C, wantwidget => $wantwidget, module => $Q->{module});

	return;
}

# args: q, C, wantwidget, module
sub moduleMenu {
	my (%args) = @_;
	my ($q, $C) = @args{qw(q C)};
	my $wantwidget = $args{wantwidget};
	my $module = $args{module};

	my $title = "NMIS Modules by FirstWave";
	my $header = $title;

	my $nmisicon = "<a target=\"nmis\" href=\"$C->{'nmis'}?\"><img class='logo' src=\"$C->{'nmis_icon'}\"/></a>";
	my $header2 = "$header <a href=\"$ENV{SCRIPT_NAME}\"><img src=\"$C->{'nmis_home'}\"/></a>";

	my $portalCode = Compat::NMIS::loadPortalCode();

	print header({-type=>"text/html",-expires=>'now'});

	if ( !$wantwidget ) {
		#Don't print the start_html, but we do need to get the javascript in there.
		print start_html(-title=>$title,
			-xbase=>&url(-base=>1)."$C->{'<url_base>'}",
			-meta=>{'keywords'=>'network management NMIS'},
			-head=>[
					Link({-rel=>'shortcut icon',-type=>'image/x-icon',-href=>$C->{'nmis_favicon'}}),
					Link({-rel=>'stylesheet',-type=>'text/css',-href=>"$C->{'styles'}"}),
				]
			);
	}

	print start_table({class=>"noborder"}) ;
	if ( !$wantwidget ) {
		print Tr(td({class=>"nav", colspan=>"3", width=>"100%"},
			"<a href='http://www.opmantek.com'><img height='30px' width='30px' class='logo' src=\"$C->{'<menu_url_base>'}/img/opmantek-logo-tiny.png\"/></a>",
			"<span class=\"title\">$header2</span>",
			$portalCode,
			"<span class=\"right\"><a id=\"menu_help\" href=\"$C->{'nmis_docs_online'}\"><img src=\"$C->{'nmis_help'}\"/></a></span>",
		));
	}

	my $MOD = NMISNG::Util::loadTable(dir=>'conf',name=>"Modules");
	if ( $module and $MOD->{$module}{description} ) {
		print Tr(th({class=>"title",colspan=>"3"}, "NMIS $module Module"));
		print Tr(td({class=>"lft",width=>"33%"}, "The $module module is not currently installed."),td({class=>"Plain",width=>"33%"},"&nbsp;"),td({class=>"Plain",width=>"33%"},"&nbsp;"));
		print Tr(td({class=>"lft",width=>"33%"}, "$MOD->{$module}{description}"),td({class=>"Plain",width=>"33%"},"&nbsp;"),td({class=>"Plain",width=>"33%"},"&nbsp;"));
		print Tr(td({class=>"lft",width=>"33%"}, "More information and contact information available at ",a({href=>"http://opmantek.com/Modules"},"Opmantek Modules")),td({class=>"Plain",width=>"33%"},"&nbsp;"),td({class=>"Plain",width=>"33%"},"&nbsp;"));
	}
	else {

	}

	print end_table, end_html;

}

1;
