#
#  Copyright Opmantek Limited (www.opmantek.com)
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
#
# a small update plugin for getting the QualityOfServiceStat index and direction

package QualityOfServiceStattable;
our $VERSION = "1.0.1";

use strict;
use Data::Dumper;

sub update_plugin
{
        my (%args) = @_;
        my ($node,$S,$C,$NG) = @args{qw(node sys config nmisng)};
	
	my $NI = $S->nmisng_node->configuration;
	# anything to do?

	#my $IFD = $S->ifDescrInfo(); # interface info indexed by ifDescr

	return (0,undef) if (ref($NI->{QualityOfServiceStat}) ne "HASH");
	my $changesweremade = 0;

	
	info("Working on $node QualityOfServiceStattable");

 
      

	for my $key (keys %{$NI->{QualityOfServiceStat}})
	{
		my $entry = $NI->{QualityOfServiceStat}->{$key};
		# |  +--hwCBQoSPolicyStatisticsClassifierEntry(1)
		# |     |	hwCBQoSIfApplyPolicyIfIndex ($first) ,
		#		 	hwCBQoSIfVlanApplyPolicyVlanid1 (undef),
		#			hwCBQoSIfApplyPolicyDirection ($third),
		#			hwCBQoSPolicyStatClassifierName ($k is the index that derives from this property)
		# $k is a QualityOfServiceStat index provided by hwCBQoSPolicyStatClassifierName
		#	and is a dot delimited string of integers (OID):
		my ($first,undef,$third) = split(/\./,$entry->{index});
		if ( defined($first) or defined ($third) ) {
			
			$changesweremade = 1;
			# hwCBQoSIfApplyPolicyDirection: 1=in; 2=out; strict implementation
			my $direction = ($third == 1? 'in': ($third == 2? 'out': undef));;
			
			$entry->{ifIndex} = $first;
			$entry->{Direction} = $direction;
			
			info("Found QoS Entry with interface $entry->{ifIndex} and direction '$entry->{Direction}'");

            dbg("QualityOfServiceStattable.pm: Node $node updating node info QualityOfServiceStat $entry->{index} ifIndex: new '$entry->{ifIndex}'");
            dbg("QualityOfServiceStattable.pm: Node $node updating node info QualityOfServiceStat $entry->{index} Direction: new '$entry->{Direction}'");
		}
	}

	return ($changesweremade,undef); # report if we changed anything
}

1;
