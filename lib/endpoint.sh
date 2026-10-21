#!/bin/bash

# MIT License
#
# Sherver: Pure Bash lightweight web server.
# Copyright (c) 2019 Rémi Ducceschi
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

set -efu

# Public: Try to run the given file (script or executable), or fail with 404.
#
# **Note:** this method is usded by the dispatcher and shouldn't be called manually.
#
# Takes the path to the file to run. The file can be a script in any language, or
# an executable. But it must have the `x` flag so we can run it.
#
# It will simply run the script if possible. If not, send a 404. If the script is outside
# of `site/app/`, send a 404. If the script fails, send a 500.
#
# How it is run depends on the name the URL ends with:
#
# * `*.sh` is a bash endpoint, `source`d in a subshell of this process: it sees the parsed
#   request (`REQUEST_HEADERS`, `URL_PARAMETERS`...) as they are, with no re-parse and no
#   `init_environment` call needed. Its `exit`, and the `send_*` functions, end the
#   subshell only; a failing command does too, and that is the 500: `set -e` is on in the
#   subshell whether or not the endpoint sets it, so the library fails the way it expects;
# * anything else is executed as a new process, with the URL in `$1` and the request in
#   the environment variable `REQUEST_FULL_STRING`.
#
# The name is the one in the URL, not the file it resolves to: a symlink `foo -> foo.sh`
# is executed, as its URL says.
#
# It is the script responsibility to send the response and everything...
#
# *Note* that the file is supposed to be in the subfolder `site/app/`. The file will be
# run inside this folder (we `cd` before running it).
#
# $1 - the path to the file to run (relative to subfolder `site/app/`)
#
# Examples
#
#    run_script '/index.sh?dummy=stuff'
#
# will do the following
#
#    cd site/app
#    ( source './index.sh' '/index.sh?dummy=stuff' )
function run_script()
{
	# here and not in the subshell: `_resolve_path` resolves against the cwd
	cd 'site/app'
	# a sourced endpoint runs in this scope: these names must not be ones it would pick
	local -r _run_script_url="${1:-$REQUEST_URL}"
	parse_url "$_run_script_url"
	_resolve_path 'site/app' "${URL_BASE:1}"
	local -r _run_script_file="$_RESOLVED_PATH"
	# existence is already guaranteed by `_resolve_path`; the exec bit is what publishes
	# an endpoint, sourced or not
	if [ ! -f "$_run_script_file" ] || [ ! -x "$_run_script_file" ]; then
		send_error 404
	fi

	case "$URL_BASE" in
		*.sh)
			# `source` reads the file where `exec` would not have to
			if [ ! -r "$_run_script_file" ]; then
				log "NOT FOUND: not readable - $_run_script_file"
				send_error 404
			fi
			# not `( ... ) || send_error 500`: bash ignores `set -e` inside anything on
			# the left of a `||`, and the endpoint would run on past its first failure.
			# The subshell forks with `-e` off, hence the `set -e` inside
			set +e
			( set -e; source "$_run_script_file" "$_run_script_url" )
			local -ir _run_script_status=$?
			set -e
			if [ "$_run_script_status" -ne 0 ]; then
				send_error 500
			fi
			;;
		*)
			"$_run_script_file" "$_run_script_url" || send_error 500
			;;
	esac
}
export -f run_script
