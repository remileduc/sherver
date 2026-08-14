<!--
MIT License

Sherver: Pure Bash lightweight web server.
Copyright (c) 2019 Rémi Ducceschi

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
-->

Sherver
=======

Pure Bash lightweight web server.

Easy solution to setup a **local** website without any server configuration!!!

This is inspired by [bashttpd](https://github.com/avleen/bashttpd). Though, the behavior is entirely different. See below for more information.

[Presentation](#presentation)
- [How to run](#how-to-run)
- [Requirements](#requirements)
- [Features](#features)

[How to use](#how-to-use)
- [Serve static pages](#serve-static-pages)
- [Serve files](#serve-files)
- [Serve dynamic pages](#serve-dynamic-pages)
- [Template mechanism](#template-mechanism)
- [POST requests](#post-requests)

[How to use (Expert)](#how-to-use-expert)
- [Logs](#logs)
- [Dispatcher](#dispatcher)
- [HTTPS](#https)
- [Run as a service (daemon)](#run-as-a-service-daemon)
	- [Sandboxing](#sandboxing)

[Example](#example)

[About Security](#about-security)

[Why Sherver?](#why-sherver)

[Tests](#tests)

[License?](#license)


Presentation
------------

### How to run ###

Just clone and run `./sherver.sh`. Then, you should be able to connect to [localhost:8080](http://localhost:8080/). You can pass the port to listen on as a parameter: `./sherver.sh 8080` (default is `8080`), and
`--debug` before it to get verbose logs: `./sherver.sh --debug 8080`. `./sherver.sh --version` prints the
version and exits; [CHANGELOG.md](./CHANGELOG.md) says what each one brought.

### Requirements ###

This is made to run with `Bash`. It may not work in another shell. The following tools need to be present in the system (note that they are all part of the default installation of Debian):
- `socat` to run the server.
	- you can use `netcat` instead, but it doesn't work well with concurrent HTTP requests
- `date`, `realpath`, `stat` and `cat` — from `coreutils` on a GNU system, but busybox's versions are enough (see below)
- optionnal: `envsubst` if you want to do templating (comes in the package `gettext-base` in Debian, or something like `gettext-envsubst` as a smaller package in Alpine)
- for development: `bats` and `shellcheck` for the tests. The two suites that open a port also want
	`curl`, and the HTTPS one uses `openssl` to generate itself a throwaway certificate, falling back on
	a committed one when there is no `openssl` around.

[docs/call-graph.md#external-commands](./docs/call-graph.md#external-commands) lists which function calls which of
these tools.

On a busybox system such as an Alpine container, `coreutils` is not needed: `date -uR`, `stat -c` and
`cat` are all covered by busybox, and `realpath` is called without any option precisely so that
busybox's — which parses none — is enough. Only `bash`, `socat` and — because the default index page
templates itself with it — `envsubst` have to come from packages.

### Features ###

Sherver is a web server that implements part of HTTP 1.0. Even if it is written in a few lines of Bash, it is able to do a lot:
- no configuration needed: you can just add files either in `scripts` or in `file` folders
- serve any HTML page no matter how complexe (with advanced JavaScript and multiple scripts or files to download...)
- serve files (text or binary, pictures...) with correct mime type
- dynamic pages
- templated HTML so you don't have to duplicate headers and footers
- parse of URL query string, percent decoded (so `/file/my%20file.txt` finds `my file.txt`)
- support for GET, HEAD and POST
- deal with client cache resources
- easily extandable
	- can run any scripts or executable of any languages as soon as they output something on `stdout`
	- comes with a library of bash functions to ease the use

All of these makes Sherver the perfect tool to run a small server that will serve few pages on your local network.

Even if it sounds awesome, Sherver still has the following limitations:
- only support HTTP GET, HEAD and POST requests, though it would be easy to add the others
- concurrency is capped at 32 connections: `socat` forks one process per connection and makes the
  next ones wait for a free slot, so a burst queues instead of thrashing the machine
- no keep alive: this is HTTP 1.0 with `Connection: close`, so one request per connection
- no shared state between requests: each one is a brand new process, so nothing is cached server side
- POST bodies are limited to 64 kio, bigger ones get a `413` answer (see [POST requests](#post-requests))
- the request line and headers are limited to 8 kio, bigger ones get a `414` or a `431` answer
- no security (see [About Security](#about-security)).

This is why Sherver is supposed to remain in a private and controlled environment. **Do not expose Sherver on Internet!!!** If you want to expose your site on Internet, you should use a tool that knows about security and scalability (like *nginx* or other).

**Always run Sherver behind a firewall that prevent any intrusions from outside**.

How to use
----------

Quick documentation about how to use Sherver for your own use. All variables mentioned here have a full description
in [docs/global-variables.md](./docs/global-variables.md), the functions in [docs/functions.md](./docs/functions.md),
and a map of who calls what is in [docs/call-graph.md](./docs/call-graph.md).

Note that the 2 important folders `file` and `scripts` can be symlink, but files inside can't.

### Serve static pages ###

The simplest thing you can do is to serve static pages : pure HTML files that don't need any processing.

To do so, you only need to put your HTML files in the subdirectory [file/pages](./file/pages). Then, you can access
to your pages through a URL like `/file/pages/index.html` (if your
file name is `index.html` for instance).

Note that you'll have to give the full file name in the URL so Sherver can find it.

It is as simple as that! If Sherver can find the file, it will serve it. Otherwise, it will return a 404 error.

### Serve files ###

You can serve any type of files from Sherver. From text-based like CSS or JavaScript to binaries like images, videos, zip...

Just put the files in the subdirectory [file](./file). You can then reference them through a URL like
`/file/venise.webp`. Note that it is preferable to give full path rather than relative paths.

Sherver will automatically serve the file if it can find it, with the correct mime type. It will even allow the browser to
cache the file, and will only serve it again if the file has changed. If Sherver can't find the file, it will return a
404 error.

For resources, like CSS, JavaScript, favicon... it is better to put them in the subfolder [file/resources](./file/resources),
though you don't have to.

**Example on how to link a CSS file:**

```html
<link rel="stylesheet" type="text/css" href="/file/resources/ugly.css">
```

**Example on how to integrate a picture in your HTML:**

```html
<img src="/file/venise.webp" alt="">
```

### Serve dynamic pages ###

This is where Sherver becomes useful: it can serve dynamic pages, built server side depending on the context.

To do so, you just need to add executables in the subfolder [scripts](./scripts). Executables can be of any types
(bash script, python script, any other scripts, any binary like C++ compiled executable...) as soon as Sherver can
execute it (it must have the `executable` flag set).

As soon as you have an executable there, Sherver will run it and serve its output. Note that `index.sh` is a
particular name as it is the one that will be executed by the dispatcher if you access to the root of the website
(see [dispatcher](#dispatcher) section below). If Sherver can't run any files, it will return a 404 error. If
the executable fails (return code is not `0`), it will return a 500 error.

To link an executable, you have to omit the folder`scripts` in the URL: `/page.sh` will look for the executable
`./scripts/page.sh`.

The executable is ran from the `scripts` folder.

**Bash scripts**

Sherver is mainly made to work with bash scripts. If you create a Bash script, the first thing you should do is to
run the function `init_environment`. Then you will have access to all the following variables:
- `SHERVER_ROOT`
- `REQUEST_METHOD`
- `REQUEST_URL`
- `REQUEST_HTTP_VERSION`
- `REQUEST_HEADERS`
- `REQUEST_BODY`
- `REQUEST_BODY_PARAMETERS`
- `URL_BASE`
- `URL_PARAMETERS`
- `RESPONSE_HEADERS`
- `HTTP_RESPONSE`
- `MAX_BODY_SIZE`
- `MAX_HEADERS_SIZE`
- `REQUEST_FULL_STRING`

And also a lot of useful functions like:
- `add_header`
- `send_response`
- `send_file`
- `send_error`

Check the whole documentation about the `SHERVER_UTILS.sh` library in [docs/functions.md](./docs/functions.md) and
[docs/global-variables.md](./docs/global-variables.md).

Everything written on the standard output will be sent to the client. Here is a very simple script that returns
the requests in a text format:

```bash
#!/bin/bash

init_environment
if [ "$REQUEST_METHOD" != 'GET' ] && [ "$REQUEST_METHOD" != 'HEAD' ]; then
	send_error 405
fi

add_header 'Content-Type' 'text/plain'
send_response 200 "$REQUEST_FULL_STRING"
```

**Any other scripts or binaries**

If you don't use Bash, you will only have access to the environment variable `REQUEST_FULL_STRING` that
contains the full request as a string. The requested URL (`REQUEST_URL`) will be passed as first argument.

Everything written on the standard output will be sent to the client. Though, you should write the
headers of the response yourself. That includes handling `HEAD` requests: the method is the first word
of `REQUEST_FULL_STRING`, and a `HEAD` answer must carry the headers only, no body.

### Template mechanism ###

For Bash scripts, there is a basic template engine integrated with Sherver (lol). It actually uses
`envsubst` to replace any occurrence of `$VARIABLE` by the variable from the environment if there is.

You can put your templates in the subfolder [scripts/templates](./scripts/templates), though it is not
mandatory.

Here is a template for a text file `template.txt` (that improves our previous Bash script example):

```
You entered the following request:

$REQUEST
```

And you would use it with the following script:

```bash
#!/bin/bash

init_environment
if [ "$REQUEST_METHOD" != 'GET' ] && [ "$REQUEST_METHOD" != 'HEAD' ]; then
	send_error 405
fi

REQUEST="$REQUEST_FULL_STRING"
# put REQUEST in the environment so we can use it in our template
export REQUEST
# load the template
response=$(envsubst < 'templates/template.txt')

add_header 'Content-Type' 'text/plain'
send_response 200 "$response"
```

Full HTML example in [Example](#example) below.


### POST requests ###

Post requests are supported. You can check the value of the variable `REQUEST_METHOD` that will be
`GET`, `HEAD` or `POST`, so you can have different behavior based on the type of the request. A `HEAD` is a
`GET` whose answer carries no body: the send functions drop it for you, so treat it like a `GET`. If you
write the response yourself instead of using them, dropping the body is on you.

The content of the POST request can be retrieved in the variable `REQUEST_BODY`. If the client sent
`application/x-www-form-urlencoded` content, the parameters are also parsed for you in the associative
array `REQUEST_BODY_PARAMETERS`.

The body is limited to 64 kio (see `MAX_BODY_SIZE`), and a bigger one gets a `413` answer. The limit is
not arbitrary: the body ends up in `REQUEST_FULL_STRING` which is exported, and Linux refuses to run a
command when a single environment variable is bigger than 128 kio.

Any content can be sent back to the client. You can add the correct mime type thanks to the method `add_header`.

How to use (Expert)
-------------------

All variables mentioned here have a full description in [docs/global-variables.md](./docs/global-variables.md), and
the functions in [docs/functions.md](./docs/functions.md).

### Logs ###

Anything written to the standard error can be logged. To ease the logs, you can use the functions
`log` and `log_debug`.

To keep the logs in a file, you can redirect the error output of *sherver.sh* in a file:

```bash
./sherver.sh 2> logs.txt
```

By default, a served request is one line, and an error adds the reason it failed:

```
::ffff:192.0.2.7 GET /file/venise.webp 200
NOT FOUND: realpath - 'nope.sh'
::ffff:192.0.2.7 GET /nope.sh 404
```

The four fields are the client address, the method, the URL and the status code. The address comes
from `SOCAT_PEERADDR`, which *socat* sets for every connection and the scripts inherit: it is
spelled the way *socat* spells it (an IPv4 client of an IPv6 listener shows up as `::ffff:` like
above), and it is a `-` when there is no *socat* in front, as when *dispatcher.sh* is driven by hand
as a filter. A request too broken to have a method logs a `-` in its place too, so the field count
never changes.

Passing `--debug` adds the headers of both the requests and the responses (never the bodies):

```bash
./sherver.sh --debug 8080
```

The flag exports `SHERVER_DEBUG=1`, which is what the scripts actually read, so the service can turn
it on with `systemctl edit sherver.service` and an `Environment=SHERVER_DEBUG=1` line. Use `log_debug`
in your own scripts for anything you only want under that flag.

When running as a service, the logs go to the journal:

```bash
journalctl -u sherver.service -f
```

### Dispatcher ###

The dispatcher is responsible of asking to either serve a file or run a script, depending on the requested UTL.
It is implemented in the file [dispatcher.sh](./dispatcher.sh).

It currently has 4 actions:

- if the URL is the root (`/`), then it executes the script `scripts/index.sh`
- if the URL asks for `index.htm` or `index.html`, it executes the script `scripts/index.sh`
- if the URL starts with `/file/`, it serves the file asked
- in any other case, it will run the script provided by the URL, prepending the *scripts* folder
  (the URL `/test/dummy.sh` will run the script `scripts/test/dummy.sh` if it exists).

All this behaviors can be changed by editing the file [dispatcher.sh](./dispatcher.sh).

### HTTPS ###

Sherver can serve over HTTPS, so a sniffer on the network only sees an encrypted stream. TLS is
terminated by `socat` itself: generate a self-signed certificate, swap the `TCP6-LISTEN` line for
the `OPENSSL-LISTEN` ones in [sherver.sh](./sherver.sh), and import the certificate on your
devices. The whole procedure — and what it does *not* protect against — is in
[docs/https.md](./docs/https.md).

### Run as a service (daemon) ###

First of all, you need to create a specific user that will run `sherver.sh` with low priviledges.
We'll call our user `sherver` and we'll put the whole website in its hone directory.

We need to add our user to the groups `sudo` and `netdev`, so it is able to manage the VPN
(it is obviously not a good idea to give `sudo` to the user, this is why you shouldn't expose
the website on Internet).

```bash
useradd -mUG sudo,netdev -s /usr/bin/bash sherver
passwd sherver
	...
```

Note that you can add your current user to the `sherver` group for practical reasons
(you'll have to relog to make it effective):
```bash
adduser USER sherver
```

Now, let's get the website in its home directory

```bash
su sherver
cd ~
git clone https://github.com/remileduc/sherver.git
cd sherver
git checkout perso
```

Finally, we need to enable the service so it starts `sherver.sh` automatically. To do so,
enable the file [systemd/sherver.service](./systemd/sherver.service). Giving `systemctl enable` an
absolute path symlinks the unit from the checkout into `/etc/systemd/system/`, so a `git pull`
updates it:

```bash
systemctl enable --now /home/sherver/sherver/systemd/sherver.service
```

If `/home` is a separate, encrypted or network mount, systemd may not be able to read the unit
when it loads its configuration at boot. Copy it instead:

```bash
cp systemd/sherver.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now sherver.service
```

The unit assumes the website is in `/home/sherver/sherver/` and listens on port 8080. Both, and the
sandboxing below, are overridden without touching the file:

```bash
systemctl edit sherver.service
	[Service]
	Environment=SHERVER_PORT=8000
```

#### Sandboxing ####

The unit runs the server under most of the systemd sandboxing options: a read-only file system, a
private `/tmp` and `/dev`, no access to the kernel interfaces, and a system call filter. It also caps
the process tree, because `socat` forks a dispatcher per connection and each one forks a few more.

Example
-------

You can see as an example the scripts that I use at home to manage my VPN. It is accessible on the
[perso](https://github.com/remileduc/sherver/tree/perso) branch. Note that you need the script
[vpn-mgr.sh](https://github.com/remileduc/vpn-mgr) to be able to use it properly.

About security
--------------

See [bashttpd](https://github.com/avleen/bashttpd#security). It is obvious to say that this comes without any security
features. **Do not expose Sherver on Internet**.

- it uses rudimentary bash scripts to parse URL and POST request body, that could lead to security breaches
- it executes blindly any script in the *scripts* subfolder
- [HTTPS](./docs/https.md) only encrypts the transport, it fixes none of the above

If you need to expose the site on internet, you need a real server that has been built especially to face all these
issues.

Though, it is perfect to use on a local network. It will be as secure as are your wifi connection and your firewall.

Why Sherver?
------------

I wanted to set up quickly a server that would serve dynamic pages, and that could execute some bash scripts, in order
to control my media center through web pages.

I didn't want to install and configure Apache or nGinx. In fact, I didn't want *any* configuration.

Sherver is able to run without any configuration. You just need to add files at the right place. It can run without
anything to be installed (all tools used are part of the default installation of Debian, except maybe for socat).

You can see my use case in the `perso` branche.

Tests
-----

A test suite is available in [tests/](./tests). All tests have been generated by `claude-code` with poor code review. Better than no tests...

Also, I'd like to see you write tests for bash scripts oO Honestly bash scripts are already aweful enough with this terrible syntax.

License
-------

Everything is under MIT License.
