The `scripts/` folder
=====================

Anything executable in this folder is a reachable HTTP endpoint: `run_script` resolves the URL
here, `cd`s in, and executes the file with the full URL in `$1`. This is also why
`SHERVER_UTILS.sh`, the library the endpoints use, is **not** executable — `tests/lint.sh`
enforces both directions. The page templates used by the endpoints live in `templates/`.

Documentation of the library:

* [docs/functions.md](../docs/functions.md) — the functions, generated from their TomDoc comments
  with [tomdoc.sh](https://github.com/mlafeldt/tomdoc.sh). Download a copy into the repository
  root (it is gitignored), and after changing a comment regenerate the file from there with
  `./tomdoc.sh --markdown scripts/SHERVER_UTILS.sh > docs/functions.md` (`tests/lint.sh` checks it
  is up to date).
* [docs/global-variables.md](../docs/global-variables.md) — the exported variables, written by
  hand.
* [docs/call-graph.md](../docs/call-graph.md) — who calls what, from the socket down.
