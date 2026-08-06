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
use File::Temp qw(tempdir);
use NMISNG::Util;

local $ENV{CONTAINER} = "1";    # skip ownership/permission enforcement

my $dir = tempdir(CLEANUP => 1);
my $updateconfig = "$FindBin::RealBin/../admin/updateconfig.pl";
ok(-x $updateconfig, "admin/updateconfig.pl exists and is executable") or die;

my $conf = { use_json => 'false', use_json_pretty => 'false', nmis_user => 'nmis', nmis_group => 'nmis' };

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

done_testing();
