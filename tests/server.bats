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
# The only suite that opens a port. Everything the dispatcher does on its own is
# covered by the other files, so this one only checks what socat adds: that a real
# client is answered, and that concurrent clients do not tread on each other.

load 'test_helper'

# Internal: Start the server on a free port, and export the URL to reach it as
# `SHERVER_URL` (plus `SHERVER_PORT` for the raw-socket test).
function setup_file()
{
	command -v socat > /dev/null || skip 'socat is not installed'

	# the suite follows the mode configured in sherver.sh — over TLS, `-k` on every curl
	# stands in for trusting the certificate, whose names need not include localhost
	local scheme='http'
	if grep -q '^socat_options+=("OPENSSL-LISTEN' "$REPO_ROOT/sherver.sh"; then
		scheme='https'
		[ -f "$REPO_ROOT/certs/cert.pem" ] || skip 'HTTPS is on but certs/cert.pem is missing, see docs/https.md'
	fi

	local -i port
	for (( port = 18080; port < 18120; port++ )); do
		# stderr goes to a file: it is the log, and the access-line test reads it
		( cd -- "$REPO_ROOT" && exec ./sherver.sh "$port" ) > /dev/null 2> "$BATS_FILE_TMPDIR/server.log" &
		local -i pid=$!
		local -i try
		for (( try = 0; try < 50; try++ )); do
			if curl -ks -o /dev/null --max-time 2 "$scheme://localhost:$port/"; then
				export SHERVER_URL="$scheme://localhost:$port" SHERVER_PORT="$port" SHERVER_PID="$pid"
				export SHERVER_LOG="$BATS_FILE_TMPDIR/server.log"
				return 0
			fi
			# socat exits when the port is taken: stop polling and try the next one
			kill -0 "$pid" 2> /dev/null || break
			sleep 0.1
		done
		kill "$pid" 2> /dev/null || true
	done
	return 1
}

# Internal: Stop the server.
#
# `sherver.sh` execs socat, so the PID from `setup_file` is the listener itself.
# Unset means nothing started — and a `kill 0` fallback would signal the whole
# process group, bats included.
function teardown_file()
{
	if [ -n "${SHERVER_PID:-}" ]; then
		kill "$SHERVER_PID" 2> /dev/null || true
	fi
}

@test "a real client is answered" {
	run curl -ks -i "$SHERVER_URL/"
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == 'HTTP/1.0 200 OK'* ]]
	[[ "$output" == *'<h1>Sherver example</h1>'* ]]
}

@test "the port given on the command line is the one it listens on" {
	# setup_file only got a connection because sherver.sh honoured its argument
	[ -n "$SHERVER_PORT" ]
	run curl -ks -o /dev/null -w '%{http_code}' "$SHERVER_URL/index.sh"
	[ "$output" = '200' ]
}

@test "the access line names the client address" {
	run curl -ks -o /dev/null "$SHERVER_URL/index.sh?from=access-log-test"
	[ "$status" -eq 0 ]
	# the exact spelling is socat's (it prints IPv6 expanded and bracketed), so only
	# assert an address took the place of the `-` the filter-driven suites get
	grep -qE '^[^- ][^ ]* GET /index\.sh\?from=access-log-test 200$' "$SHERVER_LOG"
}

@test "a binary file survives the socket" {
	run curl -ks -o "$BATS_TEST_TMPDIR/venise.webp" \
		"$SHERVER_URL/file/venise.webp"
	[ "$status" -eq 0 ]
	cmp "$BATS_TEST_TMPDIR/venise.webp" "$REPO_ROOT/file/venise.webp"
}

@test "concurrent clients are all served" {
	# this is why socat is used rather than netcat, which breaks on concurrency
	local -i i
	for (( i = 0; i < 15; i++ )); do
		curl -ks -o /dev/null -w '%{http_code}\n' \
			"$SHERVER_URL/index.sh?client=$i" \
			> "$BATS_TEST_TMPDIR/client-$i" &
	done
	wait

	local -i served=0
	for (( i = 0; i < 15; i++ )); do
		[ "$(cat "$BATS_TEST_TMPDIR/client-$i")" = '200' ] && served+=1
	done
	[ "$served" -eq 15 ]
}

@test "a POST from a real client reaches the script" {
	run curl -ks --data-binary 'hello there' "$SHERVER_URL/"
	[ "$status" -eq 0 ]
	[[ "$output" == *"You just sent me 'hello there'!"* ]]
}

@test "the server survives a client that says nothing" {
	# socat drops it after -T, and the next client must still be served
	timeout 2 bash -c "exec 3<>/dev/tcp/localhost/$SHERVER_PORT; sleep 1" || true
	run curl -ks -o /dev/null -w '%{http_code}' "$SHERVER_URL/"
	[ "$output" = '200' ]
}
