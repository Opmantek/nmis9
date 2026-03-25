package NMISCGI::CommunityRss;
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

	if ($Q->{act} eq '' ) {
		printFeed(C => $C, headeropts => $headeropts, widget => $Q->{widget});
	}
	return;
}

# args: C, headeropts, widget
sub printFeed {
	my (%args) = @_;
	my $C = $args{C};

	my $feedurl = $C->{community_rss_url} || "https://community.opmantek.com/rss/NMIS.xml";

	print header($args{headeropts});
	Compat::NMIS::pageStartJscript(title => "NMIS Community News") if (!NMISNG::Util::getbool($args{widget}));

	print qq|
<script>
		var FEED_URL = "$feedurl";
|.q|
		$.ajax(FEED_URL, { ifModified: true, cache: true}).done(function (data) {
				$(data).find("entry").each(function () {
						var el = $(this);

						var td = $("<td>").addClass("infolft Plain");
						var entrydate = el.children("published").text();
						// iso8601 time but we don't want the full timestamp,
						// just the date part
						entrydate = entrydate.substring(0, entrydate.indexOf("T"));

						var a = $("<a>").attr("href",el.children("link").attr("href"));
						a.append(el.children("title").text());
						td.append(a,", ",el.children("author").children("name").text(),															 ", ", entrydate);

						var tr = $("<tr>").append(td);
						$("#feedtable").append(tr);
				});
				$("#feedtable").append('<tr><td class="infolft Plain"><a href="https://community.opmantek.com/">More News</a></td></tr>');
		});
</script>
|.  start_table({width => "100%", id => "feedtable"});

	print end_table;

	Compat::NMIS::pageEnd if (!NMISNG::Util::getbool($args{widget}));

}

1;
