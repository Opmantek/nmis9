#!/bin/sh
#
# The NMIS Shell!
#
##
#  Copyright 1999-2013 Opmantek Limited (www.opmantek.com)
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

nmis_base=/usr/local/nmis8
nmis=$nmis_base/bin/nmis.pl
nmis_log=$nmis_base/logs/nmis.log
event_log=$nmis_base/logs/event.log
error_log=/var/log/httpd/error_log
editor=/bin/vi
DEBUG="debug=false"
MODEL="model=false"

taillines=50

helptext() {
	echo NMIS Shell Options
	echo "    $0 escalate"
	echo "    $0 summary"
	echo "    $0 threshold"
	echo "    $0 purge"
	echo "    $0 apache"
	echo "    $0 master"
	echo "    $0 event"
	echo "    $0 log"
	echo "    $0 crontab"
	echo "    $0 config"
	echo "    $0 audit"
	echo "    $0 Nodes"
	echo "    $0 Config"
	echo "    $0 Users"
	echo "    $0 fixperms"
	echo "    $0 fpingd restart"
	echo "    $0 mib \"<search string>\""
	echo "    $0 grep|grepcode \"<search string>\""
	echo "    $0 grepfile \"<search string>\""
	echo "    $0 unixtime \"time string|epoch\""
	echo "    $0 <node_name>|all collect"
	echo "    $0 <node_name>|all update"
	echo "    $0 <node_name>|all model"
	echo "    $0 <node_name>|all node"
	echo "    $0 <node_name>|all verbose"
	exit 1
}

if [ -z "$1" ] 
then
	echo No arguements given:
	helptext
fi

if [ "$3" = "model" ]
then
	MODEL="model=true"
fi

if [ "$3" = "9" ]
then
	DEBUG="debug=9"
fi

if [ "$3" = "debug" ]
then
	DEBUG="debug=true"
fi

if [ "$2" = "debug" ]
then
	DEBUG="debug=true"
fi

if [ "$1" = "log" ]
then
	tail -$taillines $nmis_log
	exit 0
fi

if [ "$1" = "event" ]
then
	tail -$taillines $event_log
	exit 0
fi

if [ "$1" = "apache" ]
then
	tail -$taillines $error_log
	exit 0
fi

if [ "$1" = "master" ]
then
	$nmis type=master debug=true sleep=1
	exit 0
fi

if [ "$1" = "threshold" ]
then
	$nmis type=threshold debug=true sleep=1
	exit 0
fi

if [ "$1" = "summary" ]
then
	$nmis type=summary debug=true
	exit 0
fi

if [ "$1" = "audit" ]
then
	$nmis type=audit debug=true
	exit 0
fi

if [ "$1" = "config" ]
then
	$nmis type=config debug=true
	exit 0
fi

if [ "$1" = "crontab" ]
then
	$nmis type=crontab debug=true
	exit 0
fi

if [ "$1" = "escalate" ]
then
	$nmis type=escalate debug=true
	exit 0
fi

if [ "$1" = "purge" ]
then
	$nmis type=purge debug=true
	exit 0
fi

if [ "$1" = "Nodes" ]
then
	$editor $nmis_base/conf/Nodes.nmis
	exit 0
fi

if [ "$1" = "Config" ]
then
	$editor $nmis_base/conf/Config.nmis
	exit 0
fi

if [ "$1" = "Users" ]
then
	$editor $nmis_base/conf/Users.nmis
	exit 0
fi

if [ "$1" = "grep" ]
then
	find $nmis_base -name "*.p?" -exec grep -H "$2" {} \;
	exit 0
fi

if [ "$1" = "unixtime" ]
then
	$nmis_base/admin/unixtime.pl $2
	exit 0
fi

if [ "$1" = "fixperms" ]
then
	$nmis_base/admin/fixperms.pl
	exit 0
fi

if [ "$1" = "fpingd" ]
then
	if [ "$2" = "restart" ]
	then
		sudo $nmis_base/bin/fpingd.pl restart
		exit 0
	fi
fi

if [ "$1" = "grepcode" ]
then
	find $nmis_base -name "*.p?" -exec grep -H "$2" {} \;
	exit 0
fi

if [ "$1" = "grepfile" ]
then
	find $nmis_base -name "*.nmis" -exec grep -H "$2" {} \;
	exit 0
fi

if [ "$1" = "mib" ]
then
	grep "$2" $nmis_base/mibs/nmis_mibs.oid
	exit 0
fi

if [ "$1" = "conf" ]
then
	if [ -f $nmis_base/conf/$2.nmis ]
	then
		$editor $nmis_base/conf/$2.nmis
	else
		echo Config $nmis_base/conf/$2.nmis does not exist
	fi
	exit 0
fi


if [ "$2" = "" ] 
then
	echo NMIS Shell option not understood.
	helptext
else
	node="node=$1"
	if [ "$1" = "all" ] 
	then
		node=""
	fi
fi

if [ "$2" = "collect" ]
then
	$nmis type=collect "$node" info=true $DEBUG $MODEL
	exit 0
fi

if [ "$2" = "update" ]
then
	$nmis type=update "$node" info=true $DEBUG $MODEL
	exit 0
fi

if [ "$2" = "threshold" ]
then
	$nmis type=threshold "$node" info=true $DEBUG
	exit 0
fi

if [ "$2" = "model" ]
then
	$nmis type=update "$node" model=true info=true
	$nmis type=collect "$node" model=true info=true
	exit 0
fi

if [ "$2" = "verbose" ]
then
	$nmis type=update "$node" model=true debug=true
	$nmis type=collect "$node" model=true debug=true
	exit 0
fi

if [ "$2" = "node" ]
then
	node=${1,,}
	if [ -f "$nmis_base/var/$node-node.json" ]
	then
		cat "$nmis_base/var/$node-node.json"
		exit 0
	fi
	if [ -f "$nmis_base/var/$node-node.nmis" ]
	then
		cat "$nmis_base/var/$node-node.nmis"
		exit 0
	fi
fi

