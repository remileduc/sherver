Global variables
================

The variables `scripts/SHERVER_UTILS.sh` exports, documented by hand:
[tomdoc.sh](https://github.com/mlafeldt/tomdoc.sh) only extracts the functions, which live in
[functions.md](./functions.md).

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

Informative only: the answer is always in HTTP 1.1 (RFC 9112 §2.3 — the version in the response advertises capability, so answering 1.1 to a 1.0 client is correct).

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

`DEBUG_LOG`
-----------

Public: `true` when verbose logging is on, see `log_debug()`

Read from the environment because that is the only channel that survives the exec into a child script: `sherver.sh --debug` exports `SHERVER_DEBUG`, and so does `systemd`.
