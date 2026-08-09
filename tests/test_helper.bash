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

# `-f` is deliberately absent: bats leaks it into every test body, where it breaks
# globbing. `-e` is not set either, as bats already fails a test on the first error.
set -u

# Public: Absolute path to the root of the repository.
declare -g REPO_ROOT
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

# Public: Absolute path to the library, for the tests that source it.
declare -gr LIBRARY="$REPO_ROOT/scripts/SHERVER_UTILS.sh"

# Public: File holding the response of the last request. See `request()`.
declare -g RESPONSE=''
# Public: File holding what the last request wrote on stderr, which is the log.
declare -g RESPONSE_LOG=''

# Public: Send the given bytes to the dispatcher, exactly as given.
#
# The response is left in the file named by `RESPONSE`, and the log in the one named
# by `RESPONSE_LOG`. They are files rather than variables so that a binary body
# survives: a command substitution eats NUL bytes and trailing newlines.
#
# The dispatcher takes its cwd as `SHERVER_ROOT` and sources the library relatively,
# so it has to run from the root of the repository.
#
# Returns the exit code of the dispatcher.
#
# $1 - the raw request
#
# Examples
#
#    request_raw $'GET / HTTP/1.0\r\n\r\n'
function request_raw()
{
	RESPONSE="$BATS_TEST_TMPDIR/response"
	RESPONSE_LOG="$BATS_TEST_TMPDIR/log"
	printf '%s' "$1" | ( cd -- "$REPO_ROOT" && ./dispatcher.sh ) \
		> "$RESPONSE" 2> "$RESPONSE_LOG"
}

# Public: Send a request to the dispatcher, adding the CRLFs for you.
#
# The body is a separate argument because it goes after the empty line that closes
# the headers, and because it must not get a CRLF of its own.
#
# $1 - body of the request, empty for none
# $2... - the request line, then one argument per header
#
# Examples
#
#    request '' 'GET /index.sh?a=1 HTTP/1.0' 'Host: localhost'
#    request 'a=1&b=2' 'POST / HTTP/1.0' 'Content-Length: 7'
function request()
{
	local -r body="$1"
	shift
	local raw=''
	local line
	for line in "$@"; do
		raw+="$line"$'\r\n'
	done
	request_raw "$raw"$'\r\n'"$body"
}

# Public: Print the status code of the last response.
function status_code()
{
	head -n 1 -- "$RESPONSE" | cut -d ' ' -f 2
}

# Public: Print the whole status line of the last response, without the CR.
function status_line()
{
	head -n 1 -- "$RESPONSE" | tr -d '\r'
}

# Internal: Print the number of the line that closes the headers, CR included.
#
# Done in bash rather than with grep, because `grep` is not always GNU grep and the
# ones that answer to that name disagree on what `-m` means.
function _header_lines()
{
	local -i count=0
	local line
	while IFS= read -r line; do
		count+=1
		if [ "$line" = $'\r' ]; then
			break
		fi
	done < "$RESPONSE"
	printf '%s\n' "$count"
}

# Public: Print the value of the given response header, or nothing if it is absent.
#
# Header names are case insensitive, and the CR belongs to the protocol rather than
# to the value.
#
# $1 - name of the header
#
# Examples
#
#    [ "$(header Content-Type)" = 'text/html; charset=utf-8' ]
function header()
{
	local -r wanted="${1,,}"
	local line name
	while IFS= read -r line; do
		line="${line%$'\r'}"
		if [ -z "$line" ]; then
			break
		fi
		# the status line holds no `: `, so it never matches a header name
		name="${line%%: *}"
		if [ "${name,,}" = "$wanted" ]; then
			printf '%s\n' "${line#*: }"
		fi
	done < "$RESPONSE"
}

# Public: Print every header name of the last response, lowercased and sorted.
#
# Bash iterates `RESPONSE_HEADERS` in hash order, so the order they are written in is
# not something a test can rely on.
function header_names()
{
	local line name
	local -i first=1
	while IFS= read -r line; do
		line="${line%$'\r'}"
		if [ -z "$line" ]; then
			break
		fi
		if [ "$first" -eq 1 ]; then
			first=0
			continue
		fi
		name="${line%%: *}"
		printf '%s\n' "${name,,}"
	done < "$RESPONSE" | sort
}

# Public: Print the body of the last response, byte for byte.
#
# `tail` on the line that closes the headers keeps a binary body intact, where
# reading the whole response into a variable would not.
function body()
{
	tail -n "+$(( $(_header_lines) + 1 ))" -- "$RESPONSE"
}

# Public: Print the log the last request wrote on stderr.
function log_output()
{
	cat -- "$RESPONSE_LOG"
}

# Public: Run a snippet with the library sourced and a request already parsed.
#
# The request goes in on stdin, the way the dispatcher itself feeds it: sourcing the
# library runs `declare -g REQUEST_FULL_STRING=''` again, so presetting that variable
# would be wiped and `init_environment` would read stdin anyway.
#
# Use `run --separate-stderr` to keep the response out of the log.
#
# $1 - the raw request to parse (no CRs needed, they are stripped anyway)
# $2 - the bash snippet to run once the library is initialized
#
# Examples
#
#    run --separate-stderr with_request 'GET /index.sh?a=b HTTP/1.0' 'echo "$URL_BASE"'
function with_request()
{
	( cd -- "$REPO_ROOT" && bash -c "source '$LIBRARY'; init_environment; $2" ) <<< "$1"
}
