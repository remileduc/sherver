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
