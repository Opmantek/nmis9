#!/bin/bash

# =============================================================
# Help subroutine
#-------
Help()
{
	echo "                             $PROGNAME"
	echo ""
	echo "NAME"
	echo "	$PROGNAME - Import settings from an existing NMIS8 installation."
	echo ""
	echo "SYNOPSIS"
	echo "	$PROGNAME [-8=<NMIS8_directory>] [-9=<NMIS9_directory>] [-h] [-v]"
	echo ""
	echo "DESCRIPTION"
	echo "	This program imports settings and configuration information from an existing NMIS8 installtion to a newly"
	echo "	installed NMIS9 installation."
	echo ""
	echo "		-8 <NMIS8_directory>      - Specify an NMIS8 directory if other than '/usr/local/nmis8'."
	echo "		--nmis8=<NMIS8_directory> - Specify an NMIS8 directory if other than '/usr/local/nmis8'."
	echo "		-9 <NMIS9_directory>      - Specify an NMIS9 directory if other than '/usr/local/nmis9'."
	echo "		--nmis9=<NMIS9_directory> - Specify an NMIS9 directory if other than '/usr/local/nmis9'."
	echo "		-h | --help               - Invoke Help."
	echo "		-v                        - Print version and exit.."
}

yes_or_no() {
    while true; do
        read -p "$* [y/n]: " yn
        case $yn in
            [Yy]*) return 0  ;;
            [Nn]*) echo "Aborted" ; return  1 ;;
        esac
    done
}

PROGNAME="`basename ${0}`"
VERSION="Version 1.00"
NMIS8_HOME="/usr/local/nmis8"
NMIS9_HOME="/usr/local/nmis9"

    while getopts 8:9:hv-: opt
    do
       case ${opt} in
		-) case "${OPTARG}" in
				nmis8=* )
					NMIS8_HOME=${OPTARG#*=}
					;;
				nmis9=* )
					NMIS9_HOME=${OPTARG#*=}
					;;
				help )	Help
					exit 2
					;;
				*)
					if [ "$OPTERR" = 1 ] && [ "${optspec:0:1}" != ":" ]; then
						echo "Unknown Option --${OPTARG}" >&2
						Help
						exit 2
					fi
					;;
					esac
				;;
		8 )	NMIS8_HOME="${OPTARG}"
			;;
		9 )	NMIS9_HOME="${OPTARG}"
			;;
		v )	echo "$VERSION" >&2
			exit 2
			;;
		h )	Help
			exit 2
			;;
		\? )	echo "Unknown option ${OPTARG}" >&2
			Help
			exit 2
			;;
       esac
    done
    shift `expr ${OPTIND} - 1`

	if [ ! -d $NMIS8_HOME  -o ! -f $NMIS8_HOME/bin/nmis.pl ]; then
		echo "'$NMIS8_HOME' is not a valid NMIS 8 directory!"
		exit 4;
	fi
	if [ ! -d $NMIS9_HOME -o ! -f $NMIS9_HOME/bin/nmisd ]; then
		echo "'$NMIS9_HOME' is not a valid NMIS 9 directory!"
		exit 4;
	fi
	echo "NMIS8 Home is '$NMIS8_HOME'"
	echo "NMIS9 Home is '$NMIS9_HOME'"
	yes_or_no "Migrate setting from NMISA8 at '$NMIS8_HOME' to NMIS9 at '$NMIS9_HOME'?" || exit 2;

removeItems=(
    ## MUST Change - 
    '/sql/'
    '/directories/<nmis_models>'
    '/directories/<nmis_base>'
    '/url/<menu_url_base>'
    '/url/<url_base>'
    '/url/<cgi_url_base>'
## If we just remove the above it works.
    ## Obsolete remove anyway.
    '/javascript/chart'
    '/javascript/highcharts'
    '/javascript/highstock'
    '/master_slave'
    '/tables NMIS4'
    '/files/ipsla_log'
    '/files/fpingd_log'
    '/files/ipsla'
    '/system/ipsla_mthreaddebug'
    '/system/ipsla_bucket_interval'
    '/system/hide_setup_widget'
    '/system/nmis4_compatibility'
    '/system/nmis_summary_poll_cycle'
    '/system/cbqos_classmap_name_delimiter'
    '/system/log_polling_time'
    '/system/ipsla_extra_buckets'
    '/system/location_field_name'
    '/system/verbose_nmis_process_events'
    '/system/fastping_sleep'
    '/system/disable_interfaces_summary'
    '/system/ipsla_maxthreads'
    '/system/nmis_mthread'
    '/system/graph_cache_maxage'
    '/system/ipsla_collect_time'
    '/system/group_list'
    '/system/ipsla_control_enable_other'
    '/system/ipsla_mthread'
    '/system/nmis_maxthreads'
    '/system/ipsla_dnscachetime'
    '/system/snpp_server'
    '/system/preserve_item_string'
    '/system/global_collect'
    '/system/selftest_max_nmis_procs'
    '/modules/opmaps_widget_height'
    ## regex change nmis8 -> nmis9 would be good as these are customised quite often.
    '/menu/menu_title'
    '/authentication/auth_login_title'
    '/authentication/auth_banner_title'
    ## Take new system   defaults by removing so update inserts new
    '/daemons'
    '/authentication/auth_user_name_regex'
    #'/globals/uuid_add_with_node'
    #'/globals/threshold_poll_cycle'
## Unknown
# '/modules'
# '/sound/sound_critical'
# '/sound/sound_major'
# '/sound/sound_fatal'
)


grep loc_sysLoc_format /usr/local/nmis8/install/Config.nmis | awk {'print $3'} >/tmp/loc_sysLoc_default.txt
grep loc_sysLoc_format /usr/local/nmis8/conf/Config.nmis | awk {'print $3'} >/tmp/loc_sysLoc_live.txt
diff /tmp/loc_sysLoc_default.txt /tmp/loc_sysLoc_live.txt >/dev/null
if [ $? -eq 0 ]; then
   loc_sysLoc_default=1
   echo "loc_sysLoc_format is defaulted."
fi
rm -f /tmp/loc_sysLoc_default.txt
rm -f /tmp/loc_sysLoc_live.txt

## Copy all the old config to the new conf folder
#first backup the installer generated Config.nmis
cp /usr/local/nmis9/conf/Config.nmis{,.installer}
cp -f `find /usr/local/nmis8/conf/*.nmis | grep -v Table-` /usr/local/nmis9/conf/
cp -f /usr/local/nmis8/conf/users.dat /usr/local/nmis9/conf/
#Now get rid of the NMIS9 installer generated Config.nmis so we can replace it with a working copy.
rm /usr/local/nmis9/conf/Config.nmis

# Create a staging copy of the NMIS8 Config.nmis
cp -f /usr/local/nmis8/conf/Config.nmis /tmp/Config.nmis.upgradepatch
sed -i "s/'node_name_rule' *=> *qr/'node_name_rule' => m/" /tmp/Config.nmis.upgradepatch
sed -i "s/nmis8/nmis9/" /tmp/Config.nmis.upgradepatch
sed -i "s/NMIS8/NMIS9/" /tmp/Config.nmis.upgradepatch


#numberKeys=0   ## Used for testing which Config items broke NMIS

for key in "${removeItems[@]}"
do 
    # if [[ $numberKeys -eq $1 ]]; then
    #      echo "got to item $key with iterations $numberKeys"
    #     break
    # fi
    echo "removing $key"
    /usr/local/nmis9/admin/patch_config.pl -f /tmp/Config.nmis.upgradepatch $key=undef
    #((numberKeys++))

done

## As much as the settings are set to undef the upgrade config will not overwrite those settings 
# with new ones so need to remove all lines with undef, at the end.
## We had to set to undef as we couldn't just loop over the above items and delete
# as they might be nested

echo "Removing undef Lines\n\n"
sed -i '/undef,/d' /tmp/Config.nmis.upgradepatch

# now create a patched copy of the Config.nmis file.
#this adds items from nmis9/conf-default/Config.nmis not found in this Config.nmis - so adds items we deleted if needs be.
/usr/local/nmis9/admin/updateconfig.pl /usr/local/nmis9/conf-default/Config.nmis /tmp/Config.nmis.upgradepatch debug=9

# reset the cluster_id to the one created at install as the nodes were imported with that cluster_id.
# it's currently blank and when NMIS runs it will create a new one.
cluster=`grep cluster_id /usr/local/nmis9/conf/Config.nmis.installer | awk '{print $3}' | sed "s/'//g"`
/usr/local/nmis9/admin/patch_config.pl -f /tmp/Config.nmis.upgradepatch /id/cluster_id=$cluster

# Migrate the Node Configuration.
/usr/local/nmis9/admin/migrate_node_config.pl act='migrate_nodeconf'


sed -i "s#'node_name_rule' *=> *'\(.*\)'#'node_name_rule' => 'qr/\1/'#" /tmp/Config.nmis.upgradepatch
if [ $loc_sysLoc_default -eq 1 ]; then
   grep loc_sysLoc_format /usr/local/nmis9/conf-default/Config.nmis | awk {'print $3'} | sed "s#\\\#\\\\\\\#g" >/tmp/loc_sysLoc_nmis9.txt
   sed -i "s#'loc_sysLoc_format' *=> *.*\$#'loc_sysLoc_format' => `cat /tmp/loc_sysLoc_nmis9.txt`#" /tmp/Config.nmis.upgradepatch
   rm -f /tmp/loc_sysLoc_nmis9.txt
fi
# Finally copy the new Config.nmis into place and start the services.
mv /tmp/Config.nmis.upgradepatch /usr/local/nmis9/conf/Config.nmis

## doesn't always work as it sometimes can't kill the nmis9 daemons.
systemctl restart nmis9d


