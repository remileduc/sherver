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
# * `SHERVER_ROOT`
# * `REQUEST_METHOD`
# * `REQUEST_URL`
# * `REQUEST_HTTP_VERSION`
# * `REQUEST_HEADERS`
# * `REQUEST_BODY`
# * `REQUEST_BODY_PARAMETERS`
# * `URL_BASE`
# * `URL_PARAMETERS`
# * `RESPONSE_HEADERS`
# * `HTTP_RESPONSE`
# * `MAX_BODY_SIZE`
# * `MAX_HEADERS_SIZE`
# * `REQUEST_FULL_STRING`
# * `DEBUG_LOG`
#
# To do so, it will read from the standard input the received request, and execute
# `read_request` to initialize everything.
#
# Then, it will export the full request in the environment variable `REQUEST_FULL_STRING`
# so it can always be reexecuted.
#
# This mechanism also allows non bash script to have access to the request through the
# environment.
function init_environment()
{
	# we set all the needed variables in the environment.
	# this is needed because we can't export associative arrays...

	# Public: Absolute path to the root of the website (canonical, no symlink)
	#
	# The dispatcher runs from the root, so we take the current directory. It is then
	# inherited by the child scripts, which need it because `run_script` moves to `scripts/`.
	#
	# Assigned apart from `declare`, whose zero return would hide a `realpath` failure from
	# `set -e` — the confinement check would then compare against `/file` and `/scripts`.
	if [ -z "${SHERVER_ROOT:-}" ]; then
		declare -g SHERVER_ROOT
		SHERVER_ROOT=$(realpath .) || { log "FATAL: cannot canonicalize '$PWD'"; exit 1; }
	fi
	export SHERVER_ROOT
	# Public: The method of the request (one of GET, HEAD, POST and OPTIONS)
	declare -g REQUEST_METHOD=''
	# Public: The requested URL, always as a path (`*` alone for an asterisk-form `OPTIONS`)
	#
	# An absolute-form target (`GET http://host/path`, the form a proxy sends) is rewritten
	# by `read_request()` to the path it points at, and any other non-path target is a 400,
	# so scripts never see a scheme or a host.
	declare -g REQUEST_URL=''
	# Public: The HTTP version the client announced (`HTTP/1.0`, `HTTP/1.1`...)
	#
	# `read_request()` rejects anything that is not `HTTP/1.x` (400 when unparseable, 505
	# on another major version), so scripts only ever see 1.x here. The answer is always
	# in HTTP 1.1 (RFC 9112 §2.3 — the version in the response advertises capability, so
	# answering 1.1 to a 1.0 client is correct).
	declare -g REQUEST_HTTP_VERSION=''
	# Public: The headers from the request (associative array)
	#
	# The keys are lowercase, because HTTP header names are case insensitive:
	# use `REQUEST_HEADERS['content-type']`, not `REQUEST_HEADERS['Content-Type']`.
	#
	# A header the client repeated is here as the `v1, v2` list it stands for (RFC 9110 §5.2).
	# `Cookie` recombines on `; ` instead (RFC 9113 §8.2.3), and a repeated `Host`,
	# `Content-Length` or `Content-Type` with two different values is a 400.
	declare -Ag REQUEST_HEADERS
	# Public: Body of the request (mainly useful for POST)
	declare -g REQUEST_BODY=''
	# Public: parameters of the request, in case of POST with `application/x-www-form-urlencoded`
	# content
	#
	# filled through the nameref of `_parse_parameters`, which shellcheck can't see
	# shellcheck disable=SC2034
	declare -Ag REQUEST_BODY_PARAMETERS
	# Public: The base URL, without the query string if any
	declare -g URL_BASE=''
	# Public: The parameters of the query string if any (in an associative array)
	#
	# See `parse_url()`.
	#
	# filled through the nameref of `_parse_parameters`, which shellcheck can't see
	# shellcheck disable=SC2034
	declare -Ag URL_PARAMETERS
	# Public: The response headers (associative array)
	declare -Ag RESPONSE_HEADERS=(
		[Server]='Sherver'
		[Connection]='close'
		[X-Content-Type-Options]='nosniff'
		[Cache-Control]='private, max-age=60'
		#[Cache-Control]='private, max-age=0, no-cache, no-store, must-revalidate'
	)
	# Public: Generic HTTP response code with their meaning (associative array)
	declare -rAg HTTP_RESPONSE=(
		[200]='OK'
		[206]='Partial Content'
		[301]='Moved Permanently'
		[302]='Found'
		[303]='See Other'
		[304]='Not Modified'
		[307]='Temporary Redirect'
		[308]='Permanent Redirect'
		[400]='Bad Request'
		[403]='Forbidden'
		[404]='Not Found'
		[405]='Method Not Allowed'
		[411]='Length Required'
		[413]='Content Too Large'
		[414]='URI Too Long'
		[416]='Range Not Satisfiable'
		[431]='Request Header Fields Too Large'
		[500]='Internal Server Error'
		[501]='Not Implemented'
		[505]='HTTP Version Not Supported'
	)
	# Public: The methods the server accepts, as an `Allow` header value
	#
	# `read_request()` tests the request method against it and sends it with its 405, and the
	# dispatcher answers `OPTIONS` with it, so adding a method here cannot leave a stale
	# `Allow` behind. A single script advertises its own list instead, `Allow` being a property
	# of the target resource and not of the server (RFC 9110 §10.2.1).
	declare -rg SUPPORTED_METHODS='GET, HEAD, POST, OPTIONS'
	# Public: Biggest request body we accept to read, in bytes
	#
	# The body ends up in `REQUEST_FULL_STRING`, which we export. Linux refuses to run a
	# command when a single environment string is bigger than 128 kio, so past that limit
	# every external command (`realpath`, `cat`...) fails and we can't answer at all.
	declare -rg MAX_BODY_SIZE=$((64 * 1024))
	# Public: Biggest request line + headers we accept to read, in characters
	#
	# They land in `REQUEST_FULL_STRING` too, so they share the 128 kio limit of
	# `MAX_BODY_SIZE`. 8 kio (what nginx and Apache use) leaves room for a full body even if
	# every header character takes 4 bytes.
	declare -rg MAX_HEADERS_SIZE=$((8 * 1024))
	# Internal: anchored regex matching a whole RFC 9110 §5.6.2 token
	#
	# Shared by the method check of `_read_request_line()` and the field name check of
	# `_read_request_headers()`: both are that one grammar rule, so they must not drift.
	# The ranges are spelled out because `[[:alnum:]]` follows the locale, and the
	# `LC_ALL=C.UTF-8` of the dispatcher would let every Unicode letter through.
	declare -rg _HTTP_TOKEN_REGEX=$'^[A-Za-z0-9!#$%&\'*+.^_`|~-]+$'
	# Internal: canonical path computed by `_resolve_path()`
	declare -g _RESOLVED_PATH=''
	# Internal: the request-target exactly as the client sent it
	#
	# The access log reads it instead of `REQUEST_URL`, which loses the absolute form to the
	# rewrite in `read_request()` — the log must keep proxy-style requests greppable.
	declare -g _REQUEST_TARGET=''
	# Internal: the validated authority of an absolute-form target, empty otherwise
	#
	# Filled by `_read_request_line()` when the target proves absolute-form, applied over
	# the `Host` header by `_read_request_headers()`.
	declare -g _REQUEST_AUTHORITY=''
	# Public: `true` when verbose logging is on, see `log_debug()`
	#
	# Read from the environment because that is the only channel that survives the exec into
	# a child script: `sherver.sh --debug` exports `SHERVER_DEBUG`, and so does `systemd`.
	declare -rg DEBUG_LOG="${SHERVER_DEBUG:-0}"

	# if REQUEST_FULL_STRING is empty, we fill it with the input stream and we export it
	if [ -z "$REQUEST_FULL_STRING" ]; then
		read_request true
		log_debug
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
# Use it for what is worth keeping on a busy server: errors, and the one line per
# response written by `_send_header()`. Everything else belongs in `log_debug()`.
#
# Examples
#
#    log "> HTTP/1.1 200 OK
#
# will output
#
#    > HTTP/1.1 200 OK
function log()
{
	printf '%s\n' "$@" >&2
}
export -f log

# Public: Same as `log()`, but only when debug logging is on.
#
# Debug logging is off unless `SHERVER_DEBUG` is `1` in the environment, which
# `sherver.sh --debug` does. It turns on the full request and response dumps, which are
# a dozen lines per request: enough to hit the rate limit of a log collector.
#
# Takes as many arguments as needed. they will all be written, separated by newlines.
#
# Examples
#
#    log_debug "> Content-Type: text/html"
function log_debug()
{
	if [ "$DEBUG_LOG" = 1 ]; then
		printf '%s\n' "$@" >&2
	fi
}
export -f log_debug

# Internal: Tell if the given string is properly percent encoded.
#
# **Note:** this method is used by `read_request()` and shouldn't be called manually.
#
# Returns 0 if the string can safely be given to `_url_decode()`, 1 otherwise. A `%` that
# is not followed by 2 hexadecimal digits can't be decoded, and `%00` decodes to a NUL
# byte, which silently truncates the string in bash.
#
# $1 - the string to check
#
# Examples
#
#    _check_encoding '/file/my%20file.txt'  # returns 0
#    _check_encoding '/file/100%'           # returns 1
function _check_encoding()
{
	if [[ $1 == *%00* ]]; then
		return 1
	fi
	# a regex stays linear, where `${1//%[hex][hex]/}` copies the string once per match
	local -r broken='%([^0-9a-fA-F]|[0-9a-fA-F][^0-9a-fA-F]|[0-9a-fA-F]?$)'
	# no `%` outside of a valid triplet means the whole string is decodable
	! [[ $1 =~ $broken ]]
}
export -f _check_encoding

# Internal: Decode the percent encoded characters of the given string.
#
# **Note:** the string must have been accepted by `_check_encoding()` first.
#
# The result is stored in the variable named by the first parameter, because a command
# substitution would drop a trailing newline coming from a `%0A`.
#
# $1 - name of the variable to store the result in
# $2 - the string to decode
#
# Examples
#
#    _url_decode value 'caf%C3%A9'
#
# will result in
#
#    value='café'
function _url_decode()
{
	# a backslash already in the string would be interpreted, so we double it first
	local -r escaped="${2//\\/\\\\}"
	printf -v "$1" '%b' "${escaped//%/\\x}"
}
export -f _url_decode

# Internal: Fill an associative array from a string of urlencoded parameters.
#
# **Note:** this method is used by `parse_url()` and `_read_request_body()` and shouldn't
# be called manually.
#
# Takes the `key=value` pairs joined by `&` that a query string and an urlencoded body
# share, decodes both sides, and stores them in the array named by the second parameter.
# The array is emptied first, so a second parse never keeps keys from the first one.
# The string must have been accepted by `_check_encoding()` first.
#
# A parameter without a name is skipped, as an empty key is not a valid array subscript.
# A `+` decodes to a space, in the query string and in a form body both.
#
# $1 - the urlencoded parameters (`key=value` pairs joined by `&`)
# $2 - name of the associative array to fill
#
# Examples
#
#    _parse_parameters 'test=youpi&city=caf%C3%A9+ville' 'URL_PARAMETERS'
#
# will result in
#
#    URL_PARAMETERS=(
#        ['test']='youpi'
#        ['city']='café ville'
#    )
function _parse_parameters()
{
	# a nameref, because the two callers fill two different arrays
	local -n _parameters=$2
	# a child script may call `parse_url` on a second URL: keys must not accumulate
	_parameters=()
	# first, split `key=value` in an array
	local -a fields
	IFS='&' read -ra fields <<< "$1"
	local key value
	local -i i
	for (( i=0; i < ${#fields[@]}; i++ )); do
		IFS='=' read -r key value <<< "${fields[i]}"
		# an empty key is a fatal `bad array subscript`, and carries no information anyway
		if [ -z "$key" ]; then
			continue
		fi
		# `+` is a space in urlencoded content
		_url_decode key "${key//+/ }"
		_url_decode value "${value//+/ }"
		_parameters["$key"]="$value"
	done
}
export -f _parse_parameters

# Public: Parse the given URL to exrtact the base URL and the query string.
#
# Takes an optional parameters: the URL to parse. By default, it will take the content of
# the variable `REQUEST_URL`.
#
# It will store the base of the URL (without query string) in `URL_BASE`.
# It will store all the parameters of the query string in the associative array `URL_PARAMETERS`.
#
# Everything is percent decoded, but only once the URL has been split: a `%3F` in the path
# is a question mark in a file name, not the start of the query string. A URL that is not
# properly percent encoded can't be decoded, and is answered with a 400.
#
# A parameter without a name is skipped, as an empty key is not a valid array subscript.
#
# $1 - Optional: URL to parse (default will take content of `REQUEST_URL`)
#
# Examples
#
#    parse_url '/index.sh?test=youpi&answer=42&city=caf%C3%A9+ville'
#
# will result in
#
#    URL_BASE='/index.sh'
#    URL_PARAMETERS=(
#        ['test']='youpi'
#        ['answer']='42'
#        ['city']='café ville'
#    )
function parse_url()
{
	local -r url="${1:-$REQUEST_URL}"
	# `read_request()` already checked the request URL, but this function is public
	if ! _check_encoding "$url"; then
		log "BAD REQUEST: invalid percent encoding in '$url'"
		send_error 400
	fi
	# get base URL and parameters
	local parameters
	IFS='?' read -r URL_BASE parameters <<< "$url"
	# a `+` stays a `+` in the path: the space treatment belongs to the parameters only
	_url_decode URL_BASE "$URL_BASE"
	_parse_parameters "$parameters" 'URL_PARAMETERS'
}
export -f parse_url

# Public: Print the given string with the HTML special characters escaped.
#
# Everything coming from the request (the URL, its parameters, the headers, the body...) is
# written by the client. A script that drops it in a page as is lets that client inject its
# own markup, so escape it, always. Best done at the point where the value is inserted, so
# that no unescaped copy is left around to be used by mistake.
#
# The 5 escaped characters cover text inside an element and the value of a quoted attribute.
# An unquoted attribute, a `<script>` or a `<style>` need more than this, and are a bad place
# to put anything the client sent in the first place.
#
# $1 - the string to escape
#
# Examples
#
#    html_escape '<script>alert(1)</script>'
#
# will print
#
#    &lt;script&gt;alert(1)&lt;/script&gt;
function html_escape()
{
	# `&` first, or we would escape the `&` of the entities added below. The `\&` are
	# mandatory: since bash 5.2, a bare `&` in a replacement means the matched text
	local escaped="${1//&/\&amp;}"
	escaped="${escaped//</\&lt;}"
	escaped="${escaped//>/\&gt;}"
	escaped="${escaped//\"/\&quot;}"
	escaped="${escaped//\'/\&#39;}"
	printf '%s\n' "$escaped"
}
export -f html_escape

# Public: Add header for the response.
#
# Takes 2 parameters: header name and header content.
#
# $1 - header name, one of the HTTP 1.1 standard value
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
#    HTTP/1.1 200 OK
#    Date: Thu, 04 Jul 2019 21:38:23 GMT
#    Server: Sherver
#    Cache-Control: private, max-age=60
function _send_header()
{
	# the access log: the only line a quiet server writes for a request it served. socat's
	# EXEC sets the peer address; a `-` means no socat in front, like the filter-driven
	# tests. A request too broken to have a method is answered before those variables are filled
	log "${SOCAT_PEERADDR:--} ${REQUEST_METHOD:--} ${_REQUEST_TARGET:--} $1"
	# HTTP header
	log_debug "> HTTP/1.1 $1 ${HTTP_RESPONSE[$1]}"
	# `printf`, not `echo -e`: a header value holding a literal `\r\n` would be turned into a
	# real CRLF and inject a header of its own
	printf 'HTTP/1.1 %s %s\r\n' "$1" "${HTTP_RESPONSE[$1]}"
	# Date. No `Expires` next to it: `Cache-Control` already carries the lifetime, and a cache
	# must ignore `Expires` whenever `max-age` is there (RFC 9111 §5.3), so the second field
	# only ever gets to disagree with the first
	local datenow
	datenow=$(date -uR)
	datenow=${datenow/%+0000/GMT}
	add_header 'Date' "$datenow"
	# rest of the headers
	local i
	for i in "${!RESPONSE_HEADERS[@]}"; do
		log_debug "> $i: ${RESPONSE_HEADERS[$i]}"
		printf '%s: %s\r\n' "$i" "${RESPONSE_HEADERS[$i]}"
	done
	printf '\r\n'
}
export -f _send_header

# Public: Send the given answer in a HTTP 1.1 format.
#
# Takes the response code as first parameter, then as many parameters as needed to write the answer.
# They will be sent, separated by newlines.
#
# Call it with the code alone to send no body at all, as a 304 requires. The body is also
# dropped on its own when the client sent a HEAD request.
#
# `Content-Length` is computed and added automatically, except for a 304.
#
# At the end of the function, we call exit to terminate the process.
#
# Note that the headers need to have already been set with `add_header()`.
#
# $1 - HTTP response code. See `HTTP_RESPONSE`
# $2... - Optional: the actual response to send (a 304 must have none)
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
#    HTTP/1.1 200 OK
#    Content-Type: text/plain
#
#    this is some
#    cool text
# ```
function send_response()
{
	local -r code="$1"
	shift
	local i
	# a 304 carries the `Content-Length` of the answer it replaces, which we don't know here
	if [ "$code" != '304' ]; then
		# `${#}` counts characters, where `Content-Length` counts bytes
		local LC_ALL=C
		local -i length=0
		for i in "$@"; do
			# every argument is written with a trailing newline below
			length+=${#i}+1
		done
		add_header 'Content-Length' "$length"
	fi
	# HTTP header
	_send_header "$code"
	# response
	if [ "$REQUEST_METHOD" != 'HEAD' ]; then
		for i in "$@"; do
			printf '%s\n' "$i"
		done
	fi
	log_debug '================================================'
	exit 0
}
export -f send_response

# Public: Send the given error as an answer.
#
# Takes one parameter: the error code. It will be sent as an answer, along with a very small
# HTML explaining what is the error.
#
# The answer is `Cache-Control: no-store` and carries none of the cache validators that may
# already have been set: this page is not the representation they describe, and several of
# these codes are triggered by a request header that nothing nominates in a `Vary`.
#
# $1 - the error code, see `HTTP_RESPONSE`
#
# Examples
#
#    send_errors 404
#
# will create an answer that starts with
#
#    HTTP/1.1 404 Not Found
#    Cache-Control: no-store
function send_error()
{
	# the access log already carries the code, so this one is only useful next to a dump
	log_debug "ERROR $1"
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
	# a 416 gets here holding the ETag and the date of the file it refused a range of, and
	# they describe that file, not this page
	unset -v 'RESPONSE_HEADERS[ETag]' 'RESPONSE_HEADERS[Last-Modified]'
	# nothing puts `Range` — or a header length, or the version — in a `Vary`, so a stored
	# 416, 431 or 505 could be replayed for a later request the server would have answered
	add_header 'Cache-Control' 'no-store'
	send_response "$@" "$html"
}
export -f send_error

# Public: Send a redirect to the given URL as an answer.
#
# Takes the target URL, and optionally the response code, one of the five redirects of
# RFC 9110 §15.4: 302 (the default) for a temporary redirect, 301 for a permanent one,
# 303 to tell the client to GET the target, and 307/308 as their method-preserving
# counterparts — a strict client may repeat a POST on a 301/302, only 303 guarantees the
# switch to GET. Anything else is refused with a 500: `send_response` would die expanding
# an unknown code mid-answer, and the client would get nothing at all.
#
# The typical use is POST-redirect-GET, so that a refresh doesn't resubmit the form —
# that is 303.
#
# A target holding a CR or a LF is refused with a 500 the same way: it would split the
# Location header in two. The rest is the caller's business — a target built from the request
# is an open redirect unless the script checks it, and a full URL is legitimate here, so the
# library cannot tell the wanted ones from the others.
#
# Like the other `send_*` functions, it exits: nothing after it runs.
#
# $1 - the URL to redirect to (a path like `/index.sh`, or a full URL)
# $2 - Optional: the response code, 301, 302, 303, 307 or 308 (default 302)
#
# Examples
#
#    send_redirect '/index.sh'
#
# will send an answer that starts with
#
#    HTTP/1.1 302 Found
#    Location: /index.sh
function send_redirect()
{
	if [ -z "${1:-}" ]; then
		log 'MISCONFIGURED: send_redirect needs a target URL'
		send_error 500
	fi
	# `_url_decode` turns a `%0d%0a` the client sent into a real CRLF, which would close the
	# Location header and let the rest of the target write headers, and a body, of its own
	if [[ $1 == *[$'\r\n']* ]]; then
		log 'MISCONFIGURED: send_redirect got a target holding a CR or a LF'
		send_error 500
	fi
	local -r code="${2:-302}"
	case "$code" in
		301|302|303|307|308) ;;
		*)
			log "MISCONFIGURED: send_redirect got code '$code', which is not a redirect"
			send_error 500
			;;
	esac
	add_header 'Location' "$1"
	send_response "$code"
}
export -f send_redirect

# Internal: Resolve the given path and check that it stays in the authorized directory.
#
# **Note:** this method is used by `send_file()` and `run_script()` and shouldn't be called
# manually.
#
# Takes the authorized directory (relative to `SHERVER_ROOT`) and the path to resolve. The
# path is canonicalized, so neither `..` nor a symlink can be used to escape the directory.
#
# The result is stored in `_RESOLVED_PATH` instead of being echoed, because this function
# exits on error: in a command substitution, the error page would be captured by the caller
# instead of being sent to the client.
#
# Sends a 404 if the path is absolute, doesn't exist, or lands outside the authorized
# directory. We purposely don't use 403 to avoid leak of the File System
#
# $1 - authorized directory, relative to `SHERVER_ROOT` (`file` or `scripts`)
# $2 - path to resolve, relative to the current directory (an absolute path is refused)
#
# Examples
#
#    _resolve_path 'file' '../file/pages/page.html'
#
# will result in (assuming `SHERVER_ROOT` is `/home/sherver/sherver`)
#
#    _RESOLVED_PATH='/home/sherver/sherver/file/pages/page.html'
function _resolve_path()
{
	local authorized
	if [[ ! -d $SHERVER_ROOT/$1 ]]; then
		log "MISCONFIGURED: '$SHERVER_ROOT/$1' is not a directory"
		send_error 500
	fi
	if ! authorized=$(realpath "$SHERVER_ROOT/$1"); then
		log "MISCONFIGURED: realpath failed on '$SHERVER_ROOT/$1'"
		send_error 500
	fi
	# the contract is a relative path: an absolute one only ever comes from a `//x` URL,
	# which the `./` below would otherwise turn into a live alias of `/x`
	if [[ $2 == /* ]]; then
		log "FORBIDDEN: absolute path '$2'"
		send_error 404
	fi
	# `./` because the URL can start with a dash and busybox realpath, having no options at
	# all, has no `--` either to stop it being read as one
	local -r target="./$2"
	# and no `-e` either: busybox realpath happily resolves a missing last component
	if [[ ! -e $target ]] || ! _RESOLVED_PATH=$(realpath "$target" 2>/dev/null); then
		log "NOT FOUND: realpath - '$2'"
		send_error 404
	fi
	if [[ $_RESOLVED_PATH != "$authorized"/* ]]; then
		log "FORBIDDEN: '$2' resolves to '$_RESOLVED_PATH', outside of '$authorized'"
		send_error 404 # not 403 to avoid leak of the FS
	fi
}
export -f _resolve_path

# Internal: Print the mime type of the given file, deduced from its extension.
#
# **Note:** this method is used by `send_file()` and shouldn't be called manually.
#
# The type comes from a static table, the way nginx and Apache do it: for a static file
# server the extension is the authoritative signal.
#
# An unknown or missing extension gives `application/octet-stream`, so that the browser
# downloads the file instead of guessing how to render it. Since we own everything under
# `file/`, that case means the table is missing an entry: it is logged.
#
# `text/*` types carry `; charset=utf-8`. The others don't: `application/json` and the
# image types have no charset parameter.
#
# $1 - the path to the file to inspect
#
# Examples
#
#    _get_mimetype '/home/sherver/sherver/file/beautiful.png'
#
# will print
#
#    image/png
function _get_mimetype()
{
	local -rA MIME_TYPES=(
		['css']='text/css; charset=utf-8'
		['csv']='text/csv; charset=utf-8'
		['htm']='text/html; charset=utf-8'
		['html']='text/html; charset=utf-8'
		['ics']='text/calendar; charset=utf-8'
		['js']='text/javascript; charset=utf-8'
		['md']='text/markdown; charset=utf-8'
		['mjs']='text/javascript; charset=utf-8'
		['txt']='text/plain; charset=utf-8'
		['vtt']='text/vtt; charset=utf-8'
		['atom']='application/atom+xml'
		['json']='application/json'
		['jsonld']='application/ld+json'
		['map']='application/json'
		['pdf']='application/pdf'
		['rss']='application/rss+xml'
		['srt']='application/x-subrip'
		['toml']='application/toml'
		['wasm']='application/wasm'
		['webmanifest']='application/manifest+json'
		['xhtml']='application/xhtml+xml'
		['xml']='application/xml'
		['yaml']='application/yaml'
		['yml']='application/yaml'
		['docx']='application/vnd.openxmlformats-officedocument.wordprocessingml.document'
		['epub']='application/epub+zip'
		['odp']='application/vnd.oasis.opendocument.presentation'
		['ods']='application/vnd.oasis.opendocument.spreadsheet'
		['odt']='application/vnd.oasis.opendocument.text'
		['pptx']='application/vnd.openxmlformats-officedocument.presentationml.presentation'
		['rtf']='application/rtf'
		['xlsx']='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
		['7z']='application/x-7z-compressed'
		['bz2']='application/x-bzip2'
		['deb']='application/vnd.debian.binary-package'
		['gz']='application/gzip'
		['rar']='application/vnd.rar'
		['rpm']='application/x-rpm'
		['tar']='application/x-tar'
		['tgz']='application/gzip'
		['xz']='application/x-xz'
		['zip']='application/zip'
		['zst']='application/zstd'
		# explicit, so that a deliberately opaque download doesn't log a missing entry
		['bin']='application/octet-stream'
		['apng']='image/apng'
		['avif']='image/avif'
		['bmp']='image/bmp'
		['gif']='image/gif'
		['heic']='image/heic'
		['heif']='image/heif'
		['ico']='image/vnd.microsoft.icon'
		['jpeg']='image/jpeg'
		['jpg']='image/jpeg'
		['jxl']='image/jxl'
		['png']='image/png'
		['svg']='image/svg+xml'
		['tif']='image/tiff'
		['tiff']='image/tiff'
		['webp']='image/webp'
		['otf']='font/otf'
		['ttc']='font/collection'
		['ttf']='font/ttf'
		['woff']='font/woff'
		['woff2']='font/woff2'
		['aac']='audio/aac'
		['flac']='audio/flac'
		['m4a']='audio/mp4'
		['mp3']='audio/mpeg'
		['oga']='audio/ogg'
		['ogg']='audio/ogg'
		['opus']='audio/ogg'
		['wav']='audio/wav'
		['weba']='audio/webm'
		['3gp']='video/3gpp'
		['avi']='video/x-msvideo'
		['m4v']='video/mp4'
		['mkv']='video/x-matroska'
		['mov']='video/quicktime'
		['mp4']='video/mp4'
		['mpeg']='video/mpeg'
		['mpg']='video/mpeg'
		['ogv']='video/ogg'
		['webm']='video/webm'
	)

	# the basename first: a dot in a parent directory is not an extension
	local -r name="${1##*/}"
	local ext="${name##*.}"
	# no dot at all: the expansion above gave back the whole name
	[ "$ext" != "$name" ] || ext=''
	ext="${ext,,}"

	if [ ! -v "MIME_TYPES[$ext]" ]; then
		log "unknown extension '$ext' for '$1', serving it as application/octet-stream"
		printf '%s\n' 'application/octet-stream'
		return 0
	fi
	printf '%s\n' "${MIME_TYPES[$ext]}"
}
export -f _get_mimetype

# Public: Try to send the given file, or fail with 404.
#
# Takes the path to the file to send as a parameter.
#
# It will automatically create a valid HTTP response that will stream the content
# of the file, with the correct mime type and all. If the file doesn't exist, or
# if the file is outside of `file/`, send a 404 error.
#
# Every answer carries two cache validators: an `ETag` built from the size and mtime
# of the file, and its `Last-Modified` date. A conditional request that matches one
# of them (`If-None-Match` first, `If-Modified-Since` only when no usable ETag was sent)
# is answered with a bodyless `304 Not Modified`. An `If-None-Match` of `*` matches too.
#
# Only a GET or a HEAD is answered that way: a 304 to a POST would leave the client
# without a representation of what it just sent.
#
# Every answer also announces `Accept-Ranges: bytes`, and a GET carrying a single byte
# range (`Range: bytes=0-499`, `bytes=500-`, `bytes=-500`) is answered with a
# `206 Partial Content` and the matching `Content-Range` — what `<video>` seeking needs.
# A range starting past the end of the file is a `416 Range Not Satisfiable`. Every
# other form — several ranges, another unit, garbage — is ignored and the whole file is
# served, as RFC 9110 §14.2 allows; so is the whole header when an `If-Range` is present
# and is not exactly the current ETag.
#
# The path generally comes from the URL (`URL_BASE`). You just need to remove the first
# `/` to get a relative path.
#
# *Note* that to find the correct mimetype, we use `_get_mimetype()`, which deduces it from
# the extension of the file.
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
#    HTTP/1.1 200 OK
#    Content-Type: image/png
#    Content-Length: 4096
function send_file()
{
	_resolve_path 'file' "$1"
	local -r file="$_RESOLVED_PATH"
	# existence is already guaranteed by `_resolve_path`
	if [ ! -f "$file" ] || [ ! -r "$file" ]; then
		send_error 404
	fi

	# one `stat` for the three headers below: read twice, it can straddle a file being
	# replaced and pair the size of one version with the validators of another. Assigned
	# through `if`, because a plain assignment returns the failure to `set -e`, which would
	# abort the dispatcher here — before `_send_header`, so the client would get zero bytes
	local stats
	if ! stats=$(stat -c '%s %Y' "$file" 2>/dev/null); then
		log "NOT FOUND: stat - '$file' went away while it was being answered"
		send_error 404
	fi
	local -r size="${stats% *}" mtime="${stats#* }"
	# two cache validators: ETag for the HTTP/1.1 clients, Last-Modified for the HTTP/1.0
	# ones — `wget -N` works off the latter alone. Set before the checks, so a 304 has both
	local -r etag="\"$size-$mtime\""
	# the bash builtin gives the same string as `date -uR -r` without the fork, and without
	# a `date` that knows `-r` to depend on. Both prefixes matter: `LC_ALL` keeps the day
	# and month abbreviations English, which is what RFC 7231 asks for
	local last_modified
	TZ=UTC0 LC_ALL=C printf -v last_modified '%(%a, %d %b %Y %H:%M:%S)T GMT' "$mtime"
	add_header 'ETag' "$etag"
	add_header 'Last-Modified' "$last_modified"
	# if client already cached it, we don't resend it. When both validators come in,
	# If-None-Match alone decides (RFC 7232): a stale date must not override the ETag.
	# Exact string match for both: a client we can't recognize just gets the full answer.
	# GET and HEAD only: a 304 answers a POST with no representation for what it just sent
	if [ "$REQUEST_METHOD" != 'POST' ]; then
		# an empty value is no validator at all: it must not swallow the date below
		local -r if_none_match="${REQUEST_HEADERS['if-none-match']:-}"
		if [ -n "$if_none_match" ]; then
			# `*` is the RFC 7232 wildcard: it matches the file whatever our ETag is
			if [ "$if_none_match" = "$etag" ] || [ "$if_none_match" = '*' ]; then
				send_response 304
			fi
		elif [ "${REQUEST_HEADERS['if-modified-since']:-}" = "$last_modified" ]; then
			send_response 304
		fi
	fi
	# HTTP header
	local content_type
	content_type=$(_get_mimetype "$file")
	add_header 'Content-Type'   "$content_type";
	# on the 200s as much as the 206s: this is what tells a video player seeking works
	add_header 'Accept-Ranges' 'bytes'
	# single byte range, on GET only (RFC 9110 §14.2 lets a HEAD ignore Range, and it keeps
	# the full-size headers meaningful). `first` stays -1 unless a satisfiable range lands
	local -i first=-1 last=-1
	# anything unparseable — several ranges, another unit, garbage, a number too long for
	# bash's 64-bit arithmetic — falls through to the full 200: §14.2 allows ignoring the
	# header wholesale, so the full answer is always a correct one, never an error
	# each number is captured twice: the outer group makes it optional, the inner one holds it
	# without its leading zeros, so the 18-digit cap measures its magnitude and not its padding
	if [ "$REQUEST_METHOD" = 'GET' ] \
			&& [[ "${REQUEST_HEADERS['range']:-}" =~ ^bytes=(0*([[:digit:]]+))?-(0*([[:digit:]]+))?$ ]] \
			&& [ -n "${BASH_REMATCH[2]}${BASH_REMATCH[4]}" ] \
			&& [ "${#BASH_REMATCH[2]}" -le 18 ] && [ "${#BASH_REMATCH[4]}" -le 18 ]; then
		# the regex already dropped the zeros, so `10#` is only a belt-and-braces base-ten
		# pin: without it a padded value would read as octal, and `bytes=08-` would die
		local -r from="${BASH_REMATCH[2]:+$(( 10#${BASH_REMATCH[2]} ))}"
		local -r to="${BASH_REMATCH[4]:+$(( 10#${BASH_REMATCH[4]} ))}"
		# a stale If-Range means the client's copy changed under it: it needs the whole
		# file, not a piece of the new one. Exact string match, like the validators above
		local -r if_range="${REQUEST_HEADERS['if-range']:-}"
		if [ -z "$if_range" ] || [ "$if_range" = "$etag" ]; then
			if [ -z "$from" ]; then
				# `-N` is the last N bytes, the whole file when N overshoots it
				if [ "$to" -gt 0 ] && [ "$size" -gt 0 ]; then
					first=$(( size > to ? size - to : 0 ))
					last=$(( size - 1 ))
				else
					# the last zero bytes, or any tail of an empty file, selects nothing
					# (RFC 9110 §14.1.2); §15.3.7 wants the full size in the answer
					add_header 'Content-Range' "bytes */$size"
					send_error 416
				fi
			elif [ -n "$to" ] && [ "$from" -gt "$to" ]; then
				: # first past last is no range at all: ignored, the 200 below answers
			elif [ "$from" -ge "$size" ]; then
				# the one unsatisfiable int-range form: it starts past the end
				add_header 'Content-Range' "bytes */$size"
				send_error 416
			else
				first="$from"
				# an open or overshooting end stops where the file does (RFC 9110 §14.1.2)
				if [ -z "$to" ] || [ "$to" -ge "$size" ]; then
					last=$(( size - 1 ))
				else
					last="$to"
				fi
			fi
		fi
	fi
	if [ "$first" -ge 0 ]; then
		local -ri length=$(( last - first + 1 ))
		add_header 'Content-Range' "bytes $first-$last/$size"
		add_header 'Content-Length' "$length"
		_send_header 206
		# no `pipefail` here, so `tail` dying of SIGPIPE once `head` has enough is inert
		tail -c "+$(( first + 1 ))" -- "$file" | head -c "$length"
	else
		add_header 'Content-Length' "$size"
		_send_header 200
		# response
		if [ "$REQUEST_METHOD" != 'HEAD' ]; then
			cat "$file"
		fi
	fi
	log_debug '================================================'
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
# It will simply run the script if possible. If not, send a 404. If the script is outside
# of `scripts/`, send a 404. If the script fails, send a 500.
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
	local -r url="${1:-$REQUEST_URL}"
	parse_url "$url"
	_resolve_path 'scripts' "${URL_BASE:1}"
	local -r script="$_RESOLVED_PATH"
	# existence is already guaranteed by `_resolve_path`
	if [ ! -f "$script" ] || [ ! -x "$script" ]; then
		send_error 404
	fi

	"$script" "$url" || send_error 500
}
export -f run_script

# Internal: Log a request parse failure, dump the request when relevant, and answer an error.
#
# **Note:** this method is used by `_read_request_line()` and `_read_request_headers()` and
# shouldn't be called manually.
#
# Owns the bail-out invariant of `read_request()`: the request is dumped on the first parse
# only (a child script re-parse would dump it once per script), the reason is always
# `log`ged, and `send_error()` ends the process — this function never returns. Only for the
# bail-outs *before* the end of the header loop: after that point, the first parse has
# already dumped the full request unconditionally, and this would dump it a second time —
# which is why `_read_request_body()` calls `send_error()` directly.
#
# $1 - the HTTP error code, one of the keys of `HTTP_RESPONSE`
# $2 - the reason, `log`ged as is
# $3 - true when parsing from the standard input, false in a child script re-parse
#
# Examples
#
#    _bail_request 400 'BAD REQUEST: malformed request line' true
function _bail_request()
{
	if [ "$3" = true ]; then
		log_debug "$REQUEST_FULL_STRING"
	fi
	log "$2"
	send_error "$1"
}
export -f _bail_request

# Internal: Read and validate the request line, and parse the URL.
#
# **Note:** this method is used by `read_request()` and shouldn't be called manually.
#
# Reads the first line of the input stream and fills `REQUEST_METHOD`, `REQUEST_URL` and
# `REQUEST_HTTP_VERSION` — plus `URL_BASE` and `URL_PARAMETERS` through `parse_url()`.
# `REQUEST_FULL_STRING` starts here, with the raw line.
#
# An absolute-form request target (`GET http://host/path`, RFC 9112 §3.2.2) is rewritten to
# the path it points at, and its authority — validated first — is stored in
# `_REQUEST_AUTHORITY` for `_read_request_headers()` to apply. Any other target that is not
# a path is refused with a 400, the asterisk form of `OPTIONS` excepted.
#
# $1 - true when parsing from the standard input, false when re-parsing, see `read_request()`
#
# Examples
#
#    _read_request_line true
function _read_request_line()
{
	local line
	# this bail-out and the 414 below stay outside `_bail_request`: `REQUEST_FULL_STRING`
	# is not filled yet, so its debug dump would be empty
	if ! read -r line; then
		log 'BAD REQUEST: empty request'
		send_error 400
	fi
	# checked before we touch the string: `send_error` runs `cat`, which fails just the same
	# once the environment is too big, and the suffix strip below is quadratic in bash
	if [ "${#line}" -gt "$MAX_HEADERS_SIZE" ]; then
		log "TOO LARGE: request line over the $MAX_HEADERS_SIZE characters limit"
		send_error 414
	fi
	line=${line%%$'\r'}
	REQUEST_FULL_STRING="$line"

	# read URL
	read -r REQUEST_METHOD REQUEST_URL REQUEST_HTTP_VERSION <<< "$line"
	_REQUEST_TARGET="$REQUEST_URL"	# saved before the rewrite below, for the access log
	# `read` collapses SP/TAB runs and drops trailing blanks (a leniency RFC 9112 §3 grants),
	# so only non-whitespace extra tokens get glued into the version and rejected here.
	if [ -z "$REQUEST_METHOD" ] || [ -z "$REQUEST_URL" ] \
			|| [[ ! "$REQUEST_HTTP_VERSION" =~ ^HTTP/[[:digit:]]\.[[:digit:]]$ ]]; then
		_bail_request 400 'BAD REQUEST: malformed request line' "$1"
	fi
	# a literal `HTTP/0.9` token means the client speaks the 1.x line format (real 0.9 has no
	# version token and took the 400 above), so a headered 505 is safe here (RFC 9112 §2.3)
	if [[ "$REQUEST_HTTP_VERSION" != HTTP/1.* ]]; then
		_bail_request 505 "UNSUPPORTED VERSION: '$REQUEST_HTTP_VERSION'" "$1"
	fi
	# RFC 9112 §3: a method is a token (RFC 9110 §5.6.2 tchar), so a stray octet in it is a
	# malformed request line — a 400 — where a well-formed unknown method is a 501 below
	if [[ ! "$REQUEST_METHOD" =~ $_HTTP_TOKEN_REGEX ]]; then
		_bail_request 400 "BAD REQUEST: invalid method token '$REQUEST_METHOD'" "$1"
	fi
	# Membership test and not a `case` pattern: a variable expanded into a pattern has its
	# `|` taken literally, which would silently match nothing. Exact because the tchar check
	# above keeps the `,` delimiter out of the method, so it cannot span two list entries.
	# Method names are case sensitive (RFC 9110 §9.1): a lowercase `get` is not a GET
	if [[ ",${SUPPORTED_METHODS// /}," != *",$REQUEST_METHOD,"* ]]; then
		case "$REQUEST_METHOD" in
			# a method we know but don't serve: 405 MUST carry `Allow` (RFC 9110 §15.5.6)
			PUT|DELETE|PATCH|TRACE|CONNECT)
				add_header 'Allow' "$SUPPORTED_METHODS"
				_bail_request 405 "METHOD NOT ALLOWED: '$REQUEST_METHOD'" "$1"
				;;
			# a method we don't know at all is a 501, not a 405 (RFC 9110 §9.1)
			*)
				_bail_request 501 "METHOD NOT IMPLEMENTED: '$REQUEST_METHOD'" "$1"
				;;
		esac
	fi
	# RFC 9112 §3.2.2: the absolute-form target a proxy sends MUST be accepted. Rewritten to
	# the origin form here, before anything reads the URL, so that `parse_url`,
	# `_resolve_path` and the child scripts only ever see a path. Only the scheme is case
	# insensitive (RFC 3986 §3.1), so everything is cut out of the original
	if [[ "${REQUEST_URL,,}" =~ ^https?:// ]]; then
		# a fragment is no part of a request-target (RFC 9112 §3.2), so it is cut off
		# here rather than glued back onto the path
		local -r target="${REQUEST_URL%%#*}"
		# the authority ends at the first `/` or `?` (RFC 3986 §3.2), and what follows it
		# keeps its own delimiter — cutting on `/` alone would eat a `?query`
		local rest="${target#*://}"
		_REQUEST_AUTHORITY="${rest%%[/?]*}"
		rest="${rest:${#_REQUEST_AUTHORITY}}"
		# RFC 9110 §4.2: an empty host — bare or in front of a `:port` — is invalid in an
		# http(s) URI and userinfo is an error — and nothing downstream `_check_encoding`s
		# what lands in `Host` here
		if [ -z "${_REQUEST_AUTHORITY%%:*}" ] || [[ "$_REQUEST_AUTHORITY" == *@* ]] \
				|| ! _check_encoding "$_REQUEST_AUTHORITY"; then
			_bail_request 400 "BAD REQUEST: invalid authority in '$REQUEST_URL'" "$1"
		fi
		REQUEST_URL="/${rest#/}"	# an absolute URI needs no path, and no path is the root
	fi
	# RFC 9112 §3.2: past the rewrite the target must be a path — the asterisk form, that
	# only `OPTIONS` may use, is the one exception. Nothing else may reach the routing
	if [[ "$REQUEST_URL" != /* ]] && [ "$REQUEST_METHOD $REQUEST_URL" != 'OPTIONS *' ]; then
		_bail_request 400 "BAD REQUEST: unsupported request target '$REQUEST_URL'" "$1"
	fi
	# `parse_url` decodes the URL, so a broken encoding can't be answered
	if ! _check_encoding "$REQUEST_URL"; then
		_bail_request 400 "BAD REQUEST: invalid percent encoding in '$REQUEST_URL'" "$1"
	fi
	# fill URL_*
	parse_url "$REQUEST_URL"
}
export -f _read_request_line

# Internal: Read the header lines and fill `REQUEST_HEADERS`.
#
# **Note:** this method is used by `read_request()` and shouldn't be called manually.
#
# Reads the input stream up to the empty line that ends the headers, appending each line to
# `REQUEST_FULL_STRING` on the way.
#
# A header line is refused with a 400 when it is folded (obs-fold), has no colon, or has a
# name that is not a token — whitespace before the colon included (RFC 9112 §5, §5.1, §5.2).
# A repeated header becomes the `v1, v2` list of RFC 9110 §5.2 — except `Cookie`, whose
# pairs recombine on `; ` (RFC 9113 §8.2.3) — but a repeated `Host`, `Content-Length` or
# `Content-Type` with two different values is a 400: they frame the request, and none of
# the three is a list. A repeated `Host` is ignored instead, without being compared, when
# the request-target already carried an authority.
#
# Once the loop is done, the `_REQUEST_AUTHORITY` of an absolute-form target replaces
# `REQUEST_HEADERS['host']` (RFC 9112 §3.2.2), and any other HTTP/1.1+ request without a
# `Host` header is refused with a 400.
#
# $1 - true when parsing from the standard input, false when re-parsing, see `read_request()`
#
# Examples
#
#    _read_request_headers true
function _read_request_headers()
{
	local line key name value separator
	# `IFS=` is load-bearing: the default one strips the leading SP/HTAB of a line, so the
	# obs-fold check below could never fire and a continuation carrying a colon would be
	# de-folded into a header of its own — and a whitespace-only line would collapse to the
	# empty string and `break` the loop, dropping every header behind it
	while IFS= read -r line; do
		# checked first, for the same reasons as the request line
		if [ $(( ${#REQUEST_FULL_STRING} + ${#line} + 1 )) -gt "$MAX_HEADERS_SIZE" ]; then
			_bail_request 431 "TOO LARGE: headers over the $MAX_HEADERS_SIZE characters limit" "$1"
		fi
		line=${line%%$'\r'}
		# reached the end of the headers, break.
		if [ -z "$line" ]; then
			break
		fi
		REQUEST_FULL_STRING="$REQUEST_FULL_STRING
$line"
		# RFC 9112 §5.2: a line starting with whitespace is an obs-fold continuation, which a
		# server must reject or splice. Rejecting is the honest half — spliced, it would have
		# to be re-split here and re-folded in `REQUEST_FULL_STRING` for the child re-parse
		if [[ "$line" == [[:space:]]* ]]; then
			_bail_request 400 'BAD REQUEST: obsolete line folding in the headers' "$1"
		fi
		key="${line%%:*}"	# cut out of the raw line: the `read` below eats what we refuse
		# RFC 9112 §5: a field line is `name ":" OWS value OWS`, so with no colon there is no
		# field at all — and a bare `Host` line used to satisfy the presence check below
		if [ "$key" = "$line" ]; then
			_bail_request 400 "BAD REQUEST: header line without a colon: '$line'" "$1"
		fi
		# a field name is a token (RFC 9110 §5.6.2), so this one test covers the whitespace
		# before the colon that RFC 9112 §5.1 MUSTs out (a request smuggling vector: a proxy
		# that trimmed it instead would forward a header we never saw), the empty name that is
		# a fatal `bad array subscript`, and any stray octet
		if [[ ! "$key" =~ $_HTTP_TOKEN_REGEX ]]; then
			_bail_request 400 "BAD REQUEST: invalid header name '$key'" "$1"
		fi
		name="${key,,}"	# header names are case insensitive
		IFS=$' \t' read -r value <<< "${line#*:}"	# strips the OWS, and only the OWS
		# the subscripts are quoted throughout: a field name may legally be `*`, and unquoted
		# that one would read as every element of the array. `[[` and never `[`: the latter
		# re-expands the subscript it is handed, so a name holding a backquote or a `$` — both
		# of them tchar — would run a command, or abort the whole dispatcher under `set -u`
		if [[ ! -v REQUEST_HEADERS["$name"] ]]; then
			REQUEST_HEADERS["$name"]="$value"
		else
			case "$name" in
				host|content-length|content-type)
					# RFC 9112 §3.2.2: with an absolute-form target its authority wins and
					# every `Host` line MUST be ignored, so two conflicting ones are no
					# ambiguity to refuse here
					if [ "$name" = 'host' ] && [ -n "$_REQUEST_AUTHORITY" ]; then
						continue
					fi
					# none of those three is a list: two `Host` values make the target
					# ambiguous (RFC 9112 §3.2), two `Content-Length` values the body framing
					# (§6.3) — the request smuggling pair — and two `Content-Type` values the
					# body parse, where `_read_request_body` cuts the merged list back at its
					# first `;` and would read one media type out of two. Repeated identical
					# values are unambiguous, they pass
					if [ "${REQUEST_HEADERS["$name"]}" != "$value" ]; then
						_bail_request 400 "BAD REQUEST: conflicting '$key' headers" "$1"
					fi
					continue	# never merged: an identical repeat collapses into the stored value
					;;
				cookie)
					# RFC 6265 §5.4 forbids repeating `Cookie`, but RFC 9113 §8.2.3 lets an
					# HTTP/2 hop split it — and it recombines on `; `, never on a comma
					separator='; '
					;;
				*)
					# RFC 9110 §5.2: a repeated field is the comma-separated list it stands
					# for. Overwriting instead would drop what the client sent, and a header
					# we compare as a whole (`If-None-Match`...) degrades to a full answer
					separator=', '
					;;
			esac
			# an empty element is ignorable anyway (RFC 9110 §5.6.1), so it never enters the
			# list: a stored empty value is replaced, an incoming empty value is dropped
			if [ -z "${REQUEST_HEADERS["$name"]}" ]; then
				REQUEST_HEADERS["$name"]="$value"
			elif [ -n "$value" ]; then
				REQUEST_HEADERS["$name"]="${REQUEST_HEADERS["$name"]}$separator$value"
			fi
		fi
	done
	if [ "$1" = true ]; then
		log_debug "$REQUEST_FULL_STRING"
	fi
	# RFC 9112 §3.2.2: with an absolute-form target, its authority wins and the `Host` header
	# MUST be ignored. Done here and not with the rewrite in `_read_request_line()`, where
	# the header loop would then let a `Host:` line overwrite it and invert the MUST
	if [ -n "$_REQUEST_AUTHORITY" ]; then
		REQUEST_HEADERS['host']="$_REQUEST_AUTHORITY"
	fi
	# RFC 9112: §3.2 requires Host on 1.1, and §2.3 processes a higher 1.x minor as 1.1, so
	# only 1.0 is exempt. Presence only: the value is unused, the same tree being served
	# whatever the authority — the header loop above is what makes it unambiguous
	if [ "$REQUEST_HTTP_VERSION" != 'HTTP/1.0' ] && [ ! -v "REQUEST_HEADERS['host']" ]; then
		log "BAD REQUEST: $REQUEST_HTTP_VERSION request without a Host header"
		send_error 400
	fi
}
export -f _read_request_headers

# Internal: Discard what may still arrive of a request body before an error answer.
#
# **Note:** this method is used by `_read_request_body()` and shouldn't be called manually.
#
# Refusing a request whose body is still in flight and exiting leaves unread bytes in the
# socket, and closing over them is a TCP reset that can destroy the error page before the
# client reads it. This is the lingering close of every real server, bounded both ways so
# a client can't pin the process: at most 64 kio are discarded, and a stalled stream is
# waited on for one 0.2 s timeout. A client blasting past the cap may still see the reset.
#
# Examples
#
#    _drain_request_input
#    send_error 413
function _drain_request_input()
{
	local -i i
	local _discard
	for (( i = 0; i < 16; i++ )); do
		# `-N` so a newline doesn't end a read early, C locale so it counts bytes
		if ! IFS= LC_ALL=C read -r -t 0.2 -N 4096 _discard; then
			break
		fi
	done
}
export -f _drain_request_input

# Internal: Read the body of a POST and fill `REQUEST_BODY` and `REQUEST_BODY_PARAMETERS`.
#
# **Note:** this method is used by `read_request()` and shouldn't be called manually.
#
# A `Transfer-Encoding` is inspected first, on any method: next to a `Content-Length` it
# is the request smuggling pair of RFC 9112 §6.3, a `400` on presence alone. A lone
# `chunked` is the only value even recognized, and it is refused too — not decoded — with
# the `411` the same section sanctions; any other value gets the `400` it MUSTs for a
# non-final chunked, since no coding will ever be decoded here there is no `501` worth
# telling apart. An emptied value is no coding at all (RFC 9110 §5.6.1, the header
# merge's own rule) and the request goes on bodyless. Past that gate, nothing is read
# unless the request is a POST carrying a `Content-Length`. The length is checked against
# `MAX_BODY_SIZE` before it is trusted, and the body lands in `REQUEST_FULL_STRING` too.
#
# A body of type `application/x-www-form-urlencoded` is decoded into
# `REQUEST_BODY_PARAMETERS`.
#
# No `_bail_request` here: every bail-out below sits after the header loop, which has
# already dumped the full request, so `send_error()` is called directly.
#
# Examples
#
#    _read_request_body
function _read_request_body()
{
	if [ -v "REQUEST_HEADERS['transfer-encoding']" ]; then
		# the TE + CL pair RFC 9112 §6.3 bans is a 400 on presence alone, emptied or not:
		# the header's presence is what a downstream parser may frame on
		if [ -v "REQUEST_HEADERS['content-length']" ]; then
			log 'BAD REQUEST: both Transfer-Encoding and Content-Length'
			_drain_request_input
			send_error 400
		fi
		local -r te_value="${REQUEST_HEADERS['transfer-encoding']}"
		# a lone chunked — coding names are case insensitive — is the only value even
		# recognized, and it is refused too, not decoded, with the 411 §6.3 sanctions
		if [ "${te_value,,}" = 'chunked' ]; then
			log 'LENGTH REQUIRED: chunked Transfer-Encoding is not decoded'
			_drain_request_input
			send_error 411
		# any other value is the 400 §6.3 MUSTs for a non-final chunked — no coding will
		# ever be decoded here, so there is no 501 worth telling apart — while an emptied
		# one names no coding at all (RFC 9110 §5.6.1) and the request goes on bodyless
		elif [ -n "$te_value" ]; then
			log "BAD REQUEST: unsupported Transfer-Encoding '$te_value'"
			_drain_request_input
			send_error 400
		fi
	fi
	if [ "$REQUEST_METHOD" != 'POST' ] || [ ! -v "REQUEST_HEADERS['content-length']" ]; then
		return 0
	fi
	local -r raw_length="${REQUEST_HEADERS['content-length']}"
	# a bogus length makes `read` fail with a bash error, and a huge one makes it wait
	# for bytes that will never come, so we check it before using it
	if [[ ! $raw_length =~ ^0*([[:digit:]]+)$ ]]; then
		log "BAD REQUEST: invalid Content-Length '$raw_length'"
		_drain_request_input
		send_error 400
	fi
	# the group drops the leading zeros `1*DIGIT` allows, so the cap below measures the
	# magnitude and not the padding — same rule as the Range parser
	local -r length="${BASH_REMATCH[1]}"
	# outside `test`'s integer range, `-gt` errors out and counts as false, which would
	# silently skip the limit. 10 digits is far above the limit anyway
	if [ "${#length}" -gt 10 ] || [ "$length" -gt "$MAX_BODY_SIZE" ]; then
		log "TOO LARGE: Content-Length '$length' over the $MAX_BODY_SIZE bytes limit"
		_drain_request_input
		send_error 413
	fi
	# `Content-Length` counts bytes, but `-N` counts characters: in a UTF-8 locale a
	# multibyte body would make us wait for characters the client never sends
	local line
	if ! LC_ALL=C read -rN "$length" line; then
		send_error 400
	fi
	REQUEST_FULL_STRING="$REQUEST_FULL_STRING

$line"
	REQUEST_BODY="$line"
	# if content is of type "application/x-www-form-urlencoded", we parse it.
	# a media type is case insensitive and can carry parameters, like `;charset=UTF-8`
	local media_type="${REQUEST_HEADERS['content-type']:-}"
	media_type="${media_type%%;*}"
	media_type="${media_type//[[:space:]]/}"
	if [ "${media_type,,}" = 'application/x-www-form-urlencoded' ]; then
		if ! _check_encoding "$REQUEST_BODY"; then
			log 'BAD REQUEST: invalid percent encoding in the body'
			send_error 400
		fi
		_parse_parameters "$REQUEST_BODY" 'REQUEST_BODY_PARAMETERS'
	fi
}
export -f _read_request_body

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
# The work happens in `_read_request_line()`, `_read_request_headers()` and
# `_read_request_body()`, which read the same input stream and must run in this order, in
# the current shell: a subshell or a command substitution would keep the variables — and
# the error page of a bail-out — to itself.
#
# *Note* that this method is highly inspired by [bashttpd](https://github.com/avleen/bashttpd)
#
# $1 - true when parsing from the standard input, false when re-parsing
#      `REQUEST_FULL_STRING` in a child script. Only the first parse logs the request, so
#      that a request is not dumped once per script it goes through
function read_request()
{
	_read_request_line "$1"
	_read_request_headers "$1"
	_read_request_body
}
export -f read_request
