#!/bin/sh
# a set of functions for installing a local mongodb if desired
# note: this module assumes that common_mongodb, common_functions AND common_repos are available,
# and that flavour() was called.

# adds the official mongodb.org rpm/apt repository,
# either the given version or 6.2 as fallback
# args: mongodb major.minor version string
add_mongo_6_repository () {
		# do mongo?
		if [ "${NO_MONGO}" = 1 ]; then
				echolog "NO_MONGO=${NO_MONGO}: Skipping MongoDB (add_mongo_6_repository) as instructed."
				return 0;
		else
				 echolog "NO_MONGO=${NO_MONGO}: Continuing (add_mongo_6_repository) ...";
		fi;

		# shellcheck disable=SC2039
		local REPOFILE
		# shellcheck disable=SC2039
		local SOURCESFILE
		# shellcheck disable=SC2039
		local RELEASENAME

		# shellcheck disable=SC2039
		local DESIREDVER
		DESIREDVER=${1:-6.0}

		# redhat/centos: mongodb supplies rpms for 6.2 for all platforms and versions we care about
                if [ "$OSFLAVOUR" = "redhat" ]; then
                        REPOFILE="/etc/yum.repos.d/mongodb-org-$DESIREDVER.repo"

                if [ -f "${REPOFILE}" ]; then
                         logmsg "Mongodb.org repository entry already present."
                return 0
                fi

                if [ "${OS_MAJOR}" -eq 9 ]; then
                # For RHEL 9 and DESIREDVER 6.0, we use RHEL 8 repo
                        baseurl="https://repo.mongodb.org/yum/redhat/8/mongodb-org/"
                else
                    	baseurl="https://repo.mongodb.org/yum/redhat/${OS_MAJOR}/mongodb-org/"
                fi
                cat >"${REPOFILE}" <<EOF
[mongodb-org-$DESIREDVER]
name=MongoDB Repository
baseurl=$baseurl$DESIREDVER/x86_64/
gpgcheck=0
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-$DESIREDVER.asc

EOF
				# we install the mongodb-supplied version for debian derivative OS
		elif [ "$OSFLAVOUR" = "debian" ] || [ "$OSFLAVOUR" = "ubuntu" ]; then
				# shellcheck disable=SC2039
				local RES;
				# shellcheck disable=SC2039
				local OUTPUT;
				SOURCESFILE=/etc/apt/sources.list.d/mongodb-org-$DESIREDVER.list
				[ ! -d /etc/apt/sources.list.d ] && mkdir -p /etc/apt/sources.list.d

				# get the release key first
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
				RELEASENAME=$(lsb_release -sc 2>&1)||RES=$?;
				# echologVerboseError expects parameters: COMMAND (as a string '$*' or '...', not an array '$@'), EXITCODE then COMMANDOUTPUT
				echologVerboseError "lsb_release -sc 2>&1" \
						    "${RES}" \
						    "${RELEASENAME:-}";

				if [ "$OSFLAVOUR" = "debian" ]; then
						[ "$OS_MAJOR" = 9 ] && MONGORELNAME=stretch || MONGORELNAME=buster
						echo "deb [ trusted=yes ] http://repo.mongodb.org/apt/debian $MONGORELNAME/mongodb-org/$DESIREDVER main" >"${SOURCESFILE}"
						# debian 9: mongo package for jessie requires older libssl, only a/v in jessie
						###[ "$OS_MAJOR" -ge 9 ] && enable_distro "jessie"
				else
						MONGORELNAME="bionic";
						echo "deb [ trusted=yes ] http://repo.mongodb.org/apt/ubuntu $MONGORELNAME/mongodb-org/$DESIREDVER multiverse" >"${SOURCESFILE}"
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
install_mongo_6 () {
		# do mongo?
		if [ "${NO_MONGO}" = 1 ]; then
				echolog "NO_MONGO=${NO_MONGO}: Skipping MongoDB (install_mongo_6) as instructed."
				return 0;
		else
				 echolog "NO_MONGO=${NO_MONGO}: Continuing (install_mongo_6) ...";
		fi;

		if [ "$OSFLAVOUR" = "redhat" ]; then
				execPrint "yum install -y mongodb-org 2>&1"||:;
				# redhat installs don't start servers - do a stop and start, important for upgrade
				execPrint "service mongod stop 2>&1"||:;
				execPrint "service mongod start 2>&1"||:;
				sleep 10; # to give it time to start up
		elif [ "$OSFLAVOUR" = "debian" ] || [ "$OSFLAVOUR" = "ubuntu" ]; then
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
#
#
# function returns 0 if ok, 1 on errors or unsatisfied requirements, 2 if the user says no to installation/upgrade
new_mongo_6_or_bust ()
{
		# do mongo?
		if [ "${NO_MONGO}" = 1 ]; then
				echolog "NO_MONGO=${NO_MONGO}: Skipping MongoDB (new_mongo_6_or_bust) as instructed."
				return 0;
		else
				 echolog "NO_MONGO=${NO_MONGO}: Continuing (new_mongo_6_or_bust) ...";
		fi;

		# shellcheck disable=SC2039
		local MIN_MAJ MIN_MIN MIN_PATCH

		# Default to 6.0 as we do in add_mongo_6_repository() function
		# Simplifies things for Dependency Check Mode
		MIN_MAJ=${1:-6}
		MIN_MIN=${2:-0}
		# shellcheck disable=SC2034
		MIN_PATCH=${3:-5}

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
				echo
				printBanner "No local MongoDB installation detected."
				if [ "${DEPENDENCY_CHECK_ONLY}" = 1 ]; then
					# shellcheck disable=SC2129
					echo "# mongodb-org install notes:" >> "${DEPENDENCY_CHECK_FILE}";
					# shellcheck disable=SC2129
					echo "#		pre-install newest available version ${MIN_MAJ}.${MIN_MIN} before installing NMIS9 or ${PRODUCT}." >> "${DEPENDENCY_CHECK_FILE}";
					# shellcheck disable=SC2129
					echo "# mongodb-org additional notes:" >> "${DEPENDENCY_CHECK_FILE}";
					# shellcheck disable=SC2129
					echo "#		Please note that $PRODUCT requires MongoDB to be either installed" >> "${DEPENDENCY_CHECK_FILE}";
					# shellcheck disable=SC2129
					echo "#		locally on this server, OR accessible via the network. MongoDB also" >> "${DEPENDENCY_CHECK_FILE}";
					# shellcheck disable=SC2129
					echo "#		MUST be configured for authentication, and needs to be primed" >> "${DEPENDENCY_CHECK_FILE}";
					# shellcheck disable=SC2129
					echo "#		specifically for Opmantek use as documented on this page:" >> "${DEPENDENCY_CHECK_FILE}";
					# shellcheck disable=SC2129
					echo "#		https://community.opmantek.com/x/h4Aj" >> "${DEPENDENCY_CHECK_FILE}";
					# shellcheck disable=SC2129
					echo "mongodb-org" >> "${DEPENDENCY_CHECK_FILE}";
					return 0;
				else
					cat <<EOF

Please note that $PRODUCT requires MongoDB to be either installed
locally on this server, OR accessible via the network. MongoDB also
MUST be configured for authentication, and needs to be primed
specifically for Opmantek use as documented on this page:

    https://community.opmantek.com/x/h4Aj

EOF

				fi
				if [ "$CANUSEWEB" != 1 ]; then
						printBanner "Cannot install MongoDB without Web access!"
						cat <<EOF

Web access is required for installing MongoDB, but your system
does not have that.

You will have to install MongoDB manually (downloadable
from http://mongodb.org/).

EOF
						return 1
				fi

				if ! input_yn "Would you like to install MongoDB locally?" "ef5b"; then
						echo
						echolog "NOT installing MongoDB, as instructed."
						return 2
				fi

				echolog "Installing MongoDB repository and software"
				add_mongo_6_repository "${MIN_MAJ}.${MIN_MIN}"||:;
				install_mongo_6||:;

		# mongo is installed - this function only deals with new installs of MongoDB
		else
			:
		fi
		return 0
}
