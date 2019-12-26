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
- [Run as a service (daemon)](#run-as-a-service-daemon)

[Example](#example)

[About Security](#about-security)

[Why Sherver?](#why-sherver)


Presentation
------------

### How to run ###

Just clone and run `./sherver.sh`. Then, you should be able to connect to [localhost:8080](http://localhost:8080/). You can pass the port to listen on as a parameter: `./sherver.sh 8080` (default is `8080`).

### Requirements ###

This is made to run with `Bash`. It may not work in another shell. The following tools need to be present in the system (note that they are all part of the default installation of Debian):
- `mimetype` command, used to get the mimetype of the files.
	- you can change it by `file --mime-type -b` if you prefer. just change the `send_file` function in [scripts/SHERVER_UTILS.sh](./scripts/SHERVER_UTILS.sh)
- `envsubst` if you want to do templating
- `socat` to run the server.
	- you can use `netcat` instead, but it doesn't work well with concurrent HTTP requests

### Features ###

Sherver is a web server that implements part of HTTP 1.0. Even if it is written in a few lines of Bash, it is able to do a lot:
- no configuration needed: you can just add files either in `scripts` or in `file` folders
- serve any HTML page no matter how complexe (with advanced JavaScript and multiple scripts or files to download...)
- serve files (text or binary, pictures...) with correct mime type
- dynamic pages
- templated HTML so you don't have to duplicate headers and footers
- parse of URL query string
- support for GET and POST
- deal with client cache resources
- easily extandable
	- can run any scripts or executable of any languages as soon as they output something on `stdout`
	- comes with a library of bash functions to ease the use

All of these makes Sherver the perfect tool to run a small server that will serve few pages on your local network.

Even if it sounds awesome, Sherver still has the following limitations:
- only support HTTP GET and POST requests, though it would be easy to add the others
- no concurrency
	- if a page needs to download a lot of files, the files are sent one after the other
	- if 2 users access the website, the second one needs to wait until the first one is fully served
- no security (see [About Security](#about-security)).

This is why Sherver is supposed to remain in a private and controlled environment. **Do not expose Sherver on Internet!!!** If you want to expose your site on Internet, you should use a tool that knows about security and concurrency (like *nginx* or other).

**Always run Sherver behind a firewall that prevent any intrusions from outside**.

How to use
----------

Quick documentation about how to use Sherver for your own use. All variables and functions mentioned here have a full
description in [scripts/README.md](./scripts/README.md).

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
- `REQUEST_FULL_STRING`
- `REQUEST_METHOD`
- `REQUEST_URL`
- `REQUEST_HEADERS`
- `REQUEST_BODY`
- `URL_BASE`
- `URL_PARAMETERS`
- `DATE`
- `RESPONSE_HEADERS`
- `HTTP_RESPONSE`

And also a lot of useful functions like:
- `add_header`
- `send_response`
- `send_file`
- `send_error`

Check the whole documentation about the `SHERVER_UTILS.sh` library in [scripts/README.md](./scripts/README.md).

Everything written on the standard output will be sent to the client. Here is a very simple script that returns
the requests in a text format:

```bash
#!/bin/bash

init_environment
if [ "$REQUEST_METHOD" != 'GET' ]; then
	send_error 405
fi

add_header 'Content-Type' 'text/plain'
send_response 200 "$REQUEST_FULL_STRING"
```

**Any other scripts or binaries**

If you don't use Bash, you will only have access to the environment variable `REQUEST_FULL_STRING` that
contains the full request as a string. The requested URL (`REQUEST_URL`) will be passed as first argument.

Everything written on the standart output will be sent to the client. Though, you should write the
headers of the response yourself.

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
if [ "$REQUEST_METHOD" != 'GET' ]; then
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

Post requests are supported. You can check the value of the variable `REQUEST_METHOD` that will either be
`GET` or `POST`, so you can have different behavior based on the type of the request.

The content of the POST request can be retreived in the variable `REQUEST_BODY`. If the data is url encoded
by the client, you can use the function `parse_url` with some tricks to get an associative array of the parameters.

Any content can be sent back to the client. You can add the correct mime type thanks to the method `add_header`.

How to use (Expert)
-------------------

All variables and functions mentioned here have a full description in [scripts/README.md](./scripts/README.md).

### Logs ###

Anything written to the standard error can be logged. To ease the logs, you can use the function `log`.

To keep the logs in a file, you can redirect the error output of *sherver.sh* in a file:

```bash
./sherver.sh 2> logs.txt
```

By default, the headers of both the requests and the responses are logged, but not the bodies.

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
copy the file [sherver.service](./sherver.service) in `/usr/share/systemd/` and then
enable the service:

```bash
cp sherver.service /usr/share/systemd/
ln -s /usr/share/systemd/sherver.service /etc/systemd/system/sherver.service
systemctl daemon-reload
systemctl enable sherver.service
```

Example
-------

You can see as an example the scripts that I use at home to manage my VPN. It is accessible on the
[perso](https://github.com/remileduc/sherver/tree/perso) branch. Note that you need the script
[vpn-mgr.sh](https://github.com/remileduc/vpn-mgr) to be able to use it properly.

About security
--------------

See [bashttpd](https://github.com/avleen/bashttpd#security). It is obvious to say that this comes without any security
features. **Do not expose Sherver on Internet**.

- it is not currently able to serve over HTTPS
- it uses rudimentary bash scripts to parse URL and POST request body, that could lead to security breaches
- it executes blindly any script in the *scripts* subfolder

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
