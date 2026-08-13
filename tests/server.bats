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

# Internal: Start the server on a free port, and export it as `SHERVER_PORT`.
function setup_file()
{
	command -v socat > /dev/null || skip 'socat is not installed'

	local -i port
	for (( port = 18080; port < 18120; port++ )); do
		( cd -- "$REPO_ROOT" && exec ./sherver.sh "$port" ) > /dev/null 2>&1 &
		local -i pid=$!
		local -i try
		for (( try = 0; try < 50; try++ )); do
			if curl -s -o /dev/null --max-time 2 "http://localhost:$port/"; then
				export SHERVER_PORT="$port" SHERVER_PID="$pid"
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
	run curl -s -i "http://localhost:$SHERVER_PORT/"
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == 'HTTP/1.0 200 OK'* ]]
	[[ "$output" == *'<h1>Sherver example</h1>'* ]]
}

@test "the port given on the command line is the one it listens on" {
	# setup_file only got a connection because sherver.sh honoured its argument
	[ -n "$SHERVER_PORT" ]
	run curl -s -o /dev/null -w '%{http_code}' "http://localhost:$SHERVER_PORT/index.sh"
	[ "$output" = '200' ]
}

@test "a binary file survives the socket" {
	run curl -s -o "$BATS_TEST_TMPDIR/venise.webp" \
		"http://localhost:$SHERVER_PORT/file/venise.webp"
	[ "$status" -eq 0 ]
	cmp "$BATS_TEST_TMPDIR/venise.webp" "$REPO_ROOT/file/venise.webp"
}

@test "concurrent clients are all served" {
	# this is why socat is used rather than netcat, which breaks on concurrency
	local -i i
	for (( i = 0; i < 15; i++ )); do
		curl -s -o /dev/null -w '%{http_code}\n' \
			"http://localhost:$SHERVER_PORT/index.sh?client=$i" \
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
	run curl -s --data-binary 'hello there' "http://localhost:$SHERVER_PORT/"
	[ "$status" -eq 0 ]
	[[ "$output" == *"You just sent me 'hello there'!"* ]]
}

@test "the server survives a client that says nothing" {
	# socat drops it after -T, and the next client must still be served
	timeout 2 bash -c "exec 3<>/dev/tcp/localhost/$SHERVER_PORT; sleep 1" || true
	run curl -s -o /dev/null -w '%{http_code}' "http://localhost:$SHERVER_PORT/"
	[ "$output" = '200' ]
}
