Changelog
=========

What changed between releases, from the point of view of someone writing scripts against
Sherver. Every release is an annotated git tag carrying the same notes; `0.9` is the first
one, everything before it is only in `git log`.

A version number says how stable the scripting API is — the library functions of
[docs/functions.md](./docs/functions.md), the variables of
[docs/global-variables.md](./docs/global-variables.md), and the layout of `file/` and
`scripts/`. It says nothing about how safe Sherver is: it is still not hardened and still
must not be exposed on Internet, at 1.0 as at 0.1 (see
[About security](./README.md#about-security)).

1.1 — 2026-08-21
----------------

Sherver speaks HTTP/1.1 now, and behaves like it: the request line and the `Host` header are
validated, `OPTIONS` is answered, and a file can be served by byte range — which is what makes
`<video>` seeking work. Nothing was removed from the scripting API.

- **answers in HTTP/1.1**, to a 1.0 client as well (RFC 9112 §2.3 — the version in the response
  says what the server can do, not what the request was). `REQUEST_HTTP_VERSION` is validated
  instead of merely parsed: anything that is not `HTTP/1.x` is a `400`, another major version a
  `505`
- **`Host` is mandatory** on an HTTP/1.1 request, missing it is a `400`. An HTTP/1.0 request
  without `Host` stays legal
- **header lines are validated**: a folded line (obs-fold), a line without a colon, a field name that
  is not a token — whitespace before the colon included — and a repeated `Host` or `Content-Length`
  carrying two different values are all a `400` now (RFC 9112 §5, §5.1, §5.2, §3.2 and §6.3). Any
  other repeated header reaches `REQUEST_HEADERS` as the `v1, v2` list it stands for (RFC 9110 §5.2)
  instead of the last value alone
- **byte ranges**: every file answer announces `Accept-Ranges: bytes`, and a GET carrying a single
  `Range: bytes=…` gets a `206` with its `Content-Range`. A range starting past the end of the file
  is a `416`; a stale `If-Range`, several ranges, another unit or plain garbage are ignored and the
  whole file is served, never an error
- **`OPTIONS`**, answered by the dispatcher for any target, `*` included, with `Allow` and an empty
  body. `PUT`, `DELETE`, `PATCH`, `TRACE` and `CONNECT` still get a `405`, which now carries `Allow`
  as RFC 9110 §15.5.6 requires — **do the same before your own `send_error 405`**. A method that is
  none of those gets a `501` instead of a `405`
- **absolute-form request target**: `GET http://host/path HTTP/1.1` is accepted, as RFC 9112 §3.2.2
  requires of a server. Scripts see the rewritten path in `REQUEST_URL`, and the authority in the
  target replaces whatever `Host` the client sent
- **an error is never stored**: `send_error` answers `Cache-Control: no-store` and drops any `ETag` and
  `Last-Modified` already set
- **no more `Expires`**: `Cache-Control` is the only freshness field now. A cache must ignore `Expires`
  whenever `max-age` is there (RFC 9111 §5.3), and the one Sherver sent carried the `Date` itself, so
  it could only contradict the `private, max-age=60` next to it. `add_header 'Expires' …` still puts
  it back on an answer of your own
- `HTTP_RESPONSE` gains the codes that go with all this: `206`, `416`, `501`, `505`
- `tail` and `head` join the external commands, for range answers only — busybox's are enough
- add support for redirections 30X
- add support for `Last-Modified` header
- add IP in logs

Deliberately left out, and worth knowing about:

- **no keep alive**, and none planned: `Connection: close` on every response is a compliant opt-out
  (RFC 9112 §9.6), and one process per connection is the whole architecture
- a **chunked request body** is read as no body at all, where it should get a `411`. No common
  client sends one unprompted
- **`Expect: 100-continue`** is not answered: a client that waits for the interim response eats
  socat's timeout and sends anyway
- a header **value** is taken as it comes: only the field name is validated, and a value is checked
  where it is read (`Content-Length`, `Range`) or not at all

1.0 — 2026-08-14
----------------

Same server, but the scripting API has stopped moving, everything it does is covered by a
test, and nothing is left that needs a package outside a default Debian or busybox install.

- **HTTPS**: switching the listener to `OPENSSL-LISTEN` turns on https communication, the
  dispatcher, the library and the scripts are untouched and never see it. See
  [docs/https.md](./docs/https.md)
- **no more Perl dependency**: the mime type comes from the extension, from a table in
  `_get_mimetype`, and an unknown extension degrades to `application/octet-stream` instead
  of being fatal
- **runs on busybox**: only `bash`, `socat` and — for templating — `envsubst` have to come
  from packages, `coreutils` is no longer needed
- `html_escape`, to be used at the point where anything from the request is inserted in a
  page
- **quiet logs**: one access line per response, plus the reason when something fails.
  The request dump and the response headers now need `SHERVER_DEBUG=1`, which
  `./sherver.sh --debug` sets
- **systemd unit rewritten**: `Type=exec` over the `exec socat`, so SIGTERM reaches the
  listener with no wrapper in between, and every sandboxing option is on by default
- **tests**: bats suites for the library, the requests, the files, the path confinement,
  the socket and TLS; `./tests/lint.sh` for the conventions; both run in GitHub Actions
- **docs**: updated documentation now living in `/docs`

0.9 — 2026-08-08
----------------

- **BREAKING**: support for HEAD requests, you need to update your scripts to accept both GET
  and HEAD
- better handling of big requests
	- cap max size for headers and body content
	- cap max simultaneous connections
	- add socat timeout to avoid dangling connections
- improve security: no more filesystem leak over curl requests
- various bug fixes
	- mimetype related issues
	- fixed some headers issues
	- support for URL with % enconding
