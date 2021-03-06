#!/bin/sh
# a set of common functions for convenience
# use POSIX functionality only, no bashisms!

# 'OMK_STRICT_SH=3'	provides verbose debugging to STDOUT
#			and each command is printed to STDERR prior to execution (sh option 'set -eux' is in place)
# 'OMK_STRICT_SH>=4'	provides as per 'OMK_STRICT_SH=3'
#			and echos current 'set' option to screen before and after set option is set in check_set_strict_sh function
check_set_strict_sh()
{
	if [ "${OPT_OMK_STRICT_SH:-0}" -gt 0 ]; then
		CHECK_SET_STRICT=1;
		ABORT_OMK_STRICT_SH="Aborting ... (only aborts when OMK_STRICT_SH > 0)";
		# ensure these 3 variables are set, but only when not set as 'strict bash' would fail:
		if [ -z "${UNATTENDED:-}" ]; then
			UNATTENDED="";
		fi;
		if [ -z "${PRESEED:-}" ]; then
			PRESEED="";
		fi;
		if [ -z "${SIMULATE:-}" ]; then
			SIMULATE="";
		fi;
		if [ -z "${LOGFILE:-}" ]; then
			LOGFILE="";
		fi;
		if [ "${OPT_OMK_STRICT_SH}" -gt 1 ]; then
			CHECK_SET_STRICT_VERBOSE=1;
		else
			CHECK_SET_STRICT_VERBOSE=0;
		fi;
		if [ "${OPT_OMK_STRICT_SH}" -gt 3 ]; then
			echo "check_set_strict_bash:IN:\$-=$-";
		fi;
		if [ "${OPT_OMK_STRICT_SH}" -ge 3 ]; then
			# /bin/sh does not support 'set -o pipefail'
			set -x;
			###set -eux;
		else
			# /bin/sh does not support 'set -o pipefail'
			:
			###set -eu;
		fi;
		if [ "${OPT_OMK_STRICT_SH}" -gt 3 ]; then
			echo "check_set_strict_bash:OUT:\$-=$-";
		fi;
	else
		CHECK_SET_STRICT=0;
		CHECK_SET_STRICT_VERBOSE=0;
		ABORT_OMK_STRICT_SH="":
	fi;
	return 0;
}
check_set_strict_sh;

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
# in non-interactive mode this function doesn't do anything
input_ok() {
		echo "$@"
		if [ -z "$UNATTENDED" ]; then
				local X
				read X
		fi
}

# print prompt, print static blurb, read response,
# or auto-answer yes in non-interactive mode, or use preseeded answer
input_yn() {
		local MSG TAG
		MSG="$1"
		TAG="$2"
		if [ -n "$PRESEED" -a -n "$TAG" ] && grep -q -E "^$TAG" $PRESEED 2>/dev/null; then
				echo "$MSG"
				local ANSWER
				ANSWER=`grep -E "^$TAG" $PRESEED|cut -f 2 -d '"'`
				logmsg "(Preseeded answer \"$ANSWER\" for '$MSG')"
				echo "(preseeded answer \"$ANSWER\")"
				if [ "$ANSWER" = "y" -o "$ANSWER" = "Y" ]; then
						return 0						# ok
				else
						return 1						# nok
				fi
		elif [ -n "$UNATTENDED" ]; then
				echo "$MSG"
				echo "(auto-default YES)"
				echo
				return 0
		else
				while true; do
						echo "$MSG"
						echo -n "Type 'y' or <Enter> to accept, or 'n' to decline: "
						local X
						read X
						logmsg "User input for '$MSG': '$X'"
						X=`echo "$X" | tr -d '[:space:]'| tr '[A-Z]' '[a-z]'`

						if [ "$X" != 'y' -a "$X" != '' -a "$X" != 'n' ]; then
								echo "Invalid input \"$X\""
								echo
								continue;
						fi

						if [ -z "$X" -o "$X" = "y" ]; then
								return 0								# ok
						else
								return 1								# nok
						fi
				done
		fi
}

# print prompt, print static blurb, read response string and
# export it as RESPONSE
# in unattended mode the response is ''
input_text() {
		local MSG TAG
		MSG="$1"
		TAG="$2"
		RESPONSE=''
		echo -n "$MSG"
		if [ -n "$PRESEED" -a -n "$TAG" ] && grep -q -E "^$TAG" $PRESEED 2>/dev/null; then
				RESPONSE=`grep -E "^$TAG" $PRESEED|cut -f 2 -d '"'`
				logmsg "(Preseeded answer \"$RESPONSE\" for '$MSG')"
				echo "(preseeded answer \"$RESPONSE\")"
		elif [ -n "$UNATTENDED" ]; then
				logmsg "Automatic blank input for '$MSG' in unattended mode"
				echo "(auto-default empty response)"
		else
				read RESPONSE
				logmsg "User input for '$MSG': '$RESPONSE'"
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
			OSVERSION=$(grep "VERSION_ID=" /etc/os-release | cut -s -d\" -f2)
		fi

		OS_MAJOR=`echo "$OS_VERSION" | cut -s -f 1 -d .`;
		OS_MINOR=`echo "$OS_VERSION" | cut -s -f 2 -d .`;
		OS_PATCH=`echo "$OS_VERSION" | cut -s -f 3 -d .`;

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
		[ -n "$RAWVERSION" ] && NMIS_VERSION=`echo "$RAWVERSION" | cut -s -f 2 -d "="`
		[ -n "$RAWVERSION" -a -z "$NMIS_VERSION" ] && NMIS_VERSION=`echo "$RAWVERSION" | cut -s -f 3 -d " "`
		# ...but if not, try a bit harder
		if [ -z "$NMIS_VERSION" ]; then
				NMIS_VERSION=`grep -E '^\s*our\s*\\$VERSION' $NMISDIR/lib/NMIS.pm 2>/dev/null | cut -s -f 2 -d '"';`
		fi
		# and if that doesn't work, give up
		[ -z "$NMIS_VERSION" ] && return 1

		NMIS_MAJOR=`echo $NMIS_VERSION | cut -s -f 1 -d .`
		# nmis doesn't consistently use N.M.Og, but also occasionally just N.Mg
		NMIS_MINOR=`echo $NMIS_VERSION | cut -s -f 2 -d . | tr -d a-zA-Z`
		NMIS_PATCH=`echo $NMIS_VERSION| cut -s -f 3 -d . | tr -d a-zA-Z`

		return 0
}

# this function detects NMIS 9, not NMIS 8!
# sets NMIS9DIR, NMIS9_VERSION, NMIS9_MAJOR/MINOR/PATCH
# returns 0 if installed/ok, 1 otherwise
get_nmis9_version()
{
		if [ -f "${TARGETDIR}/conf/Config.nmis" ] || [ -L "${TARGETDIR}/conf/Config.nmis" ]; then
				NMIS9DIR="${TARGETDIR}"
		else
				NMIS9DIR=''
				return 1
		fi

		# if nmis9 is properly installed, nmis-cli will report its version
		NMIS9_VERSION=`$NMIS9DIR/bin/nmis-cli --version 2>/dev/null |grep -F version= | cut -s -f 2 -d =`
		# ...but if it does not run (yet), try a bit harder
		if [ -z "$NMIS9_VERSION" ]; then
				NMIS9_VERSION=`grep -E '^\s*our\s*\\$VERSION' $NMIS9DIR/lib/NMISNG.pm 2>/dev/null | cut -s -f 2 -d '"';`
		fi
		# and if that doesn't work, give up
		[ -z "$NMIS9_VERSION" ] && return 1

		NMIS9_MAJOR=`echo $NMIS9_VERSION | cut -s -f 1 -d .`
		NMIS9_MINOR=`echo $NMIS9_VERSION | cut -s -f 2 -d . `
		# the patch usually has textual suffixes, which we ignore!
		NMIS9_PATCH=`echo $NMIS9_VERSION| cut -s -f 3 -d . | tr -d a-zA-Z`

		return 0
}



# takes six args: major/minor/patch current, major/minor/patch min
# returns 0 if current at or above minimum, 1 otherwise
# note: should be called with quoted args, ie. version_meets_min "$X" "$Y"...
# so that the defaults detection can work.
version_meets_min()
{
		local IS_MAJ IS_MIN IS_PATCH MIN_MAJ MIN_MIN MIN_PATCH

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

# takes two version string arguments, N.M.Oxyz and A.B.Cefg,
# textual xyz/efg suffixes are optional and IGNORED
# at least the major component MUST be there
# returns: 0 if versions are the same, 1 if first > second, 2 if second > first
version_compare()
{
		local i
		for i in 1 2 3; do
				local ACOMP BCOMP
				ACOMP=`echo "$1" | cut -s -f $i -d . | tr -d a-zA-Z`
				ACOMP=${ACOMP:-0}
				BCOMP=`echo "$2" | cut -s -f $i -d . | tr -d a-zA-Z`
				BCOMP=${BCOMP:-0}

				[ "$ACOMP" -gt "$BCOMP" ] && return 1
				[ "$ACOMP" -lt "$BCOMP" ] && return 2
		done
		return 0
}

# checks this server has an ntp type service and warns|logs if not detected
version_check_ntp_type_service (){
	NTP_DETECTED=0;
	if type timedatectl >/dev/null 2>&1; then
		if timedatectl status|grep -q -e "[Ss]ynchronized:\s\+yes" -e "Network\s\+time\s\+on:\s\+yes" -e "NTP\s\+service:\s\+active" -e "NTP\s\+enabled:\s\+yes" -e "systemd-timesyncd.service\s\+active:\s\+yes"; then
			NTP_DETECTED=1;
		fi;
	fi;
	if [ "${NTP_DETECTED}" -eq 0 ]; then
		# ensure systemd-timesyncd|chronyd|ntp|ntpd is enabled and running if installed. Chronyd is preferred
		#   centos 6 default ntpd
		#   centos 7 default chronyd
		#   centos 8 default chronyd
		#   debian 8 default systemd-timesyncd, but disabled
		#   debian 9 default systemd-timesyncd
		#   debian 10 default systemd-timesyncd
		#   ubuntu 16.04 default systemd-timesyncd
		#   ubuntu 18.04 default systemd-timesyncd
		#   ubuntu 20.04 default systemd-timesyncd
		NTP_SERVICES="systemd-timesyncd chronyd ntpd ntp openntpd";
		NTP_SERVICE_ACTIVE=;
		# if systemd
		if type systemctl >/dev/null 2>&1; then
			# first check if any ntp service is running
			for NTP_SERVICE in ${NTP_SERVICES}; do
				if systemctl is-active --quiet "${NTP_SERVICE}"; then
					NTP_SERVICE_ACTIVE="${NTP_SERVICE}";
					break;
				fi;
			done;
		elif type service >/dev/null 2>&1; then
			for NTP_SERVICE in ${NTP_SERVICES}; do
				if service "${NTP_SERVICE}" status >/dev/null 2>&1; then
					NTP_SERVICE_ACTIVE="${NTP_SERVICE}";
				fi;
			done;
		fi;
		if [ -z "${NTP_SERVICE_ACTIVE:-}" ]; then
			echolog "An enabled and running service to synchronize with the Network Time Protocol was not detected."
			cat <<EOF

$PRODUCT requires an enabled and running service to synchronize with the Network Time Protocol,
but no such service was detected.

You will have to resolve this manually before $PRODUCT will operate properly.

EOF
			input_ok "Hit <Enter> when ready to continue: ";
		fi;
	fi;
	return 0;
}
