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

# We use ipv4 only for VPN
# -T: drop a connection that goes silent, so a client can't pin a forked child forever
# max-children: ~5 users times the 6 connections a browser opens. socat accepts past the cap and
# waits for a free slot, so backlog is the room where those connections wait
socat -T 10 TCP4-LISTEN:"${1:-8080}",reuseaddr,fork,max-children=32,backlog=32,end-close EXEC:'./dispatcher.sh' &
wait "$!"

# IPV6
#socat -T 10 TCP6-LISTEN:"${1:-8080}",reuseaddr,fork,max-children=32,backlog=32,end-close EXEC:'./dispatcher.sh' &
#wait "$!"
