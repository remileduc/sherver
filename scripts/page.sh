#!/bin/bash

set -efu

source 'SHERVER_UTILS.sh'

URL="$1"
parse_url "$URL"

if [ -z "${URL_PARAMETERS[page]}" ]; then
	send_error 404
fi

send_file "../file/pages/${URL_PARAMETERS[page]}"
