# a set of common functions for convenience
# use POSIX functionality only, no bashisms!

# echo and log-append to logfile
echolog() {
		echo "$@"
		[ -f "$LOGFILE" ] && echo "$@" >> $LOGFILE
}

# append text to logfile
logmsg() {
		if [ -f "$LOGFILE" ]; then
				echo "$@" >> $LOGFILE
		fi
}

# bash needs echo -e for \n to work, dash and posix don't
# so we do it the cheap and ugly way
printBanner() {
		echo
		echo
		echo "++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		echo "$@"
		echo "++++++++++++++++++++++++++++++++++++++++++++++++++++++"
		echo

		if [ -f "$LOGFILE" ]; then
				echo '###+++' >> $LOGFILE
				echo "$@" >> $LOGFILE
				echo '###+++' >> $LOGFILE
		fi
}

# prints given prompt, reads response, DOES NOT RETURN ANYTHING
# this is just for waiting for confirmations in interactive mode.
input_ok() {
		echo "$@"
		if [ -z "$UNATTENDED" ]; then
				local X
				read X
		fi
}

# print prompt, print static blurb, read response (or auto-yes)
input_yn() {
		echo "$@"
		echo -n "Type 'y' or hit <Enter> to accept, any other key for 'no': "
		if [ -z "$UNATTENDED" ]; then
				local X
				read X
				logmsg "User input for '$@': '$X'"
				X=`echo $X | tr -d '[:space:]'| tr '[A-Z]' '[a-z]'`
				if [ -z "$X" -o "$X" = "y" -o "$X" = "yes" ]; then
						return 0								# ok
				else
						return 1								# nok
				fi
		else
				echo "(auto-default YES)"
				echo
				return 0
		fi
}

# print prompt, print static blurb, read response string and
# export it as RESPONSE
# in unattended mode the response is ''
input_text() {
		RESPONSE=''
		echo -n "$@"
		if [ -z "$UNATTENDED" ]; then
				read RESPONSE
				logmsg "User input for '$@': '$RESPONSE'"
		else
				logmsg "Automatic blank input for '$@' in unattended mode"
				echo "(auto-default empty response)"
		fi
		export RESPONSE
}



# run cmd, capture output and stderr and append to logfile
# if in simulate mode, only print what WOULD be done but
# DON'T EXECUTE anything

execPrint()
{
		if [ -n "$SIMULATE" ]; then
				echo
				echo "SIMULATION MODE, NOT executing command '$@'"
				return 0
		fi

		logmsg "###+++"
		logmsg "EXEC: $@"

		OUTPUT=`eval $@ 2>&1`
		RES=$?
		if [ $RES != 0 ]; then
				echolog "-------COMMAND RETURNED EXIT CODE $RES--------"
				echolog "$@" $OUTPUT
				echolog "----------------------------------------"
		else
				logmsg "OUTPUT: $OUTPUT"
		fi
		logmsg "###+++"
		return $RES
}

# guesses os and sets $OSFLAVOUR to debian, ubuntu, redhat or '',
# also sets OS_VERSION, OS_MAJOR, OS_MINOR (and OS_PATCH if it exists),
# plus OS_ISCENTOS if flavour is redhat.
flavour () {
		if [ -f "/etc/redhat-release" ]; then
				OSFLAVOUR=redhat
				logmsg "detected OS flavour RedHat/CentOS"
				# centos7: ugly triplet and gunk, eg. "CentOS Linux release 7.2.1511 (Core)"
				OS_VERSION=`sed -re 's/(^|.* )([0-9]+\.[0-9]+(\.[0-9]+)?).*$/\2/' < /etc/redhat-release`;
				grep -qF CentOS /etc/redhat-release && OS_ISCENTOS=1

		elif grep -q ID=debian /etc/os-release ; then
				OSFLAVOUR=debian
				logmsg "detected OS flavour Debian"
				OS_VERSION=`cat /etc/debian_version`;
		elif grep -q ID=ubuntu /etc/os-release ; then
				OSFLAVOUR=ubuntu
				logmsg "detected OS flavour Ubuntu"
				OS_VERSION=`grep VERSION_ID /etc/os-release | sed -re 's/^VERSION_ID="([0-9]+\.[0-9]+(\.[0-9]+)?)"$/\1/'`;
		fi

		if [ -f "/etc/os-release" ]; then
			OSVERSION=$(grep "VERSION_ID=" /etc/os-release | cut -d\" -f2)
		fi

		OS_MAJOR=`echo "$OS_VERSION" | cut -f 1 -d .`;
		OS_MINOR=`echo "$OS_VERSION" | cut -f 2 -d .`;
		OS_PATCH=`echo "$OS_VERSION" | cut -f 3 -d .`;

}

# this function detects NMIS 8, not NMIS 9!
# sets NMISDIR, NMIS_VERSION, NMIS_MAJOR, NMIS_MINOR and NMIS_PATCH
# and returns 0 if installed/ok, 1 otherwise
get_nmis_version() {
		if [ -d "/usr/local/nmis8" ]; then
				NMISDIR=/usr/local/nmis8
		elif [ -d "/usr/local/nmis" ]; then
				NMISDIR=/usr/local/nmis
		else
				NMISDIR=''
				return 1
		fi


		local RAWVERSION
		# if nmis is in working shape that'll do...
		RAWVERSION=`$NMISDIR/bin/nmis.pl --version 2>/dev/null |grep -F -e version= -e " version  "`
		# newest version honors --version, output version=1.2.3x; older versions have "NMIS version 1.2.3x" banner
		[ -n "$RAWVERSION" ] && NMIS_VERSION=`echo "$RAWVERSION" | cut -f 2 -d "="`
		[ -n "$RAWVERSION" -a -z "$NMIS_VERSION" ] && NMIS_VERSION=`echo "$RAWVERSION" | cut -f 3 -d " "`
		# ...but if not, try a bit harder
		if [ -z "$NMIS_VERSION" ]; then
				NMIS_VERSION=`grep -E '^\s*our\s*\\$VERSION' $NMISDIR/lib/NMIS.pm 2>/dev/null | cut -f 2 -d '"';`
		fi
		# and if that doesn't work, give up
		[ -z "$NMIS_VERSION" ] && return 1

		NMIS_MAJOR=`echo $NMIS_VERSION | cut -f 1 -d .`
		# nmis doesn't consistently use N.M.Og, but also occasionally just N.Mg
		NMIS_MINOR=`echo $NMIS_VERSION | cut -f 2 -d . | tr -d a-zA-Z`
		NMIS_PATCH=`echo $NMIS_VERSION| cut -f 3 -d . | tr -d a-zA-Z`

		return 0
}

# this function detects NMIS 9, not NMIS 8!
# sets NMIS9DIR, NMIS9_VERSION, NMIS9_MAJOR/MINOR/PATCH
# returns 0 if installed/ok, 1 otherwise
get_nmis9_version()
{
		if [ -d "/usr/local/nmis9" ]; then
				NMIS9DIR=/usr/local/nmis9
		else
				NMIS9DIR=''
				return 1
		fi

		# if nmis9 is properly installed, nmis-cli will report its version
		NMIS9_VERSION=`$NMIS9DIR/bin/nmis-cli --version 2>/dev/null |grep -F version= | cut -f 2 -d =`
		# ...but if it does not run (yet), try a bit harder
		if [ -z "$NMIS9_VERSION" ]; then
				NMIS9_VERSION=`grep -E '^\s*our\s*\\$VERSION' $NMIS9DIR/lib/NMISNG.pm 2>/dev/null | cut -f 2 -d '"';`
		fi
		# and if that doesn't work, give up
		[ -z "$NMIS9_VERSION" ] && return 1

		NMIS9_MAJOR=`echo $NMIS9_VERSION | cut -f 1 -d .`
		NMIS9_MINOR=`echo $NMIS9_VERSION | cut -f 2 -d . `
		# the patch usually has textual suffixes, which we ignore!
		NMIS9_PATCH=`echo $NMIS9_VERSION| cut -f 3 -d . | tr -d a-zA-Z`

		return 0
}



# takes six args: major/minor/patch current, major/minor/patch min
# returns 0 if current at or above minimum, 1 otherwise
# note: should be called with quoted args, ie. version_meets_min "$X" "$Y"...
# so that the defaults detection can work.
version_meets_min()
{
		local IS_MAJ
		local IS_MIN
		local IS_PATCH
		local MIN_MAJ
		local MIN_MIN
		local MIN_PATCH

		IS_MAJ=${1:-0}
		IS_MIN=${2:-0}
		IS_PATCH=${3:-0}
		MIN_MAJ=${4:-0}
		MIN_MIN=${5:-0}
		MIN_PATCH=${6:-0}

		[ "$IS_MAJ" -lt "$MIN_MAJ" ] && return 1
		[ "$IS_MAJ" = "$MIN_MAJ" -a "$IS_MIN" -lt "$MIN_MIN" ] && return 1
		[ "$IS_MAJ" = "$MIN_MAJ" -a "$IS_MIN" = "$MIN_MIN" -a "$IS_PATCH" -lt "$MIN_PATCH" ] && return 1

		return  0
}
