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
		[100]='Continue'
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
		[408]='Request Timeout'
		[411]='Length Required'
		[413]='Content Too Large'
		[414]='URI Too Long'
		[416]='Range Not Satisfiable'
		[417]='Expectation Failed'
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
	# Public: Seconds the whole request — line, headers and body — has to arrive, else a 408
	#
	# `socat -T` only drops a connection that goes *silent*: a client dripping one byte every
	# 9 s would hold a dispatcher for the hours it takes to fill `MAX_HEADERS_SIZE`, and 32
	# of them fill `max-children`. This is a deadline on the request instead, applied by
	# `read_request()` to every read.
	declare -rg MAX_REQUEST_TIME=10
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
	# Internal: the `SECONDS` value past which the request is a 408, see `read_request()`
	declare -gi _REQUEST_DEADLINE=0
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

# Internal: `read` from the request under the deadline of `read_request()`, or answer 408.
#
# **Note:** this method is used by the `_read_request_*()` functions and shouldn't be
# called manually.
#
# Behaves like `read`: the arguments are handed to it as they are, behind a `-t` holding
# the seconds left before `_REQUEST_DEADLINE`. Once the deadline is past — before the
# call, or during the read — the request is a `408 Request Timeout` and this function
# never returns. The timeout on the read itself is what bounds a client dripping a single
# header line: a check between two lines would only run once the line is complete, which
# is exactly what such a client never lets happen. The check before the read is needed
# too, as `read -t 0` polls for input instead of failing. Nothing is dumped with the 408:
# past the headers the request was dumped already, and before them there is little to
# show. Any other failure of `read` — the end of the input — is returned as is, for the
# caller to handle.
#
# `IFS=` and `LC_ALL=C` set in front of the call reach the `read` inside, like any
# temporary assignment in front of a function call.
#
# $@ - the options and variable names for `read`
#
# Examples
#
#    while IFS= _read_with_timeout -r line; do  # ends at the end of the input
function _read_with_timeout()
{
	local -i remaining=$(( _REQUEST_DEADLINE - SECONDS )) status=0
	if [ "$remaining" -gt 0 ]; then
		# the `-r` every caller passes is in `$@`, where shellcheck cannot see it
		# shellcheck disable=SC2162
		read -t "$remaining" "$@" || status=$?
	fi
	# `read -t` returns over 128 on a timeout; no time left before the read is the same
	if [ "$remaining" -le 0 ] || [ "$status" -gt 128 ]; then
		log "REQUEST TIMEOUT: request not complete after $MAX_REQUEST_TIME s"
		send_error 408
	fi
	return "$status"
}
export -f _read_with_timeout

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
# a path is refused with a 400, the asterisk form of `OPTIONS` excepted. A line that is not
# complete by the deadline of `read_request()` is a 408.
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
	if ! _read_with_timeout -r line; then
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
# A header line is refused with a 400 when it is folded (obs-fold), has no colon, still
# carries a CR once its own terminator is stripped, or has a name that is not a token —
# whitespace before the colon included (RFC 9112 §5, §5.1, §5.2 and RFC 9110 §5.5).
# A repeated header becomes the `v1, v2` list of RFC 9110 §5.2 — except `Cookie`, whose
# pairs recombine on `; ` (RFC 9113 §8.2.3) — but a repeated `Host`, `Content-Length` or
# `Content-Type` with two different values is a 400: they frame the request, and none of
# the three is a list. A repeated `Host` is ignored instead, without being compared, when
# the request-target already carried an authority. Headers still incomplete at the deadline
# of `read_request()` are a 408.
#
# Once the loop is done, any HTTP/1.1+ request without a `Host` header is refused with a
# 400 — absolute-form included, RFC 9112 §3.2.2 only voids the header's value — then the
# `_REQUEST_AUTHORITY` of an absolute-form target replaces `REQUEST_HEADERS['host']`.
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
	while IFS= _read_with_timeout -r line; do
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
		# RFC 9110 §5.5: a CR surviving the line's own terminator must be refused or blanked,
		# and refusing is this parser's way. Kept, a line ending `\r\r\n` loses one CR per
		# parse, so the child re-parse of `REQUEST_FULL_STRING` reads another value than this
		if [[ "$line" == *$'\r'* ]]; then
			_bail_request 400 'BAD REQUEST: stray carriage return in a header line' "$1"
		fi
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
	# RFC 9112: §3.2 requires Host on 1.1 — absolute-form included, whose §3.2.2 only voids
	# the header's value, never its presence — and §2.3 processes a higher 1.x minor as 1.1,
	# so only 1.0 is exempt. Checked before the rewrite below, which would mask the absence
	if [ "$REQUEST_HTTP_VERSION" != 'HTTP/1.0' ] && [ ! -v "REQUEST_HEADERS['host']" ]; then
		log "BAD REQUEST: $REQUEST_HTTP_VERSION request without a Host header"
		send_error 400
	fi
	# RFC 9112 §3.2.2: with an absolute-form target, its authority wins and the `Host` header
	# MUST be ignored. Done here and not with the rewrite in `_read_request_line()`, where
	# the header loop would then let a `Host:` line overwrite it and invert the MUST
	if [ -n "$_REQUEST_AUTHORITY" ]; then
		REQUEST_HEADERS['host']="$_REQUEST_AUTHORITY"
	fi
}
export -f _read_request_headers

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
# The whole request has `MAX_REQUEST_TIME` seconds to arrive, body included, from the
# first read: `_REQUEST_DEADLINE` is set here and every read of the three goes through
# `_read_with_timeout()`, which answers the `408 Request Timeout` itself once it is past
# (RFC 9110 §15.5.9 — the response carries the `Connection: close` it asks for, like
# every other). `SECONDS` has a one second resolution, so the budget is really
# between `MAX_REQUEST_TIME - 1` and `MAX_REQUEST_TIME`.
#
# *Note* that this method is highly inspired by [bashttpd](https://github.com/avleen/bashttpd)
#
# $1 - true when parsing from the standard input, false when re-parsing
#      `REQUEST_FULL_STRING` in a child script. Only the first parse logs the request, so
#      that a request is not dumped once per script it goes through
function read_request()
{
	_REQUEST_DEADLINE=$(( SECONDS + MAX_REQUEST_TIME ))
	_read_request_line "$1"
	_read_request_headers "$1"
	_read_request_body "$1"
}
export -f read_request
