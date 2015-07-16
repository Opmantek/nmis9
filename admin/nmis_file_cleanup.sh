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

# purge old RRD files
find $DIR/database/ -follow -name "*.rrd" -mtime +$DAYS -type f -exec rm -f {} \;

# and also get rid of definitely corrupt zero-byte-size RRD files
find $DIR/database/ -follow -name "*.rrd" -type f -size 0c -exec rm -f {} \;

# purge the NMIS files
find $DIR/var/ -follow -name "*.nmis" -mtime +$DAYS -type f -exec rm -f {} \;

# purge old JSON files, but not essential data!
find $DIR/var/ -follow -maxdepth 1 -name "*.json" -mtime +$DAYS -type f -exec rm -f {} \;
find $DIR/var/nmis_system/ -follow -name "*.json" -mtime +$DAYS -type f -exec rm -f {} \;
# similar: event history records, not current events
find $DIR/var/events/ -follow -path "*/history/*.json" -type f -mtime +$DAYS -exec rm -f {} \;

# same for the operations timestamps, which have no file extension
find $DIR/var/nmis_system/timestamps -follow -mtime +$DAYS -type f -exec rm -f {} \;

# purge the JSON log files
find $DIR/logs/ -follow -name "*json" -mtime +$DAYS -type f -exec rm -f {} \;
