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
#    './index.sh' '/index.sh?dummy=stuff'
function run_script()
{
	cd 'site/app'
	local -r url="${1:-$REQUEST_URL}"
	parse_url "$url"
	_resolve_path 'site/app' "${URL_BASE:1}"
	local -r script="$_RESOLVED_PATH"
	# existence is already guaranteed by `_resolve_path`
	if [ ! -f "$script" ] || [ ! -x "$script" ]; then
		send_error 404
	fi

	"$script" "$url" || send_error 500
}
export -f run_script
