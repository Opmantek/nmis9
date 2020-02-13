#
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System ("NMIS").
#
#  NMIS is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  NMIS is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with NMIS (most likely in a file named LICENSE).
#  If not, see <http://www.gnu.org/licenses/>
#
#  For further information on NMIS or for a license other than GPL please see
#  www.opmantek.com or email contact@opmantek.com
#
#  User group details:
#  http://support.opmantek.com/users/
#
# *****************************************************************************
package NMISNG::SQoS;
our $VERSION  = "1.0.0";

use strict;

##################################################
# SUPPORTS Standardised QoS FUNCTIONALITY

# used in loadCBQoS_standardised()
use constant {
	QOS_TYPE_QOS_STR => "QoS", # QoS Report only for now
	QOS_TYPE_BRS_STR => "BRS", # QoS Report

	# STANDARDISED: Allow for more than one QOS key per model, hence "_1"
	STANDARDISED_HUAWEI_QOS_KEY_1 => "QualityOfServiceStat",
    STANDARDISED_JUNIPER_QOS_KEY_1 => "Juniper_CoS",
    STANDARDISED_TELDAT_QOS_KEY_1 => "TeldatQoSStat",
    STANDARDISED_TELDAT_BRS_KEY_1 => "TeldatBRSStat",

	NA_STR => "N/A", # QoS Report only for now
	NOT_SUPPORTED_STR => "N/S", # QoS Report
};

# not used in NMIS: exported for convenience when using NMIS
# export %QOS_TYPES variable with key providing precedence of sort order for presentation purposes:
our %QOS_KEY_TYPES = (
	# note how to load a constant as a key: 'constant() => ...'
	QOS_TYPE_QOS_STR() => 1,
	QOS_TYPE_BRS_STR() => 2,
);

our %REPORT_STR_TYPES = (
	# note how to load a constant as a key: 'constant() => ...'
	NA_STR() => NA_STR,
	NOT_SUPPORTED_STR() => NOT_SUPPORTED_STR,
);

# static function
# required inputs: thispol, qospolkey
# returns: constant NA_STR if key supported, constant NOT_SUPPORTED_STR if key not supported, undef if required inputs fail
sub qoskey_standardised_supported_na_string
{
	my (%args) = @_;

	my $thispolicy = $args{thispolicy};
	my $qospolkey = $args{qospolkey};
	if (ref($thispolicy) eq "HASH" and $qospolkey)
	{
		# it is more efficient to grep against unsupported keys, but more accurate to grep against supported keys: just keep them up to date!
		# huawei qos and juniper cos
		if ($thispolicy->{CfgSection} eq STANDARDISED_HUAWEI_QOS_KEY_1)
		{
			# unsupported CfgDSNames: (NoBufDropPkt)
			# unsupported: (bandwidth percent NoBufDropPkt)
			my @supported_qoskeys = qw(name inout action PrePolicyPkt DropPkt PostPolicyPkt DropByte MaxDropByte DropBits MaxDropBits PrePolicyByte MaxPrePolicyByte
									   PrePolicyBits MaxPrePolicyBits PostPolicyByte MaxPostPolicyByte PostPolicyBits MaxPostPolicyBits PrePolicyUtil MaxPrePolicyUtil
									   PostPolicyUtil DropPktClass percentClass PrePolicyUtilClass);
			return NA_STR if grep { $qospolkey eq $_ }@supported_qoskeys;
		}
		# juniper qos
		elsif ($thispolicy->{CfgSection} eq STANDARDISED_JUNIPER_QOS_KEY_1)
		{
			# unsupported CfgDSNames: (TotalDropPkts NoBufDropPkt)
			# unsupported: (bandwidth percent DropPkt NoBufDropPkt)
			my @supported_qoskeys = qw(name inout action PrePolicyPkt PostPolicyPkt DropByte MaxDropByte DropBits MaxDropBits PrePolicyByte MaxPrePolicyByte
									   PrePolicyBits MaxPrePolicyBits PostPolicyByte MaxPostPolicyByte PostPolicyBits MaxPostPolicyBits PrePolicyUtil MaxPrePolicyUtil
									   PostPolicyUtil DropPktClass percentClass PrePolicyUtilClass);
			return NA_STR if grep { $qospolkey eq $_ }@supported_qoskeys;
		}
		# teldat qos
		elsif ($thispolicy->{CfgSection} eq STANDARDISED_TELDAT_QOS_KEY_1)
		{
			# unsupported CfgDSNames: (MatchedPassBytes MatchedDropBytes MatchedPassPackets MatchedDropPackets NoBufDropPkt)
			# unsupported: (bandwidth percent DropPkt PostPolicyUtil DropBits MaxDropBits PostPolicyBits MaxPostPolicyBits NoBufDropPkt DropPktClass percentClass)
			my @supported_qoskeys = qw(name inout action PrePolicyPkt PostPolicyPkt DropByte MaxDropByte PrePolicyByte MaxPrePolicyByte
									   PrePolicyBits MaxPrePolicyBits PostPolicyByte MaxPostPolicyByte PrePolicyUtil MaxPrePolicyUtil
									   PrePolicyUtilClass);
			return NA_STR if grep { $qospolkey eq $_ }@supported_qoskeys;
		}
		# teldat brs
		elsif ($thispolicy->{CfgSection} eq STANDARDISED_TELDAT_BRS_KEY_1)
		{
			# unsupported CfgDSNames: (MatchedPassBytes MatchedPassPackets NoBufDropPkt)
			# unsupported: (bandwidth percent PostPolicyPkt PostPolicyBits MaxPostPolicyBits NoBufDropPkt percentClass)
			my @supported_qoskeys = qw(name inout action PrePolicyPkt DropPkt PostPolicyPkt DropByte MaxDropByte DropBits MaxDropBits  PrePolicyByte MaxPrePolicyByte
									   PrePolicyBits MaxPrePolicyBits PostPolicyByte MaxPostPolicyByte PostPolicyBits MaxPostPolicyBits PostPolicyBits MaxPostPolicyBits
									   PrePolicyUtil MaxPrePolicyUtil PostPolicyUtil DropPktClass PrePolicyUtilClass);
			return NA_STR if grep { $qospolkey eq $_ }@supported_qoskeys;
		}
		# cisco qos
		else
		{
			# unsupported CfgDSNames: (PostPolicyPkt)
			# unsupported: (PostPolicyPkt)
			my @supported_qoskeys = qw(name inout action bandwidth percent PrePolicyPkt DropPkt DropByte MaxDropByte DropBits MaxDropBits PrePolicyByte MaxPrePolicyByte
									   PrePolicyBits MaxPrePolicyBits PostPolicyByte MaxPostPolicyByte PostPolicyBits MaxPostPolicyBits PrePolicyUtil MaxPrePolicyUtil
									   PostPolicyUtil DropPktClass percentClass PrePolicyUtilClass NoBufDropPkt);
			return NA_STR;
		}
		# unsupported qospolkey gets to this return statement
		return NOT_SUPPORTED_STR;
	}
	else
	{
		return undef;
	}
}

# Adapted from NMIS::loadCBQoS at 20191114
# Standardised to include Huawei and Teldat devices: Teldat has QOS and BRS
# Load and organize the CBQoS meta-data
# inputs: a sys object, an index, a graphtype and qos_type (constants QOS_TYPE_QOS_STR or QOS_TYPE_BRS_STR, default QOS_TYPE_QOS_STR),
# returns ref to sorted list of names, ref to hash of description/bandwidth/color/index/section
# IMPORTANT: to be flexible and allow easier customization CfgDSNames will list ALL possible DSNames, not just those supported
# TODO: to make it possible to handle QoS in almost any device generically, use the same DSNames for all models in this function;
#		this will require adjustment to QoS DSNames used in existing model and common model files in NMIS, but otherwise offers only advantages.
#		See 'CfgDSNames' comments in 'qoskey_standardised_supported_na_string()' function preceding this function
#		for a reference as to which models support which DSNames
# this function is not exported on purpose, to reduce namespace clashes.
sub loadCBQoS_standardised
{
	my %args = @_;

	my $S = $args{sys};
	my $index = $args{index};
	my $graphtype = $args{graphtype};
	my $qos_type = $args{qos_type} // QOS_TYPE_QOS_STR;

	if ($S->nmisng_node)
	{
		my $node_name = $S->nmisng_node->{_name};
		my $M = $S->mdl;

		my ($PMName,  @CMNames, %CBQosValues , @CBQosNames);

		# define line/area colors of the graph
		my @colors = ("3300ff", "33cc33", "ff9900", "660099",
									"ff66ff", "ff3333", "660000", "0099CC",
									"0033cc", "4B0082","00FF00", "FF4500",
									"008080","BA55D3","1E90FF",  "cc00cc");

		my $direction = $graphtype eq "cbqos-in" ? "in" : "out" ;

		# in the cisco case we have the classmap as basis;
		# for huawei this info comes from the QualityOfServiceStat section
		# for teldat this info comes from the TeldatQoSStat section and TeldatBRSStat section
		my $CiscoQoSKey = "ClassMap";
		my $HuaweiQoSKey = STANDARDISED_HUAWEI_QOS_KEY_1;
		my $JuniperQoSKey = STANDARDISED_JUNIPER_QOS_KEY_1;
		my $TeldatQoSKey = STANDARDISED_TELDAT_QOS_KEY_1;
		my $TeldatBRSKey = STANDARDISED_TELDAT_BRS_KEY_1;

		my ($NI, $data);
		# optimization: attempt Cisco first
		if ($qos_type eq QOS_TYPE_QOS_STR
			   and($NI = $S->inventory( concept => "cbqos-$direction", index => $index ))
			   and($data = ($NI) ? $NI->data : {})
			   and $data->{$CiscoQoSKey}) # Cisco
		{
			my $thisQoSKey = $CiscoQoSKey;
			undef $CiscoQoSKey;

			$PMName = $data->{PolicyMap}{Name};
			foreach my $k (keys %{$data->{$thisQoSKey}}) {
				my $CMName = $data->{$thisQoSKey}{$k}{Name};
				push @CMNames , $CMName if $CMName ne "";

				$CBQosValues{$index.$CMName} = { CfgType => $data->{$thisQoSKey}{$k}{'BW'}{'Descr'},
												 CfgRate => $data->{$thisQoSKey}{$k}{'BW'}{'Value'},
												 CfgIndex => $index,
												 CfgItem => undef,
												 CfgUnique => $k,  # index+cmname is not unique, doesn't cover inbound/outbound - this does.
												 CfgSection => $graphtype,
												 CfgDSNames => [qw(PrePolicyByte PostPolicyByte DropByte PrePolicyPkt PostPolicyPkt DropPkt NoBufDropPkt)]};
			}
		}
		elsif ($qos_type eq QOS_TYPE_QOS_STR
			and $M->{systemHealth}{sys}{$HuaweiQoSKey}
			and ($NI = $S->nmisng_node->retrieve_section(sys=>$S, section=>$HuaweiQoSKey))
			and exists $NI->{$HuaweiQoSKey})
		{
			my $thisQoSKey = $HuaweiQoSKey;
			undef $HuaweiQoSKey;

			my $huaweiqos = $NI->{$thisQoSKey};
			for my $k (keys %{$huaweiqos})
			{
				# plugin QualityOfServiceStattable.pm now generates the ifIndex and Direction during update in update_plugin() function
				# we keep this code for existing rrd data backward compatibility
				#
				# for huawei this info comes from the QualityOfServiceStat section
				# which is indexed (and collected+saved) per qos stat entry, NOT interface!
				# SUPPORT-5690
				# Since Huawei appear to either:
				#		have models that provide ifIndex and direction; or
				#		a process|plugin that adds ifIndex and direction to QualityOfServiceStat
				# we only retrieve ifIndex and|or direction from $k if not populated:
				if (!$huaweiqos->{$k}->{ifIndex} or !$huaweiqos->{$k}->{Direction})
				{
					# |  +--hwCBQoSPolicyStatisticsClassifierEntry(1)
					# |     |	hwCBQoSIfApplyPolicyIfIndex ($first) ,
					#		 	hwCBQoSIfVlanApplyPolicyVlanid1 (undef),
					#			hwCBQoSIfApplyPolicyDirection ($third),
					#			hwCBQoSPolicyStatClassifierName ($k is the index that derives from this property)
					# $k is a QualityOfServiceStat index provided by hwCBQoSPolicyStatClassifierName
					#	and is a dot delimited string of integers (OID):
					my ($first,undef,$third) = split(/\./,$k);

					if (!$huaweiqos->{$k}->{ifIndex})
					{
						$huaweiqos->{$k}->{ifIndex} = $first;
					}
					if (!$huaweiqos->{$k}->{Direction})
					{
						# hwCBQoSIfApplyPolicyDirection: 1=in; 2=out; strict implementation
						$huaweiqos->{$k}->{Direction} = ($third == 1? 'in': ($third == 2? 'out': undef));
					}
				}
				# rather check EQUALS: I found incorrect index passing here due to ONLY direction matching:
				###next if ($huaweiqos->{$k}->{ifIndex} != $index or $huaweiqos->{$k}->{Direction} !~ /^$direction/);
				if ($huaweiqos->{$k}->{ifIndex} == $index and $huaweiqos->{$k}->{Direction} =~ /^$direction/)
				{
					my $CMName = $huaweiqos->{$k}->{ClassifierName};
					push @CMNames, $CMName;
					$PMName = $huaweiqos->{$k}->{Direction}; # there are no policy map names in huawei's qos

					# huawei devices don't expose descriptions or (easily accessible) bw limits
					$CBQosValues{$index.$CMName} = {CfgType => "Bandwidth",
													CfgRate => undef,
													CfgIndex => $k,
													CfgItem =>  undef,
													CfgUnique => $k, # index+cmname is not unique, doesn't cover inbound/outbound - this does.
													CfgSection => $thisQoSKey,
													CfgDSNames => [qw(MatchedBytes MatchedPassBytes MatchedDropBytes MatchedPackets MatchedPassPackets MatchedDropPackets NoBufDropPkt)]};
				}
			}
		}
		elsif ($qos_type eq QOS_TYPE_QOS_STR
			   and $M->{systemHealth}{sys}{$JuniperQoSKey}
			   and ($NI = $S->nmisng_node->retrieve_section(sys=>$S, section=>$JuniperQoSKey))
			   and exists $NI->{$JuniperQoSKey})
		{
			my $thisQoSKey = $JuniperQoSKey;
			undef $JuniperQoSKey;

			my $juniperqos = $NI->{$thisQoSKey};
			for my $k (keys %{$juniperqos})
			{
				# Common-Juniper-jnxCoS.nmis common file now populates direction
				# we keep this code for existing rrd data backward compatibility
				#
				# Juniper currently only support QoS outbound, so we set the key to 'out'
				# should Juniper later support inbound, we will need to drop this hardcoding of out
				#	and ensure a suitable 'in' or 'out' key is contained in the hash key 'Direction'
				if (!$juniperqos->{$k}->{Direction})
				{
					$juniperqos->{$k}->{Direction} = 'out';
				}
				# rather check EQUALS: I found incorrect index passing here due to ONLY direction matching:
				###next if ($huaweiqos->{$k}->{ifIndex} != $index or $huaweiqos->{$k}->{Direction} !~ /^$direction/);
				if ($juniperqos->{$k}->{ifIndex} == $index and $juniperqos->{$k}->{Direction} =~ /^$direction/)
				{
					my $CMName = $juniperqos->{$k}->{jnxCosFcName};
					push @CMNames, $CMName;
					$PMName = $juniperqos->{$k}->{Direction}; # there are no policy map names in huawei's qos

					# huawei devices don't expose descriptions or (easily accessible) bw limits
					$CBQosValues{$index.$CMName} = {CfgType => "Bandwidth",
													CfgRate => undef,
													CfgIndex => $k,
													CfgItem =>  undef,
													CfgUnique => $k, # index+cmname is not unique, doesn't cover inbound/outbound - this does.
													CfgSection => $thisQoSKey,
													CfgDSNames => [qw(Queued Txed RedDropBytes QedPkts TxedPkts TotalDropPkts NoBufDropPkt)]};
				}
			}
		}
		elsif ($qos_type eq QOS_TYPE_QOS_STR
			   and $M->{systemHealth}{sys}{$TeldatQoSKey}
			   and ($NI = $S->nmisng_node->retrieve_section(sys=>$S, section=>$TeldatQoSKey))
			   and exists $NI->{$TeldatQoSKey})
		{
			my $thisQoSKey = $TeldatQoSKey;
			undef $TeldatQoSKey;

			my $teldatqos = $NI->{$thisQoSKey};
			for my $k (keys %{$teldatqos})
			{
				# Common-Teldat-cbqos.nmis common file now populates direction
				# we keep this code for existing rrd data backward compatibility
				#
				# Teldat currently only support QoS outbound, so we set the key to 'out'
				# should Teldat later support inbound, we will need to drop this hardcoding of out
				#	and ensure a suitable 'in' or 'out' key is contained in the hash key 'Direction'
				if (!$teldatqos->{$k}->{Direction})
				{
					$teldatqos->{$k}->{Direction} = 'out';
				}				

				if ($teldatqos->{$k}->{ifIndex} == $index and $teldatqos->{$k}->{Direction} =~ /^$direction/)
				{
					my $CMName;
					# teldat do not have policy names, just policy indexes
					if ($teldatqos->{$k}->{ClassifierPolicy})
					{
						
						$CMName = "$teldatqos->{$k}->{ClassifierPolicy}.$teldatqos->{$k}->{ClassifierName}";
					}
					else
					{
						$CMName = "$teldatqos->{$k}->{ClassifierName}";
					}
					push @CMNames, $CMName;
					$PMName = $teldatqos->{$k}->{Direction}; # there are no policy map names in teldat's qos

					# teldat devices don't expose descriptions or (easily accessible) bw limits
					$CBQosValues{$index.$CMName} = {CfgType => "Bandwidth",
													CfgRate => undef,
													CfgIndex => $k,
													CfgItem =>  undef,
													CfgUnique => $k, # index+cmname is not unique, doesn't cover inbound/outbound - this does.
													CfgSection => $thisQoSKey,
													CfgDSNames => [qw(MatchedBytes MatchedPassBytes MatchedDropBytes MatchedPackets MatchedPassPackets MatchedDropPackets NoBufDropPkt)]};
				}
			}
		}
		elsif ($qos_type eq QOS_TYPE_BRS_STR
			   and $M->{systemHealth}{sys}{$TeldatBRSKey}
			   and ($NI = $S->nmisng_node->retrieve_section(sys=>$S, section=>$TeldatBRSKey))
			   and exists $NI->{$TeldatBRSKey})	
		{
			my $thisQoSKey = $TeldatBRSKey;
			undef $TeldatBRSKey;

			my $teldatbrs = $NI->{$thisQoSKey};
			for my $k (keys %{$teldatbrs})
			{
				# Common-Teldat-cbqos.nmis common file now populates direction
				# we keep this code for existing rrd data backward compatibility
				#
				# Teldat currently only support QoS outbound, so we set the key to 'out'
				# should Teldat later support inbound, we will need to drop this hardcoding of out
				#	and ensure a suitable 'in' or 'out' key is contained in the hash key 'Direction'
				if (!$teldatbrs->{$k}->{Direction})
				{
					$teldatbrs->{$k}->{Direction} = 'out';
				}

				if ($teldatbrs->{$k}->{ifIndex} == $index and $teldatbrs->{$k}->{Direction} =~ /^$direction/)
				{
					my $CMName;
					# teldat do not have policy names, just policy indexes
					if ($teldatbrs->{$k}->{ClassifierPolicy})
					{
						$CMName = "$teldatbrs->{$k}->{ClassifierPolicy}.$teldatbrs->{$k}->{ClassifierName}";
					}
					else
					{
						$CMName = "$teldatbrs->{$k}->{ClassifierName}";
					}
					push @CMNames, $CMName;
					$PMName = $teldatbrs->{$k}->{Direction}; # there are no policy map names in teldat's qos

					# teldat devices don't expose descriptions or (easily accessible) bw limits
					$CBQosValues{$index.$CMName} = {CfgType => "Bandwidth",
													CfgRate => undef,
													CfgIndex => $k,
													CfgItem =>  undef,
													CfgUnique => $k, # index+cmname is not unique, doesn't cover inbound/outbound - this does.
													CfgSection => $thisQoSKey,
													CfgDSNames => [qw(MatchedBytes MatchedPassBytes MatchedDropBytes MatchedPackets MatchedPassPackets MatchedDropPackets NoBufDropPkt)]};
				}
			}
		}
		else
		{
			return undef;
		}

		if (scalar @CMNames)
		{
			# order the buttons of the classmap names for the Web page
			@CMNames = sort {uc($a) cmp uc($b)} @CMNames;
		
			my @qNames;
			my @confNames = split(',', $M->{node}{cbqos}{order_CM_buttons});
			foreach my $Name (@confNames) {
				for (my $i=0; $i<=$#CMNames; $i++) {
					if ($Name eq $CMNames[$i] ) {
						push @qNames, $CMNames[$i] ; # move entry
						splice (@CMNames,$i,1);
						last;
					}
				}
			}
		
			@CBQosNames = ($PMName,@qNames,@CMNames); #policy name, classmap names sorted, classmap names unsorted
			if ($#CBQosNames) {
				# colors of the graph in the same order
				for my $i (1..$#CBQosNames) {
					if ($i < $#colors ) {
						$CBQosValues{"${index}$CBQosNames[$i]"}{'Color'} = $colors[$i-1];
					} else {
						$CBQosValues{"${index}$CBQosNames[$i]"}{'Color'} = "000000";
					}
				}
			}
		}
	
		return \(@CBQosNames,%CBQosValues);
	}
	else
	{
		return undef;
	}
} # end loadCBQoS_standardised

# END SUPPORTS Standardised QoS FUNCTIONALITY
##################################################

1;
