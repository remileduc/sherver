#!/bin/bash

# MIT License
#
# Sherver: Pure Bash lightweight web server.
# Copyright (c) 2019 Rémi Ducceschi
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

set -efu

init_environment

if [ "$REQUEST_METHOD" != 'GET' ] && [ "$REQUEST_METHOD" != 'HEAD' ]; then
	send_error 405
fi
# `:-` because `set -u` makes a missing key fatal, which would end up as a 500
if [ -z "${URL_PARAMETERS[page]:-}" ]; then
	send_error 404
fi

send_file "../file/pages/${URL_PARAMETERS[page]}"
