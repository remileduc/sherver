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
	# tests. A request too broken to have a method is answered before those variables are
	# filled, and the raw target may hold control bytes — `log` itself is what dots them out
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
	# the same builtin as `send_file`'s validators: the `date` fork could fail under `set -e`
	# with the status line already on the wire, truncating the response to it
	TZ=UTC0 LC_ALL=C printf -v datenow '%(%a, %d %b %Y %H:%M:%S)T GMT' -1
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
