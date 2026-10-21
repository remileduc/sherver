The `site/app/` folder
======================

Anything executable in this folder is a reachable HTTP endpoint: `run_script` resolves the URL
here, `cd`s in, and executes the file with the full URL in `$1`. The library the endpoints use
lives in `lib/`, outside of this folder, so that no exec bit decides whether it is served;
`tests/lint.sh` checks that every script here is executable and that nothing under `lib/` is.
The page templates used by the endpoints live in `templates/`.

Documentation of the library:

* [docs/functions.md](../../docs/functions.md) — the functions, generated from their TomDoc comments
  with [tomdoc.sh](https://github.com/mlafeldt/tomdoc.sh). Download a copy into the repository
  root (it is gitignored), and after changing a comment regenerate the file from there, with the
  modules in the order `lib/SHERVER.sh` sources them (`tests/lint.sh` checks it is up to date):

      ./tomdoc.sh --markdown lib/log.sh lib/request.sh lib/body.sh lib/response.sh lib/static.sh lib/endpoint.sh > docs/functions.md

* [docs/global-variables.md](../../docs/global-variables.md) — the exported variables, written by
  hand.
* [docs/call-graph.md](../../docs/call-graph.md) — who calls what, from the socket down.
