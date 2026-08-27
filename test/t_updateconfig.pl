#!/usr/bin/perl
#
# OMK-12605 round 6: admin/updateconfig.pl's recursive merge is what makes
# Events.nmis safely installer-mergeable (installer_hooks/10-postcopy-
# confmerges now calls it for Events.nmis the same way it already did for
# Config.nmis). This is a generic tool, not specific to either file, so
# these tests exercise it directly: a missing top-level key is added
# wholesale, a missing key inside an EXISTING nested entry is added without
# touching that entry's other values, and nothing already present is ever
# overwritten - proving a site's own customizations survive the merge.
#
use strict;
use warnings;
our $VERSION = "1.0.0";

use FindBin;
use lib "$FindBin::RealBin/../lib";

use Test::More;
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use NMISNG::Util;

local $ENV{CONTAINER} = "1";    # skip ownership/permission enforcement

# admin/updateconfig.pl calls NMISNG::Util::loadConfTable() with no args,
# which resolves to $FindBin::RealBin/../conf - i.e. wherever the SCRIPT
# ITSELF physically lives, regardless of the template/live file arguments
# passed to it. Invoking the real checkout copy directly would read/write
# the surrounding install's actual conf/Config.nmis as a side effect (seen
# happen during round 7 review). Fixed by running a COPY of the script from
# inside our own tempdir instead, so its own $FindBin::RealBin resolves to
# a throwaway ../conf next to it - fully isolated, cleaned up with the rest
# of $dir. PERL5LIB points the copy back at the real lib/ so it can still
# find NMISNG::Util etc.
my $dir = tempdir(CLEANUP => 1);
my $conf = { use_json => 'false', use_json_pretty => 'false', nmis_user => 'nmis', nmis_group => 'nmis' };

# the shipped conf-default/Config.nmis hardcodes <nmis_base> as the real
# checkout's absolute path (normally patched by the real installer at
# install time, admin/patch_config.pl). A plain file copy keeps that real
# path, so anything deriving <nmis_var> from it (e.g. the config-changed
# marker write seen during round 7 review) would still point at the real
# install's var/ directory, not our isolated tempdir - defeating the whole
# point of the isolation. Patch it to the destination dir instead.
sub seed_isolated_config_default
{
	my ($destdir) = @_;
	make_path("$destdir/conf-default");
	my $data = NMISNG::Util::readFiletoHash(file => "$FindBin::RealBin/../conf-default/Config.nmis", conf => $conf);
	$data->{directories}{'<nmis_base>'} = $destdir;    # NOT a top-level key - lives under 'directories'
	is(NMISNG::Util::writeHashtoFile(file => "$destdir/conf-default/Config.nmis", data => $data, conf => $conf), undef,
		"fixture: isolated conf-default/Config.nmis written for $destdir, <nmis_base> patched");
}

make_path("$dir/admin", "$dir/conf");
copy("$FindBin::RealBin/../admin/updateconfig.pl", "$dir/admin/updateconfig.pl")
	or die "failed to copy admin/updateconfig.pl into tempdir: $!";
chmod 0755, "$dir/admin/updateconfig.pl";
my $updateconfig = "$dir/admin/updateconfig.pl";
ok(-x $updateconfig, "isolated copy of admin/updateconfig.pl is executable") or die;

# the copy's own loadConfTable() call (inside updateconfig.pl, called
# unconditionally before it even looks at its template/live arguments) needs
# SOME conf-default/Config.nmis to exist next to it, regardless of which
# files this test is actually merging.
seed_isolated_config_default($dir);

local $ENV{PERL5LIB} = join(":", "$FindBin::RealBin/../lib", ($ENV{PERL5LIB} // ()));

# ---------------------------------------------------------------------------
# generic recursive-merge behaviour, on small hand-built fixtures - not tied
# to Events.nmis's real content, so this keeps testing the merge tool itself
# even if Events.nmis's shape changes later.
# ---------------------------------------------------------------------------
my $template_data = {
	'Existing Event' => {
		'Log' => 'true', 'Notify' => 'true', 'NewFlag' => 'default_value',
	},
	'Brand New Event' => {
		'Log' => 'true', 'Notify' => 'true',
	},
	top_level_scalar => 'template_value',
};
my $live_data = {
	'Existing Event' => {
		'Log' => 'true', 'Notify' => 'false',    # site's own customization
	},
	top_level_scalar => 'site_value',    # site's own customization
};

my $template_file = "$dir/template.nmis";
my $live_file     = "$dir/live.nmis";
is(NMISNG::Util::writeHashtoFile(file => $template_file, data => $template_data, conf => $conf), undef,
	"fixture: template file written");
is(NMISNG::Util::writeHashtoFile(file => $live_file, data => $live_data, conf => $conf), undef,
	"fixture: live file written");

my $rc = system($^X, $updateconfig, $template_file, $live_file);
is($rc, 0, "updateconfig.pl ran without error");

my $merged = NMISNG::Util::readFiletoHash(file => $live_file, conf => $conf);
is(ref($merged), 'HASH', "merged live file reads back as a hash");

is($merged->{'Existing Event'}{Notify}, 'false',
	"an existing sub-key's customized value is left untouched");
is($merged->{'Existing Event'}{NewFlag}, 'default_value',
	"a NEW sub-key inside an EXISTING top-level entry is added from the template");
is($merged->{top_level_scalar}, 'site_value',
	"an existing top-level scalar's customized value is left untouched");
ok(exists $merged->{'Brand New Event'}, "a whole NEW top-level entry absent from live is added");
is($merged->{'Brand New Event'}{Log}, 'true',
	"...with its full content from the template");

# running it again must be a no-op: nothing left to add, nothing touched
my $before_second_run = NMISNG::Util::readFiletoHash(file => $live_file, conf => $conf);
$rc = system($^X, $updateconfig, $template_file, $live_file);
is($rc, 0, "updateconfig.pl is safe to run twice");
my $after_second_run = NMISNG::Util::readFiletoHash(file => $live_file, conf => $conf);
is_deeply($after_second_run, $before_second_run, "a second run makes no further changes (idempotent)");

# ---------------------------------------------------------------------------
# the actual, real-world case: conf-default/Events.nmis as template against
# a simulated pre-upgrade site copy (missing TrackStatus, with a genuine
# customization), proving this specific installer change behaves correctly
# against the real shipped file, not just a synthetic fixture.
# ---------------------------------------------------------------------------
my $real_template = "$FindBin::RealBin/../conf-default/Events.nmis";
my $real_template_data = NMISNG::Util::readFiletoHash(file => $real_template, conf => $conf);
ok(ref($real_template_data) eq 'HASH' && exists $real_template_data->{'Planned Outage Open'},
	"conf-default/Events.nmis has a 'Planned Outage Open' entry to test against") or die;

my $simulated_live = { %$real_template_data };    # shallow copy is enough: we only touch two entries below
$simulated_live->{'Planned Outage Open'} = { %{$real_template_data->{'Planned Outage Open'}} };
delete $simulated_live->{'Planned Outage Open'}{TrackStatus};    # simulate a pre-ticket install
$simulated_live->{'Node Down'} = { %{$real_template_data->{'Node Down'}} };
$simulated_live->{'Node Down'}{Notify} = 'false';    # simulate a site's own customization

my $site_events_file = "$dir/site_Events.nmis";
is(NMISNG::Util::writeHashtoFile(file => $site_events_file, data => $simulated_live, conf => $conf), undef,
	"fixture: simulated pre-upgrade Events.nmis written");

$rc = system($^X, $updateconfig, $real_template, $site_events_file);
is($rc, 0, "updateconfig.pl ran against the real conf-default/Events.nmis without error");

my $merged_events = NMISNG::Util::readFiletoHash(file => $site_events_file, conf => $conf);
is($merged_events->{'Planned Outage Open'}{TrackStatus},
	$real_template_data->{'Planned Outage Open'}{TrackStatus},
	"TrackStatus was added to the simulated site file, matching the shipped default");
is($merged_events->{'Node Down'}{Notify}, 'false',
	"the simulated site's own Node Down customization survived the merge untouched");

# ---------------------------------------------------------------------------
# Round 7 final review: the actual production change is the installer HOOK
# line (installer_hooks/10-postcopy-confmerges) that decides WHETHER to run
# the merge above at all - not admin/updateconfig.pl itself, which didn't
# change in this ticket. Everything above proves the merge tool is correct;
# this proves the hook wires it up correctly, specifically the guard added
# after review found the unconditional version would auto-create a full
# conf/Events.nmis (from updateconfig.pl's own missing-live-file fallback,
# an empty starting hash) for every site that never had one - silently
# freezing that site at upgrade-time defaults forever after, since a site
# with no conf/Events.nmis normally reads conf-default/Events.nmis live,
# in full, on every load (NMISNG::Util::loadTable's conf-missing fallback).
# ---------------------------------------------------------------------------
my $hook = "$FindBin::RealBin/../installer_hooks/10-postcopy-confmerges";
ok(-r $hook, "installer_hooks/10-postcopy-confmerges exists") or die;

# a fresh miniature install tree: the hook needs its own admin/updateconfig.pl
# (already isolated above) plus conf-default originals; conf/ stays empty for
# the first case below, exactly like a real site that never touched Events.nmis.
my $targetdir = "$dir/target";
make_path("$targetdir/admin", "$targetdir/conf");
copy($updateconfig, "$targetdir/admin/updateconfig.pl") or die "copy failed: $!";
chmod 0755, "$targetdir/admin/updateconfig.pl";
seed_isolated_config_default($targetdir);    # <nmis_base>-patched, not a raw copy - see the sub for why
copy($real_template, "$targetdir/conf-default/Events.nmis") or die "copy failed: $!";

sub run_hook
{
	local $ENV{TARGETDIR}  = $targetdir;
	local $ENV{PERL5LIB}   = join(":", "$FindBin::RealBin/../lib", ($ENV{PERL5LIB} // ()));
	# the hook's own "look for custom config files" section (unrelated to
	# what this test is checking) diffs Events.nmis against conf-default and
	# prompts interactively if it differs - which our deliberately-different
	# fixture in case 2 below will trigger. UNATTENDED skips that prompt,
	# same as any real scripted/automated install run.
	local $ENV{UNATTENDED} = "1";
	return system("sh", $hook);
}

# --- case 1: no conf/Events.nmis at all - the hook must not create one ---
my $rc1 = run_hook();
is($rc1, 0, "Fix 14: hook ran without error against a site with no conf/Events.nmis" );
ok( !-e "$targetdir/conf/Events.nmis",
	"Fix 14: hook did NOT create conf/Events.nmis for a site that never had one" );

# --- case 2: conf/Events.nmis already exists (a site that DID customize it,
# missing TrackStatus the way a pre-upgrade copy would be) - the hook must
# still merge it, same as admin/updateconfig.pl already proved above ---
my $preexisting = { %$real_template_data };
$preexisting->{'Planned Outage Open'} = { %{$real_template_data->{'Planned Outage Open'}} };
delete $preexisting->{'Planned Outage Open'}{TrackStatus};
$preexisting->{'Node Down'} = { %{$real_template_data->{'Node Down'}} };
$preexisting->{'Node Down'}{Notify} = 'false';
is(NMISNG::Util::writeHashtoFile(file => "$targetdir/conf/Events.nmis", data => $preexisting, conf => $conf), undef,
	"Fix 14: fixture - a site's own pre-existing conf/Events.nmis written");

my $rc2 = run_hook();
is($rc2, 0, "Fix 14: hook ran without error against a site that already has conf/Events.nmis");
my $merged_by_hook = NMISNG::Util::readFiletoHash(file => "$targetdir/conf/Events.nmis", conf => $conf);
is($merged_by_hook->{'Planned Outage Open'}{TrackStatus},
	$real_template_data->{'Planned Outage Open'}{TrackStatus},
	"Fix 14: the hook merged TrackStatus into the site's existing Events.nmis");
is($merged_by_hook->{'Node Down'}{Notify}, 'false',
	"Fix 14: ...and left the site's own customization untouched");

done_testing();
