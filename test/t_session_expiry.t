#!/usr/bin/perl
#
# OMK-12688: session files are expired by NMISNG::Auth::get_all_live_session_counter,
# which unlinks expired ones as a side effect of counting. bin/nmisd calls it from
# the hourly purge job purely for that.
#
# Nothing removed those files before, so the directory grew without bound and
# anything scanning it for one user got slower forever. t_nmis_cli_seed_password.t
# pins that nmisd still makes the call; this pins what the call actually does.

use FindBin;
use lib "$FindBin::Bin/../lib";

use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);
use NMISNG::Auth;

# an exported NMIS_* would land in the config as layer 4 and could change
# auth_expire under us
delete @ENV{ grep { /^NMIS9?_/ } keys %ENV };

my $dir     = tempdir(CLEANUP => 1);
my $sessdir = "$dir/user_session";
mkdir($sessdir) or die "cannot create $sessdir: $!";

# conf is passed as a HASH, so Auth::new never calls loadConfTable and this stays
# off the real config entirely. auth_expire is the idle window not_expired uses.
my $auth = NMISNG::Auth->new(conf => {
	session_dir => $sessdir,
	auth_expire => '+30min',
});

# minimal CGI::Session file: read_session_fields pulls username and
# _SESSION_ATIME out with a regex, which is all the expiry walk needs.
sub make_session
{
	my ($id, $user, $age) = @_;
	my $atime = time - $age;
	open(my $f, '>', "$sessdir/cgisess_$id") or die "write session $id: $!";
	print $f "\$D = {'_SESSION_ID' => '$id','username' => '$user',"
		. "'_SESSION_ATIME' => '$atime'};";
	close $f;
	return "$sessdir/cgisess_$id";
}

# 1. the walk unlinks expired files and keeps live ones. This is the behaviour
# nmisd's purge job depends on, and the reason it is called at all.
{
	my $live    = make_session('live',    'alice', 60);      # 1 min idle, inside 30
	my $expired = make_session('expired', 'bob',   3600);    # 1 hour idle, outside
	my $all = $auth->get_all_live_session_counter();

	ok(-e $live,     'a live session file survives the walk');
	ok(!-e $expired, 'an expired session file is unlinked');
	is($all->{alice}->{sessions}, 1, 'the live session is counted for its user');
	ok(!exists $all->{bob}, 'the expired one is not counted');
}

# 2. boundary: idle exactly at auth_expire is treated as expired, because
# not_expired tests (time - atime) < window, so equality falls through.
{
	unlink glob("$sessdir/cgisess_*");
	my $edge = make_session('edge', 'carol', 1800);          # exactly 30 min
	$auth->get_all_live_session_counter();
	ok(!-e $edge, 'idle exactly at auth_expire is expired, not kept');
}

# 3. a file with no parseable username is left alone rather than unlinked. It
# might be a session format we do not understand, and deleting it would log
# somebody out for being unreadable.
{
	unlink glob("$sessdir/cgisess_*");
	open(my $f, '>', "$sessdir/cgisess_junk") or die $!;
	print $f "this is not a session file";
	close $f;
	$auth->get_all_live_session_counter();
	ok(-e "$sessdir/cgisess_junk", 'an unparseable file is not unlinked');
}

# 4. many expired files all go in one pass, which is what stops the directory
# growing without bound between purge cycles.
{
	unlink glob("$sessdir/cgisess_*");
	make_session("old$_", "user$_", 7200) for (1 .. 20);
	make_session('keeper', 'dave', 30);
	$auth->get_all_live_session_counter();
	my @left = glob("$sessdir/cgisess_*");
	is(scalar(@left), 1, 'all 20 expired files went in a single pass');
	like($left[0], qr/cgisess_keeper$/, 'and the live one is what remains');
}

# 5. a missing session directory is not fatal. nmisd calls this hourly on systems
# that may not have one yet.
{
	my $nodir = NMISNG::Auth->new(conf => {
		session_dir => "$dir/does-not-exist",
		auth_expire => '+30min',
	});
	my $res = eval { $nodir->get_all_live_session_counter(); 1 };
	ok($res, 'a missing session directory does not die');
}

done_testing;
