# a small update plugin for discovering interfaces on FutureSoftware devices
# which requires custom snmp accesses
package FutureSoftware;
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

	my $svnStatus = "OK";
	my $haStatus = "OK";
	my $fwStatus = "OK";
	my $psStatus = "OK";

	if ( $NI->{system}{svnStatShortDescr} ne "OK" ) {
		$svnStatus = $NI->{system}{svnStatShortDescr};
	}

	if ( $NI->{system}{haInstalled} == 1
		and $NI->{system}{haState} eq "active" 
		and $NI->{system}{haStatShort} eq "OK" 
		and $NI->{system}{haBlockState} eq "OK" 
	) {
		$haStatus = "OK";
	}
	else {
		$haStatus = "CRITICAL";
	}

	if ( $NI->{system}{fwModuleState} ne "Installed" ) {
		$fwStatus = "CRITICAL";
	}



	$V->{system}{"svn_status_value"} = $svnStatus;
	$V->{system}{"svn_status_title"} = 'SVN Status';
	$V->{system}{"svn_status_color"} = '#00FF00';
	$V->{system}{"svn_status_color"} = '#FF0000' if $svnStatus ne "OK";
	
	$V->{system}{"ha_status_value"} = $haStatus;
	$V->{system}{"ha_status_title"} = 'HA Status';
	$V->{system}{"ha_status_color"} = '#00FF00';
	$V->{system}{"ha_status_color"} = '#FF0000' if $haStatus ne "OK";
		
	$V->{system}{"fw_status_value"} = $fwStatus;
	$V->{system}{"fw_status_title"} = 'FW Status';
	$V->{system}{"fw_status_color"} = '#00FF00';
	$V->{system}{"fw_status_color"} = '#FF0000' if $fwStatus ne "OK";
		
	$V->{system}{"ps_status_value"} = $psStatus;
	$V->{system}{"ps_status_title"} = 'PS Status';
	$V->{system}{"ps_status_color"} = '#00FF00';
	$V->{system}{"ps_status_color"} = '#FF0000' if $psStatus ne "OK";
		


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
#
## check for FW1 status
#my $state_fw = 0;
#$state_fw = 2 if ( $fw{"fw_state"} ne "Installed" );
#$short = $short . "FW1:$str[$state_fw]($fw{\"fw_name\"}) ";
#$perf = "connections=$fw{\"fw_conns\"}";
#
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
#
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
#


	return (1,undef);							# happy, changes were made so save view and nodes files
}
