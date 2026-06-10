#
# NMISNG::Test::Fakes — shared in-memory stand-ins for engine-level tests.
#
# One superset of the fake hierarchies that used to be copied (and drift)
# across t_engine_http.pl, t_engine_http_auth.pl and t_polling_redis.pl.
# These are deliberately dumb: enough surface for NMISNG::Sys::Engine::*
# unit tests without MongoDB, real logging, or a real Sys.
#
# Note: FakeSys and FakeNode swallow unknown methods via AUTOLOAD (returning
# undef) — convenient for engines that probe optional accessors, but it also
# means a typo'd method call returns undef instead of dying. Assert on
# behaviour, not on "it didn't crash".
#
package NMISNG::Test::Fakes;
use strict;
use warnings;
our $VERSION = "1.0.0";

package NMISNG::Test::FakeLog;
use strict;
use warnings;
sub new { return bless {}, shift; }
sub error { shift; my $m = shift; print STDERR "ERROR: $m\n" if $ENV{DEBUG}; }
sub warn  { shift; my $m = shift; print STDERR "WARN: $m\n"  if $ENV{DEBUG}; }
sub info   { shift; }
sub debug  { shift; } sub debug1 { shift; } sub debug2 { shift; }
sub debug3 { shift; } sub debug4 { shift; }
our $AUTOLOAD;
sub AUTOLOAD { return 1; }    # swallow anything else (logprefix etc.)
sub DESTROY  { }

package NMISNG::Test::FakeNmisng;
use strict;
use warnings;
sub new
{
	my ($class, %a) = @_;
	my $self = bless { %a }, $class;
	$self->{config} //= {};
	return $self;
}
sub log    { $_[0]{log} //= NMISNG::Test::FakeLog->new(); return $_[0]{log}; }
sub config { return $_[0]{config}; }

package NMISNG::Test::FakeNode;
use strict;
use warnings;
sub new  { my ($class, %a) = @_; return bless { %a }, $class; }
sub uuid { return $_[0]{uuid}; }
sub name { return $_[0]{name} // 'fakenode'; }
our $AUTOLOAD;
sub AUTOLOAD { return undef; }
sub DESTROY  { }

package NMISNG::Test::FakeInventory;
use strict;
use warnings;
sub new  { my ($class, $data) = @_; return bless { data => $data }, $class; }
sub data { return $_[0]{data}; }

package NMISNG::Test::FakeSys;
use strict;
use warnings;
sub new
{
	my ($class, %a) = @_;
	my $self = bless { %a }, $class;
	$self->{name} //= 'testnode';
	$self->{cfg}  //= { node => $a{node_cfg} // {
		host => '127.0.0.1', uuid => 'test-uuid', name => $self->{name},
	}};
	# vardir is the auth tests' shorthand for an nmisng whose config points
	# the token cache at a throwaway directory.
	$self->{nmisng} //= NMISNG::Test::FakeNmisng->new(
		defined $a{vardir} ? (config => { '<nmis_var>' => $a{vardir} }) : () );
	return $self;
}
sub nmisng      { return $_[0]{nmisng}; }
sub nmisng_node { return $_[0]{node}; }

# Minimal reimplementation of Sys::eval_string's CVAR handling, used by the
# HTTP engine's control/calculate expressions. Returns (error) or (undef, result).
sub eval_string
{
	my ($self, %args) = @_;
	my $input = $args{string};
	my $vars  = $args{variables} // [];
	my %cvar;
	my $consume = $input;
	my $rebuilt = '';
	while ($consume =~ s/^(.*?)(CVAR(\d)?=(\w+);|\$CVAR(\d)?)//)
	{
		$rebuilt .= $1;
		my ($n, $decl, $use) = ($3, $4, $5);
		$n = 0 if (!defined $n);
		if (defined $decl)
		{
			for my $src (@$vars)
			{
				next if (ref $src ne 'HASH' || !exists $src->{$decl});
				$cvar{$n} = $src->{$decl};
				last;
			}
			return ("CVAR$n: unknown name '$decl'") if (!exists $cvar{$n});
		}
		else
		{
			return ("CVAR$use undefined") if (!exists $cvar{$use});
			$rebuilt .= $cvar{$use};
		}
	}
	$rebuilt .= $consume;
	my $r = $args{context};
	$r = eval $rebuilt;
	return ("eval failed: $@") if $@;
	return (undef, $r);
}
our $AUTOLOAD;
sub AUTOLOAD { return undef; }
sub DESTROY  { }

1;
