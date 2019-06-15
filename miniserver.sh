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

cd "$(dirname "$0")"

socat TCP4-LISTEN:"${1:-8080}",fork EXEC:'./dispatcher.sh' &
pid=$!
echo $pid > '/tmp/sherver.pid'
wait $pid

#while nc -lp "${1:-8080}" -e './dispatcher.sh'; do
#	echo '================================================'
#done
