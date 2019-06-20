#!/bin/bash

set -efu

init_environment

if [ "$REQUEST_METHOD" != 'GET' ]; then
	send_error 405
fi
if [ -z "${URL_PARAMETERS[page]}" ]; then
	send_error 404
fi

send_file "../file/pages/${URL_PARAMETERS[page]}"
