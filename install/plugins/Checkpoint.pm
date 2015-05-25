# a small update plugin for discovering interfaces on FutureSoftware devices
# which requires custom snmp accesses
package Checkpoint;
our $VERSION = "1.0.0";

use strict;

use func;												# for loading extra tables
use NMIS;


sub collect_plugin
{
	my (%args) = @_;
	my ($node, $S, $C) = @args{qw(node sys config)};

	my $NI = $S->ndinfo;

	# this plugin deals only with Future Software devices, and only ones with snmp enabled and working
	return (0,undef) if ( $NI->{system}{nodeModel} ne "Checkpoint"
												or !getbool($NI->{system}->{collect}));

	my $V = $S->view;

	#'fwFilterName' => 'CenturyLink-DC4-Main-r02',
	#'fwModuleState' => 'Installed',
	#'fwNumConn' => 17143,
	#'fwPeakNumConn' => 141561,
	#'group' => 'DC4-SterlingVA',
	#'haBlockState' => 'OK',
	#'haInstalled' => 1,
	#'haStarted' => 'yes',
	#'haStatShort' => 'OK',
	#'haState' => 'active',
	#'svnStatShortDescr' => 'OK',
	#'dtpsConnectedUsers' => 0,
	#'dtpsLicensedUsers' => 0,
	#'dtpsStatShortDescr' => 'Down',

	my $timenow = time;

	### processing for SVN alerts

	## check for SVN status
	#my $state_svn = 0;
	#$state_svn = 2 if ( $fw{"svn_status"} ne "OK" ); # Raise to CRITICAL is SVN is not OK
	#$short = "Firewall Status [ SVN:$fw{\"svn_status\"} ";

	my $svnStatus = "OK";
	my $svnLevel = "Normal";
	my $svnEvent = "Checkpoint Monitor";
	my $svnElement = "SVN";
	my $svnDetails = "";
	my $svnValue = "";

	if ( $NI->{system}{svnStatShortDescr} ne "OK" ) {
		$svnLevel = "Critical";
		$svnDetails = "SVN:CRITICAL($NI->{system}{svnStatShortDescr})";
	}
	$svnStatus = $NI->{system}{svnStatShortDescr};
	$svnValue = $NI->{system}{svnStatShortDescr};

	# Store the results for the GUI to display
	$V->{system}{"svn_status_value"} = $svnStatus;
	$V->{system}{"svn_status_title"} = 'SVN Status';
	$V->{system}{"svn_status_color"} = '#00FF00';
	$V->{system}{"svn_status_color"} = '#FF0000' if $svnStatus ne "OK";

	# store the results for the Status Display
	$NI->{status}{"$svnEvent--$svnElement"} = {
		'element' => $svnElement,
		'event' => $svnEvent,
		'index' => undef,
		'level' => $svnLevel,
		'method' => 'Alert',
		'property' => '',
		'status' => lc($svnStatus),
		'type' => 'test',
		'updated' => $timenow,
		'value' => $svnValue
  };

	# process the status now and raise an event if needed.
	if ( $svnStatus eq "OK" ) {
		# check if event exists and clear it
		checkEvent(sys => $S, event => "Alert: $svnEvent", level => $svnLevel, element => $svnElement, details => $svnDetails);
	} 
	else {
		# raise a new event.
		notify(sys => $S, event => "Alert: $svnEvent", element => $svnElement, details => $svnDetails);
	}


	### processing for HA alerts

	## check for HA status
	#my $state_ha = 0;
	#if ($mode =~ /(2|4)/) {
	#  if (  $fw{"ha_installed"} == 1 &&
	#        $fw{"ha_active"} eq "yes" &&
	#        $fw{"ha_block_state"} eq "OK" &&
	#        $fw{"ha_status"} eq "OK" ) {
	#    $short = $short . "HA:OK($fw{\"ha_mode\"}) ";
	#  } else {
	#    $state_ha = 2;
	#    $short = $short . "HA:CRITICAL($fw{\"ha_status\"}) ";
	#  }     
	#}  

	my $haStatus = "OK";
	my $haLevel = "Normal";
	my $haEvent = "Checkpoint Monitor";
	my $haElement = "HA";
	my $haDetails = "";
	my $haValue = "";

	if ( $NI->{system}{haInstalled} == 1
		and $NI->{system}{haState} eq "active" 
		and $NI->{system}{haStatShort} eq "OK" 
		and $NI->{system}{haBlockState} eq "OK" 
	) {
		$haStatus = "OK";
	}
	else {
		$haStatus = "CRITICAL";
		$haLevel = "Critical";
		$haDetails = "HA:CRITICAL($NI->{system}{haState})";
	}
	$haValue = $NI->{system}{haState};

	$V->{system}{"ha_status_value"} = $haStatus;
	$V->{system}{"ha_status_title"} = 'HA Status';
	$V->{system}{"ha_status_color"} = '#00FF00';
	$V->{system}{"ha_status_color"} = '#FF0000' if $haStatus ne "OK";

	# store the results for the Status Display
	$NI->{status}{"$haEvent--$haElement"} = {
		'element' => $haElement,
		'event' => $haEvent,
		'index' => undef,
		'level' => $haLevel,
		'method' => 'Alert',
		'property' => '',
		'status' => lc($haStatus),
		'type' => 'test',
		'updated' => $timenow,
		'value' => $haValue
  };

	# process the status now and raise an event if needed.
	if ( $haStatus eq "OK" ) {
		# check if event exists and clear it
		checkEvent(sys => $S, event => "Alert: $haEvent", level => $haLevel, element => $haElement, details => $haDetails);
	} 
	else {
		# raise a new event.
		notify(sys => $S, event => "Alert: $haEvent", level => $haLevel, element => $haElement, details => $haDetails);
	}
		

	### processing for FW alerts
	## check for FW1 status
	#my $state_fw = 0;
	#$state_fw = 2 if ( $fw{"fw_state"} ne "Installed" );
	#$short = $short . "FW1:$str[$state_fw]($fw{\"fw_name\"}) ";
	#$perf = "connections=$fw{\"fw_conns\"}";

	my $fwStatus = "OK";
	my $fwLevel = "Normal";
	my $fwEvent = "Checkpoint Monitor";
	my $fwElement = "FW";
	my $fwDetails = "";
	my $fwValue = "";
	
	if ( $NI->{system}{fwModuleState} ne "Installed" ) {
		$fwStatus = "CRITICAL";
		$fwLevel = "Critical";
		$fwDetails = "FW1:CRITICAL($NI->{system}{haState})";
	}
	$fwValue = $NI->{system}{fwModuleState};

	$V->{system}{"fw_status_value"} = $fwStatus;
	$V->{system}{"fw_status_title"} = 'FW Status';
	$V->{system}{"fw_status_color"} = '#00FF00';
	$V->{system}{"fw_status_color"} = '#FF0000' if $fwStatus ne "OK";

	# store the results for the Status Display
	$NI->{status}{"$fwEvent--$fwElement"} = {
		'element' => $fwElement,
		'event' => $fwEvent,
		'index' => undef,
		'level' => $fwLevel,
		'method' => 'Alert',
		'property' => '',
		'status' => lc($fwStatus),
		'type' => 'test',
		'updated' => $timenow,
		'value' => $fwValue
  };

	# process the status now and raise an event if needed.
	if ( $fwStatus eq "OK" ) {
		# check if event exists and clear it
		checkEvent(sys => $S, event => "Alert: $fwEvent", level => $fwLevel, element => $fwElement, details => $fwDetails);
	} 
	else {
		# raise a new event.
		notify(sys => $S, event => "Alert: $fwEvent", level => $fwLevel, element => $fwElement, details => $fwDetails);
	}

	### processing for PS alerts
	## check for PS status
	#my $state_ps = 0;
	#if ($mode =~ /(3|4)/) {
	#  if (  $fw{"ps_status"} eq "OK" &&
	#        $fw{"ps_license"} >= $fw{"ps_users"} ) {
	#    $short = $short . "PS:OK($fw{\"ps_users\"}users) ";
	#    $perf = $perf . " users=$fw{\"ps_users\"}";
	#  } else {
	#    $state_ps = 2;
	#    $short = $short . "PS:CRITICAL($fw{\"ps_status\"}) ";
	#  }
	#}
	my $psStatus = "OK";	
	my $psLevel = "Normal";
	my $psEvent = "Checkpoint Monitor";
	my $psElement = "PS";
	my $psDetails = "";
	my $psValue = "";

	if ( $NI->{system}{dtpsStatShortDescr} eq "OK"
		and $NI->{system}{dtpsLicensedUsers} >= $NI->{system}{dtpsConnectedUsers}
	) {
		$psStatus = "OK";
	}
	else {
		$psStatus = "CRITICAL";
		$psLevel = "Critical";
		$psDetails = "PS:CRITICAL($NI->{system}{dtpsStatShortDescr})";		
	}
	$psValue = $NI->{system}{dtpsStatShortDescr};

	$V->{system}{"dtps_status_value"} = $psStatus;
	$V->{system}{"dtps_status_title"} = 'PS Status';
	$V->{system}{"dtps_status_color"} = '#00FF00';
	$V->{system}{"dtps_status_color"} = '#FF0000' if $psStatus ne "OK";

	# store the results for the Status Display
	$NI->{status}{"$psEvent--$psElement"} = {
		'element' => $psElement,
		'event' => $psEvent,
		'index' => undef,
		'level' => $psLevel,
		'method' => 'Alert',
		'property' => '',
		'status' => lc($psStatus),
		'type' => 'test',
		'updated' => $timenow,
		'value' => $psValue
  };

	# process the status now and raise an event if needed.
	if ( $psStatus eq "OK" ) {
		# check if event exists and clear it
		checkEvent(sys => $S, event => "Alert: $psEvent", level => $psLevel, element => $psElement, details => $psDetails);
	} 
	else {
		# raise a new event.
		notify(sys => $S, event => "Alert: $psEvent", level => $psLevel, element => $psElement, details => $psDetails);
	}
		
	#if ( $state_svn == 2 ||
	#     $state_ha  == 2 ||
	#     $state_fw  == 2 ||
	#     $state_ps  == 2 ) {
	#  $short = $short . "]: CRITICAL";
	#  $state = 2;
	#} else {
	#  $short = $short . "]: OK";
	#  $state = 0;
	#}

	return (1,undef);							# happy, changes were made so save view and nodes files
}
