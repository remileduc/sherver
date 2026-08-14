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
#
# This is the one part of Sherver where security is taken seriously, so every way
# out of `file/` and `scripts/` gets its own case. The answer is always 404 and
# never 403: telling the two apart would say whether the path exists.

load 'test_helper'

# Internal: Check that the given URL is refused, and that the refusal leaks nothing.
function refuses()
{
	request '' "GET $1 HTTP/1.0"
	[ "$(status_code)" = '404' ]
	# a 403 would confirm the target exists, and the body must not name it either
	[ "$(status_line)" = 'HTTP/1.0 404 Not Found' ]
	[[ "$(body)" != *"$REPO_ROOT"* ]]
}

# Internal: Check that the given URL is served with a 200.
function serves()
{
	request '' "GET $1 HTTP/1.0"
	[ "$(status_code)" = '200' ]
}

# The symlinks the tests below create are removed here rather than in the test bodies,
# because bats stops a body at its first failing line and would leak them — `scripts/-e`
# would then be a live endpoint on the real server.
function teardown()
{
	rm -f "$REPO_ROOT/file/test-escape.txt" "$REPO_ROOT/file/test-inside.webp" \
		"$REPO_ROOT/scripts/-e"
}

@test "a relative escape out of file/ is refused" {
	refuses '/file/../dispatcher.sh'
	refuses '/file/../scripts/SHERVER_UTILS.sh'
	refuses '/file/../../../../etc/passwd'
	refuses '/file/pages/../../../etc/passwd'
}

@test "a relative escape out of scripts/ is refused" {
	refuses '/../dispatcher.sh'
	refuses '/../../etc/passwd'
	refuses '/utils/../../dispatcher.sh'
}

@test "an absolute path is refused" {
	refuses '//etc/passwd'
	# the refusal must come from the deliberate branch, not from `./etc/passwd` happening
	# not to exist under `scripts/`
	[[ "$(log_output)" == *'FORBIDDEN: absolute path'* ]]
	refuses '/file//etc/passwd'
}

@test "a percent encoded escape is refused" {
	# the URL is decoded before it is resolved, so this is the same as `..`
	refuses '/file/%2e%2e/dispatcher.sh'
	refuses '/file/%2E%2E/%2E%2E/etc/passwd'
	refuses '/%2e%2e/dispatcher.sh'
}

@test "a doubly encoded escape stays a literal directory name" {
	refuses '/file/%252e%252e/dispatcher.sh'
}

@test "a script cannot be talked into escaping either" {
	# page.sh hands whatever it is given to send_file, from inside scripts/
	refuses '/page.sh?page=../../dispatcher.sh'
	refuses '/page.sh?page=../../../etc/passwd'
	refuses '/page.sh?page=/etc/passwd'
	refuses '/page.sh?page=%2e%2e%2f%2e%2e%2fdispatcher.sh'
}

@test "a symlink pointing out of the tree is refused" {
	# the path is canonicalized, so the link is followed before the check
	ln -sfn /etc/passwd "$REPO_ROOT/file/test-escape.txt"
	refuses '/file/test-escape.txt'
}

@test "a symlink staying inside the tree is served" {
	ln -sfn 'venise.webp' "$REPO_ROOT/file/test-inside.webp"
	serves '/file/test-inside.webp'
}

@test "a URL that looks like an option is still a path" {
	# `realpath` is called bare, so `/-e` must reach it as `./-e` and not as a flag
	ln -sfn 'index.sh' "$REPO_ROOT/scripts/-e"
	serves '/-e'
}

@test "a template is not served as a script" {
	# it lives under scripts/ but is not executable
	refuses '/templates/template.html'
}

@test "the server never answers 403" {
	# the split between 404 and 403 would be enough to map the file system
	local url
	for url in '/file/../dispatcher.sh' '/../etc/passwd' '/file/nope' '/nope.sh' \
		'/templates/template.html' '/page.sh?page=../../LICENSE'; do
		request '' "GET $url HTTP/1.0"
		[ "$(status_code)" != '403' ]
	done
}
