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

# Internal: Discard what may still arrive of a request body that will not be read.
#
# **Note:** this method is used by `_read_request_body()` and shouldn't be called manually.
#
# Answering a request whose body is still in flight and exiting leaves unread bytes in the
# socket, and closing over them is a TCP reset that can destroy the answer — error page or
# 200 alike — before the client reads it. This is the lingering close of every real server, bounded both ways so
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
# unless the request is a POST carrying a `Content-Length` — one announced on any other
# method is drained, unread, so the answer is not lost to a TCP reset. The length is
# checked against `MAX_BODY_SIZE` before it is trusted, and the body lands in
# `REQUEST_FULL_STRING` too. It shares the deadline of `read_request()` with the head: a
# body still incomplete when it passes is a 408, one cut short by the client a 400.
#
# A body of type `application/x-www-form-urlencoded` is decoded into
# `REQUEST_BODY_PARAMETERS`.
#
# A client that announced `Expect: 100-continue` (RFC 9110 §10.1.1) is holding the body
# back, so the interim `HTTP/1.1 100 Continue` line is written right before the body
# read. Every refusal above it answers with a final status instead — the alternative the
# same section allows. No interim line goes to an HTTP/1.0 client (a MUST NOT), whose
# expectation is ignored. `Expect` is a list, and naming anything but `100-continue` in
# it is a `417 Expectation Failed`, on any method (a MAY): a client waiting on an
# expectation we will never meet learns right away instead of timing out. An empty
# element names no expectation and is dropped, so an emptied value passes.
#
# No `_bail_request` here: every bail-out below sits after the header loop, which has
# already dumped the full request, so `send_error()` is called directly.
#
# $1 - true when reading from the standard input, false when re-parsing
#      `REQUEST_FULL_STRING` in a child script — the interim response is written only
#      once, by the first parse
#
# Examples
#
#    _read_request_body true
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
	# an expectation we won't meet is refused on any method (RFC 9110 §10.1.1 MAY): a
	# waiting client learns right away instead of timing out, and a 417 is still the
	# immediate final response §10.1.1 asks for. The value is the list §5.6.1 says it is:
	# a repeated 100-continue (the header loop merges repeated lines) still names only
	# the one expectation we meet, and an empty element names none at all — the header
	# merge's own rule — so an emptied value passes
	local expect_continue=false
	local -a expect_members
	local member
	IFS=',' read -ra expect_members <<< "${REQUEST_HEADERS['expect']:-}"
	for member in "${expect_members[@]}"; do
		IFS=$' \t' read -r member <<< "$member"	# strips the OWS around the element
		if [ -z "$member" ]; then
			continue
		fi
		if [ "${member,,}" != '100-continue' ]; then
			log "EXPECTATION FAILED: unsupported Expect '${REQUEST_HEADERS['expect']}'"
			# only a Content-Length announces a body here — a Transfer-Encoding was
			# refused above — and with none announced the drain would only sit out
			# its own read timeout
			if [ -v "REQUEST_HEADERS['content-length']" ]; then
				_drain_request_input
			fi
			send_error 417
		fi
		expect_continue=true
	done
	# past the gate above only a `Content-Length` announces a body, and only a POST's is
	# read. One announced on any other method is drained instead: left in the socket,
	# closing over it is the TCP reset the refusals here guard against — on a 200 this time.
	# First parse only: the parent has already emptied the socket for the child re-parse
	if [ "$REQUEST_METHOD" != 'POST' ]; then
		if [ "$1" = true ] && [ -v "REQUEST_HEADERS['content-length']" ]; then
			_drain_request_input
		fi
		return 0
	fi
	if [ ! -v "REQUEST_HEADERS['content-length']" ]; then
		return 0 # no body is OK
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
	# RFC 9110 §10.1.1: the client is waiting for this line before it sends the body just
	# measured. Raw, not `_send_header()`: an interim response carries no header fields
	# here, no access-log line, and must not consume `RESPONSE_HEADERS`. Never to an
	# HTTP/1.0 client (§2.3 processes a higher 1.x minor as 1.1, same rule as the Host gate)
	if [ "$1" = true ] && [ "$expect_continue" = true ] \
		&& [ "$REQUEST_HTTP_VERSION" != 'HTTP/1.0' ]; then
		printf 'HTTP/1.1 100 %s\r\n\r\n' "${HTTP_RESPONSE[100]}"
		log_debug "> HTTP/1.1 100 ${HTTP_RESPONSE[100]}"
	fi
	# `Content-Length` counts bytes, but `-N` counts characters: in a UTF-8 locale a
	# multibyte body would make us wait for characters the client never sends. Under the
	# request deadline like the head: a dripped body would pin the process just the same
	local line
	if ! LC_ALL=C _read_with_timeout -rN "$length" line; then
		log "BAD REQUEST: body ended before the $length bytes announced"
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
