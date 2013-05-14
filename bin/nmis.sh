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
error_log=/var/log/httpd/error_log

taillines=50

if [ "$1" == "" ] 
then
	echo No arguements given:
	echo You can.......
	echo "    $0 log   "
	echo "    $0 apache   "
	echo "    $0 collect <node_name>|all"
  echo "    $0 update <node_name>|all"
  exit 1
fi

if [ "$1" == "log" ]
then
	tail -$taillines $nmis_log
	exit 0
fi

if [ "$1" == "apache" ]
then
	tail -$taillines $error_log
	exit 0
fi

if [ "$1" == "summary" ]
then
	$nmis type=summary debug=true
	exit 0
fi

if [ "$1" == "master" ]
then
	$nmis type=master debug=true sleep=1
	exit 0
fi

if [ "$1" == "threshold" ]
then
	$nmis type=threshold debug=true sleep=1
	exit 0
fi

if [ "$1" == "grep" ]
then
	find $nmis_base -name "*.p?" -exec grep -H $2 {} \;
	exit 0
fi

if [ "$2" == "" ] 
then
	echo No second arguement given, need to know node name or something!
	exit 0
else
	node="node=$1"
	if [ "$1" == "all" ] 
	then
		node=""
	fi
fi

if [ "$2" == "collect" ]
then
	$nmis type=collect $node debug=true
	exit 0
fi

if [ "$2" == "update" ]
then
	$nmis type=update $node debug=true
	exit 0
fi

if [ "$2" == "threshold" ]
then
	$nmis type=threshold $node debug=true
	exit 0
fi

if [ "$2" == "model" ]
then
	$nmis type=collect $node model=true
	exit 0
fi

if [ "$2" == "node" ]
then
	node=${1,,}
	cat $nmis_base/var/$node-node.nmis
	exit 0
fi
