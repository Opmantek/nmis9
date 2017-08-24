# a set of functions for installing a local mongodb if desired
# note: this module assumes that common_functions AND common_repos are available,
# and that flavour() was called.

# returns 0 if mongo is locally installed, 1 otherwise
# also sets MONGO_VERSION, MONGO_MAJOR, _MINOR and _PATCH if installed and mongod can be found
is_mongo_installed() {
		# non-package installation? if mongod is in the path, or if there's an init script we call it ok
		if ! type mongod >/dev/null 2>&1 && [ ! -f /etc/init.d/mongod ]; then
				# check the packages
				if [ "$OSFLAVOUR" = "redhat" ]; then
						rpm -qa | fgrep -q mongodb-org-server || return 1
				elif [ "$OSFLAVOUR" = "debian" -o "$OSFLAVOUR" = "ubuntu" ]; then
						dpkg -l mongodb-server mongodb-org-server 2>/dev/null | grep -q ^ii || return 1
				fi
		fi

		# let's get the version if we can.
		if type mongod >/dev/null 2>&1 ; then
				# prints something like "db version v3.0.7" plus other gunk AND other lines
				MONGO_VERSION=`mongod --version|grep '[0-9]\.[0-9]\.[0-9]'|cut -f3 -dv|tr -c -d 0-9.`
				MONGO_MAJOR=`echo $MONGO_VERSION | cut -f 1 -d .`
				MONGO_MINOR=`echo $MONGO_VERSION | cut -f 2 -d .`
				MONGO_PATCH=`echo $MONGO_VERSION | cut -f 3 -d .`
		fi

		return 0
}


# adds the official mongodb.org rpm/apt repository,
# either the given version or 3.4 as fallback
# args: mongodb major.minor version string
add_mongo_repository () {
		local REPOFILE
		local SOURCESFILE
		local RELEASENAME

		local DESIREDVER
		DESIREDVER=${1:-3.4}

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
				SOURCESFILE=/etc/apt/sources.list.d/mongodb-org-$DESIREDVER.list
				[ ! -d /etc/apt/sources.list.d ] && mkdir -p /etc/apt/sources.list.d

				RELEASENAME=`lsb_release -sc`
				# debian 7, 8: 3.4 is a/v - upstream doesn't have newer version-specific packages
				# debian 9: 3.2 is in debian proper but we normally need 3.4.
				if [ "$OSFLAVOUR" = "debian" ]; then
						[ "$OS_MAJOR" = 7 ] && MONGORELNAME=wheezy || MONGORELNAME=jessie
						echo "deb http://repo.mongodb.org/apt/debian $MONGORELNAME/mongodb-org/$DESIREDVER main" >$SOURCESFILE
						# debian 9: mongo package for jessie requires older libssl, only a/v in jessie
						[ "$OS_MAJOR" -ge 9 ] && enable_distro "jessie"
				else
						# ubuntu 12, 14, 16: 3.2 is /av
						MONGORELNAME="xenial"; # aka 16.xx
						[ "$OS_MAJOR" = "14" ] && MONGORELNAME="trusty" # 14.04
						[ "$OS_MAJOR" = "12" ] && MONGORELNAME="precise" # aka 12.04

						echo "deb http://repo.mongodb.org/apt/ubuntu $MONGORELNAME/mongodb-org/$DESIREDVER multiverse" >$SOURCESFILE
				fi

				if [ -f "$SOURCESFILE" ]; then
						logmsg "Mongodb.org sources list already present."
						return 0;
				fi

				type wget >/dev/null 2>&1 && GIMMEKEY="wget -q -T 20 -O - https://www.mongodb.org/static/pgp/server-$DESIREDVER.asc" || GIMMEKEY="curl -s -m 20 https://www.mongodb.org/static/pgp/server-$DESIREDVER.asc"
				# apt-key adv doesn't work cleanly with gpg 2.1+
				$GIMMEKEY | apt-key add -
				apt-get update -qq
 		else
				logmsg "Unknown distribution $OSFLAVOUR!"
				return 1;
		fi
		return 0;
}

# installs and starts up a local mongodb
install_mongo () {
		if [ "$OSFLAVOUR" = "redhat" ]; then
				yum install -y mongodb-org
				# redhat installs don't start servers
				service mongod start
				sleep 10								# to give it time to start up
		elif [ "$OSFLAVOUR" = "debian" -o "$OSFLAVOUR" = "ubuntu" ]; then
				DEBIAN_FRONTEND=noninteractive
				export DEBIAN_FRONTEND
				apt-get -yq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install mongodb-org
				# normally mongod should start on installation, but with systemd that seems unreliable
				sleep 3 # to give it time to start up
				# ubuntu: service X status is running through pager and thus blocks :-(
				# debian: normal, but >/dev/null doesn' hurt
				service mongod status >/dev/null || service mongod start
				# and, for some stupid reason, mongod isn't enabled for auto-start, at least not the 3.2 packace...
				type systemctl >/dev/null 2>&1 && systemctl enable mongod
		else
				logmsg "Unknown distribution $OSFLAVOUR!"
				return 1
		fi
		return 0
}
