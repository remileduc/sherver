#!/usr/bin/env bats

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

bats_require_minimum_version 1.5.0

load 'test_helper'

# Internal: Print a string of the given length, to push past the size limits.
function filler()
{
	printf '%*s' "$1" '' | tr ' ' 'a'
}

# ------------------------------------------------------------------- routing

@test "GET / serves the index" {
	request '' 'GET / HTTP/1.0'
	[ "$(status_code)" = '200' ]
	[ "$(header Content-Type)" = 'text/html; charset=utf-8' ]
	[[ "$(body)" == *'<h1>Sherver example</h1>'* ]]
}

@test "GET /index.html and /index.htm reach the same script" {
	request '' 'GET /index.html HTTP/1.0'
	[ "$(status_code)" = '200' ]
	request '' 'GET /index.htm HTTP/1.0'
	[ "$(status_code)" = '200' ]
}

@test "GET of an unknown script is a 404" {
	request '' 'GET /nope.sh HTTP/1.0'
	[ "$(status_code)" = '404' ]
}

@test "the library itself is not a reachable endpoint" {
	# it is not executable, so run_script refuses it rather than running it
	request '' 'GET /SHERVER_UTILS.sh HTTP/1.0'
	[ "$(status_code)" = '404' ]
}

@test "the query string reaches the script" {
	request '' 'GET /index.sh?test=youpi&answer=42 HTTP/1.0'
	[ "$(status_code)" = '200' ]
	[[ "$(body)" == *'test: youpi'* ]]
	[[ "$(body)" == *'answer: 42'* ]]
}

# -------------------------------------------------------------------- methods

@test "HEAD sends the headers of the GET and no body" {
	request '' 'GET / HTTP/1.0'
	local -r get_names="$(header_names)"

	request '' 'HEAD / HTTP/1.0'
	[ "$(status_code)" = '200' ]
	[ -z "$(body)" ]
	[ "$(header_names)" = "$get_names" ]
	# the length of the body it would have sent, not 0. It is not compared to the one
	# of the GET, as this page prints the request back and `HEAD` is longer than `GET`
	[ "$(header Content-Length)" -gt 0 ]
}

@test "POST hands the body to the script" {
	request 'hello there' 'POST / HTTP/1.0' 'Content-Length: 11'
	[ "$(status_code)" = '200' ]
	[[ "$(body)" == *"You just sent me 'hello there'!"* ]]
}

@test "POST parses an urlencoded body, charset parameter and all" {
	run --separate-stderr with_request \
		'POST / HTTP/1.0
Content-Type: application/x-www-form-urlencoded; charset=UTF-8
Content-Length: 21

name=r%C3%A9mi&up=a+b' \
		'printf "%s\n" "${REQUEST_BODY_PARAMETERS[name]}" "${REQUEST_BODY_PARAMETERS[up]}"'
	[ "$status" -eq 0 ]
	[ "$output" = 'rémi
a b' ]
}

@test "an unsupported method is a 405" {
	local method
	for method in PUT DELETE OPTIONS PATCH TRACE; do
		request '' "$method / HTTP/1.0"
		[ "$(status_code)" = '405' ]
	done
}

# ------------------------------------------------------------ malformed input

@test "an empty request is a 400" {
	request_raw ''
	[ "$(status_code)" = '400' ]
}

@test "a request line missing a field is a 400" {
	request '' 'GET /'
	[ "$(status_code)" = '400' ]
	request '' 'GET'
	[ "$(status_code)" = '400' ]
}

@test "a URL that is not decodable is a 400" {
	local url
	for url in '/index.sh?a=%zz' '/%2' '/file/100%' '/index.sh?a=%00'; do
		request '' "GET $url HTTP/1.0"
		[ "$(status_code)" = '400' ]
	done
}

@test "a Content-Length that is not a number is a 400" {
	request 'body' 'POST / HTTP/1.0' 'Content-Length: abc'
	[ "$(status_code)" = '400' ]
}

@test "a body shorter than Content-Length is a 400" {
	request 'short' 'POST / HTTP/1.0' 'Content-Length: 999'
	[ "$(status_code)" = '400' ]
}

# --------------------------------------------------------------- size limits

@test "a request line over 8 kio is a 414" {
	request '' "GET /$(filler 8200) HTTP/1.0"
	[ "$(status_code)" = '414' ]
}

@test "headers over 8 kio are a 431" {
	request '' 'GET / HTTP/1.0' "X-Long: $(filler 8200)"
	[ "$(status_code)" = '431' ]
}

@test "a body over 64 kio is a 413" {
	# refused on the announced length, so there is no need to send the bytes
	request '' 'POST / HTTP/1.0' 'Content-Length: 65537'
	[ "$(status_code)" = '413' ]
}

@test "a Content-Length too big for the shell is a 413, not a crash" {
	# outside test's integer range `-gt` errors out, which would skip the limit
	request '' 'POST / HTTP/1.0' 'Content-Length: 99999999999999999999999'
	[ "$(status_code)" = '413' ]
}

# ------------------------------------------------------------------- headers

@test "header names are matched case insensitively" {
	run --separate-stderr with_request \
		'GET / HTTP/1.0
X-MiXeD-CaSe: yes' \
		'printf "%s\n" "${REQUEST_HEADERS[x-mixed-case]}"'
	[ "$status" -eq 0 ]
	[ "$output" = 'yes' ]
}

@test "every response carries the default headers" {
	request '' 'GET / HTTP/1.0'
	[ "$(header Server)" = 'Sherver' ]
	[ "$(header Connection)" = 'close' ]
	[ -n "$(header Date)" ]
	[ -n "$(header Expires)" ]
}

@test "the status line is HTTP 1.0 whatever the client announced" {
	request '' 'GET / HTTP/1.1'
	[ "$(status_line)" = 'HTTP/1.0 200 OK' ]
}

@test "an error page announces its own length" {
	request '' 'GET /nope.sh HTTP/1.0'
	[ "$(header Content-Length)" = "$(body | wc -c)" ]
}
