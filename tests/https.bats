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
# The TLS listener. `tests/server.bats` starts `sherver.sh` in plain TCP, so this
# suite starts the `OPENSSL-LISTEN` recipe of `docs/https.md` — what `./sherver.sh
# --tls` builds — itself. Everything above the socket is tested elsewhere — what is
# checked here is that TLS terminates in socat and the dispatcher still answers
# through it, unchanged and unaware.
#
# The certificate is generated per run, which also checks that the recipe of the docs
# produces something socat and curl accept. `tests/localhost.pem` — certificate and key
# in the one file socat and curl both read — is the fallback for a machine without the
# `openssl` command. Committing that key costs nothing: it serves `localhost` and it is
# never the server's, which stays in the gitignored `certs/`.

load 'test_helper'

bats_require_minimum_version 1.5.0

# Internal: Get a certificate and start a TLS listener on a free port.
#
# The socat address is composed here rather than taken from `./sherver.sh --tls`,
# because the suite degrades where the launcher refuses: a socat too old for one
# option gets the recipe without it, a host without IPv6 gets `pf=ip4`. The first
# test checks the launcher builds the very string this suite starts from. The
# certificate is the one thing that legitimately differs: the real one lives in
# `certs/` at the root of the checkout, and a test has no business writing a private
# key there.
#
# Only a socat that cannot speak TLS at all stops the suite. A missing `openssl` or a
# socat too old for one option costs the test that needs it, not the other seven.
function setup_file()
{
	command -v socat > /dev/null || skip 'socat is not installed'
	socat -V | grep -q '#define WITH_OPENSSL 1' || skip 'socat is built without OpenSSL'

	# TLS 1.3 as a floor needs socat 1.7.4, everything else here does not. The name has
	# to be the full one: `min-proto-version` is an alias socat only grew in 1.8.1, so
	# grepping for it would match the long name and then fail to start on 1.8.0
	export SHERVER_MIN_PROTO=''
	if socat -hhh | grep -q 'openssl-min-proto-version'; then
		SHERVER_MIN_PROTO=1
	fi

	# whatever went wrong is in there, and there is nowhere else to read it from once
	# bats has swallowed the output of a failing setup
	local -r log="$BATS_FILE_TMPDIR/socat.log"
	# cert.pem and key.pem, the names `--certs` expects: the recipe test hands the
	# launcher this directory
	export SHERVER_CERT="$BATS_FILE_TMPDIR/cert.pem"
	local -r key="$BATS_FILE_TMPDIR/key.pem"
	# the recipe from docs/https.md, but named after localhost so that curl can verify
	# it without `-k`, and valid for a day as it dies with the suite. `basicConstraints`
	# is spelled out rather than left to the `-x509` default, which openssl only sets
	# since 3.0 and which curl needs to accept the certificate as its own authority
	if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
		-keyout "$key" -out "$SHERVER_CERT" -days 1 -nodes \
		-subj '/CN=localhost' \
		-addext 'basicConstraints=critical,CA:TRUE' \
		-addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' 2> "$log"
	then
		# no openssl, or one that chokes on the recipe: the point of the suite is the
		# transport, so fall back on the fixture rather than test nothing. It holds both
		# objects, and OpenSSL reads the one it is asked for out of either copy
		cat -- "$log"
		printf 'falling back on tests/localhost.pem\n'
		[ -f "$REPO_ROOT/tests/localhost.pem" ] || skip 'no certificate to serve with'
		cp -- "$REPO_ROOT/tests/localhost.pem" "$SHERVER_CERT"
		cp -- "$REPO_ROOT/tests/localhost.pem" "$key"
	fi

	# the recipe of docs/https.md on this certificate, in the one comma-separated
	# address sherver.sh joins its array into (which is also why no path here may
	# contain a comma). The listener below is this string with at most two options
	# taken out, and the port swapped
	export SHERVER_RECIPE="OPENSSL-LISTEN:8080,pf=ip6,ipv6only=0,cert=$SHERVER_CERT,key=$key"
	SHERVER_RECIPE+=',verify=0,openssl-min-proto-version=TLS1.3'
	SHERVER_RECIPE+=',max-children=32,backlog=32,reuseaddr,fork,end-close'

	local -i port
	local family
	# the recipe listens dual stack; a host without IPv6 — some CI runners — gets an
	# IPv4 listener, as which family socat binds is tests/server.bats's business
	for family in 'pf=ip6,ipv6only=0' 'pf=ip4'; do
		# a range of its own: tests/server.bats takes 18080 and up
		for (( port = 18120; port < 18160; port++ )); do
			local address="${SHERVER_RECIPE/:8080,/:$port,}"
			address="${address/pf=ip6,ipv6only=0/$family}"
			[ -n "$SHERVER_MIN_PROTO" ] || address="${address/,openssl-min-proto-version=TLS1.3/}"
			( cd -- "$REPO_ROOT" && exec socat -T 10 "$address" EXEC:./dispatcher.sh ) \
				> /dev/null 2> "$log" &
			local -i pid=$!
			local -i try
			for (( try = 0; try < 50; try++ )); do
				# -k, not --cacert: this only waits for the socket, and whether the
				# certificate verifies is a test of its own
				if curl -ks -o /dev/null --max-time 2 "https://localhost:$port/"; then
					export SHERVER_URL="https://localhost:$port" \
						SHERVER_PORT="$port" SHERVER_PID="$pid"
					return 0
				fi
				# socat exits when the port is taken: stop polling and try the next one
				kill -0 "$pid" 2> /dev/null || break
				sleep 0.1
			done
			kill "$pid" 2> /dev/null || true
			# whatever this socat calls that option, it is the only optional one here:
			# drop it and let the next port try without, rather than test nothing
			if [ -n "$SHERVER_MIN_PROTO" ] && grep -q 'unknown option' -- "$log"; then
				SHERVER_MIN_PROTO=''
				continue
			fi
			# it stayed up and answered nothing, so the port is not what is wrong here:
			# the 39 others would each cost the same five seconds
			[ "$try" -lt 50 ] || break
		done
	done
	printf 'no TLS listener could be started, last socat log:\n'
	cat -- "$log"
	return 1
}

# Internal: Stop the listener. Unset means nothing started, and a `kill 0` fallback
# would signal the whole process group, bats included.
function teardown_file()
{
	if [ -n "${SHERVER_PID:-}" ]; then
		kill "$SHERVER_PID" 2> /dev/null || true
	fi
}

@test "--tls builds the recipe this suite runs" {
	# sherver.sh execs whatever `socat` resolves to, so a stub first in PATH receives the
	# exact address the flags built, without a port being opened. This is what keeps
	# the copy in setup_file from drifting away from the launcher silently
	local -r stub="$BATS_TEST_TMPDIR/bin"
	mkdir -- "$stub"
	printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' > "$stub/socat"
	chmod +x "$stub/socat"
	# the banner goes to stderr: only socat's argv is on stdout, one word per line
	run --separate-stderr env PATH="$stub:$PATH" "$REPO_ROOT/sherver.sh" \
		--tls --certs "$BATS_FILE_TMPDIR"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = '-T' ]
	[ "${lines[2]}" = "$SHERVER_RECIPE" ]
	[ "${lines[3]}" = 'EXEC:./dispatcher.sh' ]
	# and --ipv4 is the same recipe on the other family, what the fallback above binds
	run --separate-stderr env PATH="$stub:$PATH" "$REPO_ROOT/sherver.sh" \
		--tls --certs "$BATS_FILE_TMPDIR" --ipv4
	[ "$status" -eq 0 ]
	[ "${lines[2]}" = "${SHERVER_RECIPE/pf=ip6,ipv6only=0/pf=ip4}" ]
	[[ "$stderr" == *'(https, IPv4 only)'* ]]
}

@test "a client that verifies the certificate is answered" {
	# no -k: a MITM that presents its own certificate is what this rejects
	run curl -s --cacert "$SHERVER_CERT" -i "$SHERVER_URL/"
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == 'HTTP/1.1 200 OK'* ]]
	[[ "$output" == *'<h1>Sherver example</h1>'* ]]
}

@test "a client that does not trust the certificate is refused" {
	run curl -s -o /dev/null --max-time 5 "$SHERVER_URL/"
	[ "$status" -ne 0 ]
}

@test "TLS 1.2 is refused and TLS 1.3 is not" {
	[ -n "$SHERVER_MIN_PROTO" ] || skip 'this socat has no min-proto-version'
	# what min-proto-version buys, and the one option that dates the setup: it also
	# locks out clients older than Android 10 / iOS 12.2
	run curl -s -o /dev/null --max-time 5 --cacert "$SHERVER_CERT" \
		--tls-max 1.2 "$SHERVER_URL/"
	[ "$status" -ne 0 ]
	run curl -s -o /dev/null -w '%{http_code}' --cacert "$SHERVER_CERT" \
		--tlsv1.3 "$SHERVER_URL/"
	[ "$output" = '200' ]
}

@test "a plaintext request to the TLS port gets nothing" {
	# socat is one listener, not a web server: there is no redirect and no fallback
	run curl -s --max-time 5 "http://localhost:$SHERVER_PORT/"
	[ "$status" -ne 0 ]
	[ -z "$output" ]
}

@test "a binary file survives TLS" {
	run curl -s --cacert "$SHERVER_CERT" -o "$BATS_TEST_TMPDIR/venise.webp" \
		"$SHERVER_URL/static/venise.webp"
	[ "$status" -eq 0 ]
	cmp "$BATS_TEST_TMPDIR/venise.webp" "$REPO_ROOT/site/static/venise.webp"
}

@test "concurrent TLS clients are all served" {
	# every connection runs its own handshake in its own forked child
	local -i i
	for (( i = 0; i < 8; i++ )); do
		curl -s --cacert "$SHERVER_CERT" -o /dev/null -w '%{http_code}\n' \
			"$SHERVER_URL/index.sh?client=$i" \
			> "$BATS_TEST_TMPDIR/client-$i" &
	done
	wait

	local -i served=0
	for (( i = 0; i < 8; i++ )); do
		[ "$(cat "$BATS_TEST_TMPDIR/client-$i")" = '200' ] && served+=1
	done
	[ "$served" -eq 8 ]
}

@test "a POST reaches the script through TLS" {
	# the dispatcher reads plain text on stdin and knows nothing of the encryption
	run curl -s --cacert "$SHERVER_CERT" --data-binary 'hello there' "$SHERVER_URL/"
	[ "$status" -eq 0 ]
	[[ "$output" == *"You just sent me 'hello there'!"* ]]
}
