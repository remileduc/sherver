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
	request '' 'GET /file/venise.webp HTTP/1.0'
	[ "$(status_code)" = '200' ]
	[ "$(header Content-Length)" = "$(stat -c '%s' "$REPO_ROOT/file/venise.webp")" ]
	body > "$BATS_TEST_TMPDIR/served"
	cmp "$BATS_TEST_TMPDIR/served" "$REPO_ROOT/file/venise.webp"
}

@test "the mime type comes from the content, not from a desktop association" {
	local file type
	while read -r file type; do
		request '' "GET /file/$file HTTP/1.0"
		[ "$(status_code)" = '200' ]
		[ "$(header Content-Type)" = "$type" ]
	done <<-'EOF'
		venise.webp           image/webp
		resources/zergian.png image/png
		resources/ugly.css    text/css
		pages/page.html       text/html
	EOF
}

@test "HEAD of a file repeats the headers of the GET exactly" {
	request '' 'GET /file/venise.webp HTTP/1.0'
	local -r get_type="$(header Content-Type)"
	local -r get_length="$(header Content-Length)"
	local -r get_etag="$(header ETag)"
	local -r get_names="$(header_names)"

	request '' 'HEAD /file/venise.webp HTTP/1.0'
	[ "$(status_code)" = '200' ]
	[ -z "$(body)" ]
	[ "$(header Content-Type)" = "$get_type" ]
	[ "$(header Content-Length)" = "$get_length" ]
	[ "$(header ETag)" = "$get_etag" ]
	[ "$(header_names)" = "$get_names" ]
}

@test "a file answers with an ETag built from its size and mtime" {
	request '' 'GET /file/venise.webp HTTP/1.0'
	[ "$(header ETag)" = "\"$(stat -c '%s-%Y' "$REPO_ROOT/file/venise.webp")\"" ]
}

@test "a matching If-None-Match is answered with a bodyless 304" {
	request '' 'GET /file/venise.webp HTTP/1.0'
	local -r etag="$(header ETag)"

	request '' 'GET /file/venise.webp HTTP/1.0' "If-None-Match: $etag"
	[ "$(status_code)" = '304' ]
	[ -z "$(body)" ]
	# a 304 carries the length of the answer it replaces, which the server cannot know
	[ -z "$(header Content-Length)" ]
}

@test "a stale If-None-Match gets the file again" {
	request '' 'GET /file/venise.webp HTTP/1.0' 'If-None-Match: "0-0"'
	[ "$(status_code)" = '200' ]
	[ -n "$(body)" ]
}

@test "a missing file is a 404" {
	request '' 'GET /file/nope.txt HTTP/1.0'
	[ "$(status_code)" = '404' ]
}

@test "a directory is a 404 rather than a listing" {
	request '' 'GET /file/pages HTTP/1.0'
	[ "$(status_code)" = '404' ]
	request '' 'GET /file/ HTTP/1.0'
	[ "$(status_code)" = '404' ]
}

@test "a script can serve a file from outside its own directory" {
	# page.sh runs from scripts/, so it reaches the page through ../file/
	request '' 'GET /page.sh?page=page.html HTTP/1.0'
	[ "$(status_code)" = '200' ]
	[ "$(header Content-Type)" = 'text/html' ]
}

@test "page.sh without its parameter is a 404" {
	request '' 'GET /page.sh HTTP/1.0'
	[ "$(status_code)" = '404' ]
	request '' 'GET /page.sh?page= HTTP/1.0'
	[ "$(status_code)" = '404' ]
}
