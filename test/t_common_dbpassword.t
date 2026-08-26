#!/usr/bin/perl
# OMK-12709: the detect-only default-password classifier.
use strict; use warnings;
use FindBin;
use Test::More;

my $helper = "$FindBin::Bin/../installer_hooks/common_dbpassword.sh";
ok(-f $helper, "common_dbpassword.sh exists");

# Drive the shell functions through /bin/sh, the interpreter the installer uses.
sub sh_is_insecure {
	my ($pw) = @_;
	my $q = $pw; $q =~ s/'/'\\''/g;
	my $rc = system("/bin/sh", "-c", ". '$helper'; nmis_dbpassword_is_insecure '$q'");
	return $rc == 0 ? 1 : 0;   # function returns 0 (shell true) when insecure
}

ok(sh_is_insecure('op42flow42'),  "the shipped default op42flow42 is insecure");
ok(sh_is_insecure('example'),     "the docker default example is insecure");
ok(sh_is_insecure('password'),    "password is insecure");
ok(sh_is_insecure(''),            "empty is insecure");
ok(!sh_is_insecure('a-real-generated-9f3c2a1b'), "a generated value is not flagged");

# advice mentions the migration path and the username
my $advice = qx{/bin/sh -c ". '$helper'; nmis_dbpassword_advice 'opUserRW'"};
like($advice, qr/opUserRW/, "advice names the user");
like($advice, qr/setup_mongodb\.pl/, "advice points at the migration tool");
unlike($advice, qr/simply edit|just change/i, "advice does not tell them to just edit db_password");

done_testing();
