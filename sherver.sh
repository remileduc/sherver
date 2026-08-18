#!/bin/bash

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

set -efu

cd "$(dirname "$0")"

declare -r SHERVER_VERSION='1.0'

# the environment is the only thing the dispatcher and the scripts it runs inherit from us
if [ "${1:-}" = '--debug' ]; then
	export SHERVER_DEBUG=1
	shift
fi

if [ "${1:-}" = '--version' ]; then
	printf 'Sherver %s\n' "$SHERVER_VERSION"
	exit 0
fi

# Options for socat: everything a user may want to tune is one line here.
declare -a socat_options
# the listening port and IP stack — keep exactly one of the three *-LISTEN lines
# (ipv6only=0 makes the IPv6 socket answer IPv4 clients too; TCP4 doesn't know the option)
#socat_options+=("TCP4-LISTEN:${1:-8080}")
socat_options+=("TCP6-LISTEN:${1:-8080}" 'ipv6only=0')
# HTTPS: the same dual-stack listener behind TLS — generate the certificate first, see docs/https.md
# (pf=ip4 instead of pf=ip6,ipv6only=0 for IPv4 only; verify=0 = don't ask a *client* certificate)
#socat_options+=("OPENSSL-LISTEN:${1:-8080}" 'pf=ip6' 'ipv6only=0')
#socat_options+=("cert=$PWD/certs/cert.pem" "key=$PWD/certs/key.pem")
#socat_options+=('verify=0' 'openssl-min-proto-version=TLS1.3')
# ~6 connections a browser opens per user, times the number of simultaneous users
socat_options+=('max-children=32')
# connections blocked by `max-children` wait in this queue
socat_options+=('backlog=32')
# the server model itself, do not change: fork one dispatcher per connection, rebind
# the port immediately on restart, close the socket fully when the dispatcher exits
socat_options+=('reuseaddr' 'fork' 'end-close')

# the IFS=',' join below would silently split any option that contains a comma itself —
# typically a checkout path with one in it, reaching the array through cert=/key=
case "${socat_options[*]}" in
	*,*)	printf 'Sherver: no socat option may contain a comma (check the path to the checkout)\n' >&2
		exit 1
		;;
esac

printf 'Sherver %s started, listening on %s\n' "$SHERVER_VERSION" "${1:-8080}" >&2


# IFS joins the array into socat's one comma-separated argument, and dies with the exec
IFS=','
# exec: socat replaces us, so systemd tracks and signals it instead of a bash wrapper
exec socat \
	`# -T: drop a connection that goes silent, so a client can't pin a forked child forever` \
	-T 10 \
	"${socat_options[*]}" \
	EXEC:'./dispatcher.sh'
