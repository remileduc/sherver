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

export LC_ALL=C.UTF-8

source 'lib/SHERVER.sh'

init_environment

# answer OPTIONS for the whole server, before any path resolution: that is what makes the
# asterisk-form `OPTIONS * HTTP/1.1` work, as `*` is no path and would only ever 404
if [ "$REQUEST_METHOD" = 'OPTIONS' ]; then
	add_header 'Allow' "$SUPPORTED_METHODS"
	# 200 with an empty body and not 204: a 204 MUST NOT carry the `Content-Length`
	# that `send_response` adds to everything but a 304
	send_response 200
fi

# shellcheck source=site/routes.sh
source 'site/routes.sh'

exit 0
