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

# The whole library, in the order the modules need each other at load time. Paths are
# relative to the repository root, where every process that sources this runs from.
# shellcheck source=lib/log.sh
source 'lib/log.sh'
# shellcheck source=lib/request.sh
source 'lib/request.sh'
# shellcheck source=lib/body.sh
source 'lib/body.sh'
# shellcheck source=lib/response.sh
source 'lib/response.sh'
# shellcheck source=lib/static.sh
source 'lib/static.sh'
# shellcheck source=lib/endpoint.sh
source 'lib/endpoint.sh'
