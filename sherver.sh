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

# 4.4, not 4.3: expanding an empty array under `set -u` was an error before, and the code does it
if (( BASH_VERSINFO[0] < 5 && (BASH_VERSINFO[0] < 4 || BASH_VERSINFO[1] < 4) )); then
	printf 'Sherver needs bash >= 4.4, this is %s\n' "$BASH_VERSION" >&2
	exit 1
fi

declare -r SHERVER_VERSION='1.1'

# Internal: Print the manual on stdout.
function usage()
{
	cat << EOF
SHERVER(1)

NAME
	sherver.sh - pure Bash lightweight web server

SYNOPSIS
	sherver.sh [--debug] [--ipv4] [--tls [--certs DIR]] [--port PORT | PORT]
	sherver.sh --help | --version

DESCRIPTION
	Listens on PORT (8080 by default) and forks one dispatcher.sh per
	connection, which answers the request from the file/ and scripts/
	folders of this checkout. Logs go to stderr; the process runs until
	it is signalled.

	Sherver is not hardened: anything executable under scripts/ is an
	endpoint. Never expose it on Internet.

OPTIONS
	--port PORT, PORT
		The TCP port to listen on. Anything socat accepts as a port,
		a service name included. Default: 8080.

	--ipv4
		Listen on IPv4 only. By default the socket is IPv6 and answers
		IPv4 clients too.

	--tls
		Serve HTTPS, with the TLS 1.3 floor and the certificate
		described in docs/https.md. Exports SHERVER_TLS=1 to the
		dispatcher and the scripts.

	--certs DIR
		Where cert.pem and key.pem are. Only meaningful with --tls,
		refused without it. A relative DIR is taken from the current
		directory. Default: the certs/ folder of this checkout.

	--debug
		Log the full requests and responses, never the bodies. Exports
		SHERVER_DEBUG=1 to the dispatcher and the scripts.

	--help
		Print this manual and exit.

	--version
		Print the version and exit.

EXIT STATUS
	The process is socat's once started. Before that: 2 on a wrong
	command line, 1 on an unusable certificate or checkout path, or
	a bash older than 4.4.

ENVIRONMENT
	SHERVER_DEBUG, SHERVER_TLS
		Set by the flags above for the dispatcher and the scripts it
		runs; a service can set them itself instead, see README.md.

SEE ALSO
	README.md, docs/https.md, systemd/sherver.service

AUTHOR
	Rémi Ducceschi

VERSION
	Sherver $SHERVER_VERSION
EOF
}

# Internal: Refuse the command line: reason on stderr, exit 2.
#
# $1 - the reason
function usage_error()
{
	printf 'Sherver: %s, see --help\n' "$1" >&2
	exit 2
}

declare port='8080' certs='' ipv4='' tls=''
# parsed before the cd below, so a relative --certs DIR means from where the user typed it.
# The environment is the only thing the dispatcher and the scripts it runs inherit from us
while [ $# -gt 0 ]; do
	case "$1" in
		--port)
			[ -n "${2:-}" ] || usage_error "$1 needs a value"
			port="$2"
			shift
			;;
		--certs)
			[ -n "${2:-}" ] || usage_error "$1 needs a value"
			case "$2" in
				/*)	certs="$2" ;;
				*)	certs="$PWD/$2" ;;
			esac
			shift
			;;
		--ipv4)		ipv4=1 ;;
		--tls)		tls=1; export SHERVER_TLS=1 ;;
		--debug)	export SHERVER_DEBUG=1 ;;
		--help)		usage; exit 0 ;;
		--version)	printf 'Sherver %s\n' "$SHERVER_VERSION"; exit 0 ;;
		-*)		usage_error "unknown option '$1'" ;;
		*)		port="$1" ;;
	esac
	shift
done
if [ -n "$certs" ] && [ -z "$tls" ]; then
	usage_error '--certs is only meaningful with --tls'
fi

cd "$(dirname "$0")"
[ -n "$certs" ] || certs="$PWD/certs"

# Options for socat, built from the flags: the listening address first, then the
# server model, which never changes
declare -a socat_options
if [ -n "$tls" ]; then
	# socat fails on an unreadable file too, but after the fork and with a less useful
	# message — typically a key generated as root when the service runs as `sherver`
	declare file
	for file in "$certs/cert.pem" "$certs/key.pem"; do
		if [ ! -r "$file" ]; then
			printf 'Sherver: cannot read %s, see docs/https.md\n' "$file" >&2
			exit 1
		fi
	done
	# HTTPS is TLS terminated in socat: the dispatcher reads plain text and never knows
	socat_options+=("OPENSSL-LISTEN:$port")
	# pf=ip6,ipv6only=0 is what TCP6-LISTEN implies: one socket for both stacks
	if [ -n "$ipv4" ]; then
		socat_options+=('pf=ip4')
	else
		socat_options+=('pf=ip6' 'ipv6only=0')
	fi
	# verify=0: don't ask the *client* for a certificate
	socat_options+=("cert=$certs/cert.pem" "key=$certs/key.pem")
	socat_options+=('verify=0' 'openssl-min-proto-version=TLS1.3')
elif [ -n "$ipv4" ]; then
	socat_options+=("TCP4-LISTEN:$port")
else
	# ipv6only=0 makes the IPv6 socket answer IPv4 clients too; TCP4 doesn't know the option
	socat_options+=("TCP6-LISTEN:$port" 'ipv6only=0')
fi
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

declare scheme='http'
[ -z "$tls" ] || scheme='https'
printf 'Sherver %s started, listening on %s (%s%s)\n' "$SHERVER_VERSION" "$port" "$scheme" "${ipv4:+, IPv4 only}" >&2


# IFS joins the array into socat's one comma-separated argument, and dies with the exec
IFS=','
# exec: socat replaces us, so systemd tracks and signals it instead of a bash wrapper
exec socat \
	`# -T: drop a connection gone silent (a client not reading its answer); the request itself is clocked by the dispatcher` \
	-T 10 \
	"${socat_options[*]}" \
	EXEC:'./dispatcher.sh'
