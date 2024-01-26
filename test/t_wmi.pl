#!/usr/bin/perl
use Test::More;
use Test::Deep;
use Data::Dumper;
use Time::HiRes;

use lib qw(../lib);

my %args;
for my $maybe (@ARGV)
{
	if ($maybe =~ /^(host|username|password)=(.*)$/)
	{
		$args{$1} = $2;
	}
}
die "username=x, host=y, password=z args required!\n"
		if (!$args{username} or !$args{host} or !$args{password});

require_ok("NMISNG::WMI");

my $err = NMISNG::WMI->new(username => $args{username}, host => undef, password => '');
isnt(ref($err),"NMISNG::WMI", "WMI constructor refuses invalid/incomplete arguments (host)");

my $wmi = NMISNG::WMI->new(username => $args{username}, host => $args{host}, 
									 password => $args{password},
									 program => "../bin/wmic");
is(ref($wmi), "NMISNG::WMI", "WMI constructor worked");

# does it work at all?
my %res = $wmi->_run_query(query => 'select * from Win32_ComputerSystem');
is ($res{ok}, 1, "raw runquery w32 computer system reported ok") or diag(Dumper(\%res));

ok(ref($res{data}) eq "HASH"
	 && keys %{$res{data}} == 1
	 && ref($res{data}->{"Win32_ComputerSystem"}) eq "ARRAY"
	 && $res{data}->{"Win32_ComputerSystem"}->[0]->{TotalPhysicalMemory} > 0,
	 "raw runquery returned one record for w32 computer system") or diag(Dumper(\%res));

# does it report when given garbage?
%res = $wmi->_run_query(query => 'select');
isnt($res{ok},1,"bad runquery does not succeed");
isnt($res{error}, undef, "bad runquery returns error indicator") or diag($res{error});
like($res{error}, qr/wmic failed:.*NTSTATUS/, "bad runquery error indicator is ok");

# does it timeout when told to (and restore any alarm)?
my $oldalarm = 900;
alarm($oldalarm);

my $then = Time::HiRes::time;
my $desiredto = 4;
%res = $wmi->_run_query(query => 'select * from Win32_perfformatteddata',
												timeout => $desiredto);
my $now = Time::HiRes::time;
isnt($res{ok},1,"overlong query did report fault");
like($res{error},qr/timeout/, sprintf("overlong query did time out after %.3fs",
																			$now-$then));
cmp_ok($now-$then,"<=",$desiredto*1.2,"actual timeout within 120% of desired timeout");
my $remaining = alarm(0);
cmp_ok($remaining,">=",$oldalarm-$desiredto, "running alarm was restored ($remaining seconds)");


# does an overspecific select with empty response work out?
%res = $wmi->_run_query(query => 'select * from Win32_ComputerSystem where name = "nosuchthing"');
is ($res{ok}, 1, "raw runquery with no result reported ok") or diag(Dumper(\%res));
is_deeply($res{data}, {}, "raw runquery with no result returns empty data hash");

SKIP: {
	skip "perfrawdata takes a long time, add 'slowok' to cmdline to enable", 4 if (!grep(/slowok/, @ARGV));
	# does it suck in oodles of raw performance data?
	%res = $wmi->_run_query(query => 'select * from Win32_Perfrawdata');
	is ($res{ok}, 1, "raw runquery perfrawdata reported ok") or diag(Dumper(\%res));
	cmp_ok(scalar keys %{$res{data}}, ">", 10, "perfrawdata contains multiple classes")
			or diag(Dumper($res{data}));

	isnt($res{data}->{"Win32_PerfRawData_Counters_PerProcessorNetworkInterfaceCardActivity"}, undef,
			 "perfrawdata does contain perproc network activity");

	cmp_ok(scalar @{$res{data}->{"Win32_PerfRawData_Counters_PerProcessorNetworkInterfaceCardActivity"}}, ">",
			 1, "perfrawdata does contain more than one row for perproc network activity")
			or diag(Dumper($res{data}->{"Win32_PerfRawData_Counters_PerProcessorNetworkInterfaceCardActivity"}));
}

# superclass cim_logicaldisk, gives us Win32_LogicalDisk and Win32_MappedLogicalDisk
# ...on some boxes; on others we get only the logicaldisk and nothing in mapped.
%res = $wmi->_run_query(query => 'select * from cim_logicaldisk');
is ($res{ok}, 1, "raw runquery logicaldisk reported ok") or diag(Dumper(\%res));
is(ref($res{data}->{'Win32_MappedLogicalDisk'}), "ARRAY", "logicaldisk returns mappedlogicaldisk class")
		or diag(Dumper($res{data}));
is(ref($res{data}->{'Win32_LogicalDisk'}), "ARRAY", "logicaldisk returns unmapped logicaldisk class")
		or diag(Dumper($res{data}));

my $indexname = 'Name';
my @fields = (qw(Name FreeSpace Size Caption Description VolumeSerialNumber));

my ($errmsg, $goodies, $meta) = $wmi->gettable(wql => "select * from win32_logicaldisk",
																							 fields => \@fields,
																							 index => $indexname );
is($errmsg, undef, "gettable reported ok");
is($meta->{index}, $indexname, "index worked ok");
cmp_deeply([keys %{(values %$goodies)[0]}], bag(@fields), "exactly the requested fields were returned")
		or diag(Dumper($goodies));

# now try a get, precise
my $wantedser = $goodies->{'C:'}->{VolumeSerialNumber};

@fields = qw(VolumeSerialNumber Description Name Size FreeSpace);
($errmsg, $goodies, $meta) = $wmi->get(wql => "select * from win32_logicaldisk where volumeserialnumber='$wantedser'",
																			 fields => \@fields );
is($errmsg, undef, "get reported ok");
is($meta->{classname}, "Win32_LogicalDisk", "get returns desired classname");
cmp_deeply([keys %$goodies], bag(@fields), "exactly the requested fields were returned")
		or diag(Dumper($goodies));

# and another get, IMprecise
($errmsg, $goodies, $meta) = $wmi->get(wql => "select * from win32_networkadapter");
is($errmsg, undef, "unspecific get reported ok");
isnt($goodies->{Caption}, undef, "get has returned something not unlike a network adapter (caption '$goodies->{Caption}')");
is(exists($goodies->{MACAddress}), 1, "get has returned something not unlike a network adapter (macaddress exists)"); # may be undef

# and another get, semi-imprecise
($errmsg, $goodies, $meta) = $wmi->get(wql => "select * from win32_networkadapter where macaddress is not null");
is($errmsg, undef, "non-null get reported ok");
isnt($goodies->{Caption}, undef, "get has returned something not unlike a network adapter (caption '$goodies->{Caption}')");
isnt($goodies->{MACAddress}, undef, "get has returned something not unlike a network adapter (macaddress '$goodies->{MACAddress}')");

# print Dumper($errmsg, $goodies, $meta);

# make a new obj with timeout, check that it's honored down-stream
$then = Time::HiRes::time;
$desiredto = 3;

$wmi = NMISNG::WMI->new(username => $args{username},
								host => $args{host}, password => $args{password},
								timeout => $desiredto,
								program => "../bin/wmic");
is(ref($wmi), "NMISNG::WMI", "WMI constructor with timeout worked");

($errmsg, $goodies, $meta) = $wmi->get(wql => "select * from Win32_perfformatteddata");
$now = Time::HiRes::time;
like($errmsg,qr/timeout/, sprintf("overlong query did time out after %.3fs",
																	$now-$then));
cmp_ok($now-$then,"<=",$desiredto*1.2,"actual timeout within 120% of desired timeout");

done_testing;
