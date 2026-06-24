package IntfTestHarness;
use strict; use warnings;
use Clone qw(clone);
use JSON::XS;
use File::Path qw(make_path);
use FindBin;
use Test::More;

our (@DB, @RRD, @EVENTS);
my $installed = 0;

sub new {
    my ($class, %a) = @_;
    make_path($a{rrd_dir}) if ($a{rrd_dir} && !-d $a{rrd_dir});
    return bless { nmisng => $a{nmisng}, rrd_dir => $a{rrd_dir} }, $class;
}

sub install_capture {
    my ($self) = @_;
    return if $installed; $installed = 1;
    no warnings 'redefine';

    require NMISNG::DB;
    for my $op (qw(update insert remove)) {
        my $orig = \&{"NMISNG::DB::$op"};
        no strict 'refs';
        *{"NMISNG::DB::$op"} = sub {
            my %args = @_;
            push @DB, clone({ op => $op, query => $args{query}, record => $args{record},
                              upsert => $args{upsert}, multiple => $args{multiple},
                              just_one => $args{just_one} });
            return $orig->(@_);
        };
    }
    require NMISNG::Sys;
    *NMISNG::Sys::create_update_rrd = sub {
        my ($s, %args) = @_;
        push @RRD, clone({ node => $s->{name}, type => $args{type},
                           data => $args{data} });
        if (ref($args{inventory})) {
            $args{inventory}->set_subconcept_type_storage(
                subconcept => ($args{type}//'unknown'), type => 'rrd',
                data => "/nodes/$s->{name}/mock-".($args{type}//'unknown').".rrd");
        }
        return 1;
    };
    require Compat::NMIS;
    my $orig_notify = \&Compat::NMIS::notify;
    *Compat::NMIS::notify = sub {
        my %args = @_;
        push @EVENTS, clone({ event => $args{event}, element => $args{element},
                              level => $args{level}, details => $args{details} });
        return; # do not raise real events in tests
    };
}

sub reset_capture { @DB = (); @RRD = (); @EVENTS = (); }
sub captured { return { db => clone(\@DB), rrd => clone(\@RRD), events => clone(\@EVENTS) }; }

my %VOLATILE = map { $_ => 1 } qw(lastupdate lastupdate_utc expire_at _id time _ts);
sub _strip {
    my ($node) = @_;
    if (ref($node) eq 'HASH') {
        for my $k (keys %$node) {
            if ($VOLATILE{$k}) { delete $node->{$k}; next; }
            _strip($node->{$k});
        }
    } elsif (ref($node) eq 'ARRAY') { _strip($_) for @$node; }
    return $node;
}
sub normalise { my ($self, $cap) = @_; return _strip(clone($cap)); }

sub golden_path {
    my ($self, $case) = @_;
    return "$FindBin::Bin/testdata/intf_collect_golden/$case.json";
}

sub assert_golden {
    my ($self, $case, $captured, $final) = @_;
    my $payload = { captured => $self->normalise($captured),
                    final    => _strip(clone($final)) };
    my $path = $self->golden_path($case);
    if ($ENV{RECORD_GOLDEN}) {
        make_path("$FindBin::Bin/testdata/intf_collect_golden");
        open my $fh, ">", $path or die "cannot write golden $path: $!";
        print $fh JSON::XS->new->canonical(1)->pretty(1)->encode($payload);
        close $fh;
        pass("recorded golden for $case");
        return;
    }
    open my $fh, "<", $path or do { fail("golden missing for $case: $path"); return; };
    local $/; my $want = JSON::XS->new->decode(<$fh>); close $fh;
    is_deeply($payload, $want, "golden matches for $case");
}

sub generate_interface_walk {
    my (%a) = @_;
    my $n = $a{count} // 5;
    my %w = ('1.3.6.1.2.1.2.1.0' => $n);
    for my $i (1 .. $n) {
        $w{"1.3.6.1.2.1.2.2.1.1.$i"} = $i;
        $w{"1.3.6.1.2.1.2.2.1.2.$i"} = "GigabitEthernet0/$i";
        $w{"1.3.6.1.2.1.2.2.1.3.$i"} = 6;
        $w{"1.3.6.1.2.1.2.2.1.5.$i"} = 1000000000;
        $w{"1.3.6.1.2.1.2.2.1.6.$i"} = sprintf("00 11 22 %02x %02x %02x", ($i>>16)&255, ($i>>8)&255, $i&255);
        $w{"1.3.6.1.2.1.2.2.1.7.$i"} = ($a{admin} && defined $a{admin}{$i}) ? $a{admin}{$i} : 1;
        $w{"1.3.6.1.2.1.2.2.1.8.$i"} = ($a{oper}  && defined $a{oper}{$i})  ? $a{oper}{$i}  : 1;
    }
    return \%w;
}
1;
