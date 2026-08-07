#!/bin/bash

set -efu

init_environment

if [ "$REQUEST_METHOD" != 'GET' ] && [ "$REQUEST_METHOD" != 'HEAD' ]; then
	send_error 405
fi
# `:-` because `set -u` makes a missing key fatal, which would end up as a 500
if [ -z "${URL_PARAMETERS[page]:-}" ]; then
	send_error 404
fi

send_file "../file/pages/${URL_PARAMETERS[page]}"
