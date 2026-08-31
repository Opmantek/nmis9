#!/usr/bin/perl
# OMK-12827 Slice C: the encryption-of-secrets master key must survive
# container recreate. Asserts both shipped compose files mount the
# nmis_master_key named volume at /usr/local/etc/firstwave (the DIRECTORY,
# so first boot can create the key inside it) and declare the volume.
# Dependency-free static parsing, matching t_mongo_exposure.t.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $root = "$Bin/..";

my %composes = (
	'compose.yaml'                     => "$root/compose.yaml",
	'conf-default/docker/compose.yaml' => "$root/conf-default/docker/compose.yaml",
);

for my $name (sort keys %composes) {
	open(my $fh, '<', $composes{$name}) or BAIL_OUT("cannot read $composes{$name}: $!");
	my $content = do { local $/; <$fh> };
	close $fh;

	like($content, qr{^\s*-\s*nmis_master_key:/usr/local/etc/firstwave\s*$}m,
		"$name mounts nmis_master_key at /usr/local/etc/firstwave");
	like($content, qr{^\s{2}nmis_master_key:\s*$}m,
		"$name declares the nmis_master_key named volume");
	unlike($content, qr{nmis_master_key:/usr/local/etc/firstwave/master\.key},
		"$name mounts the directory, not the key file");
	like($content, qr{never bake a key}i,
		"$name carries the image-baked-key guard comment");
}

done_testing();
