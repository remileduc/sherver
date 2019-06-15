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

URL_REQUESTED=''
URL_BASE=''
declare -Ag URL_PARAMETERS
declare -a REQUEST_HEADERS
DATE=$(date -uR)
DATE=${DATE/%+0000/GMT}
declare -a RESPONSE_HEADERS=(
	"Date: $DATE"
	"Expires: $DATE"
	'Server: Sherver'
	'Cache-Control: private, max-age=0, no-cache, no-store, must-revalidate'
)
declare -rA HTTP_RESPONSE=(
	[200]='OK'
	[400]='Bad Request'
	[403]='Forbidden'
	[404]='Not Found'
	[405]='Method Not Allowed'
	[500]='Internal Server Error'
)

function log()
{
	echo "$*" >&2
}

function parse_url()
{
	URL_BASE=''
	declare -Ag URL_PARAMETERS

	# get base URL and parameters
	local parameters
	IFS='?' read -r URL_BASE parameters <<< "${1:-$URL_REQUESTED}"
	# now split parameters
	# first, split `key=value` in an array
	declare -a fields
	IFS='&' read -ra fields <<< "$parameters"
	# now we fill URL_PARAMETERS
	local key
	local value
	for (( i=0; i < ${#fields[@]}; i++ )); do
		IFS='=' read -r key value <<< "${fields[i]}"
		URL_PARAMETERS["$key"]="$value"
	done
}

function add_header()
{
   RESPONSE_HEADERS+=("$1: $2")
}

function _send_header()
{
	# HTTP header
	echo "HTTP/1.0 $1 ${HTTP_RESPONSE[$1]}"
	shift
	for i in "${RESPONSE_HEADERS[@]}"; do
		echo "$i"
	done
	echo
}

function send_response()
{
	# HTTP header
	_send_header $1
	shift
	# response
	for i in "$@"; do
		echo "$i"
	done
}

function send_error()
{
	local html=$(cat <<EOF
		<!DOCTYPE html>
		<html>

		<head>
			<meta charset="utf-8">
			<title>ERROR $1 ${HTTP_RESPONSE[$1]}</title>
			<meta name="description" content="ERROR $1 ${HTTP_RESPONSE[$1]}">
		</head>
		<body>
			<h1>ERROR $1</h1>
			<h2>${HTTP_RESPONSE[$1]}</h2>
		</body>
		</html>
EOF
)
	add_header 'Content-Type' 'text/html; charset=utf-8'
	send_response "$@" "$html"
	log "ERROR $1"
	exit 0
}

function send_file()
{
	local file="$1"
	log "$file"
	log "$(pwd)"
	# test if file exists, is a file, and is readable
	if [ ! -e "$file" ] || [ ! -f "$file" ] || [ ! -f "$file" ]; then
		send_error 404
	fi

	# HTTP header
	CONTENT_TYPE=$(mimetype -b "$file")
	CONTENT_LENGTH=$(stat -c '%s' "$file")
	add_header 'Content-Type'   "$CONTENT_TYPE";
	add_header 'Content-Length' "$CONTENT_LENGTH"
	_send_header 200
	# response
	# note: we need to use external tool to tream binary files as bash can't handle non UTF-8 bytes.
	# here we use python
	python3 -c '
import sys
with open(sys.argv[1],"rb") as f1:
	while True:
		b=f1.read(1)
		if b:
			sys.stdout.buffer.write(b)
			# for python2, replace with
			#sys.stdout.write(b)
		else: break
' "$file"
}

function run_script()
{
	cd 'scripts'
	parse_url "${1:-$URL_REQUESTED}"
	local -r script="${URL_BASE:1}"
	# test if file exists, is a file, and is runnable
	if [ ! -e "$script" ] || [ ! -f "$script" ] || [ ! -x "$script" ]; then
		send_error 404
	fi

	"./$script" "${1:-$URL_REQUESTED}" || send_error 500
}

function read_request()
{
	local line
	if ! read -r line; then
		send_error 400
	fi
	line=${line%%$'\r'}
	log "< $line"

	# read URL
	read -r REQUEST_METHOD URL_REQUESTED REQUEST_HTTP_VERSION <<<"$line"
	if [ -z "$REQUEST_METHOD" ] || [ -z "$URL_REQUESTED" ] || [ -z "$REQUEST_HTTP_VERSION" ]; then
		send_error 400
	fi
	# Only GET is supported at this time
	if [ "$REQUEST_METHOD" != 'GET' ]; then
		send_error 405
	fi
	# fill URL_*
	parse_url "$URL_REQUESTED"

	# fill REQUEST_HEADERS
	while read -r line; do
		line=${line%%$'\r'}
		# reached the end of the headers, break.
		if [ -z "$line" ]; then
			break
		fi
		REQUEST_HEADERS+=("$line")
		log "< $line"
	done
}
