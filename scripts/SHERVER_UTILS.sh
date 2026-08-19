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
	# Public: The method of the request (GET, HEAD, POST...)
	declare -g REQUEST_METHOD=''
	# Public: The requested URL
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
		[Connection]='close'
		[X-Content-Type-Options]='nosniff'
		[Cache-Control]='private, max-age=60'
		#[Cache-Control]='private, max-age=0, no-cache, no-store, must-revalidate'
	)
	# Public: Generic HTTP response code with their meaning (associative array)
	declare -rAg HTTP_RESPONSE=(
		[200]='OK'
		[301]='Moved Permanently'
		[302]='Found'
		[304]='Not Modified'
		[400]='Bad Request'
		[403]='Forbidden'
		[404]='Not Found'
		[405]='Method Not Allowed'
		[413]='Content Too Large'
		[414]='URI Too Long'
		[431]='Request Header Fields Too Large'
		[500]='Internal Server Error'
		[505]='HTTP Version Not Supported'
	)
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
	# Internal: canonical path computed by `_resolve_path()`
	declare -g RESOLVED_PATH=''
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
	_url_decode URL_BASE "$URL_BASE"
	# now split parameters
	# first, split `key=value` in an array
	local -a fields
	IFS='&' read -ra fields <<< "$parameters"
	# now we fill URL_PARAMETERS
	# keep in sync with the twin loop in `read_request`, which decodes an urlencoded body
	local key value
	local -i i
	for (( i=0; i < ${#fields[@]}; i++ )); do
		IFS='=' read -r key value <<< "${fields[i]}"
		# an empty key is a fatal `bad array subscript`, and carries no information anyway
		if [ -z "$key" ]; then
			continue
		fi
		# `+` is a space in a query string, but stays a `+` in the path above
		_url_decode key "${key//+/ }"
		_url_decode value "${value//+/ }"
		# read by the child scripts, which shellcheck can't see from here
		# shellcheck disable=SC2034
		URL_PARAMETERS["$key"]="$value"
	done
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
#    Expires: Thu, 04 Jul 2019 21:38:23 GMT
function _send_header()
{
	# the access log: the only line a quiet server writes for a request it served. socat's
	# EXEC sets the peer address; a `-` means no socat in front, like the filter-driven
	# tests. A request too broken to have a method is answered before those variables are filled
	log "${SOCAT_PEERADDR:--} ${REQUEST_METHOD:--} ${REQUEST_URL:--} $1"
	# HTTP header
	log_debug "> HTTP/1.1 $1 ${HTTP_RESPONSE[$1]}"
	# `printf`, not `echo -e`: a header value holding a literal `\r\n` would be turned into a
	# real CRLF and inject a header of its own
	printf 'HTTP/1.1 %s %s\r\n' "$1" "${HTTP_RESPONSE[$1]}"
	# Date
	local datenow
	datenow=$(date -uR)
	datenow=${datenow/%+0000/GMT}
	add_header 'Date' "$datenow"
	add_header 'Expires' "$datenow"
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
# $1 - the error code, see `HTTP_RESPONSE`
#
# Examples
#
#    send_errors 404
#
# will create an answer that starts with
#
#    HTTP/1.1 404 Not Found
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
	send_response "$@" "$html"
}
export -f send_error

# Public: Send a redirect to the given URL as an answer.
#
# Takes the target URL, and optionally the response code: 302 (the default) for a
# temporary redirect, 301 for a permanent one — the two redirects `HTTP_RESPONSE` knows.
# Anything else is refused with a 500: `send_response` would die expanding an unknown
# code mid-answer, and the client would get nothing at all.
#
# The typical use is POST-redirect-GET, so that a refresh doesn't resubmit the form.
#
# A target holding a CR or a LF is refused with a 500 the same way: it would split the
# Location header in two. The rest is the caller's business — a target built from the request
# is an open redirect unless the script checks it, and a full URL is legitimate here, so the
# library cannot tell the wanted ones from the others.
#
# Like the other `send_*` functions, it exits: nothing after it runs.
#
# $1 - the URL to redirect to (a path like `/index.sh`, or a full URL)
# $2 - Optional: the response code, 301 or 302 (default 302)
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
		301|302) ;;
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
# The result is stored in `RESOLVED_PATH` instead of being echoed, because this function
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
#    RESOLVED_PATH='/home/sherver/sherver/file/pages/page.html'
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
	if [[ ! -e $target ]] || ! RESOLVED_PATH=$(realpath "$target" 2>/dev/null); then
		log "NOT FOUND: realpath - '$2'"
		send_error 404
	fi
	if [[ $RESOLVED_PATH != "$authorized"/* ]]; then
		log "FORBIDDEN: '$2' resolves to '$RESOLVED_PATH', outside of '$authorized'"
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
	local -r file="$RESOLVED_PATH"
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
	add_header 'Content-Length' "$size"
	_send_header 200
	# response
	if [ "$REQUEST_METHOD" != 'HEAD' ]; then
		cat "$file"
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
	local -r script="$RESOLVED_PATH"
	# existence is already guaranteed by `_resolve_path`
	if [ ! -f "$script" ] || [ ! -x "$script" ]; then
		send_error 404
	fi

	"$script" "$url" || send_error 500
}
export -f run_script

# Internal: Log a request parse failure, dump the request when relevant, and answer an error.
#
# **Note:** this method is used by `read_request()` and shouldn't be called manually.
#
# Owns the bail-out invariant of `read_request()`: the request is dumped on the first parse
# only (a child script re-parse would dump it once per script), the reason is always
# `log`ged, and `send_error()` ends the process — this function never returns. Only for the
# bail-outs *before* the end of the header loop: after that point, the first parse has
# already dumped the full request unconditionally, and this would dump it a second time.
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
# $1 - true when parsing from the standard input, false when re-parsing
#      `REQUEST_FULL_STRING` in a child script. Only the first parse logs the request, so
#      that a request is not dumped once per script it goes through
function read_request()
{
	local line
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
	# `read` collapses SP/TAB runs and drops trailing blanks (a leniency RFC 9112 §3 grants),
	# so only non-whitespace extra tokens get glued into the version and rejected here.
	# [0123456789] and not [0-9]: bracket ranges follow the locale and would take unicode digits
	if [ -z "$REQUEST_METHOD" ] || [ -z "$REQUEST_URL" ] \
			|| [[ ! "$REQUEST_HTTP_VERSION" =~ ^HTTP/[0123456789]\.[0123456789]$ ]]; then
		_bail_request 400 'BAD REQUEST: malformed request line' "$1"
	fi
	# a literal `HTTP/0.9` token means the client speaks the 1.x line format (real 0.9 has no
	# version token and took the 400 above), so a headered 505 is safe here (RFC 9112 §2.3)
	if [[ "$REQUEST_HTTP_VERSION" != HTTP/1.* ]]; then
		_bail_request 505 "UNSUPPORTED VERSION: '$REQUEST_HTTP_VERSION'" "$1"
	fi
	# Only GET, HEAD and POST are supported at this time
	case "$REQUEST_METHOD" in
		GET|HEAD|POST) ;;
		*)
			_bail_request 405 "METHOD NOT ALLOWED: '$REQUEST_METHOD'" "$1"
			;;
	esac
	# `parse_url` decodes the URL, so a broken encoding can't be answered
	if ! _check_encoding "$REQUEST_URL"; then
		_bail_request 400 "BAD REQUEST: invalid percent encoding in '$REQUEST_URL'" "$1"
	fi
	# fill URL_*
	parse_url "$REQUEST_URL"

	# fill REQUEST_HEADERS
	local key value
	while read -r line; do
		# checked first, for the same reasons as the request line above
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
		IFS=$': \t' read -r key value <<< "$line"
		# an empty name is a fatal `bad array subscript`, and only a broken client sends one
		if [ -z "$key" ]; then
			_bail_request 400 'BAD REQUEST: header line without a name' "$1"
		fi
		# header names are case insensitive, so we normalize them to lowercase
		REQUEST_HEADERS["${key,,}"]="$value"
	done
	if [ "$1" = true ]; then
		log_debug "$REQUEST_FULL_STRING"
	fi
	# RFC 9112: §3.2 requires Host on 1.1, and §2.3 processes a higher 1.x minor as 1.1, so
	# only 1.0 is exempt. Presence only: value unused (same tree served), duplicates overwrite
	if [ "$REQUEST_HTTP_VERSION" != 'HTTP/1.0' ] && [ ! -v "REQUEST_HEADERS['host']" ]; then
		log "BAD REQUEST: $REQUEST_HTTP_VERSION request without a Host header"
		send_error 400
	fi

	# fill REQUEST_BODY if POST
	if [ "$REQUEST_METHOD" = 'POST' ] && [ -v "REQUEST_HEADERS['content-length']" ]; then
		local -r length="${REQUEST_HEADERS['content-length']}"
		# a bogus length makes `read` fail with a bash error, and a huge one makes it wait
		# for bytes that will never come, so we check it before using it
		if [[ ! $length =~ ^[0-9]+$ ]]; then
			log "BAD REQUEST: invalid Content-Length '$length'"
			send_error 400
		fi
		# outside `test`'s integer range, `-gt` errors out and counts as false, which would
		# silently skip the limit. 10 digits is far above the limit anyway
		if [ "${#length}" -gt 10 ] || [ "$length" -gt "$MAX_BODY_SIZE" ]; then
			log "TOO LARGE: Content-Length '$length' over the $MAX_BODY_SIZE bytes limit"
			send_error 413
		fi
		# `Content-Length` counts bytes, but `-N` counts characters: in a UTF-8 locale a
		# multibyte body would make us wait for characters the client never sends
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
			# keep in sync with the twin loop in `parse_url`, which decodes the query string
			local -a fields
			IFS='&' read -ra fields <<< "$REQUEST_BODY"
			local key value
			local -i i
			for (( i=0; i < ${#fields[@]}; i++ )); do
				IFS='=' read -r key value <<< "${fields[i]}"
				# an empty key is a fatal `bad array subscript`, and carries no information
				if [ -z "$key" ]; then
					continue
				fi
				# `+` is a space in urlencoded content
				_url_decode key "${key//+/ }"
				_url_decode value "${value//+/ }"
				# read by the child scripts, which shellcheck can't see from here
				# shellcheck disable=SC2034
				REQUEST_BODY_PARAMETERS["$key"]="$value"
			done
		fi
	fi
}
export -f read_request
