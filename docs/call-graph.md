Call graph
==========

Who calls what, from the listening socket down to the library functions. The functions are
documented in [docs/functions.md](./functions.md) and the exported variables in
[docs/global-variables.md](./global-variables.md); this file only maps the edges. It is maintained by
hand: update it when a call is added or removed, not for doc-only changes.

Processes
---------

```
sherver.sh ──exec──> socat ──fork+exec (per connection)──> dispatcher.sh
                                                               │ source lib/SHERVER.sh
                                                               │ init_environment
                                                               ├─ method OPTIONS     ──> send_response 200
                                                               │ source site/routes.sh
                                                               ├─ /static/*          ──> send_file
                                                               ├─ / or /index.htm[l] ──> run_script '/index.sh'
                                                               └─ anything else      ──> run_script "$REQUEST_URL"
```

`run_script` `cd`s into `site/app/` and executes the resolved endpoint as a **new process**
(`index.sh`, `page.sh`, ...). A Bash endpoint starts by calling `init_environment` again, which
re-parses the request from the exported `REQUEST_FULL_STRING` instead of stdin.

Two clocks run on a connection: `socat -T 10` drops one that goes *silent*, in either direction,
and the dispatcher gives the request itself `MAX_REQUEST_TIME` seconds to arrive — every read of
`read_request` goes through `_read_with_timeout`, and the 408 is the dispatcher's, never socat's.

Function graph
--------------

Two kinds of edges are left out to keep the graph readable: everything may call `log` and
`log_debug`, and everything that sets a response header does it through `add_header`. Functions
marked `exit` are terminal: they write the response and end the process, so nothing after them
runs — including in their callers. `read_request` stands for its three `_read_request_*` helpers
too, which is why `lib/body.sh` (the body reader and the drain) and `lib/log.sh` draw no box.

```mermaid
flowchart TD
    subgraph endpoints ["endpoints (one process each)"]
        dispatcher[dispatcher.sh]
        index[site/app/index.sh]
        page[site/app/page.sh]
    end

    subgraph library ["lib/ (sourced by lib/SHERVER.sh)"]
        subgraph request ["request.sh"]
            init_environment
            read_request
            bail_request["_bail_request (exit)"]
            read_with_timeout[_read_with_timeout]
            parse_url
            check_encoding[_check_encoding]
            url_decode[_url_decode]
        end
        subgraph response ["response.sh"]
            html_escape
            send_header[_send_header]
            send_response["send_response (exit)"]
            send_error["send_error (exit)"]
            send_redirect["send_redirect (exit)"]
        end
        subgraph static ["static.sh"]
            resolve_path[_resolve_path]
            get_mimetype[_get_mimetype]
            send_file["send_file (exit)"]
        end
        subgraph endpoint ["endpoint.sh"]
            run_script
        end
    end

    dispatcher --> init_environment
    dispatcher --> send_file
    dispatcher --> run_script
    dispatcher --> send_response

    init_environment --> read_request
    read_request --> read_with_timeout
    read_with_timeout --> send_error
    read_request --> bail_request
    read_request --> check_encoding
    read_request --> parse_url
    read_request --> url_decode
    read_request --> send_error
    bail_request --> send_error
    parse_url --> check_encoding
    parse_url --> url_decode
    parse_url --> send_error

    run_script --> parse_url
    run_script --> resolve_path
    run_script --> send_error
    run_script -. exec .-> index
    run_script -. exec .-> page

    index --> init_environment
    index --> html_escape
    index --> send_response
    page --> init_environment
    page --> send_error
    page --> send_file

    send_file --> resolve_path
    send_file --> get_mimetype
    send_file --> send_response
    send_file --> send_header
    send_file --> send_error
    resolve_path --> send_error
    send_error --> send_response
    send_redirect --> send_response
    send_redirect --> send_error
    send_response --> send_header
```

The same edges as a table, with the process boundaries spelled out:

| Caller                 | Calls                                                                           |
| ---------------------- | ------------------------------------------------------------------------------- |
| `sherver.sh`           | `socat` (exec: socat becomes the listener)                                      |
| `dispatcher.sh`        | `init_environment`, then `send_response` (OPTIONS), `send_file` or `run_script` |
| `init_environment`     | `read_request`                                                                  |
| `read_request`         | `_read_with_timeout`, `_bail_request`, `_check_encoding`, `parse_url`,          |
|                        | `_url_decode`, `send_error`                                                     |
| `_read_with_timeout`   | `send_error`                                                                    |
| `_bail_request`        | `send_error`                                                                    |
| `parse_url`            | `_check_encoding`, `_url_decode`, `send_error`                                  |
| `run_script`           | `parse_url`, `_resolve_path`, `send_error`, the endpoint (exec)                 |
| `send_file`            | `_resolve_path`, `_get_mimetype`, `send_response`, `_send_header`, `send_error` |
| `_resolve_path`        | `send_error`                                                                    |
| `send_error`           | `send_response`                                                                 |
| `send_redirect`        | `send_response`, `send_error`                                                   |
| `send_response`        | `_send_header`                                                                  |
| `site/app/index.sh`    | `init_environment`, `html_escape`, `send_response`                              |
| `site/app/page.sh`     | `init_environment`, `send_error`, `send_file`                                   |

`send_file` answers a 304 through `send_response`, but streams the body itself: `_send_header` then
`cat` for a 200, or `tail -c | head -c` for a 206. `_send_header` writes the status line, the headers
and the one access log line per request.

Leaf functions (nothing below them but `log`/`log_debug`): `_check_encoding`, `_url_decode`,
`html_escape`, `add_header`, `_get_mimetype`, `_send_header`.

Error codes
-----------

Which function sends which code through `send_error` (`read_request` routes its early parse
failures through `_bail_request`, which owns the dump-and-log convention, and its reads through
`_read_with_timeout`, which owns the 408):

| Function               | Codes                                       | Sent when                                                 |
| ---------------------- | ------------------------------------------- | --------------------------------------------------------- |
| `read_request`         | 400, 405, 411, 413, 414, 417, 431, 501, 505 | bad request line, header or body; method; version; limits |
| `_read_with_timeout`   | 408                                         | request not whole after `MAX_REQUEST_TIME` seconds        |
| `parse_url`            | 400                                         | invalid percent encoding                                  |
| `_resolve_path`        | 404, 500                                    | path missing or escaping the tree — never 403             |
| `run_script`           | 404, 500                                    | endpoint not executable, or it exited non-zero            |
| `send_file`            | 404, 416                                    | not a readable regular file; unsatisfiable `Range`        |
| `send_redirect`        | 500                                         | no target, a CR or LF in it, or non-redirect code         |
| `site/app/page.sh`     | 404, 405                                    | missing `page` parameter; method not GET or HEAD          |

`read_request` also writes the interim `HTTP/1.1 100 Continue` itself, raw — never through
`_send_header`, which would log an access line and consume `RESPONSE_HEADERS`.

External commands
-----------------

| Command    | Called from                                                  |
| ---------- | ------------------------------------------------------------ |
| `socat`    | `sherver.sh`                                                 |
| `realpath` | `init_environment` (`SHERVER_ROOT`), `_resolve_path`         |
| `stat`     | `send_file` (ETag, `Last-Modified`, `Content-Length`)        |
| `cat`      | `send_file` (body), heredocs in `send_error` and `index.sh`  |
| `tail`     | `send_file` (a range answer, piped into `head`)              |
| `head`     | `send_file` (a range answer)                                 |
| `envsubst` | `index.sh`                                                   |
