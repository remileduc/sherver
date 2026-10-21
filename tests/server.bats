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
# The suite of `sherver.sh`: its command line, and the plain TCP listener it starts.
# Everything the dispatcher does on its own is covered by the other files, so the
# socket tests only check what socat adds: that a real client is answered, and that
# concurrent clients do not tread on each other. `tests/https.bats` has the TLS side.

load 'test_helper'

bats_require_minimum_version 1.5.0

# Internal: Start `./sherver.sh` on the first free port of a range, and wait for it
# to answer. Sets `STARTED_PORT` and `STARTED_PID`; returns 1 when no port was free.
#
# $1 - the host to poll: `localhost`, or `127.0.0.1` for an `--ipv4` listener, as
#      curl tries `::1` first and a refused connection there costs a retry per poll
# $2 - the first port of the range to try (40 ports)
# $3 - where stderr — the log — goes
# $@ - any further flags for `sherver.sh`
function start_server()
{
	local -r host="$1" log="$3"
	local -ir first_port="$2"
	shift 3
	local -i port
	for (( port = first_port; port < first_port + 40; port++ )); do
		( cd -- "$REPO_ROOT" && exec ./sherver.sh "$@" --port "$port" ) > /dev/null 2> "$log" &
		local -i pid=$!
		local -i try
		for (( try = 0; try < 50; try++ )); do
			if curl -s -o /dev/null --max-time 2 "http://$host:$port/"; then
				declare -g STARTED_PORT="$port" STARTED_PID="$pid"
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

# Internal: Open a connection, send `$1` at once, then one more byte every 2 s until the
# server answers — or 40 s pass, when it never does. Prints the response.
#
# For the deadline tests: a byte every 2 s never trips socat's `-T 10`, which is an
# inactivity timeout, so only the dispatcher's own clock can end such a request. The
# client ignores SIGPIPE, as the server closing mid-drip is the very outcome under test:
# a write that then fails must end the loop, not kill the client before its `wait`.
#
# $1 - the start of the request, sent at once
function drip_request()
{
	timeout 40 bash -c '
		exec 3<> "/dev/tcp/localhost/$1"
		cat <&3 &
		reader=$!
		printf "%s" "$2" >&3
		trap "" PIPE
		while sleep 2 && kill -0 "$reader" 2> /dev/null; do
			printf "x" >&3 2> /dev/null || break
		done
		wait
	' drip "$SHERVER_PORT" "$1"
}

# Internal: Start the server and export the URL to reach it as `SHERVER_URL` (plus
# `SHERVER_PORT` for the raw-socket tests).
function setup_file()
{
	command -v socat > /dev/null || skip 'socat is not installed'

	# stderr goes to a file: it is the log, and the access-line test reads it
	start_server 'localhost' 18080 "$BATS_FILE_TMPDIR/server.log"
	export SHERVER_URL="http://localhost:$STARTED_PORT" SHERVER_PORT="$STARTED_PORT" \
		SHERVER_PID="$STARTED_PID" SHERVER_LOG="$BATS_FILE_TMPDIR/server.log"
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

# The command line: every path that exits before socat is exec'd needs no port.

@test "--version prints the version and exits" {
	run --separate-stderr "$REPO_ROOT/sherver.sh" --version
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^Sherver\ [0-9]+\.[0-9]+$ ]]
}

@test "--help prints the manual and exits" {
	run --separate-stderr "$REPO_ROOT/sherver.sh" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *'SYNOPSIS'* ]]
	[[ "$output" == *'--certs DIR'* ]]
	# the manual carries the version, and it is the one the flag prints
	local version
	version=$("$REPO_ROOT/sherver.sh" --version)
	[[ "$output" == *"$version"* ]]
}

@test "an unknown option is refused with a pointer to --help" {
	run "$REPO_ROOT/sherver.sh" --bogus
	[ "$status" -eq 2 ]
	[[ "$output" == *"'--bogus'"*'--help'* ]]
}

@test "a flag that needs a value is refused without one" {
	run "$REPO_ROOT/sherver.sh" --port
	[ "$status" -eq 2 ]
	[[ "$output" == *'--port needs a value'* ]]
	run "$REPO_ROOT/sherver.sh" --tls --certs
	[ "$status" -eq 2 ]
	[[ "$output" == *'--certs needs a value'* ]]
}

@test "--certs without --tls is refused" {
	run "$REPO_ROOT/sherver.sh" --certs "$BATS_TEST_TMPDIR"
	[ "$status" -eq 2 ]
	[[ "$output" == *'--certs is only meaningful with --tls'* ]]
}

@test "--tls fails before socat when the certificate is unreadable" {
	# the message names the file and the doc, where socat would only name the OpenSSL call
	run "$REPO_ROOT/sherver.sh" --tls --certs "$BATS_TEST_TMPDIR"
	[ "$status" -eq 1 ]
	[[ "$output" == *"$BATS_TEST_TMPDIR/cert.pem"*'docs/https.md'* ]]
}

# The listener.

@test "a real client is answered" {
	run curl -s -i "$SHERVER_URL/"
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == 'HTTP/1.1 200 OK'* ]]
	[[ "$output" == *'<h1>Sherver example</h1>'* ]]
}

@test "the port given on the command line is the one it listens on" {
	# setup_file only got a connection because sherver.sh honoured --port
	[ -n "$SHERVER_PORT" ]
	run curl -s -o /dev/null -w '%{http_code}' "$SHERVER_URL/index.sh"
	[ "$output" = '200' ]
	# and the banner names it
	grep -q "^Sherver .* started, listening on $SHERVER_PORT (http)\$" "$SHERVER_LOG"
}

@test "--ipv4 listens on IPv4 only" {
	start_server '127.0.0.1' 18160 "$BATS_TEST_TMPDIR/ipv4.log" --ipv4
	local -i v4=0 v6=0
	curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$STARTED_PORT/" || v4=$?
	curl -s -o /dev/null --max-time 2 "http://[::1]:$STARTED_PORT/" || v6=$?
	# stop it before asserting, or a failure here leaves a listener behind
	kill "$STARTED_PID" 2> /dev/null || true
	[ "$v4" -eq 0 ]
	[ "$v6" -ne 0 ]
	grep -q ' (http, IPv4 only)$' "$BATS_TEST_TMPDIR/ipv4.log"
}

@test "the access line names the client address" {
	run curl -s -o /dev/null "$SHERVER_URL/index.sh?from=access-log-test"
	[ "$status" -eq 0 ]
	# the exact spelling is socat's (it prints IPv6 expanded and bracketed), so only
	# assert an address took the place of the `-` the filter-driven suites get
	grep -qE '^[^- ][^ ]* GET /index\.sh\?from=access-log-test 200$' "$SHERVER_LOG"
}

@test "a binary file survives the socket" {
	run curl -s -o "$BATS_TEST_TMPDIR/venise.webp" \
		"$SHERVER_URL/static/venise.webp"
	[ "$status" -eq 0 ]
	cmp "$BATS_TEST_TMPDIR/venise.webp" "$REPO_ROOT/site/static/venise.webp"
}

@test "concurrent clients are all served" {
	# this is why socat is used rather than netcat, which breaks on concurrency
	local -i i
	for (( i = 0; i < 15; i++ )); do
		curl -s -o /dev/null -w '%{http_code}\n' \
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
	run curl -s --data-binary 'hello there' "$SHERVER_URL/"
	[ "$status" -eq 0 ]
	[[ "$output" == *"You just sent me 'hello there'!"* ]]
}

@test "the server survives a client that says nothing" {
	# socat drops it after -T, and the next client must still be served
	timeout 2 bash -c "exec 3<>/dev/tcp/localhost/$SHERVER_PORT; sleep 1" || true
	run curl -s -o /dev/null -w '%{http_code}' "$SHERVER_URL/"
	[ "$output" = '200' ]
}

# The request deadline: the only clock socat has is an inactivity timeout, so these are
# the two tests in the suite that need a real socket and real time — about 12 s each.

@test "a client dripping a header line is answered 408 by the deadline" {
	local -i started=$SECONDS
	run --separate-stderr drip_request $'GET / HTTP/1.1\r\nHost: l'
	local -ri took=$(( SECONDS - started ))
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == 'HTTP/1.1 408 Request Timeout'* ]]
	# MAX_REQUEST_TIME is 10 s: well under 20 proves the dispatcher ended it, not the
	# client giving up at 40
	[ "$took" -lt 20 ]
	grep -q 'REQUEST TIMEOUT: request not complete' "$SHERVER_LOG"
	# and the slot is free again
	run curl -s -o /dev/null -w '%{http_code}' "$SHERVER_URL/"
	[ "$output" = '200' ]
}

@test "a client dripping its body is answered 408 by the same deadline" {
	local -i started=$SECONDS
	run --separate-stderr drip_request \
		$'POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1000\r\n\r\nhello'
	local -ri took=$(( SECONDS - started ))
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == 'HTTP/1.1 408 Request Timeout'* ]]
	[ "$took" -lt 20 ]
}
