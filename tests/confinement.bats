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
# out of `site/static/` and `site/app/` gets its own case. The answer is always 404 and
# never 403: telling the two apart would say whether the path exists.

load 'test_helper'

# Internal: Check that the given URL is refused, and that the refusal leaks nothing.
function refuses()
{
	request '' "GET $1 HTTP/1.1" 'Host: localhost'
	[ "$(status_code)" = '404' ]
	# a 403 would confirm the target exists, and the body must not name it either
	[ "$(status_line)" = 'HTTP/1.1 404 Not Found' ]
	[[ "$(body)" != *"$REPO_ROOT"* ]]
}

# Internal: Check that the given URL is served with a 200.
function serves()
{
	request '' "GET $1 HTTP/1.1" 'Host: localhost'
	[ "$(status_code)" = '200' ]
}

# The symlinks the tests below create are removed here rather than in the test bodies,
# because bats stops a body at its first failing line and would leak them — `site/app/-e`
# would then be a live endpoint on the real server.
function teardown()
{
	rm -f "$REPO_ROOT/site/static/test-escape.txt" "$REPO_ROOT/site/static/test-inside.webp" \
		"$REPO_ROOT/site/app/-e"
}

# Both trees sit two levels down (`site/static/`, `site/app/`), so the escapes that aim at a
# real file need two `..` to reach the root — one, and the refusal would only be a 404 for a
# path that does not exist, which proves nothing about the check. The exception is `site/`
# itself: `site/routes.sh` and the sibling tree are real files a single `..` away.

@test "the site/ parent and the sibling tree are out of reach" {
	# a check that compared against `site/` instead of the served subtree would pass these
	refuses '/../routes.sh'
	refuses '/static/../routes.sh'
	refuses '/../static/venise.webp'
	refuses '/static/../app/index.sh'
}

@test "a relative escape out of site/static/ is refused" {
	refuses '/static/../../dispatcher.sh'
	refuses '/static/../../lib/SHERVER.sh'
	refuses '/static/../../../../../etc/passwd'
	refuses '/static/pages/../../../../etc/passwd'
}

@test "a relative escape out of site/app/ is refused" {
	refuses '/../../dispatcher.sh'
	refuses '/../../../etc/passwd'
	refuses '/utils/../../../dispatcher.sh'
}

@test "the library is out of reach from both trees" {
	# the engine lives in `lib/` so that no exec bit decides whether it is served
	refuses '/../../lib/SHERVER.sh'
	refuses '/../../lib/request.sh'
	refuses '/static/../../lib/request.sh'
}

@test "an absolute path is refused" {
	refuses '//etc/passwd'
	# the refusal must come from the deliberate branch, not from `./etc/passwd` happening
	# not to exist under `site/app/`
	[[ "$(log_output)" == *'FORBIDDEN: absolute path'* ]]
	refuses '/static//etc/passwd'
}

@test "an escape hidden in an absolute-form target is refused" {
	# the target is rewritten to its path before anything resolves it, so it lands in the
	# same check as an origin form — the authority is no way around it
	refuses 'http://example.com/static/../../dispatcher.sh'
	refuses 'https://example.com/../../../etc/passwd'
	refuses 'http://example.com//etc/passwd'
}

@test "a percent encoded escape is refused" {
	# the URL is decoded before it is resolved, so this is the same as `..`
	refuses '/static/%2e%2e/%2e%2e/dispatcher.sh'
	refuses '/static/%2E%2E/%2E%2E/%2E%2E/etc/passwd'
	refuses '/%2e%2e/%2e%2e/dispatcher.sh'
}

@test "a doubly encoded escape stays a literal directory name" {
	refuses '/static/%252e%252e/%252e%252e/dispatcher.sh'
}

@test "a script cannot be talked into escaping either" {
	# page.sh hands whatever it is given to send_file, from inside site/app/, as
	# `../static/pages/<page>`: three `..` from there reach the root
	refuses '/page.sh?page=../../../dispatcher.sh'
	refuses '/page.sh?page=../../../../etc/passwd'
	refuses '/page.sh?page=/etc/passwd'
	refuses '/page.sh?page=%2e%2e%2f%2e%2e%2f%2e%2e%2fdispatcher.sh'
}

@test "a symlink pointing out of the tree is refused" {
	# the path is canonicalized, so the link is followed before the check
	ln -sfn /etc/passwd "$REPO_ROOT/site/static/test-escape.txt"
	refuses '/static/test-escape.txt'
}

@test "a symlink staying inside the tree is served" {
	ln -sfn 'venise.webp' "$REPO_ROOT/site/static/test-inside.webp"
	serves '/static/test-inside.webp'
}

@test "a URL that looks like an option is still a path" {
	# `realpath` is called bare, so `/-e` must reach it as `./-e` and not as a flag
	ln -sfn 'index.sh' "$REPO_ROOT/site/app/-e"
	serves '/-e'
}

@test "a template is not served as a script" {
	# it lives under site/app/ but is not executable
	refuses '/templates/template.html'
}

@test "the server never answers 403" {
	# the split between 404 and 403 would be enough to map the file system
	local url
	for url in '/static/../../dispatcher.sh' '/../../etc/passwd' '/static/nope' '/nope.sh' \
		'/templates/template.html' '/page.sh?page=../../../LICENSE'; do
		request '' "GET $url HTTP/1.1" 'Host: localhost'
		[ "$(status_code)" != '403' ]
	done
}
