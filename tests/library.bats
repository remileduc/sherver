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

# `run --separate-stderr` keeps the response apart from the log
bats_require_minimum_version 1.5.0

load 'test_helper'

# ------------------------------------------------------------------ parse_url

@test "parse_url splits the base from the query string" {
	run --separate-stderr with_request 'GET /index.sh?test=youpi&answer=42 HTTP/1.0' \
		'printf "%s\n" "$URL_BASE" "${URL_PARAMETERS[test]}" "${URL_PARAMETERS[answer]}"'
	[ "$status" -eq 0 ]
	[ "$output" = '/index.sh
youpi
42' ]
}

@test "parse_url keeps a percent encoded question mark in the path" {
	run --separate-stderr with_request 'GET /file/what%3F.txt?real=yes HTTP/1.0' \
		'printf "%s\n" "$URL_BASE" "${URL_PARAMETERS[real]}"'
	[ "$status" -eq 0 ]
	[ "$output" = '/file/what?.txt
yes' ]
}

@test "parse_url decodes a multibyte character" {
	run --separate-stderr with_request 'GET /index.sh?city=caf%C3%A9+ville HTTP/1.0' \
		'printf "%s\n" "${URL_PARAMETERS[city]}"'
	[ "$status" -eq 0 ]
	[ "$output" = 'café ville' ]
}

@test "parse_url turns + into a space in the query but not in the path" {
	run --separate-stderr with_request 'GET /a+b.sh?key=a+b HTTP/1.0' \
		'printf "%s\n" "$URL_BASE" "${URL_PARAMETERS[key]}"'
	[ "$status" -eq 0 ]
	[ "$output" = '/a+b.sh
a b' ]
}

@test "parse_url skips a parameter without a name" {
	# an empty key is a fatal `bad array subscript`, so this must not reach the array
	run --separate-stderr with_request 'GET /index.sh?=orphan&kept=1 HTTP/1.0' \
		'printf "%s\n" "${#URL_PARAMETERS[@]}" "${URL_PARAMETERS[kept]}"'
	[ "$status" -eq 0 ]
	[ "$output" = '1
1' ]
}

@test "parse_url leaves a parameter without a value empty" {
	run --separate-stderr with_request 'GET /index.sh?flag HTTP/1.0' \
		'printf "[%s]\n" "${URL_PARAMETERS[flag]}"'
	[ "$status" -eq 0 ]
	[ "$output" = '[]' ]
}

# ------------------------------------------------------- _check_encoding

@test "_check_encoding accepts a properly encoded string" {
	run --separate-stderr with_request 'GET / HTTP/1.0' \
		'for s in "/file/my%20file.txt" "/plain" "100%25"; do
			_check_encoding "$s" && echo "ok $s" || echo "ko $s"
		done'
	[ "$status" -eq 0 ]
	[ "$output" = 'ok /file/my%20file.txt
ok /plain
ok 100%25' ]
}

@test "_check_encoding rejects what _url_decode cannot decode" {
	# a NUL truncates the string in bash, the rest is simply not decodable
	run --separate-stderr with_request 'GET / HTTP/1.0' \
		'for s in "%00" "a%00b" "/file/100%" "%zz" "%2" "%g0"; do
			_check_encoding "$s" && echo "ok $s" || echo "ko $s"
		done'
	[ "$status" -eq 0 ]
	[ "$output" = 'ko %00
ko a%00b
ko /file/100%
ko %zz
ko %2
ko %g0' ]
}

# ----------------------------------------------------------- _url_decode

@test "_url_decode keeps a backslash literal" {
	run --separate-stderr with_request 'GET / HTTP/1.0' \
		'_url_decode value "back\\slash"; printf "[%s]\n" "$value"'
	[ "$status" -eq 0 ]
	[ "$output" = '[back\slash]' ]
}

@test "_url_decode keeps a trailing newline" {
	# this is why it assigns through printf -v instead of echoing: a command
	# substitution would drop the newline that %0A decodes to
	run --separate-stderr with_request 'GET / HTTP/1.0' \
		'_url_decode value "line%0A"; printf "%s" "$value" | od -An -c | tr -s " "'
	[ "$status" -eq 0 ]
	[ "$output" = ' l i n e \n' ]
}

# --------------------------------------------------------- response headers

@test "a header value cannot inject a header of its own" {
	# `printf`, not `echo -e`: the two characters `\r` must stay two characters
	run --separate-stderr with_request 'GET / HTTP/1.0' \
		'add_header "X-Test" "a\r\nEvil: yes"; send_response 200 "body"'
	[ "$status" -eq 0 ]
	[[ $output == *'X-Test: a\r\nEvil: yes'* ]]
	# an injected header would start a line of its own
	[[ $output != *$'\n''Evil:'* ]]
}

@test "send_response counts Content-Length in bytes, not in characters" {
	# 'café' is 4 characters but 5 bytes, plus the newline printf adds
	run --separate-stderr with_request 'GET / HTTP/1.0' 'send_response 200 "café"'
	[ "$status" -eq 0 ]
	[[ $output == *'Content-Length: 6'* ]]
}

@test "send_response sends no Content-Length on a 304" {
	run --separate-stderr with_request 'GET / HTTP/1.0' 'send_response 304'
	[ "$status" -eq 0 ]
	[[ $output != *'Content-Length'* ]]
}

# ------------------------------------------------------------- _get_mimetype

@test "_get_mimetype matches the extension whatever its case" {
	run --separate-stderr with_request 'GET / HTTP/1.0' \
		'_get_mimetype "/file/PHOTO.JPG"; _get_mimetype "/file/photo.jpg"'
	[ "$status" -eq 0 ]
	[ "$output" = 'image/jpeg
image/jpeg' ]
}

@test "_get_mimetype falls back to octet-stream and logs it" {
	run --separate-stderr with_request 'GET / HTTP/1.0' '_get_mimetype "/file/archive.xyz"'
	[ "$status" -eq 0 ]
	[ "$output" = 'application/octet-stream' ]
	[[ $stderr == *'unknown extension'* ]]
}

@test "_get_mimetype ignores a dot that belongs to a parent directory" {
	# '${path##*.}' alone would read 'd/README' as the extension here
	run --separate-stderr with_request 'GET / HTTP/1.0' '_get_mimetype "/file/conf.d/README"'
	[ "$status" -eq 0 ]
	[ "$output" = 'application/octet-stream' ]
}
