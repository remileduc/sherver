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

# The requested URL
URL_REQUESTED=''
# The base URL, without the query string if any
URL_BASE=''
# The parameters of the query string if any (in an associative array)
#
# See `parse_url()`.
declare -Ag URL_PARAMETERS
# The headers from the request
declare -A REQUEST_HEADERS
DATE=$(date -uR)
DATE=${DATE/%+0000/GMT}
# The response headers (in an array)
declare -a RESPONSE_HEADERS=(
	"Date: $DATE"
	"Expires: $DATE"
	'Server: Sherver'
	'Cache-Control: private, max-age=60'
	#'Cache-Control: private, max-age=0, no-cache, no-store, must-revalidate'
)
# Generic HTTP response code with their meaning.
declare -rA HTTP_RESPONSE=(
	[200]='OK'
	[304]='Not Modified'
	[400]='Bad Request'
	[403]='Forbidden'
	[404]='Not Found'
	[405]='Method Not Allowed'
	[500]='Internal Server Error'
)

# Log any messages in the error outut of the script (default is console).
#
# Takes as many arguments as needed. they will all be written, separated by newlines.
#
# Examples
#
#    log "> HTTP/1.0 200 OK
#
# will output
#
#    > HTTP/1.0 200 OK
function log()
{
	echo "$*" >&2
}

# Parse the given URL to exrtact the base URL and the query string.
#
# Takes an optional parameters: the URL to parse. By default, it will take the content of
# the variable `URL_REQUESTED`.
#
# It will store the base of the URL (without query string) in `URL_BASE`.
# It will store all the parameters of the query string in the associative array `URL_PARAMETERS`.
#
# $1 - Optional: URL to parse (default will take content of `URL_REQUESTED`)
#
# Examples
#
#    parse_url '/index.sh?test=youpi&answer=42'
#
# will result in
#
#    URL_BASE='/index.sh'
#    URL_PARAMETERS=(
#        ['test']='youpi'
#        ['answer']='42'
#    )
function parse_url()
{
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
	local -i i
	for (( i=0; i < ${#fields[@]}; i++ )); do
		IFS='=' read -r key value <<< "${fields[i]}"
		URL_PARAMETERS["$key"]="$value"
	done
}

# Add header for the response.
#
# Takes 2 parameters: header name and header content.
#
# $1 - header name, one of the HTTP 1.0 standard value
# $2 - value of the header
#
# Examples
#
#    add_header 'Content-Type' 'text/html; charset=utf-8'
#
# will add the following line in the header of the response
#
#    Content-Type: text/html; charset=utf-8
function add_header()
{
   RESPONSE_HEADERS+=("$1: $2")
}

function _send_header()
{
	# HTTP header
	echo -en "HTTP/1.0 $1 ${HTTP_RESPONSE[$1]}\r\n"
	shift
	local i
	for i in "${RESPONSE_HEADERS[@]}"; do
		echo -en "$i\r\n"
	done
	echo -en '\r\n'
}

# Send the given answer in a HTTP 1.0 format.
#
# Takes the response code as first parameter, then as many parameters as needed to write the answer.
# They will be sent, separated by newlines.
#
# Note that the headers need to have already been set with `add_header()`.
#
# $1 - HTTP response code. See `HTTP_RESPONSE`
# $2... - The actual response to send
#
# Examples
#
#    add_header 'Content-Type' 'text/plain'
#    send_response 200 'this is some' 'cool text'
#
# will send something like (depends on your default headers, see `RESPONSE_HEADERS`)
#
# ```
#
#    HTTP/1.0 200 OK
#    Content-Type: text/plain
#
#    this is some
#    cool text
# ```
function send_response()
{
	# HTTP header
	_send_header $1
	shift
	# response
	local i
	for i in "$@"; do
		echo "$i"
	done
}

# Send the given error as an answer.
#
# Takes one parameter: the error code. It will be sent as an answer, along with a very small
# HTML explaining what is the error.
#
# $1 - the error code, see `HTTP_RESPONSE`
#
# Examples
#
#    send_errors 404
#
# will create an answer that starts with
#
#    HTTP/1.0 404 Not Found
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

# Try to send the given file, or fail with 404.
#
# Takes the path to the file to send as a parameter.
#
# It will automatically create a valid HTTP response that will stream the content
# of the file, with the correct mime type and all. If the file doesn't exist, send
# a 404 error.
#
# The path generally comes from the URL (`URL_BASE`). You just need to remove the first
# `/` to get a relative path.
#
# *Note* that to find the correct mimetypem we use `mimetype` command which is shipped
# by default in Debian. You can change it to use `file` command instead, but it doesn't
# work as well...
#
# *Note* that we use a small inline Python script to stream the content of the file.
# This is because, for binary files, bash can't stream non UTF-8 characters properly.
#
# $1 - the path to the file to send
#
# Examples
#
#    parse_url '/file/beautiful.png?dummy=stuff'
#    send_file "${URL_BASE:1}"
#
# if the file exist, will send a response that starts with (assuming file size is 4 kio)
#
#    HTTP/1.0 200 OK
#    Content-Type: image/png
#    Content-Length: 4096
function send_file()
{
	local file="$1"
	# test if file exists, is a file, and is readable
	if [ ! -e "$file" ] || [ ! -f "$file" ] || [ ! -f "$file" ]; then
		send_error 404
	fi

	# we create an ETag
	local etag="$(stat -c '%s-%y-%z' "$file")"
	add_header 'ETag' "$etag"
	# if client already cached it, we don't resend it
	if [ -n "${REQUEST_HEADERS['If-None-Match']+1}" ] && [ "${REQUEST_HEADERS['If-None-Match']}" = "$etag" ]; then
		send_response 304 ''
	else
		# HTTP header
		local content_type=$(mimetype -b "$file")
		local content_length=$(stat -c '%s' "$file")
		add_header 'Content-Type'   "$content_type";
		add_header 'Content-Length' "$content_length"
		_send_header 200
		# response
		# note: we need to use external tool to stream binary files as bash can't handle non UTF-8 bytes.
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
	fi
}

# Try to run the given file (script or executable), or fail with 404.
#
# **Note:** this method is usded by the dispatcher and shouldn't be called manually.
#
# Takes the path to the file to run. The file can be a script in any language, or
# an executable. But it must have the `x` flag so we can run it.
#
# It will simply run the script if possible. If not, send a 404. If the script fails,
# send a 500.
#
# It is the script responsibility to send the response and everything...
#
# *Note* that the file is supposed to be in the subfolder `scripts/`. The file will be
# run inside this folder (we `cd` before running it).
#
# $1 - the path to the file to run (relative to subfolder `scripts/`)
#
# Examples
#
#    run_script '/index.sh?dummy=stuff'
#
# will do the following
#
#    cd scripts
#    './index.sh' '/index.sh?dummy=stuff'
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

# Read the client request and set up environment.
#
# **Note:** this method is usded by the dispatcher and shouldn't be called manually.
#
# Reads the input stream and fills the following variables (also run `parse_url()`):
#
# - `REQUEST_METHOD`
# - `REQUEST_HTTP_VERSION`
# - `REQUEST_HEADERS`
# - `URL_REQUESTED`
# - `URL_BASE`
# - `URL_PARAMETERS`
#
# *Note* that this method is highly inspired by [bashttpd](https://github.com/avleen/bashttpd)
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
	local key
	local value
	while read -r line; do
		line=${line%%$'\r'}
		# reached the end of the headers, break.
		if [ -z "$line" ]; then
			break
		fi
		IFS=': ' read -r key value <<< "$line"
		REQUEST_HEADERS["$key"]="$value"
		log "< $line"
	done
}
