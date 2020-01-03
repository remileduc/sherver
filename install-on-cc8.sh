#!/bin/bash

# prerequisites
yum upgrade
yum install git nano htop socat perl-File-MimeInfo

# firewall
firewall-cmd --zone=public --add-port=80/tcp --permanent
firewall-cmd --reload

# clone
cd /usr/local/bin
git clone https://github.com/remileduc/sherver.git
cd sherver
git checkout sechrest

# install
cp sherver.service /usr/share/systemd/
ln -s /usr/share/systemd/sherver.service /etc/systemd/system/sherver.service
systemctl daemon-reload
systemctl enable sherver.service

# start
service sherver start
