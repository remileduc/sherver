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

# Internal: Resolve the given path and check that it stays in the authorized directory.
#
# **Note:** this method is used by `send_file()` and `run_script()` and shouldn't be called
# manually.
#
# Takes the authorized directory (relative to `SHERVER_ROOT`) and the path to resolve. The
# path is canonicalized, so neither `..` nor a symlink can be used to escape the directory.
#
# The result is stored in `_RESOLVED_PATH` instead of being echoed, because this function
# exits on error: in a command substitution, the error page would be captured by the caller
# instead of being sent to the client.
#
# Sends a 404 if the path is absolute, doesn't exist, or lands outside the authorized
# directory. We purposely don't use 403 to avoid leak of the File System
#
# $1 - authorized directory, relative to `SHERVER_ROOT` (`site/static` or `site/app`)
# $2 - path to resolve, relative to the current directory (an absolute path is refused)
#
# Examples
#
#    _resolve_path 'site/static' '../static/pages/page.html'
#
# will result in (assuming `SHERVER_ROOT` is `/home/sherver/sherver`)
#
#    _RESOLVED_PATH='/home/sherver/sherver/site/static/pages/page.html'
function _resolve_path()
{
	local authorized
	if [[ ! -d $SHERVER_ROOT/$1 ]]; then
		log "MISCONFIGURED: '$SHERVER_ROOT/$1' is not a directory"
		send_error 500
	fi
	if ! authorized=$(realpath "$SHERVER_ROOT/$1"); then
		log "MISCONFIGURED: realpath failed on '$SHERVER_ROOT/$1'"
		send_error 500
	fi
	# the contract is a relative path: an absolute one only ever comes from a `//x` URL,
	# which the `./` below would otherwise turn into a live alias of `/x`
	if [[ $2 == /* ]]; then
		log "FORBIDDEN: absolute path '$2'"
		send_error 404
	fi
	# `./` because the URL can start with a dash and busybox realpath, having no options at
	# all, has no `--` either to stop it being read as one
	local -r target="./$2"
	# and no `-e` either: busybox realpath happily resolves a missing last component
	if [[ ! -e $target ]] || ! _RESOLVED_PATH=$(realpath "$target" 2>/dev/null); then
		log "NOT FOUND: realpath - '$2'"
		send_error 404
	fi
	if [[ $_RESOLVED_PATH != "$authorized"/* ]]; then
		log "FORBIDDEN: '$2' resolves to '$_RESOLVED_PATH', outside of '$authorized'"
		send_error 404 # not 403 to avoid leak of the FS
	fi
}
export -f _resolve_path

# Internal: Print the mime type of the given file, deduced from its extension.
#
# **Note:** this method is used by `send_file()` and shouldn't be called manually.
#
# The type comes from a static table, the way nginx and Apache do it: for a static file
# server the extension is the authoritative signal.
#
# An unknown or missing extension gives `application/octet-stream`, so that the browser
# downloads the file instead of guessing how to render it. Since we own everything under
# `site/static/`, that case means the table is missing an entry: it is logged.
#
# `text/*` types carry `; charset=utf-8`. The others don't: `application/json` and the
# image types have no charset parameter.
#
# $1 - the path to the file to inspect
#
# Examples
#
#    _get_mimetype '/home/sherver/sherver/site/static/beautiful.png'
#
# will print
#
#    image/png
function _get_mimetype()
{
	local -rA MIME_TYPES=(
		['css']='text/css; charset=utf-8'
		['csv']='text/csv; charset=utf-8'
		['htm']='text/html; charset=utf-8'
		['html']='text/html; charset=utf-8'
		['ics']='text/calendar; charset=utf-8'
		['js']='text/javascript; charset=utf-8'
		['md']='text/markdown; charset=utf-8'
		['mjs']='text/javascript; charset=utf-8'
		['txt']='text/plain; charset=utf-8'
		['vtt']='text/vtt; charset=utf-8'
		['atom']='application/atom+xml'
		['json']='application/json'
		['jsonld']='application/ld+json'
		['map']='application/json'
		['pdf']='application/pdf'
		['rss']='application/rss+xml'
		['srt']='application/x-subrip'
		['toml']='application/toml'
		['wasm']='application/wasm'
		['webmanifest']='application/manifest+json'
		['xhtml']='application/xhtml+xml'
		['xml']='application/xml'
		['yaml']='application/yaml'
		['yml']='application/yaml'
		['docx']='application/vnd.openxmlformats-officedocument.wordprocessingml.document'
		['epub']='application/epub+zip'
		['odp']='application/vnd.oasis.opendocument.presentation'
		['ods']='application/vnd.oasis.opendocument.spreadsheet'
		['odt']='application/vnd.oasis.opendocument.text'
		['pptx']='application/vnd.openxmlformats-officedocument.presentationml.presentation'
		['rtf']='application/rtf'
		['xlsx']='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
		['7z']='application/x-7z-compressed'
		['bz2']='application/x-bzip2'
		['deb']='application/vnd.debian.binary-package'
		['gz']='application/gzip'
		['rar']='application/vnd.rar'
		['rpm']='application/x-rpm'
		['tar']='application/x-tar'
		['tgz']='application/gzip'
		['xz']='application/x-xz'
		['zip']='application/zip'
		['zst']='application/zstd'
		# explicit, so that a deliberately opaque download doesn't log a missing entry
		['bin']='application/octet-stream'
		['apng']='image/apng'
		['avif']='image/avif'
		['bmp']='image/bmp'
		['gif']='image/gif'
		['heic']='image/heic'
		['heif']='image/heif'
		['ico']='image/vnd.microsoft.icon'
		['jpeg']='image/jpeg'
		['jpg']='image/jpeg'
		['jxl']='image/jxl'
		['png']='image/png'
		['svg']='image/svg+xml'
		['tif']='image/tiff'
		['tiff']='image/tiff'
		['webp']='image/webp'
		['otf']='font/otf'
		['ttc']='font/collection'
		['ttf']='font/ttf'
		['woff']='font/woff'
		['woff2']='font/woff2'
		['aac']='audio/aac'
		['flac']='audio/flac'
		['m4a']='audio/mp4'
		['mp3']='audio/mpeg'
		['oga']='audio/ogg'
		['ogg']='audio/ogg'
		['opus']='audio/ogg'
		['wav']='audio/wav'
		['weba']='audio/webm'
		['3gp']='video/3gpp'
		['avi']='video/x-msvideo'
		['m4v']='video/mp4'
		['mkv']='video/x-matroska'
		['mov']='video/quicktime'
		['mp4']='video/mp4'
		['mpeg']='video/mpeg'
		['mpg']='video/mpeg'
		['ogv']='video/ogg'
		['webm']='video/webm'
	)

	# the basename first: a dot in a parent directory is not an extension
	local -r name="${1##*/}"
	local ext="${name##*.}"
	# no dot at all: the expansion above gave back the whole name
	[ "$ext" != "$name" ] || ext=''
	ext="${ext,,}"

	if [ ! -v "MIME_TYPES[$ext]" ]; then
		log "unknown extension '$ext' for '$1', serving it as application/octet-stream"
		printf '%s\n' 'application/octet-stream'
		return 0
	fi
	printf '%s\n' "${MIME_TYPES[$ext]}"
}
export -f _get_mimetype

# Public: Try to send the given file, or fail with 404.
#
# Takes the path to the file to send as a parameter.
#
# It will automatically create a valid HTTP response that will stream the content
# of the file, with the correct mime type and all. If the file doesn't exist, or
# if the file is outside of `site/static/`, send a 404 error.
#
# Every answer carries two cache validators: an `ETag` built from the size and mtime
# of the file, and its `Last-Modified` date. A conditional request that matches one
# of them (`If-None-Match` first, `If-Modified-Since` only when no usable ETag was sent)
# is answered with a bodyless `304 Not Modified`. An `If-None-Match` of `*` matches too.
#
# Only a GET or a HEAD is answered that way: a 304 to a POST would leave the client
# without a representation of what it just sent.
#
# Every answer also announces `Accept-Ranges: bytes`, and a GET carrying a single byte
# range (`Range: bytes=0-499`, `bytes=500-`, `bytes=-500`) is answered with a
# `206 Partial Content` and the matching `Content-Range` — what `<video>` seeking needs.
# A range starting past the end of the file is a `416 Range Not Satisfiable`. Every
# other form — several ranges, another unit, garbage — is ignored and the whole file is
# served, as RFC 9110 §14.2 allows; so is the whole header when an `If-Range` is present
# and is not exactly the current ETag.
#
# The path generally comes from the URL (`URL_BASE`). You just need to remove the first
# `/` to get a relative path.
#
# *Note* that to find the correct mimetype, we use `_get_mimetype()`, which deduces it from
# the extension of the file.
#
# $1 - the path to the file to send
#
# Examples
#
#    parse_url '/static/beautiful.png?dummy=stuff'
#    send_file "${URL_BASE:1}"
#
# if the file exist, will send a response that starts with (assuming file size is 4 kio)
#
#    HTTP/1.1 200 OK
#    Content-Type: image/png
#    Content-Length: 4096
function send_file()
{
	_resolve_path 'site/static' "$1"
	local -r file="$_RESOLVED_PATH"
	# existence is already guaranteed by `_resolve_path`
	if [ ! -f "$file" ] || [ ! -r "$file" ]; then
		send_error 404
	fi

	# one `stat` for the three headers below: read twice, it can straddle a file being
	# replaced and pair the size of one version with the validators of another. Assigned
	# through `if`, because a plain assignment returns the failure to `set -e`, which would
	# abort the dispatcher here — before `_send_header`, so the client would get zero bytes
	local stats
	if ! stats=$(stat -c '%s %Y' "$file" 2>/dev/null); then
		log "NOT FOUND: stat - '$file' went away while it was being answered"
		send_error 404
	fi
	local -r size="${stats% *}" mtime="${stats#* }"
	# two cache validators: ETag for the HTTP/1.1 clients, Last-Modified for the HTTP/1.0
	# ones — `wget -N` works off the latter alone. Set before the checks, so a 304 has both
	local -r etag="\"$size-$mtime\""
	# the bash builtin gives the same string as `date -uR -r` without the fork, and without
	# a `date` that knows `-r` to depend on. Both prefixes matter: `LC_ALL` keeps the day
	# and month abbreviations English, which is what RFC 7231 asks for
	local last_modified
	TZ=UTC0 LC_ALL=C printf -v last_modified '%(%a, %d %b %Y %H:%M:%S)T GMT' "$mtime"
	add_header 'ETag' "$etag"
	add_header 'Last-Modified' "$last_modified"
	# if client already cached it, we don't resend it. When both validators come in,
	# If-None-Match alone decides (RFC 7232): a stale date must not override the ETag.
	# Exact string match for both: a client we can't recognize just gets the full answer.
	# GET and HEAD only: a 304 answers a POST with no representation for what it just sent
	if [ "$REQUEST_METHOD" != 'POST' ]; then
		# an empty value is no validator at all: it must not swallow the date below
		local -r if_none_match="${REQUEST_HEADERS['if-none-match']:-}"
		if [ -n "$if_none_match" ]; then
			# `*` is the RFC 7232 wildcard: it matches the file whatever our ETag is
			if [ "$if_none_match" = "$etag" ] || [ "$if_none_match" = '*' ]; then
				send_response 304
			fi
		elif [ "${REQUEST_HEADERS['if-modified-since']:-}" = "$last_modified" ]; then
			send_response 304
		fi
	fi
	# HTTP header
	local content_type
	content_type=$(_get_mimetype "$file")
	add_header 'Content-Type'   "$content_type";
	# on the 200s as much as the 206s: this is what tells a video player seeking works
	add_header 'Accept-Ranges' 'bytes'
	# single byte range, on GET only (RFC 9110 §14.2 lets a HEAD ignore Range, and it keeps
	# the full-size headers meaningful). `first` stays -1 unless a satisfiable range lands
	local -i first=-1 last=-1
	# anything unparseable — several ranges, another unit, garbage, a number too long for
	# bash's 64-bit arithmetic — falls through to the full 200: §14.2 allows ignoring the
	# header wholesale, so the full answer is always a correct one, never an error
	# each number is captured twice: the outer group makes it optional, the inner one holds it
	# without its leading zeros, so the 18-digit cap measures its magnitude and not its padding
	if [ "$REQUEST_METHOD" = 'GET' ] \
			&& [[ "${REQUEST_HEADERS['range']:-}" =~ ^bytes=(0*([[:digit:]]+))?-(0*([[:digit:]]+))?$ ]] \
			&& [ -n "${BASH_REMATCH[2]}${BASH_REMATCH[4]}" ] \
			&& [ "${#BASH_REMATCH[2]}" -le 18 ] && [ "${#BASH_REMATCH[4]}" -le 18 ]; then
		# the regex already dropped the zeros, so `10#` is only a belt-and-braces base-ten
		# pin: without it a padded value would read as octal, and `bytes=08-` would die
		local -r from="${BASH_REMATCH[2]:+$(( 10#${BASH_REMATCH[2]} ))}"
		local -r to="${BASH_REMATCH[4]:+$(( 10#${BASH_REMATCH[4]} ))}"
		# a stale If-Range means the client's copy changed under it: it needs the whole
		# file, not a piece of the new one. Exact string match, like the validators above
		local -r if_range="${REQUEST_HEADERS['if-range']:-}"
		if [ -z "$if_range" ] || [ "$if_range" = "$etag" ]; then
			if [ -z "$from" ]; then
				# `-N` is the last N bytes, the whole file when N overshoots it
				if [ "$to" -gt 0 ] && [ "$size" -gt 0 ]; then
					first=$(( size > to ? size - to : 0 ))
					last=$(( size - 1 ))
				else
					# the last zero bytes, or any tail of an empty file, selects nothing
					# (RFC 9110 §14.1.2); §15.3.7 wants the full size in the answer
					add_header 'Content-Range' "bytes */$size"
					send_error 416
				fi
			elif [ -n "$to" ] && [ "$from" -gt "$to" ]; then
				: # first past last is no range at all: ignored, the 200 below answers
			elif [ "$from" -ge "$size" ]; then
				# the one unsatisfiable int-range form: it starts past the end
				add_header 'Content-Range' "bytes */$size"
				send_error 416
			else
				first="$from"
				# an open or overshooting end stops where the file does (RFC 9110 §14.1.2)
				if [ -z "$to" ] || [ "$to" -ge "$size" ]; then
					last=$(( size - 1 ))
				else
					last="$to"
				fi
			fi
		fi
	fi
	if [ "$first" -ge 0 ]; then
		local -ri length=$(( last - first + 1 ))
		add_header 'Content-Range' "bytes $first-$last/$size"
		add_header 'Content-Length' "$length"
		_send_header 206
		# no `pipefail` here, so `tail` dying of SIGPIPE once `head` has enough is inert
		tail -c "+$(( first + 1 ))" -- "$file" | head -c "$length"
	else
		add_header 'Content-Length' "$size"
		_send_header 200
		# response
		if [ "$REQUEST_METHOD" != 'HEAD' ]; then
			cat "$file"
		fi
	fi
	log_debug '================================================'
	exit 0
}
export -f send_file
