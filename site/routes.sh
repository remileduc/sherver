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

# The routing of the site, sourced by `dispatcher.sh` once the request is parsed and
# OPTIONS answered. Edit this file, not the dispatcher, to add a route.

# serve static content: the URL `/static/x` is the file `site/static/x`, cwd being the root
if [[ $URL_BASE =~ ^/static/.* ]]; then
	send_file "site/${URL_BASE:1}"
# run script
# special case for root
elif [ "$URL_BASE" = '/' ] || [[ $URL_BASE =~ ^/index\.html?$ ]]; then
	# the query string goes along: the endpoint sees the URL `run_script` was handed. Cut
	# at the raw `?`, not at the length of `URL_BASE`: that one is percent-decoded
	declare -g query_string=''
	if [[ $REQUEST_URL == *\?* ]]; then
		query_string="?${REQUEST_URL#*\?}"
	fi
	run_script "/index.sh$query_string"
else
	run_script "$REQUEST_URL"
fi
