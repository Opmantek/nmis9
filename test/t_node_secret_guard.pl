#!/usr/bin/perl
# OMK-12827 Slice B: NMISNG::Node::new's secret self-migration must never
# persist a failed conversion. encrypt/decrypt fail closed by returning
# input unchanged; the guard must then leave the stored value alone rather
# than dirty-and-save it.
#
# Mongo-backed: creates and drops t_nodeguard-<timestamp> in the configured
# mongodb (dev container). The master key is a custom temp path via
# NMIS_MASTER_KEY_FILE so no root and no default-path key is needed.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use File::Temp;

my ($tempdir, $keyfile);
BEGIN {
	$tempdir = File::Temp::tempdir(CLEANUP => 1);
	$keyfile = "$tempdir/master.key";
	$ENV{NMIS_MASTER_KEY_FILE} = $keyfile;
	$ENV{NMIS_GLOBAL_ENABLE_PASSWORD_ENCRYPTION} = 'true';
}

use Test::More;

# Phase A hides the modules; later phases restore them.
BEGIN {
	eval { require Test::Without::Module; 1 }
		or BAIL_OUT("Test::Without::Module is required to run this test and is not installed: $@");
	Test::Without::Module->import(qw(Crypt::CBC Crypt::Cipher::AES Math::Random::Secure));
}

use NMISNG;
use NMISNG::Node;
use NMISNG::Log;
use NMISNG::Util;

# Neutralise config writes for the whole process. With the encryption flag
# forced on, NMISNG::DB's decrypt(db_password, 'database', 'db_password')
# up-migration would otherwise re-encrypt the REAL conf/Config.nmis
# db_password with this test's ephemeral key, breaking Mongo auth for every
# later run. This test needs no config writes; node saves go through the
# nodes collection, not writeConfData.
{
	no warnings 'redefine';
	*NMISNG::Util::writeConfData = sub { return; };
}

my $C = NMISNG::Util::loadConfTable();
$C->{db_name} = "t_nodeguard-" . time;

my $logger = NMISNG::Log->new(level => 'warn');
my $nmisng = NMISNG->new(config => $C, log => $logger);
die "NMISNG object required" if (!$nmisng);

my $uuid = NMISNG::Util::getUUID();
my $node = NMISNG::Node->new(nmisng => $nmisng, uuid => $uuid);
$node->name("guardnode1");
$node->cluster_id($nmisng->config->{cluster_id});
$node->configuration({host => "127.0.0.1", group => "test", netType => "lan",
	roleType => "access", community => "plainsecret", threshold => 1});
my ($op, $err) = $node->save();
ok($op > 0, "test node saved") or diag("save error: " . ($err // ''));

my $coll = $nmisng->nodes_collection;
sub raw_community
{
	my $doc = $coll->find_one({uuid => $uuid});
	return $doc ? $doc->{configuration}->{community} : undef;
}
is(raw_community(), "plainsecret", "secret is stored as plaintext before any migration");

# Spy on Node::save from here on: a failed conversion must not save at all.
# Pre-guard code dirtied and saved the unchanged value on every load, which
# is how a "" or plaintext result got persisted over a stored secret.
my $save_count = 0;
{
	no warnings 'redefine';
	my $orig_save = \&NMISNG::Node::save;
	*NMISNG::Node::save = sub { $save_count++; goto &$orig_save; };
}

# --- Phase A: encryption enabled, modules missing. encrypt returns the
# plaintext unchanged; the guard must not dirty or save, and must never
# let '' or a non-'!!' overwrite happen.
$save_count = 0;
my $reload = $nmisng->node(uuid => $uuid);
ok($reload, "node reloads with crypto modules missing");
is(raw_community(), "plainsecret",
	"stored secret is untouched when encryption cannot run (no wipe)");
is($save_count, 0,
	"a failed conversion triggers NO save (the guard skips dirty-and-save)");

# --- Phase B: modules restored, key present. self-migration encrypts.
Test::Without::Module->unimport(qw(Crypt::CBC Crypt::Cipher::AES Math::Random::Secure));
open(my $fh, '>', $keyfile) or die "cannot write $keyfile: $!";
print $fh ("G" x 256) . "\n";
close $fh;
chmod(0400, $keyfile);

$save_count = 0;
$reload = $nmisng->node(uuid => $uuid);
ok($reload, "node reloads with working crypto");
like(raw_community(), qr/^!!/, "stored secret migrated to ciphertext");
is($save_count, 1, "the successful migration saved exactly once");
is(NMISNG::Util::decrypt(raw_community()), "plainsecret",
	"and the ciphertext round-trips back to the original secret");

# --- Phase C: decrypt direction. Encryption disabled for the node (via its
# nmisng config), stored value undecryptable. decrypt returns it unchanged;
# the guard must leave it stored as-is (no '' wipe, no save).
$coll->update_one({uuid => $uuid},
	{'$set' => {'configuration.community' => '!!notrealciphertext'}});
my %conf_disabled = %$C;
$conf_disabled{global_enable_password_encryption} = 'false';
my $nmisng_disabled = NMISNG->new(config => \%conf_disabled, log => $logger);
$save_count = 0;
$reload = $nmisng_disabled->node(uuid => $uuid);
ok($reload, "node reloads through the decrypt branch");
is(raw_community(), '!!notrealciphertext',
	"an undecryptable stored value is left untouched (no wipe)");
is($save_count, 0, "a failed decryption triggers NO save");

# --- Phase D: decrypt direction with working crypto down-migrates.
my $cipher = NMISNG::Util::encrypt("plainsecret", '', '', 1);
$coll->update_one({uuid => $uuid},
	{'$set' => {'configuration.community' => $cipher}});
$reload = $nmisng_disabled->node(uuid => $uuid);
is(raw_community(), "plainsecret",
	"a decryptable value down-migrates to plaintext when encryption is disabled");

$nmisng->get_db()->drop();
done_testing();
