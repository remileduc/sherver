Changelog
=========

What changed between releases, from the point of view of someone writing scripts against
Sherver. Every release is an annotated git tag carrying the same notes; `0.9` is the first
one, everything before it is only in `git log`.

A version number says how stable the scripting API is — the library functions of
[docs/functions.md](./docs/functions.md), the variables of
[docs/global-variables.md](./docs/global-variables.md), and the layout of `site/static/` and
`site/app/`. It says nothing about how safe Sherver is: it is still not hardened and still
must not be exposed on Internet, at 1.0 as at 0.1 (see
[About security](./README.md#about-security)).


2.0 — unreleased
----------------

The checkout is laid out again, and one URL moved with it. Every contract this breaks is listed
here; there is no redirect and no migration shim, on purpose.

- **`/file/` is now `/static/`**: static content lives in `site/static/` instead of `file/`, and
  the URL prefix follows the folder name
- endpoints live in `site/app/` instead of `scripts/` (templates in `site/app/templates/`); a
  script reaches static content through `../static/`, no longer `../file/`
- the engine moved out of the served tree: `scripts/SHERVER_UTILS.sh` became the `lib/` modules,
  sourced by `lib/SHERVER.sh`, so no exec bit decides whether it is served anymore
- the routing is `site/routes.sh`, sourced by `dispatcher.sh` once `OPTIONS` is answered — edit
  it, not the dispatcher, to add a route


1.1 — 2026-10-18
----------------

Sherver speaks HTTP/1.1 now, and behaves like it: the request line and the `Host` header are
validated, `OPTIONS` is answered, and a file can be served by byte range — which is what makes
`<video>` seeking work. Nothing was removed from the scripting API.

- **answers in HTTP/1.1**, to a 1.0 client as well (RFC 9112 §2.3)
- `REQUEST_HTTP_VERSION` is validated instead of merely parsed: anything that is not `HTTP/1.x` is a
  `400`, another major version a `505`
- **`Host` is mandatory** on an HTTP/1.1 request, missing it is a `400`. OK for HTTP/1.0 request
- **header lines are validated**: sends `400` for bad requests (RFC 9112 §5, §5.1, §5.2, §3.2 and
  §6.3, RFC 9110 §5.5).
- Repeated header reaches `REQUEST_HEADERS` as the `v1, v2` list it stands for (RFC 9110 §5.2)
  except `Cookie`, whose pairs recombine on `; ` (RFC 9113 §8.2.3)
- **byte ranges**: advertise `Accept-Ranges: bytes`, and GET carrying a single `Range: bytes=…`
  gets a `206` with its `Content-Range`. A range we can't use falls back to the full `200`;
  only one that selects nothing — starting at or past the end — is a `416`
- **`OPTIONS`**, answered by the dispatcher for any target, `*` included, with `Allow` and an empty
  body. `PUT`, `DELETE`, `PATCH`, `TRACE` and `CONNECT` still get a `405`.
  **Do the same before your own `send_error 405`**.
- **absolute-form request target**: `GET http://host/path HTTP/1.1` is accepted, as RFC 9112 §3.2.2
- **an error is never stored**: `send_error` answers `Cache-Control: no-store` and drops any `ETag` and
  `Last-Modified` already set
- **no more `Expires`**: `Cache-Control` is the only freshness field now.
- **a chunked request body is a `411`**, where it was silently read as no body at all: chunked
  framing is still not decoded, but it is refused loudly, on any method.
- **`Expect: 100-continue` is answered** (RFC 9110 §10.1.1) with `HTTP/1.1 100 Continue`
- **an `Expect` naming anything but `100-continue` is a `417 Expectation Failed`**
- **a request has 10 s to arrive whole**, body included, or it is a `408 Request Timeout`: `socat -T`
  only ever dropped a client gone silent, and one dripping a byte every 9 s held a dispatcher for
  hours. `MAX_REQUEST_TIME` is the knob, next to `MAX_BODY_SIZE` and `MAX_HEADERS_SIZE`
- `HTTP_RESPONSE` gains the codes that go with all this:
  `100`, `206`, `301`, `302`, `303`, `307`, `308`, `408`, `411`, `416`, `417`, `501`, `505`
- `tail` and `head` join the external commands, for range answers only — busybox's are enough
- add support for redirections 30X
- add support for `Last-Modified` header
- add IP in logs
- **command line flags** replace editing `sherver.sh`: `--port N`, `--ipv4`, `--tls`,
  `--certs DIR`, `--debug`, `--version`, and `--help`
- **bash 4.4 is the floor**, checked at startup by `sherver.sh`, `dispatcher.sh` and
  `tests/lint.sh`

Deliberately left out, and worth knowing about:

- **no keep alive**, and none planned: `Connection: close` on every response is a compliant opt-out
  (RFC 9112 §9.6), and one process per connection is the whole architecture
- a **chunked request body** is refused with a `411` rather than decoded. No common client
  sends one unprompted
- a header **value** is taken as it comes: past the stray-CR refusal of RFC 9110 §5.5, only the
  field name is validated, and a value is checked where it is read (`Content-Length`, `Range`)
  or not at all

Special thanks for this release:

- https://github.com/vaibhav8a @vaibhav8a for his typo fix

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
