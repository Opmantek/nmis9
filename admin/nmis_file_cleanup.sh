#!/bin/sh

if [ "$1" = "" ] 
then
	echo Please define the location of the NMIS8 installation, usually /usr/local/nmis8
	echo e.g. $0 /usr/local/nmis8 30
	echo For crontab use something like:
	echo 30 0 \* \* \* /usr/local/nmis8/admin/nmis_file_cleanup.sh /usr/local/nmis8 30
	exit
else
	DIR=$1
fi

if [ "$2" = "" ] 
then
	echo Please define number of days to cleanup e.g. 30
	echo e.g. $0 /usr/local/nmis8 30
	echo For crontab use something like:
	echo 30 0 \* \* \* /usr/local/nmis8/admin/nmis_file_cleanup.sh /usr/local/nmis8 30
	exit
else
	DAYS=$2
fi

# purge the RRD files
find $DIR/database -name "*rrd" -mtime +$DAYS -type f -exec rm -f {} \;

# purge the NMIS files
find $DIR/var/ -name "*nmis" -mtime +$DAYS -type f -exec rm -f {} \;

# purge the JSON files
find $DIR/var/ -name "*json" -mtime +$DAYS -type f -exec rm -f {} \;

# purge the JSON files
find $DIR/logs/ -name "*json" -mtime +$DAYS -type f -exec rm -f {} \;
