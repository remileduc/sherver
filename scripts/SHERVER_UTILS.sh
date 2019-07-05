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

# Public: The full request string
declare -g REQUEST_FULL_STRING=''

# Public: Initialize the environment.
#
# This function should always be ran at the top of any scripts. Once this function has
# run, all the following variables will be available:
#
# * `REQUEST_METHOD`
# * `REQUEST_URL`
# * `REQUEST_HEADERS`
# * `REQUEST_BODY`
# * `REQUEST_BODY_PARAMETERS`
# * `URL_BASE`
# * `URL_PARAMETERS`
# * `RESPONSE_HEADERS`
# * `HTTP_RESPONSE`
# * `REQUEST_FULL_STRING`
#
# To do so, ti will read from the standard input the received request, and execute
# `read_request` to initialize everything.
#
# Then, it will export the full request in the environment variable `REQUEST_FULL_STRING`
# so it can always be reexecuted.
#
# This echanism also allows non bash script to have access to the request through the
#environment.
function init_environment()
{
	# we set all the needed variables in the environment.
	# this is needed because we can't export associative arrays...

	# Public: The method of the request (GET, POST...)
	declare -g REQUEST_METHOD=''
	# Public: The requested URL
	declare -g REQUEST_URL=''
	# Public: The headers from the request (associative array)
	declare -Ag REQUEST_HEADERS
	# Public: Body of the request (mainly useful for POST)
	declare -g REQUEST_BODY=''
	# Public: parameters of the request, in case of POST with `application/x-www-form-urlencoded`
	# content
	declare -Ag REQUEST_BODY_PARAMETERS
	# Public: The base URL, without the query string if any
	declare -g URL_BASE=''
	# Public: The parameters of the query string if any (in an associative array)
	#
	# See `parse_url()`.
	declare -Ag URL_PARAMETERS
	# Public: The response headers (associative array)
	declare -Ag RESPONSE_HEADERS=(
		[Server]='Sherver'
		[Cache-Control]='private, max-age=60'
		#[Cache-Control]='private, max-age=0, no-cache, no-store, must-revalidate'
	)
	# Public: Generic HTTP response code with their meaning (associative array)
	declare -rAg HTTP_RESPONSE=(
		[200]='OK'
		[304]='Not Modified'
		[400]='Bad Request'
		[403]='Forbidden'
		[404]='Not Found'
		[405]='Method Not Allowed'
		[500]='Internal Server Error'
	)

	# if REQUEST_FULL_STRING is empty, we fill it with the input stream and we export it
	if [ -z "$REQUEST_FULL_STRING" ]; then
		read_request true
		log
		export REQUEST_FULL_STRING
	else
		read_request false <<< "$REQUEST_FULL_STRING"
	fi
}
export -f init_environment

# Public: Log any messages in the error outut of the script (default is console).
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
export -f log

# Public: Parse the given URL to exrtact the base URL and the query string.
#
# Takes an optional parameters: the URL to parse. By default, it will take the content of
# the variable `REQUEST_URL`.
#
# It will store the base of the URL (without query string) in `URL_BASE`.
# It will store all the parameters of the query string in the associative array `URL_PARAMETERS`.
#
# $1 - Optional: URL to parse (default will take content of `REQUEST_URL`)
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
	IFS='?' read -r URL_BASE parameters <<< "${1:-$REQUEST_URL}"
	# now split parameters
	# first, split `key=value` in an array
	local -a fields
	IFS='&' read -ra fields <<< "$parameters"
	# now we fill URL_PARAMETERS
	local key value
	local -i i
	for (( i=0; i < ${#fields[@]}; i++ )); do
		IFS='=' read -r key value <<< "${fields[i]}"
		URL_PARAMETERS["$key"]="$value"
	done
}
export -f parse_url

# Public: Add header for the response.
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
   RESPONSE_HEADERS["$1"]="$2"
}
export -f add_header

# Internal: Write the headers to the standard output.
#
# It will write all the headers defined in `RESPONSE_HEADERS`,
# see `add_header()`.
# It also automatically add the date header.
#
# Takes one parameter which is the code of the response.
#
# $1 - The code of the response, must exist in `HTTP_RESPONSE`
#
# Examples
#
#    _send_header 200
#
# will result in:
#
#    HTTP/1.0 200 OK
#    Date: Thu, 04 Jul 2019 21:38:23 GMT
#    Server: Sherver
#    Cache-Control: private, max-age=60
#    Expires: Thu, 04 Jul 2019 21:38:23 GMT
function _send_header()
{
	# HTTP header
	echo -en "HTTP/1.0 $1 ${HTTP_RESPONSE[$1]}\r\n"
	log "> HTTP/1.0 $1 ${HTTP_RESPONSE[$1]}"
	# Date
	local datenow
	datenow=$(date -uR)
	datenow=${datenow/%+0000/GMT}
	add_header 'Date' "$datenow"
	add_header 'Expires' "$datenow"
	# rest of the headers
	local i
	for i in "${!RESPONSE_HEADERS[@]}"; do
		echo -en "$i: ${RESPONSE_HEADERS[$i]}\r\n"
		log "> $i: ${RESPONSE_HEADERS[$i]}"
	done
	echo -en '\r\n'
}
export -f _send_header

# Public: Send the given answer in a HTTP 1.0 format.
#
# Takes the response code as first parameter, then as many parameters as needed to write the answer.
# They will be sent, separated by newlines.
#
# At the end of the function, we call exit to terminate the process.
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
	_send_header "$1"
	shift
	# response
	local i
	for i in "$@"; do
		echo "$i"
	done
	log '================================================'
	exit 0
}
export -f send_response

# Public: Send the given error as an answer.
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
	local html
	html=$(cat <<EOF
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
	log "ERROR $1"
	send_response "$@" "$html"
}
export -f send_error

# Public: Try to send the given file, or fail with 404.
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
	local etag
	etag="$(stat -c '%s-%y-%z' "$file")"
	add_header 'ETag' "$etag"
	# if client already cached it, we don't resend it
	if [ -n "${REQUEST_HEADERS['If-None-Match']+1}" ] && [ "${REQUEST_HEADERS['If-None-Match']}" = "$etag" ]; then
		send_response 304 ''
	else
		# HTTP header
		local content_type content_length
		content_type=$(mimetype -b "$file")
		content_length=$(stat -c '%s' "$file")
		add_header 'Content-Type'   "$content_type";
		add_header 'Content-Length' "$content_length"
		_send_header 200
		# response
		cat "$file"
		log '================================================'
	fi
	exit 0
}
export -f send_file

# Public: Try to run the given file (script or executable), or fail with 404.
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
	parse_url "${1:-$REQUEST_URL}"
	local -r script="${URL_BASE:1}"
	# test if file exists, is a file, and is runnable
	if [ ! -e "$script" ] || [ ! -f "$script" ] || [ ! -x "$script" ]; then
		send_error 404
	fi

	"./$script" "${1:-$REQUEST_URL}" || send_error 500
}
export -f run_script

# Internal: Read the client request and set up environment.
#
# **Note:** this method is used by the dispatcher and shouldn't be called manually.
#
# Reads the input stream and fills the following variables (also run `parse_url()`):
#
# * `REQUEST_METHOD`
# * `REQUEST_HTTP_VERSION`
# * `REQUEST_HEADERS`
# * `REQUEST_BODY`
# * `REQUEST_BODY_PARAMETERS`
# * `REQUEST_URL`
# * `URL_BASE`
# * `URL_PARAMETERS`
#
# *Note* that this method is highly inspired by [bashttpd](https://github.com/avleen/bashttpd)
#
# $1 - if true, logs will be written (whole header, but not the body)
function read_request()
{
	local line
	if ! read -r line; then
		send_error 400
	fi
	line=${line%%$'\r'}
	REQUEST_FULL_STRING="$line"

	# read URL
	read -r REQUEST_METHOD REQUEST_URL REQUEST_HTTP_VERSION <<< "$line"
	if [ -z "$REQUEST_METHOD" ] || [ -z "$REQUEST_URL" ] || [ -z "$REQUEST_HTTP_VERSION" ]; then
		if [ "$1" = true ]; then
			log "$REQUEST_FULL_STRING"
		fi
		send_error 400
	fi
	# Only GET and POST are supported at this time
	if [ "$REQUEST_METHOD" != 'GET' ] && [ "$REQUEST_METHOD" != 'POST' ]; then
		if [ "$1" = true ]; then
			log "$REQUEST_FULL_STRING"
		fi
		send_error 405
	fi
	# fill URL_*
	parse_url "$REQUEST_URL"

	# fill REQUEST_HEADERS
	local key value
	while read -r line; do
		line=${line%%$'\r'}
		# reached the end of the headers, break.
		if [ -z "$line" ]; then
			break
		fi
		REQUEST_FULL_STRING="$REQUEST_FULL_STRING
$line"
		IFS=': ' read -r key value <<< "$line"
		REQUEST_HEADERS["$key"]="$value"
	done
	if [ "$1" = true ]; then
		log "$REQUEST_FULL_STRING"
	fi

	# fill REQUEST_BODY if POST
	if [ "$REQUEST_METHOD" = 'POST' ] && [ -n "${REQUEST_HEADERS['Content-Length']+1}" ]; then
		if ! read -rN "${REQUEST_HEADERS['Content-Length']}" line; then
			send_error 400
		fi
		line=${line%%$'\r'}
		REQUEST_FULL_STRING="$REQUEST_FULL_STRING

$line"
		REQUEST_BODY="$line"
		# if content is of type "application/x-www-form-urlencoded", we parse it
		if [ -n "${REQUEST_HEADERS['Content-Type']+1}" ] && [ "${REQUEST_HEADERS['Content-Type']}" = 'application/x-www-form-urlencoded' ]; then
			local -a fields
			IFS='&' read -ra fields <<< "$REQUEST_BODY"
			local key value
			local -i i
			for (( i=0; i < ${#fields[@]}; i++ )); do
				IFS='=' read -r key value <<< "${fields[i]}"
				REQUEST_BODY_PARAMETERS["$key"]="$value"
			done
		fi
	fi
}
export -f read_request
