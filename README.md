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

How to run
----------

Just clone and run `./miniserver.sh`. Then, you should be able to connect to [localhost:8080](http://localhost:8080/).

Requirements
------------

This is made to run with `Bash`. It may not work in another shell. The following tools need to be present in the system (note that they are all part of the default installation of Debian):
- `mimetype` command, used to get the mimetype of the files.
	- you can change it by `file` if you prefer. just change the `send_file` function in [scripts/SHERVER_UTILS.sh](./scripts/SHERVER_UTILS.sh)
- `python` used to stream binary files. Python 2 or 3 can be used.
	- default is Python 3, if you want to use Python 2, you'll have to change one line in the `send_file` function in [scripts/SHERVER_UTILS.sh](./scripts/SHERVER_UTILS.sh)
- `socat` to run the server. Socat is installed by default on Debian.
	- you can use `netcat` instead, but it doesn't work well with concurrent HTTP requests

More documentation later...
