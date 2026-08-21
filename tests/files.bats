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

load 'test_helper'

@test "a file is served whole and unaltered" {
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost'
	[ "$(status_code)" = '200' ]
	[ "$(header Content-Length)" = "$(stat -c '%s' "$REPO_ROOT/file/venise.webp")" ]
	body > "$BATS_TEST_TMPDIR/served"
	cmp "$BATS_TEST_TMPDIR/served" "$REPO_ROOT/file/venise.webp"
}

@test "the mime type comes from the extension, and text types announce utf-8" {
	local file type
	while read -r file type; do
		request '' "GET /file/$file HTTP/1.1" 'Host: localhost'
		[ "$(status_code)" = '200' ]
		[ "$(header Content-Type)" = "$type" ]
	done <<-'EOF'
		venise.webp           image/webp
		resources/zergian.png image/png
		resources/ugly.css    text/css; charset=utf-8
		pages/page.html       text/html; charset=utf-8
	EOF
}

@test "HEAD of a file repeats the headers of the GET exactly" {
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost'
	local -r get_type="$(header Content-Type)"
	local -r get_length="$(header Content-Length)"
	local -r get_etag="$(header ETag)"
	local -r get_names="$(header_names)"

	request '' 'HEAD /file/venise.webp HTTP/1.1' 'Host: localhost'
	[ "$(status_code)" = '200' ]
	[ -z "$(body)" ]
	[ "$(header Content-Type)" = "$get_type" ]
	[ "$(header Content-Length)" = "$get_length" ]
	[ "$(header ETag)" = "$get_etag" ]
	[ "$(header_names)" = "$get_names" ]
}

@test "a file answers with an ETag built from its size and mtime" {
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost'
	[ "$(header ETag)" = "\"$(stat -c '%s-%Y' "$REPO_ROOT/file/venise.webp")\"" ]
}

@test "a matching If-None-Match is answered with a bodyless 304" {
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost'
	local -r etag="$(header ETag)"

	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost' "If-None-Match: $etag"
	[ "$(status_code)" = '304' ]
	[ -z "$(body)" ]
	# a 304 carries the length of the answer it replaces, which the server cannot know
	[ -z "$(header Content-Length)" ]
}

@test "a stale If-None-Match gets the file again" {
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost' 'If-None-Match: "0-0"'
	[ "$(status_code)" = '200' ]
	[ -n "$(body)" ]
}

@test "a file answers with its Last-Modified date" {
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost'
	local expected
	expected="$(date -uR -r "$REPO_ROOT/file/venise.webp")"
	[ "$(header Last-Modified)" = "${expected/%+0000/GMT}" ]
}

@test "a matching If-Modified-Since is answered with a bodyless 304" {
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost'
	local -r date="$(header Last-Modified)"

	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost' "If-Modified-Since: $date"
	[ "$(status_code)" = '304' ]
	[ -z "$(body)" ]
}

@test "an If-Modified-Since that is not ours gets the file again" {
	# the comparison is an exact string match, like the ETag one
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost' 'If-Modified-Since: Thu, 04 Jul 2019 21:38:23 GMT'
	[ "$(status_code)" = '200' ]
	[ -n "$(body)" ]
}

@test "If-None-Match alone decides when both validators are sent" {
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost'
	local -r etag="$(header ETag)"
	local -r date="$(header Last-Modified)"

	# a stale ETag must win over a matching date...
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost' 'If-None-Match: "0-0"' "If-Modified-Since: $date"
	[ "$(status_code)" = '200' ]
	# ...and a matching ETag over a stale date
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost' "If-None-Match: $etag" \
		'If-Modified-Since: Thu, 04 Jul 2019 21:38:23 GMT'
	[ "$(status_code)" = '304' ]
}

@test "an empty If-None-Match does not swallow the If-Modified-Since" {
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost'
	local -r date="$(header Last-Modified)"

	# the header is there but holds no validator, so the date is what decides
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost' 'If-None-Match:' "If-Modified-Since: $date"
	[ "$(status_code)" = '304' ]
	[ -z "$(body)" ]
}

@test "an If-None-Match of * matches whatever we would have sent" {
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost' 'If-None-Match: *'
	[ "$(status_code)" = '304' ]
	[ -z "$(body)" ]
}

@test "a POST is never answered with a 304" {
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost'
	local -r etag="$(header ETag)"
	local -r date="$(header Last-Modified)"

	# conditional requests are defined for GET and HEAD: a 304 here would leave the
	# client with no representation at all for the body it just sent
	request '' 'POST /file/venise.webp HTTP/1.1' 'Host: localhost' "If-None-Match: $etag" \
		"If-Modified-Since: $date" 'Content-Length: 0'
	[ "$(status_code)" = '200' ]
	[ -n "$(body)" ]
}

@test "every file answer announces Accept-Ranges: bytes" {
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost'
	[ "$(status_code)" = '200' ]
	[ "$(header Accept-Ranges)" = 'bytes' ]
}

@test "a single byte range is answered with a 206 and the exact bytes" {
	local -r size="$(stat -c '%s' "$REPO_ROOT/file/venise.webp")"
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost' 'Range: bytes=0-3'
	[ "$(status_code)" = '206' ]
	[ "$(header Content-Range)" = "bytes 0-3/$size" ]
	[ "$(header Content-Length)" = '4' ]
	body > "$BATS_TEST_TMPDIR/served"
	head -c 4 -- "$REPO_ROOT/file/venise.webp" > "$BATS_TEST_TMPDIR/expected"
	cmp "$BATS_TEST_TMPDIR/served" "$BATS_TEST_TMPDIR/expected"
}

@test "an open-ended range runs to the end of the file" {
	local -r size="$(stat -c '%s' "$REPO_ROOT/file/venise.webp")"
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost' 'Range: bytes=4-'
	[ "$(status_code)" = '206' ]
	[ "$(header Content-Range)" = "bytes 4-$(( size - 1 ))/$size" ]
	[ "$(header Content-Length)" = "$(( size - 4 ))" ]
	body > "$BATS_TEST_TMPDIR/served"
	tail -c '+5' -- "$REPO_ROOT/file/venise.webp" > "$BATS_TEST_TMPDIR/expected"
	cmp "$BATS_TEST_TMPDIR/served" "$BATS_TEST_TMPDIR/expected"
}

@test "a suffix range serves the last N bytes" {
	local -r size="$(stat -c '%s' "$REPO_ROOT/file/venise.webp")"
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost' 'Range: bytes=-4'
	[ "$(status_code)" = '206' ]
	[ "$(header Content-Range)" = "bytes $(( size - 4 ))-$(( size - 1 ))/$size" ]
	[ "$(header Content-Length)" = '4' ]
	body > "$BATS_TEST_TMPDIR/served"
	tail -c 4 -- "$REPO_ROOT/file/venise.webp" > "$BATS_TEST_TMPDIR/expected"
	cmp "$BATS_TEST_TMPDIR/served" "$BATS_TEST_TMPDIR/expected"
}

@test "a range end past the file is clamped to its size" {
	local -r size="$(stat -c '%s' "$REPO_ROOT/file/venise.webp")"
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost' 'Range: bytes=0-999999999'
	[ "$(status_code)" = '206' ]
	[ "$(header Content-Range)" = "bytes 0-$(( size - 1 ))/$size" ]
	[ "$(header Content-Length)" = "$size" ]
	body > "$BATS_TEST_TMPDIR/served"
	cmp "$BATS_TEST_TMPDIR/served" "$REPO_ROOT/file/venise.webp"
}

@test "a range starting past the end of the file is a 416" {
	local -r size="$(stat -c '%s' "$REPO_ROOT/file/venise.webp")"
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost' 'Range: bytes=999999999-'
	[ "$(status_code)" = '416' ]
	# RFC 9110 §15.3.7: the 416 tells the client how big the file actually is
	[ "$(header Content-Range)" = "bytes */$size" ]
}

@test "a suffix range of zero bytes is a 416" {
	local -r size="$(stat -c '%s' "$REPO_ROOT/file/venise.webp")"
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost' 'Range: bytes=-0'
	[ "$(status_code)" = '416' ]
	[ "$(header Content-Range)" = "bytes */$size" ]
}

@test "a 416 is uncacheable and carries none of the file's validators" {
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost' 'Range: bytes=999999999-'
	[ "$(status_code)" = '416' ]
	# nothing nominates Range in a Vary, so a storable 416 could be replayed for a plain GET
	[ "$(header Cache-Control)" = 'no-store' ]
	# this is the one error path reached with the validators of a file already set: they
	# describe that file, and the body here is the error page
	local -r names="$(header_names)"
	[[ "$names" != *etag* ]]
	[[ "$names" != *last-modified* ]]
}

@test "leading zeros in a range are legal digits, not garbage" {
	local -r size="$(stat -c '%s' "$REPO_ROOT/file/venise.webp")"
	# RFC 9110 reads these as `1*DIGIT`: 21 digits of padding is still the number 3
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost' 'Range: bytes=000-000000000000000000003'
	[ "$(status_code)" = '206' ]
	[ "$(header Content-Range)" = "bytes 0-3/$size" ]
	[ "$(header Content-Length)" = '4' ]

	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost' 'Range: bytes=-0000000000000000000004'
	[ "$(status_code)" = '206' ]
	[ "$(header Content-Range)" = "bytes $(( size - 4 ))-$(( size - 1 ))/$size" ]

	# and a padded zero-length suffix is still the 416 that `bytes=-0` is
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost' 'Range: bytes=-000'
	[ "$(status_code)" = '416' ]
}

@test "an unparseable or multi-range Range is ignored, never an error" {
	local -r size="$(stat -c '%s' "$REPO_ROOT/file/venise.webp")"
	local range
	while read -r range; do
		request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost' "Range: $range"
		[ "$(status_code)" = '200' ]
		[ "$(header Content-Length)" = "$size" ]
	done <<-'EOF'
		bytes=0-1,5-9
		bytes=-
		bytes=5-2
		items=0-3
		bytes=garbage
		bytes=99999999999999999999-
	EOF
}

@test "a stale If-Range disables the range and serves the whole file" {
	local -r size="$(stat -c '%s' "$REPO_ROOT/file/venise.webp")"
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost' 'Range: bytes=0-3' 'If-Range: "0-0"'
	[ "$(status_code)" = '200' ]
	[ "$(header Content-Length)" = "$size" ]
}

@test "an If-Range matching the ETag lets the range through" {
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost'
	local -r etag="$(header ETag)"

	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost' 'Range: bytes=0-3' "If-Range: $etag"
	[ "$(status_code)" = '206' ]
	[ "$(header Content-Length)" = '4' ]
}

@test "a matching If-None-Match wins over a Range" {
	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost'
	local -r etag="$(header ETag)"

	request '' 'GET /file/venise.webp HTTP/1.1' 'Host: localhost' 'Range: bytes=0-3' "If-None-Match: $etag"
	[ "$(status_code)" = '304' ]
	[ -z "$(body)" ]
}

@test "a HEAD ignores Range and answers the full-size headers" {
	local -r size="$(stat -c '%s' "$REPO_ROOT/file/venise.webp")"
	request '' 'HEAD /file/venise.webp HTTP/1.1' 'Host: localhost' 'Range: bytes=0-3'
	[ "$(status_code)" = '200' ]
	[ "$(header Content-Length)" = "$size" ]
	[ -z "$(body)" ]
}

@test "a missing file is a 404" {
	request '' 'GET /file/nope.txt HTTP/1.1' 'Host: localhost'
	[ "$(status_code)" = '404' ]
}

@test "a directory is a 404 rather than a listing" {
	request '' 'GET /file/pages HTTP/1.1' 'Host: localhost'
	[ "$(status_code)" = '404' ]
	request '' 'GET /file/ HTTP/1.1' 'Host: localhost'
	[ "$(status_code)" = '404' ]
}

@test "a script can serve a file from outside its own directory" {
	# page.sh runs from scripts/, so it reaches the page through ../file/
	request '' 'GET /page.sh?page=page.html HTTP/1.1' 'Host: localhost'
	[ "$(status_code)" = '200' ]
	[ "$(header Content-Type)" = 'text/html; charset=utf-8' ]
}

@test "page.sh without its parameter is a 404" {
	request '' 'GET /page.sh HTTP/1.1' 'Host: localhost'
	[ "$(status_code)" = '404' ]
	request '' 'GET /page.sh?page= HTTP/1.1' 'Host: localhost'
	[ "$(status_code)" = '404' ]
}
