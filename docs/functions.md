`init_environment()`
--------------------

Public: Initialize the environment.

This function should always be ran at the top of any scripts. Once this function has run, all the following variables will be available:

* `SHERVER_ROOT`
* `REQUEST_METHOD`
* `REQUEST_URL`
* `REQUEST_HTTP_VERSION`
* `REQUEST_HEADERS`
* `REQUEST_BODY`
* `REQUEST_BODY_PARAMETERS`
* `URL_BASE`
* `URL_PARAMETERS`
* `RESPONSE_HEADERS`
* `HTTP_RESPONSE`
* `MAX_BODY_SIZE`
* `MAX_HEADERS_SIZE`
* `REQUEST_FULL_STRING`
* `DEBUG_LOG`

To do so, it will read from the standard input the received request, and execute `read_request` to initialize everything.

Then, it will export the full request in the environment variable `REQUEST_FULL_STRING` so it can always be reexecuted.

This mechanism also allows non bash script to have access to the request through the environment.


`log()`
-------

Public: Log any messages in the error outut of the script (default is console).

Takes as many arguments as needed. they will all be written, separated by newlines.

Use it for what is worth keeping on a busy server: errors, and the one line per response written by `_send_header()`. Everything else belongs in `log_debug()`.

Examples

     log "> HTTP/1.1 200 OK

will output

     > HTTP/1.1 200 OK


`log_debug()`
-------------

Public: Same as `log()`, but only when debug logging is on.

Debug logging is off unless `SHERVER_DEBUG` is `1` in the environment, which `sherver.sh --debug` does. It turns on the full request and response dumps, which are a dozen lines per request: enough to hit the rate limit of a log collector.

Takes as many arguments as needed. they will all be written, separated by newlines.

Examples

     log_debug "> Content-Type: text/html"


`_check_encoding()`
-------------------

Internal: Tell if the given string is properly percent encoded.

**Note:** this method is used by `read_request()` and shouldn't be called manually.

Returns 0 if the string can safely be given to `_url_decode()`, 1 otherwise. A `%` that is not followed by 2 hexadecimal digits can't be decoded, and `%00` decodes to a NUL byte, which silently truncates the string in bash.

* $1 - the string to check

Examples

     _check_encoding '/file/my%20file.txt'  # returns 0
     _check_encoding '/file/100%'           # returns 1


`_url_decode()`
---------------

Internal: Decode the percent encoded characters of the given string.

**Note:** the string must have been accepted by `_check_encoding()` first.

The result is stored in the variable named by the first parameter, because a command substitution would drop a trailing newline coming from a `%0A`.

* $1 - name of the variable to store the result in
* $2 - the string to decode

Examples

     _url_decode value 'caf%C3%A9'

will result in

     value='café'


`parse_url()`
-------------

Public: Parse the given URL to exrtact the base URL and the query string.

Takes an optional parameters: the URL to parse. By default, it will take the content of the variable `REQUEST_URL`.

It will store the base of the URL (without query string) in `URL_BASE`. It will store all the parameters of the query string in the associative array `URL_PARAMETERS`.

Everything is percent decoded, but only once the URL has been split: a `%3F` in the path is a question mark in a file name, not the start of the query string. A URL that is not properly percent encoded can't be decoded, and is answered with a 400.

A parameter without a name is skipped, as an empty key is not a valid array subscript.

* $1 - Optional: URL to parse (default will take content of `REQUEST_URL`)

Examples

     parse_url '/index.sh?test=youpi&answer=42&city=caf%C3%A9+ville'

will result in

     URL_BASE='/index.sh'
     URL_PARAMETERS=(
         ['test']='youpi'
         ['answer']='42'
         ['city']='café ville'
     )


`html_escape()`
---------------

Public: Print the given string with the HTML special characters escaped.

Everything coming from the request (the URL, its parameters, the headers, the body...) is written by the client. A script that drops it in a page as is lets that client inject its own markup, so escape it, always. Best done at the point where the value is inserted, so that no unescaped copy is left around to be used by mistake.

The 5 escaped characters cover text inside an element and the value of a quoted attribute. An unquoted attribute, a `<script>` or a `<style>` need more than this, and are a bad place to put anything the client sent in the first place.

* $1 - the string to escape

Examples

     html_escape '<script>alert(1)</script>'

will print

     &lt;script&gt;alert(1)&lt;/script&gt;


`add_header()`
--------------

Public: Add header for the response.

Takes 2 parameters: header name and header content.

* $1 - header name, one of the HTTP 1.1 standard value
* $2 - value of the header

Examples

     add_header 'Content-Type' 'text/html; charset=utf-8'

will add the following line in the header of the response

     Content-Type: text/html; charset=utf-8


`_send_header()`
----------------

Internal: Write the headers to the standard output.

It will write all the headers defined in `RESPONSE_HEADERS`, see `add_header()`. It also automatically add the date header.

Takes one parameter which is the code of the response.

* $1 - The code of the response, must exist in `HTTP_RESPONSE`

Examples

     _send_header 200

will result in:

     HTTP/1.1 200 OK
     Date: Thu, 04 Jul 2019 21:38:23 GMT
     Server: Sherver
     Cache-Control: private, max-age=60
     Expires: Thu, 04 Jul 2019 21:38:23 GMT


`send_response()`
-----------------

Public: Send the given answer in a HTTP 1.1 format.

Takes the response code as first parameter, then as many parameters as needed to write the answer. They will be sent, separated by newlines.

Call it with the code alone to send no body at all, as a 304 requires. The body is also dropped on its own when the client sent a HEAD request.

`Content-Length` is computed and added automatically, except for a 304.

At the end of the function, we call exit to terminate the process.

Note that the headers need to have already been set with `add_header()`.

* $1 - HTTP response code. See `HTTP_RESPONSE`
* $2... - Optional: the actual response to send (a 304 must have none)

Examples

     add_header 'Content-Type' 'text/plain'
     send_response 200 'this is some' 'cool text'

will send something like (depends on your default headers, see `RESPONSE_HEADERS`)

```

     HTTP/1.1 200 OK
     Content-Type: text/plain

     this is some
     cool text
 ```


`send_error()`
--------------

Public: Send the given error as an answer.

Takes one parameter: the error code. It will be sent as an answer, along with a very small HTML explaining what is the error.

* $1 - the error code, see `HTTP_RESPONSE`

Examples

     send_errors 404

will create an answer that starts with

     HTTP/1.1 404 Not Found


`send_redirect()`
-----------------

Public: Send a redirect to the given URL as an answer.

Takes the target URL, and optionally the response code: 302 (the default) for a temporary redirect, 301 for a permanent one — the two redirects `HTTP_RESPONSE` knows. Anything else is refused with a 500: `send_response` would die expanding an unknown code mid-answer, and the client would get nothing at all.

The typical use is POST-redirect-GET, so that a refresh doesn't resubmit the form.

A target holding a CR or a LF is refused with a 500 the same way: it would split the Location header in two. The rest is the caller's business — a target built from the request is an open redirect unless the script checks it, and a full URL is legitimate here, so the library cannot tell the wanted ones from the others.

Like the other `send_*` functions, it exits: nothing after it runs.

* $1 - the URL to redirect to (a path like `/index.sh`, or a full URL)
* $2 - Optional: the response code, 301 or 302 (default 302)

Examples

     send_redirect '/index.sh'

will send an answer that starts with

     HTTP/1.1 302 Found
     Location: /index.sh


`_resolve_path()`
-----------------

Internal: Resolve the given path and check that it stays in the authorized directory.

**Note:** this method is used by `send_file()` and `run_script()` and shouldn't be called manually.

Takes the authorized directory (relative to `SHERVER_ROOT`) and the path to resolve. The path is canonicalized, so neither `..` nor a symlink can be used to escape the directory.

The result is stored in `RESOLVED_PATH` instead of being echoed, because this function exits on error: in a command substitution, the error page would be captured by the caller instead of being sent to the client.

Sends a 404 if the path is absolute, doesn't exist, or lands outside the authorized directory. We purposely don't use 403 to avoid leak of the File System

* $1 - authorized directory, relative to `SHERVER_ROOT` (`file` or `scripts`)
* $2 - path to resolve, relative to the current directory (an absolute path is refused)

Examples

     _resolve_path 'file' '../file/pages/page.html'

will result in (assuming `SHERVER_ROOT` is `/home/sherver/sherver`)

     RESOLVED_PATH='/home/sherver/sherver/file/pages/page.html'


`_get_mimetype()`
-----------------

Internal: Print the mime type of the given file, deduced from its extension.

**Note:** this method is used by `send_file()` and shouldn't be called manually.

The type comes from a static table, the way nginx and Apache do it: for a static file server the extension is the authoritative signal.

An unknown or missing extension gives `application/octet-stream`, so that the browser downloads the file instead of guessing how to render it. Since we own everything under `file/`, that case means the table is missing an entry: it is logged.

`text/*` types carry `; charset=utf-8`. The others don't: `application/json` and the image types have no charset parameter.

* $1 - the path to the file to inspect

Examples

     _get_mimetype '/home/sherver/sherver/file/beautiful.png'

will print

     image/png


`send_file()`
-------------

Public: Try to send the given file, or fail with 404.

Takes the path to the file to send as a parameter.

It will automatically create a valid HTTP response that will stream the content of the file, with the correct mime type and all. If the file doesn't exist, or if the file is outside of `file/`, send a 404 error.

Every answer carries two cache validators: an `ETag` built from the size and mtime of the file, and its `Last-Modified` date. A conditional request that matches one of them (`If-None-Match` first, `If-Modified-Since` only when no usable ETag was sent) is answered with a bodyless `304 Not Modified`. An `If-None-Match` of `*` matches too.

Only a GET or a HEAD is answered that way: a 304 to a POST would leave the client without a representation of what it just sent.

Every answer also announces `Accept-Ranges: bytes`, and a GET carrying a single byte range (`Range: bytes=0-499`, `bytes=500-`, `bytes=-500`) is answered with a `206 Partial Content` and the matching `Content-Range` — what `<video>` seeking needs. A range starting past the end of the file is a `416 Range Not Satisfiable`. Every other form — several ranges, another unit, garbage — is ignored and the whole file is served, as RFC 9110 §14.2 allows; so is the whole header when an `If-Range` is present and is not exactly the current ETag.

The path generally comes from the URL (`URL_BASE`). You just need to remove the first `/` to get a relative path.

*Note* that to find the correct mimetype, we use `_get_mimetype()`, which deduces it from the extension of the file.

* $1 - the path to the file to send

Examples

     parse_url '/file/beautiful.png?dummy=stuff'
     send_file "${URL_BASE:1}"

if the file exist, will send a response that starts with (assuming file size is 4 kio)

     HTTP/1.1 200 OK
     Content-Type: image/png
     Content-Length: 4096


`run_script()`
--------------

Public: Try to run the given file (script or executable), or fail with 404.

**Note:** this method is usded by the dispatcher and shouldn't be called manually.

Takes the path to the file to run. The file can be a script in any language, or an executable. But it must have the `x` flag so we can run it.

It will simply run the script if possible. If not, send a 404. If the script is outside of `scripts/`, send a 404. If the script fails, send a 500.

It is the script responsibility to send the response and everything...

*Note* that the file is supposed to be in the subfolder `scripts/`. The file will be run inside this folder (we `cd` before running it).

* $1 - the path to the file to run (relative to subfolder `scripts/`)

Examples

     run_script '/index.sh?dummy=stuff'

will do the following

     cd scripts
     './index.sh' '/index.sh?dummy=stuff'


`_bail_request()`
-----------------

Internal: Log a request parse failure, dump the request when relevant, and answer an error.

**Note:** this method is used by `read_request()` and shouldn't be called manually.

Owns the bail-out invariant of `read_request()`: the request is dumped on the first parse only (a child script re-parse would dump it once per script), the reason is always `log`ged, and `send_error()` ends the process — this function never returns. Only for the bail-outs *before* the end of the header loop: after that point, the first parse has already dumped the full request unconditionally, and this would dump it a second time.

* $1 - the HTTP error code, one of the keys of `HTTP_RESPONSE`
* $2 - the reason, `log`ged as is
* $3 - true when parsing from the standard input, false in a child script re-parse

Examples

     _bail_request 400 'BAD REQUEST: malformed request line' true


`read_request()`
----------------

Internal: Read the client request and set up environment.

**Note:** this method is used by the dispatcher and shouldn't be called manually.

Reads the input stream and fills the following variables (also run `parse_url()`):

* `REQUEST_METHOD`
* `REQUEST_HTTP_VERSION`
* `REQUEST_HEADERS`
* `REQUEST_BODY`
* `REQUEST_BODY_PARAMETERS`
* `REQUEST_URL`
* `URL_BASE`
* `URL_PARAMETERS`

An absolute-form request target (`GET http://host/path`, RFC 9112 §3.2.2) is rewritten to the path it points at, and its authority — validated first — replaces `REQUEST_HEADERS['host']`. Any other target that is not a path is refused with a 400, the asterisk form of `OPTIONS` excepted.

*Note* that this method is highly inspired by [bashttpd](https://github.com/avleen/bashttpd)

* $1 - true when parsing from the standard input, false when re-parsing `REQUEST_FULL_STRING` in a child script. Only the first parse logs the request, so that a request is not dumped once per script it goes through


