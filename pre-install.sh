#!/bin/sh
# check that the actual installer can work, ie. all required perl modules present.
# if not, complain and offer to help.

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


# lets be environment aware
if [ -f /etc/environment ]; then
        # shellcheck disable=SC1091
        . /etc/environment;
fi;
if [ -n "${PAR_GLOBAL_TMPDIR:-}" ]; then
        export PAR_GLOBAL_TMPDIR;
fi;


# COPIED FROM bin/installer_hooks/common_functions.sh
# guesses os and sets $OSFLAVOUR to debian, ubuntu, redhat or '',
# also sets OS_VERSION, OS_MAJOR, OS_MINOR (and OS_PATCH if it exists),
# plus OS_ISCENTOS if flavour is redhat.
flavour () {
		if [ -f "/etc/redhat-release" ]; then
				OSFLAVOUR=redhat
				echo "detected OS flavour RedHat/CentOS"
				# centos7: ugly triplet and gunk, eg. "CentOS Linux release 7.2.1511 (Core)"
				OS_VERSION=`sed -re 's/(^|.* )([0-9]+\.[0-9]+(\.[0-9]+)?).*$/\2/' < /etc/redhat-release`||:;
				grep -qF CentOS /etc/redhat-release && OS_ISCENTOS=1
				OS_ISCENTOS="${OS_ISCENTOS:-0}";

		elif grep -q ID=debian /etc/os-release ; then
				OSFLAVOUR=debian
				echo "detected OS flavour Debian"
				OS_VERSION=`cat /etc/debian_version`||:;
		elif grep -q ID=ubuntu /etc/os-release ; then
				OSFLAVOUR=ubuntu
				echo "detected OS flavour Ubuntu"
				OS_VERSION=`grep VERSION_ID /etc/os-release | sed -re 's/^VERSION_ID="([0-9]+\.[0-9]+(\.[0-9]+)?)"$/\1/'`||:;
		elif grep -q ID=linuxmint /etc/os-release ; then
				OSFLAVOUR=mint`
				echo "detected OS flavour Mint"
				OS_VERSION=`grep VERSION_ID /etc/os-release | sed -re 's/^VERSION_ID="([0-9]+\.[0-9]+(\.[0-9]+)?)"$/\1/'`||:;
		fi

		# this code had no objective: OSVERSION is not used anywhere
		# it is a good pointer to an alternative method to determine OSFLAVOUR, OS_VERSION, etc. from /etc/os-release though ...
		#
		if [ -f "/etc/os-release" ]; then
			OSVERSION=$(grep "VERSION_ID=" /etc/os-release | cut -s -d\" -f2)||:;
		fi

		OS_VERSION="${OS_VERSION:-}";
		OS_MAJOR=`echo "$OS_VERSION" | cut -s -f 1 -d .`||:;
		OS_MAJOR="${OS_MAJOR:-0}";
		OS_MINOR=`echo "$OS_VERSION" | cut -s -f 2 -d .`||:;
		OS_MINOR="${OS_MINOR:-0}";
		OS_PATCH=`echo "$OS_VERSION" | cut -s -f 3 -d .`||:;
		OS_PATCH="${OS_PATCH:-0}";

		if [ "${CHECK_SET_STRICT_VERBOSE:-0}" -eq 1 ]; then
				printBanner "flavour: OS_VERSION=${OS_VERSION}; OS_MAJOR=${OS_MAJOR}; OS_MINOR=${OS_MINOR}; OS_PATCH=${OS_PATCH}; /etc/os-release OSVERSION='${OSVERSION:-}'";
		fi;

		return 0;
}
flavour;

# note: this assumes that the current dir is the unpacked directory! (true in the .run environment)
if type perl >/dev/null 2>&1; then
		if perl -c ./installer 2>/dev/null; then
				exec ./installer "$@";
		fi
fi

cat <<EOF

Error: no Perl or Perl core modules installed!

NMIS (and this installer) require that Perl and the
core Perl modules are present on your system.

On CentOS/RedHat systems you need to install the packages 
"perl-core" and "cpan" with:
sudo yum install perl-core cpan

on Debian/Ubuntu the package "perl" is required:
sudo apt-get install perl

Do you want the installer to install Perl for you? 
EOF

# check for unattended -y mode
for i in "$@"; do
		if [ "$i" = "-y" ]; then
				UNATTENDED=1
				break;
		fi
done

# let's not even ask if -y mode is on
[ -n "${UNATTENDED:-}" ] && DOIT=1 && EXTRA="-y" && DEBIAN_FRONTEND="noninteractive" && DEBCONF_NONINTERACTIVE_SEEN=true && PERL_MM_USE_DEFAULT=1 && echo "Unattended Mode - default answer Y"
export DEBIAN_FRONTEND
export DEBCONF_NONINTERACTIVE_SEEN;
# IMPORTANT: read sends prompt message to stderr, so we must redirect stderr to stdout when using read
# let's accept enter as yes
if [ -z "${UNATTENDED:-}" ] && { read -p "Enter y to continue, anything else to abort: "  X 2>&1; } && [ -z "$X" -o "$X" = 'y' -o "$X" = 'Y' ]; then
		DOIT=1;
		PERL_MM_USE_DEFAULT=0;
fi
export PERL_MM_USE_DEFAULT;

if [ "${DOIT:-0}" = 1 ]; then
		if type yum >/dev/null 2>&1; then
				if [ "$OS_ISCENTOS" != 1 ] && [ "$OSFLAVOUR" = "redhat" ]; then
						echo "Enabling RHEL ${OS_MAJOR} Repositories"
						if [ -n "$(subscription-manager repos | grep -A4 "rhel-${OS_MAJOR}-server-optional-rpms" | grep Enabled | grep 0)" ]; then
							subscription-manager repos --enable="rhel-${OS_MAJOR}-server-optional-rpms"
						fi;
						if [ "$OS_MAJOR" = 7 ]; then
							if [ -n "$(subscription-manager repos | grep -A4 "rhel-${OS_MAJOR}-server-supplementary-rpms" | grep Enabled | grep 0)" ]; then
								subscription-manager repos --enable="rhel-${OS_MAJOR}-server-supplementary-rpms"
							fi;
						fi
						if [ "$OS_MAJOR" = 8 ]; then
							if [ -n "$(subscription-manager repos | grep -A4 "rhel-${OS_MAJOR}-for-x86_64-supplementary-rpms" | grep Enabled | grep 0)" ]; then
								subscription-manager repos --enable="rhel-${OS_MAJOR}-for-x86_64-supplementary-rpms"
							fi;
							if [ -n "$(subscription-manager repos | grep -A4 "codeready-builder-for-rhel-${OS_MAJOR}-x86_64-rpms" | grep Enabled | grep 0)" ]; then
								subscription-manager repos --enable="codeready-builder-for-rhel-${OS_MAJOR}-x86_64-rpms"
							fi;
						fi;
				fi
				echo "Starting yum install"
				yum ${EXTRA:-} install perl-core
				
		elif type apt-get >/dev/null 2>&1; then
				echo "Starting apt-get install"
				apt-get ${EXTRA:-} install perl
		fi

		# time to try once more
		if type perl >/dev/null 2>&1; then
				if perl -c ./installer 2>/dev/null; then
						exec ./installer "$@";
				else
						echo "Perl is present, but lacking some of the required modules! " >&2
						perl -c ./installer
						exit 1
				fi
		fi
		exit 0
fi

echo "No Perl available, aborting installation." >&2
exit 1

