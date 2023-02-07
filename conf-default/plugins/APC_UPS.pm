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
# A small update plugin for manipulating APC Ups Battery change indication.
#
# This plugin is controlled by two configuration flags.
#   *  'ups_battery_replace_months' => 48,
#   *  'ups_enable_timed_battery_replacement' => 'false',
#
# Change these as desired. 

# If 'ups_enable_timed_battery_replacement' is defaulted to 'false', alerts will
# only be generated if the 'upsAdvBatteryReplaceIndicator' OID returns '0',
# indicating that APC recommends replacing the battery.
#
# If 'ups_enable_timed_battery_replacement' is set to 'true', an alert will be
# generated if EITHER the 'upsAdvBatteryReplaceIndicator' OID returns '0', or
# the 'upsBasicBatteryLastReplaceDate' OID date is older than the value of
# 'ups_battery_replace_months'.
# 

package APC_UPS;
our $VERSION = "1.0.0";

use strict;
use warnings;
use Compat::NMIS;
use NMISNG;                                             # get_nodeconf
use NMISNG::Util;                               # for the conf table extras
use Data::Dumper;
use NMISNG::Snmp;

sub collect_plugin
{
	my (%args) = @_;
	my ($node, $S, $C, $NG) = @args{qw(node sys config nmisng)};
	my $catchall = $S->inventory( concept => 'catchall' )->{_data};
	
	return (0,undef) if ($S->{mdl}->{system}->{nodeModel} ne "APC-ups" or !NMISNG::Util::getbool($catchall->{collect}));
	my $changesweremade = 0;
	my $nodeobj        = $NG->node(name => $node);
	my $NC             = $nodeobj->configuration;
	my $upsAdvBatteryReplaceIndicator  = ".1.3.6.1.4.1.318.1.1.1.2.2.4.0";
	my $upsBasicBatteryLastReplaceDate = ".1.3.6.1.4.1.318.1.1.1.2.1.3.0";

	# NMISNG::Snmp doesn't fall back to global config
	my $max_repetitions         = $NC->{node}->{max_repetitions} || $C->{snmp_max_repetitions};
	my $enableTimeedReplacement = NMISNG::Util::getbool($C->{ups_enable_timed_battery_replacement}) // 0;
	my $replacementTimeMonths   = $C->{ups_battery_replace_months} // 48;

	# Get the SNMP Session going.
	my %nodeconfig = %{$S->nmisng_node->configuration};

	my $snmp = NMISNG::Snmp->new(name => $node, nmisng => $NG);
	# configuration now contains  all snmp needs to know
	if (!$snmp->open(config => \%nodeconfig))
	{
		my $error = $snmp->error;
		undef $snmp;
		$NG->log->error("Could not open SNMP session to node $node: ".$error);
		return (2, "Could not open SNMP session to node $node: ".$error);
	}
	if (!$snmp->testsession)
	{
		my $error = $snmp->error;
		$snmp->close;
		$NG->log->warn("Could not retrieve SNMP vars from node $node: ".$error);
		return (2, "Could not retrieve SNMP vars from node $node: ".$error);
	}
	my @oids = (
		"$upsAdvBatteryReplaceIndicator",
		"$upsBasicBatteryLastReplaceDate"
	);
		
	# Store them straight into the results
	my $snmpData = $snmp->get(@oids);
	if ($snmp->error)
	{
		$snmp->close;
		$NG->log->warn("Got an empty Interface, skipping.");
		return(2, "Got an empty Interface, skipping.");
	}
	if (ref($snmpData) ne "HASH")
	{
		$snmp->close;
		$NG->log->warn("Failed to retrieve SNMP variables for index $upsAdvBatteryReplaceIndicator.");
		return(2, "Failed to retrieve SNMP variables for index $upsAdvBatteryReplaceIndicator.");
	}

	my $batteryReplaceIndicator = $snmpData->{"$upsAdvBatteryReplaceIndicator"};
	my $batteryLastReplaceDate  = $snmpData->{"$upsBasicBatteryLastReplaceDate"};
	$snmp->close;
	my $lastrepaced = NMISNG::Util::getUnixTime($batteryLastReplaceDate);
	my $today       = time();
	my $monthsSinceReplaced = (($today - $lastrepaced) / 86400 / 30.4);
	my $replace  = 0;
	my $details  = "";

	$NG->log->debug("Battery Replace Indicator         = $batteryReplaceIndicator");
	$NG->log->debug("Timed Battery Replacement enabled = $enableTimeedReplacement");
	$NG->log->debug("Battery Last Replaced             = $batteryLastReplaceDate");
	$NG->log->debug("Battery Last Epoch                = $lastrepaced");
	$NG->log->debug("Today Epoch                       = $today");
	$NG->log->debug("Months since replacement          = $monthsSinceReplaced");
	$NG->log->debug("Replacement Time in Months        = $replacementTimeMonths");
	if ($enableTimeedReplacement && ($monthsSinceReplaced > $replacementTimeMonths))
	{
		$NG->log->info("Battery needs to be replaced (too old)");
		$details  = "Battery older than $replacementTimeMonths months.";
		$replace  = 1;
	}

	if ($batteryReplaceIndicator == 1)
	{
		$NG->log->debug("Battery is ok");
	}
	elsif ($batteryReplaceIndicator == 0)
	{
		$NG->log->info("Battery needs to be replaced (APC recommendation)");
		$details  = "APC recommends replacement.";
		$replace  = 1;
	}
	else
	{
		$NG->log->warn("Battery Replace Indicator is not recognized '$batteryReplaceIndicator'.");
		return (2, "Battery Replace Indicator is not recognized '$batteryReplaceIndicator'.");
	}

	if ($replace)
	{
		Compat::NMIS::notify(sys=>$S,event=>"Replace Battery",element=>"Battery",details=>"$details");
	}
	else
	{
		Compat::NMIS::checkEvent(sys=>$S,event=>"Replace Battery",level=>"Normal",element=>"Battery",details=>"$details");
	}

	$changesweremade = 1;
	return ($changesweremade,undef);
}


1;
