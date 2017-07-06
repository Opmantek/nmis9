# a small update plugin for converting the mac addresses in dot1q dot1qTpFdbs
# into a more human-friendly form
package tcpConn;
our $VERSION = "1.1.0";

use strict;
use NMISNG::Util;												# for the conf table extras
use snmp 1.1.0;									# for snmp-related access

sub collect_plugin
{
	my (%args) = @_;
	my ($node,$S,$C) = @args{qw(node sys config)};

	my $NI = $S->ndinfo;
	my $changesweremade = 0;

	my $connState = {
		'1' => 'closed',
		'2' => 'listen',
		'3' => 'synSent',
		'4' => 'synReceived',
		'5' => 'established',
		'6' => 'finWait1',
		'7' => 'finWait2',
		'8' => 'closeWait',
		'9' => 'lastAck',
		'10' => 'closing',
		'11' => 'timeWait',
		'12' => 'deleteTCB'
	};

	my $addressType = {
		'0' => 'unknown',
		'1' => 'ipv4',
		'2' => 'ipv6',
		'3' => 'ipv4z',
		'4' => 'ipv6z',
		'16' => 'dns',
	};

	if (ref($NI->{tcpConn}) eq "HASH" or ref($NI->{tcpConnection}) eq "HASH")
	{
		my $NC = $S->ndcfg;

		my $snmp = NMISNG::Snmp->new(name => $node);
		return (2,"Could not open SNMP session to node $node: ".$snmp->error)
				if (!$snmp->open(config => $NC->{node}, host_addr => $NI->{system}->{host_addr}));

		return (2, "Could not retrieve SNMP vars from node $node: ".$snmp->error)
				if (!$snmp->testsession);

		if (ref($NI->{tcpConn}) eq "HASH" and $NI->{system}{nodedown} ne "true")
		{
			dbg("SNMP tcpConnState for $node");

			#tcpConnLocalAddress
			#tcpConnLocalPort
			#tcpConnRemAddress
		  #tcpConnRemPort

		  #tcpConnState

	    #"192.168.1.42.3306.192.168.1.7.47883" : {
	    #   "tcpConnLocalAddress" : "192.168.1.42",
	    #   "tcpConnRemPort" : 47883,
	    #   "index" : "192.168.1.42.3306.192.168.1.7.47883",
	    #   "tcpConnLocalPort" : 3306,
	    #   "tcpConnState" : "established",
	    #   "tcpConnRemAddress" : "192.168.1.7"
	    #},

			my $oid = "1.3.6.1.2.1.6.13.1.1";
			if ( my $tcpConn = $snmp->getindex($oid, $NI->{system}->{max_repetitions} || $C->{snmp_max_repetitions}) )
			{
				### OK we have data, lets get rid of the old one.
				delete $NI->{tcpConn};

				my $date = returnDateStamp();
				foreach my $tcpKey (keys %$tcpConn)
				{
					my $thistarget = $NI->{tcpConn}->{$tcpKey} = {};

					$thistarget->{tcpConnState} = $connState->{$tcpConn->{$tcpKey}};
					if ( $tcpKey =~ /(\d+\.\d+\.\d+\.\d+)\.(\d+)\.(\d+\.\d+\.\d+\.\d+)\.(\d+)/ )
					{
						$thistarget->{tcpConnLocalAddress} = $1;
						$thistarget->{tcpConnLocalPort} = $2;
						$thistarget->{tcpConnRemAddress} = $3;
						$thistarget->{tcpConnRemPort} = $4;
						$thistarget->{date} = $date;
					}
					$changesweremade = 1;
				}
			}
		}

		if (ref($NI->{tcpConnection}) eq "HASH" and $NI->{system}{nodedown} ne "true")
		{
			dbg("SNMP tcpConnState for $node");

	    #  "1.4.192.168.1.42.3306.1.4.192.168.1.7.47883" : {
	    #     "tcpConnectionState" : "established",
	    #     "index" : "1.4.192.168.1.42.3306.1.4.192.168.1.7.47883"
	    #  },
      #"2.16.0.0.0.0.0.0.0.0.0.0.255.255.192.168.1.7.80.2.16.0.0.0.0.0.0.0.0.0.0.255.255.192.168.1.7.34089" : {
      #   "tcpConnectionState" : "timeWait",
      #   "index" : "2.16.0.0.0.0.0.0.0.0.0.0.255.255.192.168.1.7.80.2.16.0.0.0.0.0.0.0.0.0.0.255.255.192.168.1.7.34089"
      #},

			my $oid = "1.3.6.1.2.1.6.19.1.7";
			if ( my $tcpConn = $snmp->getindex($oid, $NI->{system}->{max_repetitions} || $C->{snmp_max_repetitions}) )
			{
				### OK we have data, lets get rid of the old one.
				delete $NI->{tcpConnection};
				my $date = returnDateStamp();

				foreach my $tcpKey (keys %$tcpConn)
				{
					my $thistarget = $NI->{tcpConnection}->{$tcpKey} = {};

					$thistarget->{tcpConnectionState} = $connState->{$tcpConn->{$tcpKey}};

					if ( $tcpKey =~ /1\.4\.(\d+\.\d+\.\d+\.\d+)\.(\d+)\.1\.4\.(\d+\.\d+\.\d+\.\d+)\.(\d+)$/ )
					{
						$thistarget->{tcpConnectionLocalAddress} = $1;
						$thistarget->{tcpConnectionLocalPort} = $2;
						$thistarget->{tcpConnectionRemAddress} = $3;
						$thistarget->{tcpConnectionRemPort} = $4;
						$thistarget->{date} = $date;
					}
					elsif ( $tcpKey =~ /2\.16\.([\d+\.]+)\.(\d+)\.2\.16\.([\d+\.]+)\.(\d+)$/ )
					{
						$thistarget->{tcpConnectionLocalAddress} = $1;
						$thistarget->{tcpConnectionLocalPort} = $2;
						$thistarget->{tcpConnectionRemAddress} = $3;
						$thistarget->{tcpConnectionRemPort} = $4;
						$thistarget->{date} = $date;
					}
					$changesweremade = 1;
				}
			}
		}
		$snmp->close;
	}
	return ($changesweremade,undef); # report if we changed anything
}


1;
