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

# every path below is relative to the root, and this script lives in `tests/`
cd "$(dirname "$0")/.."

declare -r LIBRARY='scripts/SHERVER_UTILS.sh'
declare -i FAILURES=0

# Every file we wrote, straight from git: it already knows about `tomdoc.sh` and the
# rest of `.gitignore`, and a file nobody committed is not ours to check.
declare -a SOURCE_FILES
mapfile -t SOURCE_FILES < <(git ls-files -- '*.sh' '*.bash' '*.bats')

# What bash itself can read. A `.bats` file is not valid bash until bats has rewritten
# its `@test` blocks, so neither shellcheck nor `bash -n` can say anything about it.
declare -a SHELL_FILES
mapfile -t SHELL_FILES < <(git ls-files -- '*.sh' '*.bash')

# Standalone scripts, as opposed to the `.bash` helpers that bats sources into the
# tests: `-f` leaks from a helper into every test body and breaks globbing there.
declare -a STANDALONE_SCRIPTS
mapfile -t STANDALONE_SCRIPTS < <(git ls-files -- '*.sh')

# Test files, which only bats can parse.
declare -a BATS_FILES
mapfile -t BATS_FILES < <(git ls-files -- '*.bats')

# Every check below walks a list of files, so an empty list would make all of them
# pass without looking at anything. Fail loudly instead.
if [ ! -f "$LIBRARY" ]; then
	printf '%s: %s is missing, run me from a checkout\n' "$0" "$LIBRARY" >&2
	exit 2
fi
if [[ " ${STANDALONE_SCRIPTS[*]} " != *" $LIBRARY "* ]]; then
	printf '%s: git does not list %s, is this a git checkout?\n' "$0" "$LIBRARY" >&2
	exit 2
fi

# Internal: Run one check and report it. A check reports its findings on its output.
#
# Exit code 77 means the check could not run and is reported as skipped, following
# the convention of autotools and of most test runners.
#
# $1 - human readable name of the check
# $2... - the command to run
function check()
{
	local -r name="$1"
	shift
	local output
	local -i status=0
	output=$("$@" 2>&1) || status=$?
	case "$status" in
		0)
			printf '  ok   %s\n' "$name"
			;;
		77)
			printf ' skip  %s\n' "$name"
			;;
		*)
			printf ' FAIL  %s\n' "$name"
			FAILURES+=1
			;;
	esac
	if [ -n "$output" ] && [ "$status" -ne 0 ]; then
		printf '%s\n' "$output" | sed 's/^/         /'
	fi
}

# Internal: Report the given files as offending, if there are any.
#
# $1 - the message to print before the list
# $2... - the offending files
function report()
{
	local -r message="$1"
	shift
	if [ "$#" -eq 0 ]; then
		return 0
	fi
	printf '%s\n' "$message"
	printf '  %s\n' "$@"
	return 1
}

# Internal: Static analysis. `-x` follows the `source` in the dispatcher.
function check_shellcheck()
{
	shellcheck --external-sources -- "${SHELL_FILES[@]}"
}

# Internal: Every script must at least parse.
function check_syntax()
{
	local file
	local -a broken=()
	for file in "${SHELL_FILES[@]}"; do
		bash -n "$file" || broken+=("$file")
	done
	report 'does not parse:' "${broken[@]}"
}

# Internal: Same for the test files, which only bats can parse.
#
# `--count` stops after collecting the tests, so it reports a syntax error without
# running anything.
function check_bats_syntax()
{
	if ! command -v bats > /dev/null; then
		echo 'bats is not installed'
		return 77
	fi
	local file
	local -a broken=()
	for file in "${BATS_FILES[@]}"; do
		bats --count "$file" > /dev/null || broken+=("$file")
	done
	report 'does not parse:' "${broken[@]}"
}

# Internal: `-e -f -u` is the contract every script relies on, `-f` especially:
# an unquoted expansion would otherwise glob against the server's own files.
function check_shell_options()
{
	local file
	local -a missing=()
	for file in "${STANDALONE_SCRIPTS[@]}"; do
		grep -qx 'set -efu' "$file" || missing+=("$file")
	done
	report "missing 'set -efu':" "${missing[@]}"
}

# Internal: The project ships under the MIT license, so every source file says so.
function check_license()
{
	local file
	local -a missing=()
	for file in "${SOURCE_FILES[@]}"; do
		grep -q 'MIT License' "$file" || missing+=("$file")
	done
	report 'missing the MIT header:' "${missing[@]}"
}

# Internal: Tabs for indentation, and no trailing blanks or CRLF.
#
# A stray CR matters more than usual here: the parser strips the CR of the request
# itself, so one in the source is genuinely confusing to read.
function check_whitespace()
{
	local -i status=0
	local -a found=()
	mapfile -t found < <(grep -nP '^\t* +' -- "${SOURCE_FILES[@]}")
	report 'indented with spaces:' "${found[@]}" || status=1
	mapfile -t found < <(grep -nP '[ \t]+$' -- "${SOURCE_FILES[@]}")
	report 'trailing whitespace:' "${found[@]}" || status=1
	mapfile -t found < <(grep -lP '\r$' -- "${SOURCE_FILES[@]}")
	report 'CRLF line endings:' "${found[@]}" || status=1
	return "$status"
}

# Internal: A library function without `export -f` is invisible to the child scripts,
# which fail at run time with `command not found` and nothing else.
function check_exports()
{
	local -i status=0
	local -a names=()
	mapfile -t names < <(comm -23 \
		<(grep -oP '^function \K\w+' "$LIBRARY" | sort) \
		<(grep -oP '^export -f \K\w+' "$LIBRARY" | sort))
	report "declared but never exported with 'export -f':" "${names[@]}" || status=1
	mapfile -t names < <(comm -13 \
		<(grep -oP '^function \K\w+' "$LIBRARY" | sort) \
		<(grep -oP '^export -f \K\w+' "$LIBRARY" | sort))
	report "exported with 'export -f' but not declared:" "${names[@]}" || status=1
	return "$status"
}

# Internal: Every library function needs a TomDoc block, as `docs/functions.md` is
# generated from them.
function check_tomdoc()
{
	local -a lines
	mapfile -t lines < "$LIBRARY"
	local -a undocumented=()
	local name line documented
	local -i i
	while IFS=: read -r line name; do
		# walk back over the comment block sitting right above the declaration.
		# `lines` is 0 indexed, so the line above line N sits at N-2
		documented=false
		for (( i=line-2; i >= 0; i-- )); do
			[[ ${lines[i]} == '#'* ]] || break
			if [[ ${lines[i]} == *'Public:'* || ${lines[i]} == *'Internal:'* ]]; then
				documented=true
				break
			fi
		done
		[ "$documented" = true ] || undocumented+=("$name (line $line)")
	done < <(grep -noP '^function \K\w+' "$LIBRARY")
	report "missing a 'Public:'/'Internal:' TomDoc block:" "${undocumented[@]}"
}

# Internal: `send_error` looks the code up in `HTTP_RESPONSE` under `set -u`, so an
# unknown one — sent directly or through `_bail_request` — kills the script mid-answer
# instead of producing an error page.
function check_error_codes()
{
	local -A known=()
	local code
	while read -r code; do
		known["$code"]=1
	done < <(sed -n '/HTTP_RESPONSE=(/,/^\t)/p' "$LIBRARY" | grep -oP '\[\K[0-9]+(?=\])')
	local -a unknown=()
	while read -r code; do
		[ -v "known[$code]" ] || unknown+=("$code")
	done < <(grep -rhoP '(send_error|_bail_request) \K[0-9]+' -- "${SOURCE_FILES[@]}" | sort -u)
	report "sent by send_error or _bail_request but absent from HTTP_RESPONSE:" "${unknown[@]}"
}

# Internal: Anything executable under `scripts/` is a reachable HTTP endpoint, so the
# library must not be, and the endpoints must be.
function check_executable_bits()
{
	local file
	local -a wrong=()
	for file in sherver.sh dispatcher.sh tests/lint.sh; do
		[ -x "$file" ] || wrong+=("$file is not executable")
	done
	for file in "${STANDALONE_SCRIPTS[@]}"; do
		case "$file" in
			"$LIBRARY")
				[ ! -x "$file" ] || wrong+=("$file is executable, so it is served as an endpoint")
				;;
			scripts/*)
				[ -x "$file" ] || wrong+=("$file is not executable, so it answers 404")
				;;
		esac
	done
	report 'wrong permissions:' "${wrong[@]}"
}

# Internal: `docs/functions.md` is entirely generated from the TomDoc comments of the
# library, so it must match a fresh run byte for byte.
function check_generated_docs()
{
	if [ ! -x './tomdoc.sh' ]; then
		echo 'tomdoc.sh is not in the repository root, see scripts/README.md'
		return 77
	fi
	local generated
	generated=$(mktemp)
	./tomdoc.sh --markdown "$LIBRARY" > "$generated"
	local -i status=0
	diff 'docs/functions.md' "$generated" || status=$?
	rm -f "$generated"
	if [ "$status" -ne 0 ]; then
		echo "run './tomdoc.sh --markdown scripts/SHERVER_UTILS.sh > docs/functions.md'"
	fi
	return "$status"
}

printf 'Checking %s files\n\n' "${#SOURCE_FILES[@]}"

check 'shellcheck'                    check_shellcheck
check 'syntax (bash -n)'              check_syntax
check 'syntax (bats)'                 check_bats_syntax
check 'set -efu'                      check_shell_options
check 'MIT header'                    check_license
check 'whitespace'                    check_whitespace
check 'library exports'               check_exports
check 'library TomDoc comments'       check_tomdoc
check 'HTTP error codes'              check_error_codes
check 'executable bits'               check_executable_bits
check 'generated docs/functions.md'   check_generated_docs

if [ "$FAILURES" -ne 0 ]; then
	printf '\n%s check(s) failed\n' "$FAILURES"
	exit 1
fi
printf '\nall checks passed\n'
