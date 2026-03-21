package NMISCGI::Access;
our $VERSION = "9.6.5";
use strict;
use Compat::NMIS;
use NMISNG::Util;
use Data::Dumper;
$Data::Dumper::Indent = 1;
use CGI qw(:standard *table *Tr *td *form *Select *div);

our ($q, $Q, $C, $AU, $headeropts);

sub runcgi {
	my ($args) = @_;
	($q, $Q, $C, $AU) = @{$args}{qw(q Q C AU)};
	$headeropts = $args->{headeropts};

	# select function
	if ($Q->{act} eq 'access_menu_load') {	loadAccess();
	} else { notfound(); }

	return;
}

sub notfound {
	print header($headeropts);
	print "Access: ERROR, act=$Q->{act}<br>\n";
	print "Request not found\n";
}

#===================

sub loadAccess {

	print header($headeropts);

	my $start_page_id = ($Q->{start_page} ne '') ? $Q->{start_page} :
		($C->{menu_start_page_id} ne '') ? $C->{menu_start_page_id} : '';

	print table(Tr(td(p(b("Welcome at the Network Management Information System"))))) if $start_page_id eq '';

	my $AT = Compat::NMIS::loadGenericTable("Access");
	if ($AT) {
		print "<script>\n";
		for my $nm (keys %{$AT}) {
			if ($AT->{$nm}{group} eq 'button' and ($AT->{$nm}{"level$AU->{privlevel}"} or not $AU->Require)) {
				print "menuHr.enableItem(\"$AT->{$nm}{name}\");\n";
			}
		}
		print "loadStartPage('".$start_page_id."');" if $start_page_id ne '';
		print "</script>";
	} else {
		print "ERROR, cannot load Access table";
	}

}

1;
