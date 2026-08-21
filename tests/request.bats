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
	request '' 'GET / HTTP/1.1' 'Host: localhost'
	[ "$(status_code)" = '200' ]
	[ "$(header Content-Type)" = 'text/html; charset=utf-8' ]
	[[ "$(body)" == *'<h1>Sherver example</h1>'* ]]
}

@test "GET /index.html and /index.htm reach the same script" {
	request '' 'GET /index.html HTTP/1.1' 'Host: localhost'
	[ "$(status_code)" = '200' ]
	request '' 'GET /index.htm HTTP/1.1' 'Host: localhost'
	[ "$(status_code)" = '200' ]
}

@test "GET of an unknown script is a 404" {
	request '' 'GET /nope.sh HTTP/1.1' 'Host: localhost'
	[ "$(status_code)" = '404' ]
}

@test "the library itself is not a reachable endpoint" {
	# it is not executable, so run_script refuses it rather than running it
	request '' 'GET /SHERVER_UTILS.sh HTTP/1.1' 'Host: localhost'
	[ "$(status_code)" = '404' ]
}

@test "the query string reaches the script" {
	request '' 'GET /index.sh?test=youpi&answer=42 HTTP/1.1' 'Host: localhost'
	[ "$(status_code)" = '200' ]
	[[ "$(body)" == *'test: youpi'* ]]
	[[ "$(body)" == *'answer: 42'* ]]
}

# -------------------------------------------------------------------- methods

@test "HEAD sends the headers of the GET and no body" {
	request '' 'GET / HTTP/1.1' 'Host: localhost'
	local -r get_names="$(header_names)"

	request '' 'HEAD / HTTP/1.1' 'Host: localhost'
	[ "$(status_code)" = '200' ]
	[ -z "$(body)" ]
	[ "$(header_names)" = "$get_names" ]
	# the length of the body it would have sent, not 0. It is not compared to the one
	# of the GET, as this page prints the request back and `HEAD` is longer than `GET`
	[ "$(header Content-Length)" -gt 0 ]
}

@test "POST hands the body to the script" {
	request 'hello there' 'POST / HTTP/1.1' 'Host: localhost' 'Content-Length: 11'
	[ "$(status_code)" = '200' ]
	[[ "$(body)" == *"You just sent me 'hello there'!"* ]]
}

@test "POST parses an urlencoded body, charset parameter and all" {
	run --separate-stderr with_request \
		'POST / HTTP/1.1
Host: localhost
Content-Type: application/x-www-form-urlencoded; charset=UTF-8
Content-Length: 21

name=r%C3%A9mi&up=a+b' \
		'printf "%s\n" "${REQUEST_BODY_PARAMETERS[name]}" "${REQUEST_BODY_PARAMETERS[up]}"'
	[ "$status" -eq 0 ]
	[ "$output" = 'rémi
a b' ]
}

@test "a known but unsupported method is a 405 carrying Allow" {
	local method
	for method in PUT DELETE PATCH TRACE CONNECT; do
		request '' "$method / HTTP/1.1" 'Host: localhost'
		[ "$(status_code)" = '405' ]
		[ "$(header Allow)" = 'GET, HEAD, POST, OPTIONS' ]
	done
}

@test "an unknown method is a 501" {
	local method
	# `get` included: method names are case sensitive, so it is not a GET
	for method in BREW FOO get; do
		request '' "$method / HTTP/1.1" 'Host: localhost'
		[ "$(status_code)" = '501' ]
	done
}

@test "a method that is not a token is a 400, not a 501" {
	# RFC 9112 §3: a stray octet in the method is a malformed request line, not an unknown
	# method. The comma-glued ones would even span entries of the supported-methods list
	local method
	for method in GET,HEAD HEAD,POST 'GE(T' 'GET;' '"GET"'; do
		request '' "$method / HTTP/1.1" 'Host: localhost'
		[ "$(status_code)" = '400' ]
	done
}

@test "a script answers its own 405 with Allow" {
	request '' 'DELETE /page.sh?page=page.html HTTP/1.1' 'Host: localhost'
	[ "$(status_code)" = '405' ]
	# the dispatcher never reaches the script for DELETE, so this is the library's list
	[ "$(header Allow)" = 'GET, HEAD, POST, OPTIONS' ]
	request '' 'POST /page.sh?page=page.html HTTP/1.1' 'Host: localhost' 'Content-Length: 0'
	[ "$(status_code)" = '405' ]
	[ "$(header Allow)" = 'GET, HEAD, OPTIONS' ]
}

@test "OPTIONS is answered server wide with Allow and an empty body" {
	request '' 'OPTIONS / HTTP/1.1' 'Host: localhost'
	[ "$(status_code)" = '200' ]
	[ "$(header Allow)" = 'GET, HEAD, POST, OPTIONS' ]
	[ "$(header Content-Length)" = '0' ]
	[ -z "$(body)" ]
}

@test "OPTIONS answers before any routing" {
	# asterisk form (RFC 9112 §3.2.4), and a path that would otherwise be a 404
	local target
	for target in '*' '/nope.sh' '/file/nope.txt'; do
		request '' "OPTIONS $target HTTP/1.1" 'Host: localhost'
		[ "$(status_code)" = '200' ]
		[ "$(header Allow)" = 'GET, HEAD, POST, OPTIONS' ]
	done
}

# --------------------------------------------------------- absolute-form URL

@test "an absolute-form target is served as its path" {
	# RFC 9112 §3.2.2, what a proxy sends. The scheme is case insensitive, the path is not
	local target
	for target in 'http://example.com/index.sh?test=youpi' \
		'HTTPS://Example.COM/index.sh?test=youpi' \
		'http://example.com:8080/index.sh?test=youpi'; do
		request '' "GET $target HTTP/1.1" 'Host: localhost'
		[ "$(status_code)" = '200' ]
		[[ "$(body)" == *'test: youpi'* ]]
	done
}

@test "an absolute-form target with no path is the root" {
	local target
	for target in 'http://example.com' 'http://example.com/'; do
		request '' "GET $target HTTP/1.1" 'Host: localhost'
		[ "$(status_code)" = '200' ]
		[[ "$(body)" == *'<h1>Sherver example</h1>'* ]]
	done
}

@test "a query string survives a target that has no path" {
	# the authority stops at the `?` as well, so the query is not swallowed with it
	request '' 'GET http://example.com?test=youpi HTTP/1.1' 'Host: localhost'
	[ "$(status_code)" = '200' ]
	[[ "$(body)" == *'test: youpi'* ]]
}

@test "an absolute-form target satisfies the Host requirement on its own" {
	# its authority is the host, so a 1.1 request needs no Host header
	request '' 'GET http://example.com/ HTTP/1.1'
	[ "$(status_code)" = '200' ]
}

@test "the authority of an absolute-form target overrides the Host header" {
	# RFC 9112 §3.2.2 makes it a MUST, whichever order the client sends them in
	run --separate-stderr with_request \
		'GET http://authority.example/index.sh HTTP/1.1
Host: header.example' \
		'printf "%s\n" "$REQUEST_URL" "${REQUEST_HEADERS[host]}"'
	[ "$status" -eq 0 ]
	[ "$output" = '/index.sh
authority.example' ]
}

@test "a fragment on an absolute-form target is dropped, not glued onto the path" {
	# a request-target carries no fragment (RFC 9112 §3.2), wherever the client put one
	request '' 'GET http://example.com/index.sh?test=youpi#frag HTTP/1.1' 'Host: localhost'
	[ "$(status_code)" = '200' ]
	[[ "$(body)" == *'test: youpi'* ]]
	request '' 'GET http://example.com#frag HTTP/1.1' 'Host: localhost'
	[ "$(status_code)" = '200' ]
	[[ "$(body)" == *'<h1>Sherver example</h1>'* ]]
}

@test "an absolute-form target with an invalid authority is a 400" {
	# RFC 9110 §4.2: an http(s) URI with an empty host is invalid and userinfo is an
	# error, and the authority must be decodable like everything else client-sent
	local target
	# `:8080` and `:` are an empty host too, and would land in `Host` and skip its 400
	for target in 'http://' 'http:///index.sh' 'http://user:pass@example.com/index.sh' \
		'http://:8080/index.sh' 'http://:/index.sh' \
		'http://a%00b/index.sh' 'http://100%/index.sh'; do
		request '' "GET $target HTTP/1.1" 'Host: localhost'
		[ "$(status_code)" = '400' ]
	done
}

@test "a target that is neither a path nor a form we rewrite is a 400" {
	# RFC 9112 §3.2: origin, absolute (http/https here) and asterisk forms are all there
	# is — and the asterisk one belongs to OPTIONS alone
	local target
	for target in 'ftp://example.com/x' 'Zindex.sh' '*'; do
		request '' "GET $target HTTP/1.1" 'Host: localhost'
		[ "$(status_code)" = '400' ]
	done
}

@test "the access log shows an absolute-form target as the client sent it" {
	# the rewrite must not hide proxy-style requests from whoever greps the log
	request '' 'GET http://example.com/index.sh HTTP/1.1' 'Host: localhost'
	[ "$(status_code)" = '200' ]
	[[ "$(log_output)" == *'GET http://example.com/index.sh 200'* ]]
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

@test "a version that is not HTTP/major.minor is a 400" {
	local version
	for version in 'HTP/1.1' 'HTTP/1.1garbage' 'HTTP/11' 'http/1.1'; do
		request '' "GET / $version" 'Host: localhost'
		[ "$(status_code)" = '400' ]
	done
}

@test "non-whitespace extra tokens on the request line are a 400" {
	request '' 'GET / HTTP/1.1 extra' 'Host: localhost'
	[ "$(status_code)" = '400' ]
}

@test "whitespace-only extras on the request line are tolerated" {
	# `read` eats them before the version check ever runs; RFC 9112 §3 grants the leniency
	local line
	for line in 'GET / HTTP/1.1 ' 'GET  /  HTTP/1.1' $'GET\t/\tHTTP/1.1'; do
		request '' "$line" 'Host: localhost'
		[ "$(status_code)" = '200' ]
	done
}

@test "an HTTP major version other than 1 is a 505" {
	local version
	for version in 'HTTP/2.0' 'HTTP/0.9'; do
		request '' "GET / $version" 'Host: localhost'
		[ "$(status_code)" = '505' ]
	done
}

@test "an HTTP 1.x minor above 1 is served as 1.1, Host gate included" {
	# RFC 9112 §2.3: process it as the highest minor version we conform to
	request '' 'GET / HTTP/1.9' 'Host: localhost'
	[ "$(status_code)" = '200' ]
	request '' 'GET / HTTP/1.9'
	[ "$(status_code)" = '400' ]
}

@test "a header line without a name is a 400, not a crash" {
	local header
	for header in ': naughty' ':naughty' $'\t: naughty'; do
		request '' 'GET / HTTP/1.1' 'Host: localhost' "$header"
		[ "$(status_code)" = '400' ]
	done
}

@test "an HTTP 1.1 request without a Host header is a 400" {
	# RFC 9112 §3.2. The HTTP 1.0 fixture below proves 1.0 stays exempt
	request '' 'GET / HTTP/1.1'
	[ "$(status_code)" = '400' ]
}

@test "a URL that is not decodable is a 400" {
	local url
	for url in '/index.sh?a=%zz' '/%2' '/file/100%' '/index.sh?a=%00'; do
		request '' "GET $url HTTP/1.1" 'Host: localhost'
		[ "$(status_code)" = '400' ]
	done
}

@test "a Content-Length that is not a number is a 400" {
	request 'body' 'POST / HTTP/1.1' 'Host: localhost' 'Content-Length: abc'
	[ "$(status_code)" = '400' ]
}

@test "a body shorter than Content-Length is a 400" {
	request 'short' 'POST / HTTP/1.1' 'Host: localhost' 'Content-Length: 999'
	[ "$(status_code)" = '400' ]
}

# --------------------------------------------------------------- size limits

@test "a request line over 8 kio is a 414" {
	request '' "GET /$(filler 8200) HTTP/1.1" 'Host: localhost'
	[ "$(status_code)" = '414' ]
}

@test "headers over 8 kio are a 431" {
	request '' 'GET / HTTP/1.1' 'Host: localhost' "X-Long: $(filler 8200)"
	[ "$(status_code)" = '431' ]
}

@test "a body over 64 kio is a 413" {
	# refused on the announced length, so there is no need to send the bytes
	request '' 'POST / HTTP/1.1' 'Host: localhost' 'Content-Length: 65537'
	[ "$(status_code)" = '413' ]
}

@test "a Content-Length too big for the shell is a 413, not a crash" {
	# outside test's integer range `-gt` errors out, which would skip the limit
	request '' 'POST / HTTP/1.1' 'Host: localhost' 'Content-Length: 99999999999999999999999'
	[ "$(status_code)" = '413' ]
}

@test "a Content-Length is measured on its value, not its padding" {
	# `1*DIGIT` allows leading zeros, which say nothing about magnitude
	request 'hello there' 'POST / HTTP/1.1' 'Host: localhost' 'Content-Length: 00000000011'
	[ "$(status_code)" = '200' ]
	[[ "$(body)" == *"You just sent me 'hello there'!"* ]]
	# and padding must not smuggle a huge value past the digit cap either
	request '' 'POST / HTTP/1.1' 'Host: localhost' 'Content-Length: 000000000099999999999'
	[ "$(status_code)" = '413' ]
}

# ------------------------------------------------------------------- headers

@test "header names are matched case insensitively" {
	run --separate-stderr with_request \
		'GET / HTTP/1.1
Host: localhost
X-MiXeD-CaSe: yes' \
		'printf "%s\n" "${REQUEST_HEADERS[x-mixed-case]}"'
	[ "$status" -eq 0 ]
	[ "$output" = 'yes' ]
}

@test "every response carries the default headers" {
	request '' 'GET / HTTP/1.1' 'Host: localhost'
	[ "$(header Server)" = 'Sherver' ]
	[ "$(header Connection)" = 'close' ]
	[ "$(header X-Content-Type-Options)" = 'nosniff' ]
	[ -n "$(header Date)" ]
	# no `Expires`: a cache ignores it whenever `max-age` is there (RFC 9111 §5.3), so it
	# could only ever contradict the `Cache-Control` above
	[[ "$(header_names)" != *expires* ]]
}

@test "an error page is never stored" {
	# several codes depend on a request header nothing nominates in a `Vary` (Range, the
	# header-size limits, the version), so a stored error page could answer a good request
	request '' 'GET /file/nope.txt HTTP/1.1' 'Host: localhost'
	[ "$(status_code)" = '404' ]
	[ "$(header Cache-Control)" = 'no-store' ]
}

@test "the status line is HTTP 1.1 even to an HTTP 1.0 client" {
	# the version advertises capability (RFC 9112 §2.3), it does not echo the request.
	# Deliberately no Host header either: it is the HTTP 1.0 compatibility fixture
	request '' 'GET / HTTP/1.0'
	[ "$(status_line)" = 'HTTP/1.1 200 OK' ]
}

@test "the Host header survives the child script re-parse" {
	# index.sh re-parses REQUEST_FULL_STRING in its own process: the Host line must
	# round-trip through it, or every scripted endpoint would 400 on the second parse
	request '' 'GET /index.sh HTTP/1.1' 'Host: localhost'
	[ "$(status_code)" = '200' ]
}

@test "an error page announces its own length" {
	request '' 'GET /nope.sh HTTP/1.1' 'Host: localhost'
	[ "$(header Content-Length)" = "$(body | wc -c)" ]
}

# ------------------------------------------------------------------- logging

@test "a served request logs exactly one access line" {
	request '' 'GET /index.sh?a=1 HTTP/1.1' 'Host: localhost'
	# the address is socat's; driven as a filter there is none, hence the `-`
	[ "$(log_output)" = '- GET /index.sh?a=1 200' ]
}

@test "an error logs its reason next to the access line" {
	request '' 'GET /nope.sh HTTP/1.1' 'Host: localhost'
	[[ "$(log_output)" == *'NOT FOUND'* ]]
	[[ "$(log_output)" == *'- GET /nope.sh 404'* ]]
}

@test "index.sh escapes what the client sent instead of reflecting it" {
	request '' 'GET /index.sh?%3Cscript%3E=%3Cimg+onerror%3Dalert(1)%3E HTTP/1.1' 'Host: localhost' \
		'X-Evil: <script>alert(2)</script>'
	[ "$(status_code)" = '200' ]
	# nothing the client wrote may come back as markup
	body > "$BATS_TEST_TMPDIR/page"
	! grep -qe '<script>alert' -e '<img onerror' "$BATS_TEST_TMPDIR/page"
	grep -q '&lt;script&gt;alert(2)&lt;/script&gt;' "$BATS_TEST_TMPDIR/page"
}
