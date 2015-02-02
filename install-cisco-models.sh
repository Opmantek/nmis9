#!/bin/sh

echo This script will NOT backup your existing NMIS installation, please backup your installation before proceeding.
echo press Enter to continue ctrl+C to stop.
read X

unalias cp

cp ./install/* /usr/local/nmis8/install
cp ./models-install/* /usr/local/nmis8/models
cp ./mibs/nmis_mibs.oid /usr/local/nmis8/mibs

/usr/local/nmis8/install/install_cisco_model_dev.pl

/usr/local/nmis8/admin/fixperms.pl
