#!/bin/sh
# a set of common functions for convenience
# use POSIX functionality only, no bashisms!
# https://mywiki.wooledge.org/Bashism

# load enmvironment variables in case PAR_GLOBAL_TMPDIR has been implemented, but not yet properly exported:
[ -f /etc/environment ] && . /etc/environment;

# for release testing and debugging:
#	commandline option 'OMK_STRICT_SH=1'	will cause OMK installer to run bash|sh scripts using 'strict sh' (sh option 'set -eu' is in place)
#											and will cause installer to abort with 'exit 1' upon catastrophic errors
#											and will print message to STDOUT just before aborting ALWAYS ending with either
#												text "Aborting ... (only aborts when OMK_STRICT_SH > 0)", OR
#												text containing "418 I'm a teapot" upon execPrint418 command exiting with exit code > 0
#											Purpose of 'OMK_STRICT_SH=1' is to provide the same visual STDOUT messages as when not running in 'strict sh' mode
#					   'OMK_STRICT_SH=2'	provides as per 'OMK_STRICT_SH=1, and provides verbose debugging to STDOUT (sh option 'set -eu' is in place)
#					   'OMK_STRICT_SH=3'	provides as per 'OMK_STRICT_SH=2, and provides verbose debugging to STDOUT
#											and each command is printed to STDERR prior to execution (sh option 'set -eux' is in place)
#					   'OMK_STRICT_SH>=4'	provides as per 'OMK_STRICT_SH=3'
#											and echos current 'set' option to screen before and after set option is set in check_set_strict_sh function
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

# this setting is not compatible with the DAEMONS variable in its current format:
#	code then fails to loop through DAEMONS
#	needs DAEMONS to be one per line
#	however this issue may then occur elsewhere and is therefore just not robust enough with legacy sh code:
#IFS=$(printf '\n\t');
#if [ "${OPT_OMK_STRICT_SH}" -gt 2 ]; then
#	echo 'general setting: IFS="\\n\\t\"';
#fi;

# Decrypt a password.
decrypt_password()
{
    PWD="$1"
    DECR_PWD=`$NMIS9DIR/bin/nmis-cli act=decrypt-password password="$PWD";`
    echo "$DECR_PWD"
}

# Encrypt a password.
encrypt_password()
{
    PWD="$1"
    ENCR_PWD=`$NMIS9DIR/bin/nmis-cli act=encrypt-password password="$PWD";`
    echo "$ENCR_PWD"
}

# generate a line using repeating character
# $1 is the number of times to repeat
# $2 is the character to repeat (default to =)
echoLine() {
	char="="
	[ "$2" != "" ] && [ "$2" != "-" ] && char=$2
	printf "$char%.0s" $(seq $1)
	echo
}


# echo and log-append to logfile
echolog() {
		echo "$@"
		[ -f "$LOGFILE" ] && echo "$@" >> $LOGFILE
		return 0;
}

# append text to logfile
logmsg() {
		if [ -f "$LOGFILE" ]; then
				echo "$@" >> $LOGFILE
		fi
		return 0;
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
				# when debugging log what is seen on the screen to make it easier
				if [ "${CHECK_SET_STRICT_VERBOSE:-0}" -ne 1 ]; then
						echo "$@" >> $LOGFILE
				else
						echo "++++++++++++++++++++++++++++++++++++++++++++++++++++++" >> $LOGFILE
						echo "$@" >> $LOGFILE
						echo "++++++++++++++++++++++++++++++++++++++++++++++++++++++" >> $LOGFILE
				fi
				echo '###+++' >> $LOGFILE
		fi
		return 0;
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
		TAG="${2:-}"

		if [ -z "${TAG}" ]; then
			if [ "${CHECK_SET_STRICT}" -eq 1 ]; then
				# ensure we wrap this log entry within the error header and footer with 1 (any value > 0)
				echologVerboseError "input_yn: MSG=${MSG}: TAG='': No preseed question should be fixed. ${ABORT_OMK_STRICT_SH}" 1;
				exit 1;
			else
				# ensure we wrap this log entry within the error header and footer with 1 (any value > 0)
				echologVerboseError "input_yn: MSG=${MSG}: TAG='': No preseed question. Continuing..." 1;
			fi;
		fi;

		if [ -n "$PRESEED" -a -n "$TAG" ] && grep -q -E "^$TAG" $PRESEED 2>/dev/null; then
				echo "$MSG"
				local ANSWER
				ANSWER=`grep -E "^$TAG" $PRESEED|cut -f 2 -d '"'`||:;
				ANSWER="${ANSWER:-}";

				if [ -z "${ANSWER}" ]; then
					if [ "${CHECK_SET_STRICT}" -eq 1 ]; then
						# ensure we wrap this log entry within the error header and footer with 1 (any value > 0)
						echologVerboseError "input_yn: MSG=${MSG}: TAG=${TAG}: ANSWER='': Preseed question not in preseed file. Should be fixed. ${ABORT_OMK_STRICT_SH}" 1;
						exit 1;
					else
						# ensure we wrap this log entry within the error header and footer with 1 (any value > 0)
						echologVerboseError "input_yn: MSG=${MSG}: TAG=${TAG}: ANSWER='': Preseed question not in preseed file. Should be fixed. Continuing..." 1;
					fi;
				fi;

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
						X=`echo "$X" | tr -d '[:space:]'| tr '[A-Z]' '[a-z]'`||:;

						# consider setting a default if strict sh fails here
						###if [ "${CHECK_SET_STRICT}" -eq 1 ]; then
						###	X="${X:-}";
						###fi;
 
						if [ "$X" != 'y' -a "$X" != 'yes' -a "$X" != '' -a "$X" != 'n' -a "$X" != 'no' ]; then
								echo "Invalid input \"$X\""
								echo
								continue;
						fi

						if [ -z "$X" -o "$X" = "y" -o "$X" = "yes" ]; then
								return 0								# ok
						else
								return 1								# nok
						fi
				done
		fi
}

# print prompt, print static blurb, read response,
# or auto-answer no in non-interactive mode, or use preseeded answer
input_ny() {
		local MSG TAG
		MSG="$1"
		TAG="${2:-}"

		if [ -z "${TAG}" ]; then
			if [ "${CHECK_SET_STRICT}" -eq 1 ]; then
				# ensure we wrap this log entry within the error header and footer with 1 (any value > 0)
				echologVerboseError "input_ny: MSG=${MSG}: TAG='': No preseed question should be fixed. ${ABORT_OMK_STRICT_SH}" 1;
				exit 1;
			else
				# ensure we wrap this log entry within the error header and footer with 1 (any value > 0)
				echologVerboseError "input_ny: MSG=${MSG}: TAG='': No preseed question. Continuing..." 1;
			fi;
		fi;

		if [ -n "$PRESEED" -a -n "$TAG" ] && grep -q -E "^$TAG" $PRESEED 2>/dev/null; then
				echo "$MSG"
				local ANSWER
				ANSWER=`grep -E "^$TAG" $PRESEED|cut -f 2 -d '"'`||:;
				ANSWER="${ANSWER:-}";

				if [ -z "${ANSWER}" ]; then
					if [ "${CHECK_SET_STRICT}" -eq 1 ]; then
						# ensure we wrap this log entry within the error header and footer with 1 (any value > 0)
						echologVerboseError "input_ny: MSG=${MSG}: TAG=${TAG}: ANSWER='': Preseed question not in preseed file. Should be fixed. ${ABORT_OMK_STRICT_SH}" 1;
						exit 1;
					else
						# ensure we wrap this log entry within the error header and footer with 1 (any value > 0)
						echologVerboseError "input_ny: MSG=${MSG}: TAG=${TAG}: ANSWER='': Preseed question not in preseed file. Should be fixed. Continuing..." 1;
					fi;
				fi;

				logmsg "(Preseeded answer \"$ANSWER\" for '$MSG')"
				echo "(preseeded answer \"$ANSWER\")"
				if [ "$ANSWER" = "y" -o "$ANSWER" = "Y" ]; then
						return 0						# ok
				else
						return 1						# nok
				fi
		elif [ -n "$UNATTENDED" ]; then
				echo "$MSG"
				echo "(auto-default NO)"
				echo
				return 1
		else
				while true; do
						echo "$MSG"
						echo -n "Type 'y' to accept, or 'n' or <Enter> to decline: "
						local X
						read X
						logmsg "User input for '$MSG': '$X'"
						X=`echo "$X" | tr -d '[:space:]'| tr '[A-Z]' '[a-z]'`||:;

						# consider setting a default if strict sh fails here
						###if [ "${CHECK_SET_STRICT}" -eq 1 ]; then
						###	X="${X:-}";
						###fi;

						if [ "$X" != 'y' -a "$X" != '' -a "$X" != 'n' ]; then
								echo "Invalid input \"$X\""
								echo
								continue;
						fi

						if [ -z "$X" -o "$X" = "n" ]; then
								return 1								# nok
						else
								return 0								# ok
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
		TAG="${2:-}"

		if [ -z "${TAG}" ]; then
			if [ "${CHECK_SET_STRICT}" -eq 1 ]; then
				# ensure we wrap this log entry within the error header and footer with 1 (any value > 0)
				echologVerboseError "input_text: MSG=${MSG}: TAG='': No preseed question. Should be fixed. ${ABORT_OMK_STRICT_SH}" 1;
				exit 1;
			else
				# ensure we wrap this log entry within the error header and footer with 1 (any value > 0)
				echologVerboseError "input_text: MSG=${MSG}: TAG='': No preseed question. Continuing..." 1;
			fi;
		fi;

		RESPONSE=''
		echo -n "$MSG"
		if [ -n "$PRESEED" -a -n "$TAG" ] && grep -q -E "^$TAG" $PRESEED 2>/dev/null; then
				RESPONSE=`grep -E "^$TAG" $PRESEED|cut -f 2 -d '"'`||:;
				RESPONSE="${RESPONSE:-}";
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

# execPrint is preferred
#	NOT executing anything so can't honor simulate mode (COMMAND was executed prior to call to this function)
# this function allows wrap error in standard OMK installer header and footer 'if [ $RES != 0 ]'
#	where execPrint cannot be used, for example when OUTPUT is returned by command: OUTPUT=$(COMMAND);
# requires parameters: COMMAND (as a string $*, not an array $@), then EXIT CODE ($?) then optional COMMAND OUTPUT
echologVerboseError()
{
	local THIS_CMD_STRING;
	THIS_CMD_STRING="${1}";

	local THIS_CMD_RES;
	THIS_CMD_RES="${2}";

	local THIS_CMD_OUTPUT;
	THIS_CMD_OUTPUT="${3:-}";

	if [ "${THIS_CMD_RES}" != 0 ]; then
			echolog "-------COMMAND RETURNED EXIT CODE ${THIS_CMD_RES}--------"
			echolog "${THIS_CMD_STRING}" "${THIS_CMD_OUTPUT}"
			echolog "----------------------------------------"
	else
			if [ -n "${THIS_CMD_OUTPUT}" ]; then
				THIS_CMD_OUTPUT="${THIS_CMD_STRING}";
			fi;
			logmsg "OUTPUT: ${THIS_CMD_OUTPUT}";
	fi;
	return 0;
}

# run cmd, capture output and stderr and append to logfile
# if in simulate mode, only print what WOULD be done but
#	DON'T EXECUTE anything
execPrint()
{
		if [ -n "$SIMULATE" ]; then
				echo
				echo "SIMULATION MODE, NOT executing command '$*'"
				return 0
		fi

		logmsg "###+++"
		logmsg "EXEC: $*"

		OUTPUT=""
		RES=0
		# robust: retry on failure
		for N in 1 2 3 4 5 6; do
			# shellcheck disable=SC2068
			OUTPUT=$(eval $@ 2>&1)||RES=$?
			# pre-initialised RES=0 before loop so we don't need a default value here
			if [ "${RES}" = 0 ]; then
				if [ "${CHECK_SET_STRICT_VERBOSE:-0}" -eq 1 ]; then
					echolog "execPrint '$*' succeeded"
				fi
				break
			elif [ "${CHECK_SET_STRICT_VERBOSE:-0}" -eq 1 ]; then
				printBanner "execPrint '$*' failed. Retrying..."
			else
				:
				#echo
				#echolog "execPrint '$*' failed. Retrying..."
				#echo
			fi
			sleep 10
		done

		# initialising before loop with 'OUTPUT=""' means OUTPUT is always set at this point
		# echologVerboseError expects parameters: COMMAND (as a string '$*' or '...', not an array '$@'), EXITCODE then COMMANDOUTPUT
		# pre-initialised RES=0 before loop so we don't need a default value here
		echologVerboseError "$*" "${RES}" "${OUTPUT}";
		logmsg "###+++"
		return $RES
}

# run cmd, capture output and stderr and append to logfile
#	and not retrying on failure
# if in simulate mode, only print what WOULD be done but
#	DON'T EXECUTE anything
execPrintNoRetry()
{
		if [ -n "$SIMULATE" ]; then
				echo
				echo "SIMULATION MODE, NOT executing command '$*'"
				return 0
		fi

		logmsg "###+++"
		logmsg "EXEC: $*"

		OUTPUT=""
		RES=0

		# shellcheck disable=SC2068
		OUTPUT=$(eval $@ 2>&1)||RES=$?
		# pre-initialised RES=0 before loop so we don't need a default value here
		if [ "${RES}" = 0 ]; then
			if [ "${CHECK_SET_STRICT_VERBOSE:-0}" -eq 1 ]; then
				echolog "execPrint '$*' succeeded"
			fi
		elif [ "${CHECK_SET_STRICT_VERBOSE:-0}" -eq 1 ]; then
			printBanner "execPrint '$*' failed. Retrying..."
		else
			:
			#echo
			#echolog "execPrint '$*' failed. Retrying..."
			#echo
		fi

		# initialising before loop with 'OUTPUT=""' means OUTPUT is always set at this point
		# echologVerboseError expects parameters: COMMAND (as a string '$*' or '...', not an array '$@'), EXITCODE then COMMANDOUTPUT
		# pre-initialised RES=0 before loop so we don't need a default value here
		echologVerboseError "$*" "${RES}" "${OUTPUT}";
		logmsg "###+++"
		return $RES
}

# run cmd, DON'T "capture output and stderr and append to logfile"
# if in simulate mode, print what WOULD be done BUT DON'T append to logfile and
#	DON'T EXECUTE anything
# TO SUMMARISE: THIS FUNCTION WILL ECHO COMMANDS AND OUTPUT TO SCREEN BUT NOT TO LOG OR STDERR.
#				SEE SETTING OF xtrace IN THIS SCRIPT TO PREVENT secrets LEAKING ON STDERR TOO.
#				FOR AN EXAMPLE OF USE OF THIS FUNCTION AND SETTING OF xtrace TO PROTECT SECRETS FROM LEAKING TO STDERR:
#					SEE SCRIPT 'bin/installer_hooks/50-postcopy-setup-redis'
execPrintSecure()
{
		# TO PROTECT OUR secret WE NEED TO TURN OFF xtrace IN THIS SCRIPT IF ON - REINSTATE xtrace ON EXIT WHERE IT WAS SET ON ENTRY TO THIS SCRIPT:
		local SETUP_EXECPRINTSECURE_XTRACE_ON;
		if set -o|grep xtrace|grep -q on; then
			SETUP_EXECPRINTSECURE_XTRACE_ON=1;
		else
			SETUP_EXECPRINTSECURE_XTRACE_ON=0;
		fi;
		set +x;

		if [ -n "$SIMULATE" ]; then
				echo
				echo "SIMULATION MODE, NOT executing command '$*'"

				# REINSTATE xtrace ON EXIT WHERE IT WAS SET ON ENTRY TO THIS SCRIPT
				if [ "${SETUP_EXECPRINTSECURE_XTRACE_ON}" -eq 1 ]; then
					set -x;
				fi;

				return 0
		fi

		echo "###+++"
		echo "EXEC: $*"

		OUTPUT=""
		RES=0
		# robust: retry on failure
		for N in 1 2 3 4 5 6; do
			# shellcheck disable=SC2068
			OUTPUT=$(eval $@ 2>&1)||RES=$?
			# pre-initialised RES=0 before loop so we don't need a default value here
			if [ "${RES}" = 0 ]; then
				if [ "${CHECK_SET_STRICT_VERBOSE:-0}" -eq 1 ]; then
					echo "execPrintSecure '$*' succeeded"
					echo
					echolog "execPrintSecure '<command_present_but_not_shown>' succeeded"
				fi
				break
			elif [ "${CHECK_SET_STRICT_VERBOSE:-0}" -eq 1 ]; then
				echo "execPrintSecure '$*' failed. Retrying..."
				echo
				printBanner "execPrintSecure '<command_present_but_not_shown>' failed. Retrying..."
			else
				:
				#echo
				#echo "execPrintSecure '$*' failed. Retrying..."
				#echolog "execPrintSecure '<command_present_but_not_shown>' failed. Retrying..."
				#echo
			fi
			sleep 10
		done

		# initialising before loop with 'OUTPUT=""' means OUTPUT is always set at this point
		local THIS_CMD_STRING;
		THIS_CMD_STRING="$*";

		local THIS_CMD_RES;
		THIS_CMD_RES="${RES}";

		local THIS_CMD_OUTPUT;
		THIS_CMD_OUTPUT="${OUTPUT:-}";
		if [ "${THIS_CMD_RES}" != 0 ]; then
				echo "-------COMMAND RETURNED EXIT CODE ${THIS_CMD_RES}--------"
				echo "${THIS_CMD_STRING}" "${THIS_CMD_OUTPUT}"
				echo "----------------------------------------"
		else
				if [ -n "${THIS_CMD_OUTPUT}" ]; then
					THIS_CMD_OUTPUT="${THIS_CMD_STRING}";
				fi;
				echo "OUTPUT: ${THIS_CMD_OUTPUT}";
		fi;
		echo
		# echologVerboseError expects parameters: COMMAND (as a string '$*' or '...', not an array '$@'), EXITCODE then COMMANDOUTPUT
		# pre-initialised RES=0 before loop so we don't need a default value here
		echologVerboseError "<command_present_but_not_shown>" "${RES}" "<command_output_present_but_not_shown>";
		echo "###+++"

		# REINSTATE xtrace ON EXIT WHERE IT WAS SET ON ENTRY TO THIS SCRIPT
		if [ "${SETUP_EXECPRINTSECURE_XTRACE_ON}" -eq 1 ]; then
			set -x;
		fi;

		return $RES
}

# run cmd, capture output and stderr and append to logfile
#	but not using standard error header and footer in echologVerboseError
#		when in test mode 'CHECK_SET_STRICT=1'
#			designed to filter out unwanted "418 I'm a teapot" errors
# if in simulate mode, only print what WOULD be done but
#	DON'T EXECUTE anything
execPrint418()
{
		if [ -n "$SIMULATE" ]; then
				echo
				echo "SIMULATION MODE, NOT executing command '$*'"
				return 0
		fi

		if [ "${CHECK_SET_STRICT}" -eq 1 ]; then
			logmsg "###+++"
			logmsg "EXEC: $*"
		fi;

		OUTPUT=""
		RES=0
		# robust: retry on failure
		for N in 1 2 3 4 5 6; do
			# shellcheck disable=SC2068
			OUTPUT=$(eval $@ 2>&1)||RES=$?
			# pre-initialised RES=0 before loop so we don't need a default value here
			if [ "${RES}" = 0 ]; then
				if [ "${CHECK_SET_STRICT_VERBOSE:-0}" -eq 1 ]; then
					echolog "execPrint '$*' succeeded"
				fi
				break
			elif [ "${CHECK_SET_STRICT_VERBOSE:-0}" -eq 1 ]; then
				printBanner "execPrint '$*' failed. Retrying..."
			else
				:
				# we don't print these 418 I'm a teapot errors to stdout or log for customer
				#	as they are just attempts to get status and fail often - create bad impression:
				#echo
				#echolog "execPrint '$*' failed. Retrying..."
				#echo
			fi
			sleep 10
		done

		# we don't print these 418 I'm a teapot errors to stdout or log for customer
		#	as they are just attempts to get status and fail often - create bad impression:
		if [ "${RES}" != 0 ] && [ "${CHECK_SET_STRICT}" -eq 1 ]; then
			echolog "- - - -COMMAND RETURNED EXIT CODE ${RES}- - - - -"
			echolog "$*" "${OUTPUT}"
			echolog "418 I'm a teapot (this message block prints to STDOUT and LOG only when OMK_STRICT_SH > 0)"
			echolog "- - - - - - - - - - - - - - - - - - - - -"
		elif [ "${CHECK_SET_STRICT_VERBOSE:-0}" -eq 1 ]; then
			# initialising before loop with 'OUTPUT=""' means OUTPUT is always set at this point
			# echologVerboseError expects parameters: COMMAND (as a string '$*' or '...', not an array '$@'), EXITCODE then COMMANDOUTPUT
			# pre-initialised RES=0 before loop so we don't need a default value here
			echologVerboseError "$*" "${RES}" "${OUTPUT}";
			logmsg "###+++"
			#else
				#echolog "$*" "${OUTPUT}"
				#logmsg "###+++"
		fi;
		return $RES
}

# run cmd, capture output and stderr and append to logfile
#	but not using standard error header and footer in echologVerboseError
#		when in test mode 'CHECK_SET_STRICT=1'
#			designed to filter out unwanted "418 I'm a teapot" errors
#	and not retrying on failure
# if in simulate mode, only print what WOULD be done but
#	DON'T EXECUTE anything
execPrintNoRetry418()
{
		if [ -n "$SIMULATE" ]; then
				echo
				echo "SIMULATION MODE, NOT executing command '$*'"
				return 0
		fi

		if [ "${CHECK_SET_STRICT}" -eq 1 ]; then
			logmsg "###+++"
			logmsg "EXEC: $*"
		fi;

		OUTPUT=""
		RES=0

		# shellcheck disable=SC2068
		OUTPUT=$(eval $@ 2>&1)||RES=$?
		# pre-initialised RES=0 before loop so we don't need a default value here
		if [ "${RES}" = 0 ]; then
			if [ "${CHECK_SET_STRICT_VERBOSE:-0}" -eq 1 ]; then
				echolog "execPrint '$*' succeeded"
			fi
		elif [ "${CHECK_SET_STRICT_VERBOSE:-0}" -eq 1 ]; then
			printBanner "execPrint '$*' failed. Retrying..."
		else
			:
			# we don't print these 418 I'm a teapot errors to stdout or log for customer
			#	as they are just attempts to get status and fail often - create bad impression:
			#echo
			#echolog "execPrint '$*' failed. Retrying..."
			#echo
		fi

		# we don't print these 418 I'm a teapot errors to stdout or log for customer
		#	as they are just attempts to get status and fail often - create bad impression:
		if [ "${RES}" != 0 ] && [ "${CHECK_SET_STRICT}" -eq 1 ]; then
			echolog "- - - -COMMAND RETURNED EXIT CODE ${RES}- - - - -"
			echolog "$*" "${OUTPUT}"
			echolog "418 I'm a teapot (this message block prints to STDOUT and LOG only when OMK_STRICT_SH > 0)"
			echolog "- - - - - - - - - - - - - - - - - - - - -"
		elif [ "${CHECK_SET_STRICT_VERBOSE:-0}" -eq 1 ]; then
			# initialising before loop with 'OUTPUT=""' means OUTPUT is always set at this point
			# echologVerboseError expects parameters: COMMAND (as a string '$*' or '...', not an array '$@'), EXITCODE then COMMANDOUTPUT
			# pre-initialised RES=0 before loop so we don't need a default value here
			echologVerboseError "$*" "${RES}" "${OUTPUT}";
			logmsg "###+++"
			#else
				#echolog "$*" "${OUTPUT}"
				#logmsg "###+++"
		fi;
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
				OS_VERSION=`sed -re 's/(^|.* )([0-9]+\.[0-9]+(\.[0-9]+)?).*$/\2/' < /etc/redhat-release`||:;
				if grep -qF CentOS /etc/redhat-release; then
					OS_ISCENTOS=1;
				# This code should mimic that in determining /path/to/nmis9_dev/installer $osflavour variable:
				#### OS_ISCENTOS in this installer code is essentially 'OS_IS_RHEL_DERIVATIVE'
				###elif grep -qF Rocky /etc/redhat-release; then
				###	OS_ISCENTOS=1;
				###	logmsg "detected Rocky OS derivative of RHEL: OS_VERSION='${OS_VERSION}'"
				###elif grep -qF Fedora /etc/redhat-release; then
				###	OS_ISCENTOS=1;
				###	OS_VERSION=`sed -re 's/(^|.* )([0-9]+).*$/\2/' < /etc/redhat-release`;
				###	if [ "${OS_VERSION}" -ge 28 ]; then
				###		OS_VERSION='8.0.0';
				###	elif [ "${OS_VERSION}" -ge 19 ]; then
				###		OS_VERSION='7.0.0';
				###	elif [ "${OS_VERSION}" -ge 12 ]; then
				###		OS_VERSION='6.0.0';
				###	fi;
				###	logmsg "detected Fedora OS derivative of RHEL: OS_VERSION='${OS_VERSION}'"
				fi;

				# ensure OS_ISCENTOS is defined:
				OS_ISCENTOS="${OS_ISCENTOS:-0}";

		elif grep -q ID=debian /etc/os-release ; then
				OSFLAVOUR=debian
				logmsg "detected OS flavour Debian"
				OS_VERSION=`cat /etc/debian_version`||:;
		elif grep -q ID=ubuntu /etc/os-release ; then
				OSFLAVOUR=ubuntu
				logmsg "detected OS flavour Ubuntu"
				OS_VERSION=`grep VERSION_ID /etc/os-release | sed -re 's/^VERSION_ID="([0-9]+\.[0-9]+(\.[0-9]+)?)"$/\1/'`||:;
		fi

		# this code had no objective: OSVERSION is not used anywhere
		# it is a good pointer to an alternative method to determine OSFLAVOUR, OS_VERSION, etc. from /etc/os-release though ...
		#
		if [ -f "/etc/os-release" ]; then
			OSVERSION=$(grep "VERSION_ID=" /etc/os-release | cut -s -d\" -f2)||:;
		fi

		OS_VERSION="${OS_VERSION:-}";

		# This code should mimic that in determining /path/to/nmis9_dev/installer $osflavour variable:
		# grep 'ID_LIKE' as a catch-all for debian and ubuntu repectively - done last to not affect existing tried and tested code:
		if [ -z "${OSFLAVOUR:-}" ]; then
			if egrep -q ID_LIKE=[\'\"]?debian /etc/os-release ; then
					OSFLAVOUR=debian
					DEBIAN_CODENAME="$(grep DEBIAN_CODENAME /etc/os-release|sed 's/DEBIAN_CODENAME=\s*//')";
					# we dont need 'else' catch-all blocks here as we fall back to the debian version
					# populated in the generic block above 'if [ -f "/etc/os-release" ]; then ...':
					if [ -n "${DEBIAN_CODENAME:-}" ]; then
						if echo "${DEBIAN_CODENAME}"|grep -qi 'bookworm'; then
							OS_VERSION='12.0.0';
						elif echo "${DEBIAN_CODENAME}"|grep -qi 'bullseye'; then
							OS_VERSION='11.0.0';
						elif echo "${DEBIAN_CODENAME}"|grep -qi 'buster'; then
							OS_VERSION='10.0.0';
						elif echo "${DEBIAN_CODENAME}"|grep -qi 'stretch'; then
							OS_VERSION='9.0.0';
						elif echo "${DEBIAN_CODENAME}"|grep -qi 'jessie'; then
							OS_VERSION='8.0.0';
						fi;
					fi;
					logmsg "detected OS derivative of Debian: OS_VERSION='${OS_VERSION}'";
			elif egrep -q ID_LIKE=[\'\"]?ubuntu /etc/os-release ; then
					OSFLAVOUR=ubuntu
					UBUNTU_CODENAME="$(grep UBUNTU_CODENAME /etc/os-release|sed 's/UBUNTU_CODENAME=\s*//')";
					# we dont need 'else' catch-all blocks here as we fall back to the ubuntu version
					# populated in the generic block above 'if [ -f "/etc/os-release" ]; then ...':
					if [ -n "${UBUNTU_CODENAME:-}" ]; then
						if echo "${UBUNTU_CODENAME}"|grep -qi 'lunar'; then
							OS_VERSION='23.04.0';
						elif echo "${UBUNTU_CODENAME}"|grep -qi 'kinetic'; then
							OS_VERSION='22.10.0';
						elif echo "${UBUNTU_CODENAME}"|grep -qi 'jammy'; then
							OS_VERSION='22.04.0';
						elif echo "${UBUNTU_CODENAME}"|grep -qi 'impish'; then
							OS_VERSION='21.10.0';
						elif echo "${UBUNTU_CODENAME}"|grep -qi 'hirsute'; then
							OS_VERSION='21.04.0';
						elif echo "${UBUNTU_CODENAME}"|grep -qi 'groovy'; then
							OS_VERSION='20.10.0';
						elif echo "${UBUNTU_CODENAME}"|grep -qi 'focal'; then
							OS_VERSION='20.04.0';
						elif echo "${UBUNTU_CODENAME}"|grep -qi 'eoan'; then
							OS_VERSION='19.10.0';
						elif echo "${UBUNTU_CODENAME}"|grep -qi 'disco'; then
							OS_VERSION='19.04.0';
						elif echo "${UBUNTU_CODENAME}"|grep -qi 'cosmic'; then
							OS_VERSION='18.10.0';
						elif echo "${UBUNTU_CODENAME}"|grep -qi 'bionic'; then
							OS_VERSION='18.04.0';
						elif echo "${UBUNTU_CODENAME}"|grep -qi 'xenial'; then
							OS_VERSION='16.04.0';
						fi;
					fi;
					logmsg "detected OS derivative of Ubuntu: OS_VERSION='${OS_VERSION}'"
			fi
		fi;

		OS_MAJOR=`echo "$OS_VERSION" | cut -s -f 1 -d .`||:;
		OS_MAJOR="${OS_MAJOR:-0}";
		OS_MINOR=`echo "$OS_VERSION" | cut -s -f 2 -d .`||:;
		OS_MINOR="${OS_MINOR:-0}";
		OS_PATCH=`echo "$OS_VERSION" | cut -s -f 3 -d .`||:;
		OS_PATCH="${OS_PATCH:-0}";

		if [ "${CHECK_SET_STRICT_VERBOSE:-0}" -eq 1 ]; then
				printBanner "flavour: OS_VERSION=${OS_VERSION}; OS_MAJOR=${OS_MAJOR}; OS_MINOR=${OS_MINOR}; OS_PATCH=${OS_PATCH}; /etc/os-release OSVERSION='${OSVERSION:-}'";
		fi;

		if [ -z "${OSFLAVOUR:-}" ]; then
			logdie "Unsupported or unknown distribution!";
		fi;

		return 0;

}

# NMIS9 does use this function
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
		NMIS9_VERSION=`$NMIS9DIR/bin/nmis-cli --version 2>/dev/null |grep -F version= | cut -s -f 2 -d =`||:;
		# ...but if it does not run (yet), try a bit harder
		if [ -z "${NMIS9_VERSION:-}" ]; then
				NMIS9_VERSION=`grep -E '^\s*our\s*\\$VERSION' $NMIS9DIR/lib/NMISNG.pm 2>/dev/null | cut -s -f 2 -d '"';`||:;
		fi
		# and if that doesn't work, give up
		[ -z "${NMIS9_VERSION:-}" ] && return 1

		NMIS9_MAJOR=`echo $NMIS9_VERSION | cut -s -f 1 -d .`||:;
		NMIS9_MAJOR="${NMIS9_MAJOR:-0}";
		NMIS9_MINOR=`echo $NMIS9_VERSION | cut -s -f 2 -d . `||:;
		NMIS9_MINOR="${NMIS9_MINOR:-0}";
		# the patch usually has textual suffixes, which we ignore!
		NMIS9_PATCH=`echo $NMIS9_VERSION| cut -s -f 3 -d . | tr -d a-zA-Z`||:;
		NMIS9_PATCH="${NMIS9_PATCH:-0}";

		if [ "${CHECK_SET_STRICT_VERBOSE:-0}" -eq 1 ]; then
				printBanner "get_nmis9_version: NMIS9_VERSION=${NMIS9_VERSION}; NMIS9_MAJOR=${NMIS9_MAJOR}; NMIS9_MINOR=${NMIS9_MINOR}; NMIS9_PATCH=${NMIS9_PATCH}";
		fi;

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
				ACOMP=`echo "$1" | cut -s -f $i -d . | tr -d a-zA-Z`||:;
				ACOMP=${ACOMP:-0}
				BCOMP=`echo "$2" | cut -s -f $i -d . | tr -d a-zA-Z`||:;
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
		if type systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1; then
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
} # end version_check_ntp_type_service
