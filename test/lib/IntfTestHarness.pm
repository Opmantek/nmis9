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
            # bulk_used: whether this write was routed through a bulk batch
            # (bulk_save path) vs a direct collection op. The bulk object
            # itself is not serialisable, so we record only its presence as a
            # boolean -- this is what makes BULK_TIMED_DATA on/off observable
            # in the golden (the timed-data insert/upsert carries bulk_used=1
            # under bulk, 0 when saved directly).
            push @DB, clone({ op => $op, query => $args{query}, record => $args{record},
                              upsert => $args{upsert}, multiple => $args{multiple},
                              just_one => $args{just_one},
                              bulk_used => ($args{bulk} ? 1 : 0) });
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
our $SERVER_SENTINEL  = "<SERVER_NAME>";
our $OID_SENTINEL     = "<OID>";

# Keys that are per-run ephemeral: stripped before golden comparison.
# inventory_id is a BSON::OID assigned at insert time, so varies per run.
my %VOLATILE = map { $_ => 1 } qw(lastupdate lastupdate_utc expire_at _id time _ts inventory_id);

# recursively: drop volatile keys, replace every occurrence of the run's
# cluster_id (in hash values, array elements, and substrings of scalar strings,
# including the values of "path.N" query keys) with a fixed sentinel, and replace
# the run's server_name with a sentinel so goldens are portable across environments
# with different cluster_ids/server_names. node_uuid is already deterministic in
# tests, so it is left alone.
#
# cluster_id is a UUID (globally unique) so it is safe to substring-replace anywhere.
# server_name is a short, arbitrary config string (e.g. "nmis"), so a blind substring
# replace could corrupt unrelated values that happen to contain it (a node name, an
# rrd path). We therefore substitute server_name ONLY where it is the *value of a
# "server_name" key* ($under_server_key), which is exactly where it is written into
# records, and is robust regardless of what the server_name string is.
sub _strip {
    my ($node, $cluster_id, $server_name, $under_server_key) = @_;
    # Convert BSON typed objects to plain Perl values before further processing.
    $node = _debless($node) if Scalar::Util::blessed($node);
    if (ref($node) eq 'HASH') {
        for my $k (keys %$node) {
            if ($VOLATILE{$k}) { delete $node->{$k}; next; }
            $node->{$k} = _strip($node->{$k}, $cluster_id, $server_name, ($k eq 'server_name'));
        }
    } elsif (ref($node) eq 'ARRAY') {
        $_ = _strip($_, $cluster_id, $server_name, $under_server_key) for @$node;
    } elsif (defined($node) && !ref($node) && !Scalar::Util::looks_like_number($node)) {
        # only touch non-numeric scalars so numeric values keep their JSON number
        # type (looks_like_number does not stringify the scalar).
        if (defined($cluster_id) && length($cluster_id)) {
            $node =~ s/\Q$cluster_id\E/$CLUSTER_SENTINEL/g;
        }
        # server_name: only when this scalar is the value of a server_name key
        if ($under_server_key && defined($server_name) && length($server_name)
            && $node eq $server_name) {
            $node = $SERVER_SENTINEL;
        }
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

# resolve the run's server_name from the nmisng config (empty/undef -> no substitution).
# server_name comes from config->{server_name} (same value get_server_name returns for
# the local cluster_id), which is what gets written onto inventory records.
sub _server_name {
    my ($self) = @_;
    return undef unless ($self->{nmisng} && $self->{nmisng}->can('config'));
    my $c = $self->{nmisng}->config;
    return (ref($c) eq 'HASH') ? $c->{server_name} : undef;
}

my $_canon_json = JSON::XS->new->canonical(1)->allow_nonref(1);

# Phase signature for a DB op: op-class + which query keys are present +
# which record top-level keys are present. This is mostly VALUE-FREE (it
# ignores the ifDescr/index/OID that vary per interface) so that all ops
# belonging to the same collect_intf_data phase that differ ONLY in interface
# identity share a signature -- those are the genuinely non-deterministic
# (hash-iteration-ordered) phase-4 writes that we then sort. Ops from
# different phases (different query/record shape) get different signatures and
# act as ordering barriers, so the overall phase sequence is preserved.
#
# Exception: a "$set" carrying a single fixed semantic flag (historic) is a
# deterministic, fixed-order write (e.g. the phase-9 historic pair always
# emits historic=1 then historic=0 from one bulk_update_inventory_historic
# call). We fold that flag's VALUE into the signature so the two ops get
# distinct signatures, become length-1 runs, and keep their real emission
# order instead of being sorted against each other.
my %FIXED_FLAG = (historic => 1);
sub _phase_sig {
    my ($v) = @_;
    return '' unless ref($v) eq 'HASH';
    my $op = $v->{op} // '';
    my $qk = (ref($v->{query}) eq 'HASH') ? join(',', sort keys %{$v->{query}}) : '';
    my $rk = '';
    if (ref($v->{record}) eq 'HASH') {
        # include top-level record keys, plus the keys under $set if present,
        # so a "$set:{historic}" op is distinguished from a "$set:{dataset_info}" op
        my @top = sort keys %{$v->{record}};
        my $set = $v->{record}{'$set'};
        my $setk = '';
        if (ref($set) eq 'HASH') {
            my @sk = sort keys %$set;
            $setk = '{'.join(',', @sk).'}';
            # fold the value of a single fixed-flag $set into the signature
            if (@sk == 1 && $FIXED_FLAG{$sk[0]} && !ref($set->{$sk[0]})) {
                $setk .= '='.$set->{$sk[0]};
            }
        }
        $rk = join(',', @top) . $setk;
    }
    return "$op|q[$qk]|r[$rk]";
}

# Total ordering key for a DB op: canonical JSON of the whole op. Guarantees
# two distinct ops never collide on key (no reliance on sort stability for
# ties), so the within-run ordering is fully deterministic.
sub _total_key {
    my ($v) = @_;
    return $_canon_json->encode($v);
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

# Stabilise ONLY the non-deterministic ordering (collect_intf_data phase 4
# iterates interfaces in hash order) while preserving the overall phase
# sequence. We do this by sorting within maximal contiguous runs of ops that
# share a phase signature; phase transitions act as barriers and are never
# reordered. The phase-9 historic pair (always the last block) and the
# index-ordered phase-5/8 saves keep their real execution position.
sub _stabilise_db_stream {
    my ($db) = @_;
    return unless ref($db) eq 'ARRAY' && @$db;
    my @out;
    my $i = 0;
    while ($i < @$db) {
        my $sig = _phase_sig($db->[$i]);
        my $j = $i;
        $j++ while ($j < @$db && _phase_sig($db->[$j]) eq $sig);
        # contiguous run [$i, $j): sort by total key (canonical JSON)
        my @run = @{$db}[$i .. $j-1];
        @run = sort { _total_key($a) cmp _total_key($b) } @run if (@run > 1);
        push @out, @run;
        $i = $j;
    }
    @$db = @out;
}

sub _canonicalise {
    my ($payload) = @_;
    # Sort inner arrays (subconcepts, data_info, dataset_info, datasets) within
    # each DB op record and within final inventory entries, since their element
    # order is hash-iteration-dependent and varies between runs. This must run
    # BEFORE _stabilise_db_stream so the total-key (canonical JSON) is itself
    # stable.
    if (ref($payload->{captured}{db}) eq 'ARRAY') {
        _sort_inner_arrays($_) for @{$payload->{captured}{db}};
        _stabilise_db_stream($payload->{captured}{db});
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

sub normalise { my ($self, $cap) = @_; return _strip(clone($cap), $self->_cluster_id, $self->_server_name); }

sub golden_path {
    my ($self, $case) = @_;
    return "$FindBin::Bin/testdata/intf_collect_golden/$case.json";
}

sub assert_golden {
    my ($self, $case, $captured, $final) = @_;
    my $cluster_id = $self->_cluster_id;
    my $server_name = $self->_server_name;
    my $payload = _canonicalise({
        captured => $self->normalise($captured),
        final    => _strip(clone($final), $cluster_id, $server_name),
    });
    my $path = $self->golden_path($case);
    if ($ENV{RECORD_GOLDEN}) {
        # RECORD_ONLY=<case>[,<case>...] restricts recording to the named case(s) so a
        # single golden can be (re)baselined without rewriting the others (used to record
        # the B1-object dirty-save case against pre-refactor code).
        if ($ENV{RECORD_ONLY}) {
            my %only = map { $_ => 1 } split(/,/, $ENV{RECORD_ONLY});
            if (!$only{$case}) {
                pass("skipped recording $case (RECORD_ONLY)");
                return;
            }
        }
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

# IF-MIB / ifXTable counter OIDs that the Generic model's interface + pkts rrd
# sections read (verified against Model-Generic / Common-Cisco-* interface defs).
# Used when a case asks for counters => 1 so getData returns real (non-noSuchInstance)
# traffic values, which makes the interface genuinely collectable.
my %COUNTER_OID = (
    ifInOctets       => '1.3.6.1.2.1.2.2.1.10',
    ifInUcastPkts    => '1.3.6.1.2.1.2.2.1.11',
    ifInNUcastPkts   => '1.3.6.1.2.1.2.2.1.12',
    ifInDiscards     => '1.3.6.1.2.1.2.2.1.13',
    ifInErrors       => '1.3.6.1.2.1.2.2.1.14',
    ifOutOctets      => '1.3.6.1.2.1.2.2.1.16',
    ifOutUcastPkts   => '1.3.6.1.2.1.2.2.1.17',
    ifOutNUcastPkts  => '1.3.6.1.2.1.2.2.1.18',
    ifOutDiscards    => '1.3.6.1.2.1.2.2.1.19',
    ifOutErrors      => '1.3.6.1.2.1.2.2.1.20',
    ifHCInOctets     => '1.3.6.1.2.1.31.1.1.1.6',
    ifHCInUcastPkts  => '1.3.6.1.2.1.31.1.1.1.7',
    ifHCOutOctets    => '1.3.6.1.2.1.31.1.1.1.10',
    ifHCOutUcastPkts => '1.3.6.1.2.1.31.1.1.1.11',
);

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

        # counters => 1: emit interface/pkts traffic counters so the interface is
        # genuinely collectable (getData returns numeric values, not noSuchInstance).
        if ($a{counters}) {
            my $base = $a{counter_base} // 1000;
            my $j = 0;
            for my $name (sort keys %COUNTER_OID) {
                # deterministic, per-index, per-ds distinct values
                $w{"$COUNTER_OID{$name}.$i"} = $base + $i * 100 + $j++;
            }
        }
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
