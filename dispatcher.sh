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

source 'scripts/SHERVER_UTILS.sh'

init_environment

# serve file
if [[ $URL_BASE =~ ^/file/.* ]]; then
	send_file "${URL_BASE:1}"
# run script
# special case for root
elif [ $URL_BASE = '/' ] || [[ $URL_BASE =~ ^/index\.(htm|html) ]]; then
	run_script '/index.sh'
else
	run_script "$REQUEST_URL"
fi

log '================================================'
exit 0
