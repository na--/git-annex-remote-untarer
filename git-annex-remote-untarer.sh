#!/bin/sh
#
# This git-annex external special remote program is inteded to be used with
# fully reproducible tar archives [1]. They are transparently unpacked when
# stored and repacked when retrieved by git-annex.

# This external remote allows us to semi-efficiently handle a lot of small(ish)
# files. We can keep them in tar archives in most repositories so we don't
# overburden git and git-annex. At the same time, we can also have them unpacked
# in a few places with this remote, somewhere they will not tracked by git
# individually. This allows us to directly serve them with a web server,
# seed them, or just have them readiliy available without needing to manually
# unpack them first. But since the tar archive is reproducible, if we need to,
# we can always seamlessly retrieve the same original archive that the external
# remote first received by tar-ing the files again.
#
# The tar archives are unpacked in a similar hierarchy as the directory special
# remote. For convenience, symlinks to the top-level unpacked files and
# directories are created in a specified folder in the remote.
# TODO: explanation about the symlinks
# TODO: explanation how to create the original tar files
#
# Install in PATH as git-annex-remote-untarer
#
# Licenced under the GNU GPL version 3 or higher.
# Based on work originally copyright 2013 Joey Hess which was licenced under
# the GNU GPL version 3 or higher [2]
#
# [1] https://reproducible-builds.org/docs/archives/
# [2] https://git-annex.branchable.com/special_remotes/external/

set -euo pipefail

# This program speaks a line-based protocol on stdin and stdout.
# When running any commands, their stdout should be redirected to stderr
# (or /dev/null) to avoid messing up the protocol.
runcmd () {
	"$@" >&2
}

# Gets a value from the remote's configuration, and stores it in RET
getconfig () {
	ask GETCONFIG "$1"
}

# Stores a value in the remote's configuration.
setconfig () {
	echo SETCONFIG "$1" "$2"
}

# Sets LOC to the location to use to store a key.
calclocation () {
	ask DIRHASH "$1"
	LOC="$mydirectory/$RET/$1"
}

# Asks for some value, and stores it in RET
ask () {
	echo "$1" "$2"
	read -r resp
	# Tricky POSIX shell code to split first word of the resp,
	# preserving all other whitespace
	case "${resp%% *}" in
		VALUE)
			RET="$(echo "$resp" | sed 's/^VALUE \?//')"
		;;
		*)
			RET=""
		;;
	esac
}

# This remote doesn't need credentials to access it,
# but many of them will. Here's how to handle requiring the user
# set MYPASSWORD and MYLOGIN when running initremote. The creds
# will be stored securely for later use, so the user only needs
# to provide them once.
setupcreds () {
	if [ -z "$MYPASSWORD" ] || [ -z "$MYLOGIN" ]; then
		echo INITREMOTE-FAILURE "You need to set MYPASSWORD and MYLOGIN environment variables when running initremote."
	else
		echo SETCREDS mycreds "$MYLOGIN" "$MYPASSWORD"
		echo INITREMOTE-SUCCESS
	fi
}

getcreds () {
	echo GETCREDS mycreds
	read -r resp
	case "${resp%% *}" in
		CREDS)
			MYLOGIN="$(echo "$resp" | sed 's/^CREDS \([^ ]*\) .*/\1/')"
			MYPASSWORD="$(echo "$resp" | sed 's/^CREDS [^ ]* //')"
		;;
	esac

}

# This has to come first, to get the protocol started.
echo VERSION 1

while read -r line; do
	# shellcheck disable=SC2086
	set -- $line
	case "$1" in
		INITREMOTE)
			# Do anything necessary to create resources
			# used by the remote. Try to be idempotent.
			#
			# Use GETCONFIG to get any needed configuration
			# settings, and SETCONFIG to set any persistent
			# configuration settings.
			#
			# (Note that this is not run every time, only when
			# git annex initremote or git annex enableremote is
			# run.)

			# The directory provided by the user
			# could be relative; make it absolute,
			# and store that.
			getconfig directory
			mydirectory="$(readlink -f "$RET")" || true
			setconfig directory "$mydirectory"
			if [ -z "$mydirectory" ]; then
				echo INITREMOTE-FAILURE "You need to set directory="
			else
				if mkdir -p "$mydirectory"; then
					setupcreds
				else
					echo INITREMOTE-FAILURE "Failed to write to $mydirectory"
				fi
			fi
		;;
		PREPARE)
			# Use GETCONFIG to get configuration settings,
			# and do anything needed to get ready for using the
			# special remote here.
			getcreds
			getconfig directory
			mydirectory="$RET"
			if [ -d "$mydirectory" ]; then
				echo PREPARE-SUCCESS
			else
				echo PREPARE-FAILURE "$mydirectory not found"
			fi
		;;
		TRANSFER)
			key="$3"
			file="$4"
			case "$2" in
				STORE)
					# Store the file to a location
					# based on the key.
					# XXX when at all possible, send PROGRESS
					calclocation "$key"
					mkdir -p "$(dirname "$LOC")"
					# Store in temp file first, so that
					# CHECKPRESENT does not see it
					# until it is all stored.
					mkdir -p "$mydirectory/tmp"
					tmp="$mydirectory/tmp/$key"
					if runcmd cp "$file" "$tmp" \
					   && runcmd mv -f "$tmp" "$LOC"; then
						echo TRANSFER-SUCCESS STORE "$key"
					else
						echo TRANSFER-FAILURE STORE "$key"
					fi

					mkdir -p "$(dirname "$LOC")"
					# The file may already exist, so
					# make sure we can overwrite it.
					chmod 644 "$LOC" 2>/dev/null || true
				;;
				RETRIEVE)
					# Retrieve from a location based on
					# the key, outputting to the file.
					# XXX when easy to do, send PROGRESS
					calclocation "$key"
					if runcmd cp "$LOC" "$file"; then
						echo TRANSFER-SUCCESS RETRIEVE "$key"
					else
						echo TRANSFER-FAILURE RETRIEVE "$key"
					fi
				;;
			esac
		;;
		CHECKPRESENT)
			key="$2"
			calclocation "$key"
			if [ -e "$LOC" ]; then
				echo CHECKPRESENT-SUCCESS "$key"
			else
				if [ -d "$mydirectory" ]; then
					echo CHECKPRESENT-FAILURE "$key"
				else
					# When the directory does not exist,
					# the remote is not available.
					# (A network remote would similarly
					# fail with CHECKPRESENT-UNKNOWN
					# if it couldn't be contacted).
					echo CHECKPRESENT-UNKNOWN "$key" "this remote is not currently available"
				fi
			fi
		;;
		REMOVE)
			key="$2"
			calclocation "$key"
			# Note that it's not a failure to remove a
			# key that is not present.
			if [ -e "$LOC" ]; then
				if runcmd rm -f "$LOC"; then
					echo REMOVE-SUCCESS "$key"
				else
					echo REMOVE-FAILURE "$key"
				fi
			else
				echo REMOVE-SUCCESS "$key"
			fi
		;;
		*)
			# The requests listed above are all the ones
			# that are required to be supported, so it's fine
			# to say that any other request is unsupported.
			echo UNSUPPORTED-REQUEST
		;;
	esac
done
