#!/usr/bin/perl
# OMK-12827 Slice B: _resolve_seed owns master key location, permission
# validation, and the create-only-at-default-path rule. A custom
# master_key_file is never created by NMIS; a group- or world-writable key
# file is refused; a good file returns its first line chomped.
#
# The path is a custom (non-default) location supplied via the normal
# NMIS_* env override, so the never-create rule applies on every failure.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use File::Temp;

my $tempdir;
BEGIN {
	$tempdir = File::Temp::tempdir(CLEANUP => 1);
	$ENV{NMIS_MASTER_KEY_FILE} = "$tempdir/custom-master.key";
}

use Test::More;
use NMISNG::Util;
use NMISNG::Log;

my $keyfile = "$tempdir/custom-master.key";
my $logger  = NMISNG::Log->new(level => 'fatal', path => undef);

my $conf = NMISNG::Util::loadConfTable();
is($conf->{master_key_file}, $keyfile,
	"master_key_file is settable through the NMIS_* env override");

# --- missing custom file: fail, and never create it ---
my ($seed, $err) = NMISNG::Util::_resolve_seed($logger);
is($seed, undef, "missing custom key file resolves to no seed");
like($err, qr/never creates a key at a custom/,
	"error explains the never-create rule for custom paths");
ok(!-e $keyfile, "the custom key file was NOT created");

# --- good file: seed returned, first line, chomped ---
open(my $fh, '>', $keyfile) or die "cannot write $keyfile: $!";
print $fh "SEEDVALUE0123456789\n";
close $fh;
chmod(0400, $keyfile);
($seed, $err) = NMISNG::Util::_resolve_seed($logger);
is($seed, 'SEEDVALUE0123456789', "readable key file returns its first line chomped");
is($err, undef, "no error for a good key file");

# --- group- or world-writable: refused outright ---
chmod(0660, $keyfile);
($seed, $err) = NMISNG::Util::_resolve_seed($logger);
is($seed, undef, "group-writable key file is refused");
like($err, qr/group- or world-writable/, "error names the permission problem");

chmod(0446, $keyfile);
($seed, $err) = NMISNG::Util::_resolve_seed($logger);
is($seed, undef, "world-writable key file is refused");

# --- back to sane perms: works again ---
chmod(0400, $keyfile);
($seed, $err) = NMISNG::Util::_resolve_seed($logger);
is($seed, 'SEEDVALUE0123456789', "key file works again once permissions are fixed");

# --- empty file: refused ---
chmod(0644, $keyfile);  # Make writable for truncation
open($fh, '>', $keyfile) or die "cannot truncate $keyfile: $!";
close $fh;
chmod(0400, $keyfile);
($seed, $err) = NMISNG::Util::_resolve_seed($logger);
is($seed, undef, "empty key file resolves to no seed");
like($err, qr/empty/, "error says the key file is empty");

done_testing();
