package IntfTestHarness;
use strict; use warnings;
use Clone qw(clone);
use JSON::XS;
use File::Path qw(make_path);
use FindBin;
use Scalar::Util;
use Test::More;

# Convert BSON typed values (BSON::OID, BSON::String, BSON::Time, etc.) to
# plain Perl scalars so that JSON::XS can encode them without allow_blessed.
# Called before _strip so the result is always a plain scalar/hash/array.
sub _debless {
    my ($v) = @_;
    my $blessed = Scalar::Util::blessed($v);
    return $v unless defined $blessed;
    if ($blessed eq 'BSON::OID') {
        return "$v";  # OID stringifies to its hex string
    } elsif ($blessed eq 'BSON::String') {
        return $v->value;
    } elsif ($blessed eq 'BSON::Time') {
        return $v->value;  # milliseconds since epoch as integer
    } elsif ($blessed eq 'BSON::Int32' || $blessed eq 'BSON::Int64') {
        return $v->value;
    } elsif ($blessed eq 'BSON::Double') {
        return $v->value;
    } elsif ($blessed eq 'BSON::Boolean') {
        return $v ? 1 : 0;
    } else {
        # Unknown blessed ref: stringify
        return "$v";
    }
}

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

our $CLUSTER_SENTINEL = "<CLUSTER_ID>";
our $OID_SENTINEL     = "<OID>";

# Keys that are per-run ephemeral: stripped before golden comparison.
# inventory_id is a BSON::OID assigned at insert time, so varies per run.
my %VOLATILE = map { $_ => 1 } qw(lastupdate lastupdate_utc expire_at _id time _ts inventory_id);

# recursively: drop volatile keys, and replace every occurrence of the run's
# cluster_id (in hash values, array elements, and substrings of scalar strings,
# including the values of "path.N" query keys) with a fixed sentinel so goldens
# are portable across environments with different cluster_ids.
# node_uuid is already deterministic in tests, so it is left alone.
sub _strip {
    my ($node, $cluster_id) = @_;
    # Convert BSON typed objects to plain Perl values before further processing.
    $node = _debless($node) if Scalar::Util::blessed($node);
    if (ref($node) eq 'HASH') {
        for my $k (keys %$node) {
            if ($VOLATILE{$k}) { delete $node->{$k}; next; }
            $node->{$k} = _strip($node->{$k}, $cluster_id);
        }
    } elsif (ref($node) eq 'ARRAY') {
        $_ = _strip($_, $cluster_id) for @$node;
    } elsif (defined($node) && !ref($node) && defined($cluster_id) && length($cluster_id)
             && !Scalar::Util::looks_like_number($node)) {
        # only touch non-numeric scalars; the cluster_id is a UUID (never numeric)
        # and any value containing it is a string, so numeric values keep their
        # JSON number type (looks_like_number does not stringify the scalar).
        $node =~ s/\Q$cluster_id\E/$CLUSTER_SENTINEL/g;
    }
    return $node;
}

# resolve the run's cluster_id from the nmisng config (empty/undef -> no substitution)
sub _cluster_id {
    my ($self) = @_;
    return undef unless ($self->{nmisng} && $self->{nmisng}->can('config'));
    my $c = $self->{nmisng}->config;
    return (ref($c) eq 'HASH') ? $c->{cluster_id} : undef;
}

# Produce a stable sort key for a DB-op or final-inventory entry so the
# golden is reproducible across runs regardless of hash-iteration order.
sub _sort_key {
    my ($v) = @_;
    return '' unless ref($v) eq 'HASH';
    # For DB ops: use op + canonical JSON of the query (minus OID values).
    # For final inventory entries: use data.ifDescr or description.
    my $op    = $v->{op} // '';
    my $ifD   = (ref($v->{data}) eq 'HASH') ? ($v->{data}{ifDescr} // $v->{data}{ifIndex} // '') : '';
    my $desc  = $v->{description} // $ifD;
    # Extract a stable path fragment from query if present
    my $qpath = '';
    if (ref($v->{query}) eq 'HASH') {
        for my $k (sort keys %{$v->{query}}) {
            my $val = $v->{query}{$k} // '';
            $qpath .= "$k=$val;";
        }
    }
    # For record data, try to grab ifDescr or description
    my $rdesc = '';
    if (ref($v->{record}) eq 'HASH') {
        my $d = $v->{record}{data} // $v->{record}{'$set'}{data} // {};
        $rdesc = (ref($d) eq 'HASH') ? ($d->{ifDescr} // $d->{description} // '') : '';
        $rdesc ||= $v->{record}{description} // '';
    }
    return "$op|$desc|$qpath|$rdesc";
}

# Sort any subconcepts/data_info/dataset_info arrays within a hash (and recurse).
# This normalises internal ordering of BSON arrays that are written in
# hash-iteration order (non-deterministic between Perl versions/runs).
# Also sorts plain string arrays (e.g. datasets lists) alphabetically.
sub _sort_inner_arrays {
    my ($v) = @_;
    return $v unless ref($v) eq 'HASH';
    for my $k (keys %$v) {
        next unless ref($v->{$k}) eq 'ARRAY';
        if ($k eq 'subconcepts' || $k eq 'data_info' || $k eq 'dataset_info') {
            # Sort by subconcept name
            @{$v->{$k}} = sort {
                my $as = ref($a) eq 'HASH' ? ($a->{subconcept} // '') : ($a // '');
                my $bs = ref($b) eq 'HASH' ? ($b->{subconcept} // '') : ($b // '');
                $as cmp $bs
            } @{$v->{$k}};
        } elsif ($k eq 'datasets') {
            # datasets is a plain array of strings - sort alphabetically
            @{$v->{$k}} = sort @{$v->{$k}};
        }
        # Recurse into array elements that are hashes
        for my $elem (@{$v->{$k}}) {
            _sort_inner_arrays($elem) if ref($elem) eq 'HASH';
        }
    }
    # Recurse into nested hashes (including $set, record, etc.)
    for my $k (keys %$v) {
        _sort_inner_arrays($v->{$k}) if ref($v->{$k}) eq 'HASH';
    }
    return $v;
}

sub _canonicalise {
    my ($payload) = @_;
    # Sort inner arrays (subconcepts, data_info) within each DB op record
    # and within final inventory entries, since array element order is
    # hash-iteration-dependent and varies between runs.
    if (ref($payload->{captured}{db}) eq 'ARRAY') {
        _sort_inner_arrays($_) for @{$payload->{captured}{db}};
        # Sort the DB write stream so interface-processing order does not affect the golden.
        @{$payload->{captured}{db}} = sort { _sort_key($a) cmp _sort_key($b) } @{$payload->{captured}{db}};
    }
    # Sort the final inventory list by ifDescr for stability, and sort inner arrays.
    if (ref($payload->{final}) eq 'ARRAY') {
        _sort_inner_arrays($_) for @{$payload->{final}};
        @{$payload->{final}} = sort {
            my $ad = (ref($a->{data}) eq 'HASH') ? ($a->{data}{ifDescr} // '') : '';
            my $bd = (ref($b->{data}) eq 'HASH') ? ($b->{data}{ifDescr} // '') : '';
            $ad cmp $bd;
        } @{$payload->{final}};
    }
    return $payload;
}

sub normalise { my ($self, $cap) = @_; return _strip(clone($cap), $self->_cluster_id); }

sub golden_path {
    my ($self, $case) = @_;
    return "$FindBin::Bin/testdata/intf_collect_golden/$case.json";
}

sub assert_golden {
    my ($self, $case, $captured, $final) = @_;
    my $cluster_id = $self->_cluster_id;
    my $payload = _canonicalise({
        captured => $self->normalise($captured),
        final    => _strip(clone($final), $cluster_id),
    });
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
        # ifLastChange (1.3.6.1.2.1.2.2.1.9): emit a non-zero value so iflastchange_detect
        # sees a changed value vs. a seeded ifLastChangeSec of 0.
        $w{"1.3.6.1.2.1.2.2.1.9.$i"} = 500;  # 5 seconds in 1/100s ticks
    }

    # _reindex: move per-index OIDs from old ifIndex to new ifIndex (same ifDescr).
    # For each (from => to) pair: rename all OIDs ending in .$from to .$to and
    # update the ifIndex value OID to $to.
    if (ref($a{_reindex}) eq 'HASH') {
        for my $from (keys %{$a{_reindex}}) {
            my $to = $a{_reindex}{$from};
            my @move = grep { /\.\Q$from\E$/ } keys %w;
            for my $old (@move) {
                (my $new = $old) =~ s/\.\Q$from\E$/.$to/;
                $w{$new} = $w{$old};
                delete $w{$old};
            }
            # update the ifIndex value itself to the new index
            $w{"1.3.6.1.2.1.2.2.1.1.$to"} = $to;
        }
    }

    return \%w;
}
1;
