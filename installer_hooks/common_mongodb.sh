#!/bin/sh
# a set of functions for installing a local mongodb if desired
# note: this module assumes that common_functions AND common_repos are available,
# and that flavour() was called.

# returns 0 if mongo is locally installed, 1 otherwise
# also sets MONGO_VERSION, MONGO_MAJOR, _MINOR and _PATCH if installed and mongod can be found
is_mongo_installed() {
		# non-package installation? if mongod is in the path we call it ok
		if ! type mongod >/dev/null 2>&1; then
				if [ "${DEPENDENCY_CHECK_ONLY}" = 1 ]; then
					# we need to return 1 as SIMULATION_MODE=1 will cause the execPrint418 functions below to return 0
					# '! type mongod' command here has told us we don't have mongod installed
					return 1;
				fi;
				# check the packages
				if [ "$OSFLAVOUR" = "redhat" ]; then
						# filter out unwanted "418 I'm a teapot" errors
						execPrintNoRetry418 "rpm -qa|fgrep -q mongodb-org-server 2>&1"||return 1
				elif [ "$OSFLAVOUR" = "debian" -o "$OSFLAVOUR" = "ubuntu" ]; then
						# filter out unwanted "418 I'm a teapot" errors
						execPrintNoRetry418 "dpkg -l mongodb-server mongodb-org-server 2>/dev/null|grep -q ^[hi]i 2>&1"||return 1
				fi
		fi

		# let's get the version if we can.
		if type mongod >/dev/null 2>&1 ; then
				# prints something like "db version v3.0.7" plus other gunk AND other lines
				MONGO_VERSION=`mongod --version|grep '[0-9]\.[0-9]\.[0-9]'|cut -f3 -dv|tr -c -d 0-9.`||:;
				MONGO_MAJOR=`echo ${MONGO_VERSION:-} | cut -f 1 -d .`||:;
				MONGO_MINOR=`echo ${MONGO_VERSION:-} | cut -f 2 -d .`||:;
				MONGO_PATCH=`echo ${MONGO_VERSION:-} | cut -f 3 -d .`||:;
		fi

		return 0
}


# adds the official mongodb.org rpm/apt repository,
# either the given version or 3.4 as fallback
# args: mongodb major.minor version string
add_mongo_repository () {
		# do mongo?
		if [ "${NO_MONGO}" = 1 ]; then
				echolog "NO_MONGO=${NO_MONGO}: Skipping MongoDB (add_mongo_repository) as instructed."
				return 0;
		else
				 echolog "NO_MONGO=${NO_MONGO}: Continuing (add_mongo_repository) ...";
		fi;

		local REPOFILE
		local SOURCESFILE
		local RELEASENAME

		local DESIREDVER
		DESIREDVER=${1:-6.0}

		# redhat/centos: mongodb supplies rpms for 3.2 and 3.4 for all platforms and versions we care about
		if [ "$OSFLAVOUR" = "redhat" ]; then
				REPOFILE=/etc/yum.repos.d/mongodb-org-$DESIREDVER.repo
				if [ -f $REPOFILE ]; then
						logmsg "Mongodb.org repository entry already present."
						return 0;
				fi
				cat >$REPOFILE <<EOF
[mongodb-org-$DESIREDVER]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/\$releasever/mongodb-org/$DESIREDVER/x86_64/
gpgcheck=0
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-$DESIREDVER.asc

EOF
				# ubuntu, debian: only newest distros have 3.2, none have 3.4
				# so we install the mongodb-supplied version
		elif [ "$OSFLAVOUR" = "debian" -o "$OSFLAVOUR" = "ubuntu" ]; then
				local RES;
				local OUTPUT;
				SOURCESFILE=/etc/apt/sources.list.d/mongodb-org-$DESIREDVER.list
				[ ! -d /etc/apt/sources.list.d ] && mkdir -p /etc/apt/sources.list.d

				# get the release key first
				# however, as of [2018-02-08 Thu 12:18] the 3.4 repository signing is broken: BADSIG
				type wget >/dev/null 2>&1 && GIMMEKEY="wget -q -T 20 --tries=3 -O - https://www.mongodb.org/static/pgp/server-$DESIREDVER.asc" || GIMMEKEY="curl -L -s -m 20 --retry 2 https://www.mongodb.org/static/pgp/server-$DESIREDVER.asc"

				RES=0;
				OUTPUT="";
				# apt-key adv doesn't work cleanly with gpg 2.1+
				OUTPUT="$($GIMMEKEY | apt-key add - 2>&1)"||RES=$?;
				# echologVerboseError expects parameters: COMMAND (as a string '$*' or '...', not an array '$@'), EXITCODE then COMMANDOUTPUT
				echologVerboseError "$GIMMEKEY | apt-key add - " \
						    "${RES}" \
						    "${OUTPUT:-}";

				RES=0;
				RELEASENAME=""
				RELEASENAME=`lsb_release -sc 2>&1`||RES=$?;
				# echologVerboseError expects parameters: COMMAND (as a string '$*' or '...', not an array '$@'), EXITCODE then COMMANDOUTPUT
				echologVerboseError "lsb_release -sc 2>&1" \
						    "${RES}" \
						    "${RELEASENAME:-}";

				# debian 7, 8: 3.4 is a/v - upstream doesn't have newer version-specific packages
				# debian 9: 3.2 is in debian proper but we normally need 3.4.
				if [ "$OSFLAVOUR" = "debian" ]; then
						[ "$OS_MAJOR" = 7 ] && MONGORELNAME=wheezy || MONGORELNAME=jessie
						# BADSIG on repository as of [2018-02-08 Thu 12:22]
						echo "deb [ trusted=yes ] http://repo.mongodb.org/apt/debian $MONGORELNAME/mongodb-org/$DESIREDVER main" >$SOURCESFILE
						# debian 9: mongo package for jessie requires older libssl, only a/v in jessie
						[ "$OS_MAJOR" -ge 9 ] && enable_distro "jessie"
				else
						# ubuntu 12, 14, 16: 3.2 is /av
						MONGORELNAME="xenial"; # aka 16.xx
						[ "$OS_MAJOR" = "14" ] && MONGORELNAME="trusty" # 14.04
						[ "$OS_MAJOR" = "12" ] && MONGORELNAME="precise" # aka 12.04

						# BADSIG on repository as of [2018-02-08 Thu 12:22]
						echo "deb [ trusted=yes ] http://repo.mongodb.org/apt/ubuntu $MONGORELNAME/mongodb-org/$DESIREDVER multiverse" >$SOURCESFILE
				fi

				execPrint "apt-get update -qq 2>&1"||:;

				unset RES;
				unset OUTPUT;
 		else
				logmsg "Unknown distribution $OSFLAVOUR!"
				return 1;
		fi
		return 0;
}

# installs and starts up a local mongodb
install_mongo () {
		# do mongo?
		if [ "${NO_MONGO}" = 1 ]; then
				echolog "NO_MONGO=${NO_MONGO}: Skipping MongoDB (install_mongo) as instructed."
				return 0;
		else
				 echolog "NO_MONGO=${NO_MONGO}: Continuing (install_mongo) ...";
		fi;

		if [ "$OSFLAVOUR" = "redhat" ]; then
				execPrint "yum install -y mongodb-org 2>&1"||:;
				# redhat installs don't start servers - do a stop and start, important for upgrade
				execPrint "service mongod stop 2>&1"||:;
				execPrint "service mongod start 2>&1"||:;
				sleep 10; # to give it time to start up
		elif [ "$OSFLAVOUR" = "debian" -o "$OSFLAVOUR" = "ubuntu" ]; then
				DEBIAN_FRONTEND=noninteractive
				export DEBIAN_FRONTEND
				DEBCONF_NONINTERACTIVE_SEEN=true
				export DEBCONF_NONINTERACTIVE_SEEN

				# remove debian's mongo-tools, undeclared conflict with
				# mongodb-org-tools, not co-installable
				# filter out unwanted "418 I'm a teapot" errors
				if execPrintNoRetry418 "dpkg -l mongo-tools >/dev/null 2>&1"; then
					execPrint "apt-get -yq remove mongo-tools 2>&1"||:;
				fi;

				# mongodb-org doesn't have versioned dependencies
				execPrint "apt-get -yq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install mongodb-org mongodb-org-shell mongodb-org-server mongodb-org-mongos mongodb-org-tools 2>&1"||:;

				# if this system uses sysv init, then we need to supply our /etc/init.d/mongod
				# the mongodb.org package only caters for systemd :-(
				if ! type systemctl >/dev/null 2>&1 ; then
						if [ ! -r /etc/init.d/mongod ]; then
								execPrint "cp -a ./install/mongod.init.d /etc/init.d/mongod 2>&1"||:;
						fi
						execPrint "update-rc.d mongod defaults 2>&1"||:;
						execPrint "service mongod start 2>&1"||:;
				fi

				# normally mongod should start on installation, but with systemd that seems unreliable
				sleep 3 # to give it time to start up
				# ubuntu: service X status is running through pager and thus blocks :-(
				# debian: normal, but >/dev/null doesn' hurt
				execPrint "service mongod status >/dev/null || service mongod start 2>&1"||:;
				# and, for some stupid reason, mongod isn't enabled for auto-start, at least not the 3.2 package...
				execPrint "type systemctl >/dev/null 2>&1 && systemctl enable mongod 2>&1"||:;
		else
				logmsg "Unknown distribution $OSFLAVOUR!"
				return 1
		fi
		return 0
}


# wrapper function that performs all supported mongodb-related check/install/upgrade functions
# args: MinMaj MinMin MinPatch - mongodb minimum acceptable version,
# optional: WarnMaj WarnMin WarnPatch - mongodb version that's acceptable but elicits warning
#
#
# function returns 0 if ok, 1 on errors or unsatisfied requirements, 2 if the user says no to installation/upgrade
mongo_or_bust ()
{
		# do mongo?
		if [ "${NO_MONGO}" = 1 ]; then
				echolog "NO_MONGO=${NO_MONGO}: Skipping MongoDB (mongo_or_bust) as instructed."
				return 0;
		else
				 echolog "NO_MONGO=${NO_MONGO}: Continuing (mongo_or_bust) ...";
		fi;

		local MIN_MAJ MIN_MIN MIN_PATCH WARN_MAJ WARN_MIN WARN_PATCH

		# Default to 3.4 to tie in with add_mongo_repository() function variable DESIREDVER defaulting to 3.4
		# Previously defaulted to '0.0'
		# Simplifies things for Dependency Check Mode
		MIN_MAJ=${1:-3}
		MIN_MIN=${2:-4}

		MIN_PATCH=${3:-0}

		WARN_MAJ=${4:-}
		WARN_MIN=${5:-}
		WARN_PATCH=${6:-}

		# ignore mongodb altogether if NO_LOCAL_MONGODB is set, but do warn about it
		if [ -n "${NO_LOCAL_MONGODB:-}" ]; then
				printBanner "Ignoring local MongoDB installation state as directed!"
				cat <<EOF
The installer has been instructed to not check or install a local
MongoDB instance. Please note that $PRODUCT will not work unless
you deploy and configure a network-accessible MongoDB instance
as documented on this page:

    https://community.opmantek.com/x/h4Aj

EOF
				input_ok "Hit <Enter> when ready to continue: "
				return 0
		fi


		# not present yet? then offer to install
		if ! is_mongo_installed; then

				# find out where we are, and get additional common function to install mongo 4.2
				SCRIPTPATH=${0%/*}
				. $SCRIPTPATH/common_mongodb_6.sh
				# check and get mongodb 4.2, returns 0 if ok, 1 or 2 otherwise
				new_mongo_6_or_bust 6 0 15|| exit 1

		# mongo is installed, but is the version sufficient?
		else
				echo
				echolog "MongoDB package is installed locally."

				if [ -z "${MONGO_VERSION:-}" ]; then
						printBanner "Could not determine MongoDB Version!";
						cat <<EOF

It seems that MongoDB is installed on your system but the installer
could not find the 'mongod' executable and thus could not determine
your MongoDB version. Please ensure that the PATH
environment variable includes the directory of the 'mongod' executable,
then restart the installer, e.g.:

PATH=\$PATH:/where/mongod/lives sh ./$PRODUCT-Linux-x86_64-$VERSION.run

EOF
						input_ok "Hit <Enter> when ready to continue: "
						return 1;
				fi

				# too old?
				if ! version_meets_min "$MONGO_MAJOR" "$MONGO_MINOR" "$MONGO_PATCH" "$MIN_MAJ" "$MIN_MIN" "$MIN_PATCH"; then
						printBanner "Your MongoDB Version is too old."

						# can we offer an upgrade? that's doable for 3.x to 3.2 to 3.4, not feasible for anything older than that
						# also only possible if web access is available
						if [ "$MONGO_MAJOR" -ge 3 -a "$CANUSEWEB" = 1 ]; then
								cat <<EOF

Your installed version of MongoDB ($MONGO_VERSION) is too old for $PRODUCT.
$PRODUCT requires MongoDB version $MIN_MAJ.$MIN_MIN.$MIN_PATCH or newer for correct operation.

However, the installer can perform an upgrade of MongoDB to 3.4.

EOF
								if ! input_yn "Would you like the installer to upgrade your (too old) MongoDB installation to 3.4?" "d85b"; then
										echo
										echolog "NOT upgrading MongoDB, as instructed."
										return 2
								fi

								echolog "Upgrading MongoDB repository and software"
								# 3.0? must go to 3.2 first :-(
								if [ "$MONGO_MINOR" -lt 2 ]; then
										echolog "Performing intermediate upgrade to 3.2"
										add_mongo_repository 3.2||:;
										install_mongo||:;
								fi
								echolog "Performing upgrade to 3.4"
								add_mongo_repository 3.4||:;
								install_mongo||:;
						else
								# too old, cannot upgrade, give up
								cat <<EOF

Your installed version of MongoDB ($MONGO_VERSION) is too old for $PRODUCT.
$PRODUCT requires MongoDB version $MIN_MAJ.$MIN_MIN.$MIN_PATCH or newer for correct operation.

Please upgrade your installation to MongoDB 3.4, then restart
the $PRODUCT installer. MongoDB can be downloaded
from http://mongodb.org/ and our wiki has further information about
MongoDB upgrades here: https://community.opmantek.com/x/h4Aj

EOF
 								logmsg "MongoDB Version $MONGO_VERSION is too old to continue."
								return 1
						fi
        # strict minimum is met, but is there a warning level?
				elif [ -n "$WARN_MAJ" -a -n "$WARN_MIN" -a -n "$WARN_MIN" ] \
								 && 	! version_meets_min "$MONGO_MAJOR" "$MONGO_MINOR" "$MONGO_PATCH" "$WARN_MAJ" "$WARN_MIN" "$WARN_MIN"; then

						printBanner "MongoDB Version is too old for optimal operation."

						cat <<EOF

Your installed version of MongoDB ($MONGO_VERSION) is sufficient
but not ideal for $PRODUCT.
$PRODUCT works best with MongoDB $WARN_MAJ.$WARN_MIN.$WARN_PATCH.

You may continue the $PRODUCT installation, but please note that some
features of $PRODUCT might not work efficiently with this version of MongoDB.

It is highly recommended that you upgrade to MongoDB 3.4,
which can be downloaded from http://mongodb.org/. Our wiki has
further information about MongoDB upgrades here:
    https://community.opmantek.com/x/h4Aj

EOF
						# again offer upgrade is  possible
						if [ "$MONGO_MAJOR" -ge 3 -a "$CANUSEWEB" = 1 ]; then

								if ! input_yn "Would you like the installer to upgrade your (slightly old) MongoDB installation to 3.4?" "24f8"; then
										echo
										echolog "NOT upgrading MongoDB, as instructed."
										return 0		# not ideal but good enough
								fi

								echolog "Upgrading MongoDB repository and software"
								# 3.0? must go to 3.2 first :-(
								if [ "$MONGO_MINOR" -lt 2 ]; then
										echolog "Performing intermediate upgrade to 3.2"
										add_mongo_repository 3.2||:;
										install_mongo||:;
								fi
								echolog "Performing upgrade to 3.4"
								add_mongo_repository 3.4||:;
								install_mongo||:;
						else
								input_ok "Hit <Enter> when ready to continue: "
						fi

				else
						echolog "MongoDB version is $MONGO_VERSION."
				fi
		fi
		return 0
}
