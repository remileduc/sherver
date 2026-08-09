Documentation partially generated with [tomdoc.sh](https://github.com/mlafeldt/tomdoc.sh).

SHERVER_UTILS.sh
================

Documentation of the library SHERVER_UTILS.sh.

`REQUEST_FULL_STRING`
---------------------

Public: The full request string


`SHERVER_ROOT`
--------------

Public: Absolute path to the root of the website (canonical, no symlink)

The dispatcher runs from the root, so we take the current directory. It is then inherited by the child scripts, which need it because `run_script` moves to `scripts/`.

`REQUEST_METHOD`
----------------

Public: The method of the request (GET, HEAD, POST...)

`REQUEST_URL`
-------------

Public: The requested URL

`REQUEST_HTTP_VERSION`
----------------------

Public: The HTTP version the client announced (`HTTP/1.0`, `HTTP/1.1`...)

Informative only: the answer is always in HTTP 1.0.

`REQUEST_HEADERS`
-----------------

Public: The headers from the request (associative array)

The keys are lowercase, because HTTP header names are case insensitive: use `REQUEST_HEADERS['content-type']`, not `REQUEST_HEADERS['Content-Type']`.

`REQUEST_BODY`
--------------

Public: Body of the request (mainly useful for POST)

`REQUEST_BODY_PARAMETERS`
-------------------------

Public: parameters of the request, in case of POST with `application/x-www-form-urlencoded` content

`URL_BASE`
----------

Public: The base URL, without the query string if any

`URL_PARAMETERS`
----------------

Public: The parameters of the query string if any (in an associative array)

See `parse_url()`.

`RESPONSE_HEADERS`
------------------

Public: The response headers (associative array)

`HTTP_RESPONSE`
---------------

Public: Generic HTTP response code with their meaning (associative array)

`MAX_BODY_SIZE`
---------------

Public: Biggest request body we accept to read, in bytes

The body ends up in `REQUEST_FULL_STRING`, which we export. Linux refuses to run a command when a single environment string is bigger than 128 kio, so past that limit every external command (`realpath`, `cat`...) fails and we can't answer at all.

`MAX_HEADERS_SIZE`
------------------

Public: Biggest request line + headers we accept to read, in characters

They land in `REQUEST_FULL_STRING` too, so they share the 128 kio limit of `MAX_BODY_SIZE`. 8 kio (what nginx and Apache use) leaves room for a full body even if every header character takes 4 bytes.

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

To do so, it will read from the standard input the received request, and execute `read_request` to initialize everything.

Then, it will export the full request in the environment variable `REQUEST_FULL_STRING` so it can always be reexecuted.

This mechanism also allows non bash script to have access to the request through the environment.


`log()`
-------

Public: Log any messages in the error outut of the script (default is console).

Takes as many arguments as needed. they will all be written, separated by newlines.

Examples

     log "> HTTP/1.0 200 OK

will output

     > HTTP/1.0 200 OK


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

* $1 - header name, one of the HTTP 1.0 standard value
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

     HTTP/1.0 200 OK
     Date: Thu, 04 Jul 2019 21:38:23 GMT
     Server: Sherver
     Cache-Control: private, max-age=60
     Expires: Thu, 04 Jul 2019 21:38:23 GMT


`send_response()`
-----------------

Public: Send the given answer in a HTTP 1.0 format.

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

     HTTP/1.0 200 OK
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

     HTTP/1.0 404 Not Found


`_resolve_path()`
-----------------

Internal: Resolve the given path and check that it stays in the authorized directory.

**Note:** this method is used by `send_file()` and `run_script()` and shouldn't be called manually.

Takes the authorized directory (relative to `SHERVER_ROOT`) and the path to resolve. The path is canonicalized, so neither `..` nor a symlink can be used to escape the directory.

The result is stored in `RESOLVED_PATH` instead of being echoed, because this function exits on error: in a command substitution, the error page would be captured by the caller instead of being sent to the client.

Sends a 404 if the path doesn't exist or if it lands outside the authorized directory. We purposely don't use 403 to avoid leak of the File System

* $1 - authorized directory, relative to `SHERVER_ROOT` (`file` or `scripts`)
* $2 - path to resolve, relative to the current directory

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

The path generally comes from the URL (`URL_BASE`). You just need to remove the first `/` to get a relative path.

*Note* that to find the correct mimetype, we use `_get_mimetype()`, which deduces it from the extension of the file.

* $1 - the path to the file to send

Examples

     parse_url '/file/beautiful.png?dummy=stuff'
     send_file "${URL_BASE:1}"

if the file exist, will send a response that starts with (assuming file size is 4 kio)

     HTTP/1.0 200 OK
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

*Note* that this method is highly inspired by [bashttpd](https://github.com/avleen/bashttpd)

* $1 - if true, logs will be written (whole header, but not the body)


