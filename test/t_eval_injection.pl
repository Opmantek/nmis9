#!/usr/bin/perl
#
# t_eval_injection.pl - security regression tests for OMK-12689 (C4) and the
# related control-expression path.
#
# Device-controlled values (SNMP/WMI fields) reach Perl eval via CVAR/$var
# substitution in model calculate/test/value/control expressions, and nmisd
# runs as root. These tests assert that a device value carrying a Perl payload
# is treated as DATA, never executed, while legitimate expressions keep working.
#
# Isolated by design: the real NMISNG::Sys expression logic runs; only the
# logger/nmisng sidecar is stubbed, so no MongoDB or full config is needed.
#
use strict;
use warnings;
our $VERSION = "1.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use File::Temp ();

use NMISNG::Sys;

# --- minimal stubs so eval_string/parseString can be called without Mongo ---
# eval_string touches only $self->nmisng->log->debugN; stub those as no-ops.
{
	package T::Log;
	sub new { bless {}, shift }
	our $AUTOLOAD;
	sub AUTOLOAD { return; }    # debug/debug2/debug3/info/warn/error/fatal -> no-op
	sub DESTROY  { }
}
{
	package T::Nmisng;
	sub new { bless {}, shift }
	sub log { $_[0]->{log} ||= T::Log->new }
	sub config { {} }
}

my $sys = bless { _nmisng => T::Nmisng->new }, 'NMISNG::Sys';

# a Perl payload of the shape a crafted device field would carry.
# "//1" keeps the whole expression truthy so a naive eval still "succeeds".
sub payload_touching
{
	my ($marker) = @_;
	return 'system("touch ' . $marker . '") // 1';
}

# ============================================================
# Sink 1: NMISNG::Sys::eval_string (calculate)
# ============================================================
{
	my $dir    = File::Temp->newdir();
	my $marker = "$dir/pwned_calc";

	my ( $err, $res ) = $sys->eval_string(
		string   => 'CVAR0=ifDescr;$CVAR0',
		context  => 1,
		variables => [ { ifDescr => payload_touching($marker) } ],
	);

	ok( !-e $marker, 'sink1/eval_string: device CVAR value is NOT executed as code' );
	is( $res, payload_touching("$dir/pwned_calc"),
		'sink1/eval_string: crafted CVAR value is returned verbatim as data' );
}

# --- functionality guards: these pass today and MUST stay green after the fix ---
{
	my ( $err, $res ) = $sys->eval_string( string => '$r * 8', context => 100 );
	is( $res, 800, 'sink1: $r arithmetic still works' );
	ok( !defined $err, 'sink1: $r arithmetic has no error' );
}
{
	my ( $err, $res ) = $sys->eval_string(
		string    => 'CVAR0=speed;$CVAR0 * 8',
		context   => 1,
		variables => [ { speed => 100 } ],
	);
	is( $res, 800, 'sink1: numeric CVAR used in arithmetic still computes' );
}
{
	my ( $err, $res ) = $sys->eval_string(
		string    => 'CVAR0=ifDescr;$CVAR0',
		context   => 1,
		variables => [ { ifDescr => 'GigabitEthernet0/1' } ],
	);
	is( $res, 'GigabitEthernet0/1', 'sink1: benign string CVAR flows through as its value' );
}
{
	my ( $err, $res ) = $sys->eval_string(
		string    => 'CVAR0=ifDescr;"port $CVAR0"',
		context   => 1,
		variables => [ { ifDescr => 'Gi0/1' } ],
	);
	is( $res, 'port Gi0/1', 'sink1: CVAR interpolation in a string still works' );
}
{
	my ( $err, $res ) = $sys->eval_string(
		string    => 'CVAR0=nosuch;$CVAR0',
		context   => 1,
		variables => [ {} ],
	);
	like( $err, qr/unknown object/, 'sink1: unknown CVAR object still reports an error' );
}

# ============================================================
# Sink 2: NMISNG::Node::handle_custom_alerts (alert test/value)
#
# This path cannot be driven without Mongo (it walks inventory), so the fix is
# a delegation refactor: the duplicated CVAR loop and its own string eval are
# replaced by a call to the hardened eval_string. The security property is then
# inherited from sink 1 above; here we assert the invariant that the independent
# eval sink is gone and the safe evaluator is used. Behavioural alert regression
# is covered by t_sys.pl in the in-container gate.
# ============================================================
{
	my $node_pm = "$FindBin::Bin/../lib/NMISNG/Node.pm";
	open( my $fh, '<', $node_pm ) or die "cannot read $node_pm: $!";
	local $/;
	my $src = <$fh>;
	close $fh;

	# isolate the handle_custom_alerts sub body
	my ($body) = $src =~ /\nsub handle_custom_alerts\b(.*?)\nsub /s;
	ok( defined $body && length $body, 'sink2: located handle_custom_alerts body' );

	unlike( $body, qr/eval \s* \{ \s* eval \s* \$rebuilt/x,
		'sink2: the independent string-eval of device CVAR data is removed' );
	unlike( $body, qr/\$rebuilt \s* \.= \s* \$CVAR\[/x,
		'sink2: the duplicated raw-value CVAR concatenation is removed' );
	like( $body, qr/eval_string/,
		'sink2: alert test/value now go through the hardened eval_string' );
}

# ============================================================
# Sink 3: NMISNG::Sys::parseString eval mode (control, $var substitution)
#
# control expressions and $var substitution eval device values that today are
# defended only by single-quote stripping + wrapping. That defence corrupts
# legitimate values and is escapable. The fix binds substituted values as data
# (%EXTRAS) in eval mode; the non-eval textual path is unchanged.
# ============================================================

# RED driver: a benign device value containing a single quote must compare
# equal. Current code strips the quote (data corruption); data-binding fixes it.
{
	my $str = q{($ifDescr eq q{Bob's port}) ? 1 : 0};
	my $res = $sys->parseString(
		string => $str,
		extras => { ifDescr => "Bob's port" },
		eval   => 1,
	);
	is( $res, 1, 'sink3/parseString: single-quote value preserved as data (not stripped)' );
}

# Security invariant: a value crafted to break out of the quoting must not
# execute. Guaranteed post-fix by data-binding.
{
	my $dir     = File::Temp->newdir();
	my $marker  = "$dir/pwned_control";
	my $payload = 'z' . chr(92);    # value ending in a backslash (escapes the wrap quote)
	my $res = $sys->parseString(
		string => '($a, $b) ? 1 : 0',
		extras => { a => $payload, b => ', system("touch ' . $marker . '"), 1' },
		eval   => 1,
	);
	ok( !-e $marker, 'sink3/parseString: quote-escape breakout does not execute' );
}

# Functionality guard: numeric control comparison still works.
{
	my $res = $sys->parseString(
		string => '($ifType == 6) ? 1 : 0',
		extras => { ifType => 6 },
		eval   => 1,
	);
	is( $res, 1, 'sink3: numeric control comparison still evaluates' );
}

# Defence in depth: eval mode must bind as data even when filter is also set.
# No shipped caller passes eval=1 with filter=1, but eval mode must never fall
# back to the escapable quote-splice path.
{
	my $str = q{($ifDescr eq q{Bob's port}) ? 1 : 0};
	my $res = $sys->parseString(
		string => $str,
		extras => { ifDescr => "Bob's port" },
		eval   => 1,
		filter => 1,
	);
	is( $res, 1, 'sink3: eval mode binds as data even with filter set' );
}

# Non-eval path must be unchanged: textual substitution still returns the string.
{
	my $res = $sys->parseString(
		string => 'prefix-$node-suffix',
		extras => { node => 'router1' },
		eval   => 0,
	);
	is( $res, 'prefix-router1-suffix', 'sink3: non-eval textual substitution preserved' );
}

done_testing();
