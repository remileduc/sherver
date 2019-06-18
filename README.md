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

Presentation
------------

### How to run ###

Just clone and run `./miniserver.sh`. Then, you should be able to connect to [localhost:8080](http://localhost:8080/). You can pass the port to listen on as a parameter: `./miniserver.sh 8081`.

### Requirements ###

This is made to run with `Bash`. It may not work in another shell. The following tools need to be present in the system (note that they are all part of the default installation of Debian):
- `mimetype` command, used to get the mimetype of the files.
	- you can change it by `file` if you prefer. just change the `send_file` function in [scripts/SHERVER_UTILS.sh](./scripts/SHERVER_UTILS.sh)
- `envsubst` if you want to do templating
- `python` used to stream binary files. Python 2 or 3 can be used.
	- default is Python 3, if you want to use Python 2, you'll have to change one line in the `send_file` function in [scripts/SHERVER_UTILS.sh](./scripts/SHERVER_UTILS.sh)
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

Even if it sounds awesome, Sherver still has the following limitations:
- only support HTTP GET and POST requests, though it would be easy to add the others
- no concurrency
	- if a page needs to download a lot of files, the files are sent one after the other
	- if 2 users access the website, the second one needs to wait until the first one is fully served
- no security (see below)

This is why Sherver is supposed to remain in a private and controlled environment. **Do not expose Sherver on Internet!!!** If you want to expose your site on Internet, you should use a tool that knows about security and concurrency.

**Always run Sherver behind a firewall that prevent any intrusions from outside**.

About security
--------------

Why Sherver?
------------

More documentation later...
