#!/bin/bash

# print the status of vpn-mgr in HTML way.
# result should be stored in an list.

set -efu

# $1 - result of `vpn-mgr.sh status`
# $2 - name of the status to take
# put the result in `$status`
function set_status()
{
	status=''
	[[ "$1" =~ $2[[:space:]]+([[:alpha:]]+) ]]
	if [ "${BASH_REMATCH[1]}" = 'active' ]; then
		status='"<span class="active">ON</span>"'
	elif [ "${BASH_REMATCH[1]}" = 'online' ]; then
		status='"<span class="active">online</span>"'
	else
		status='"<span class="inactive">OFF</span>"'
	fi
	status="$2 $status"
}

internet=''
ufwstatus=''
vpnstatus=''
server=''

vpnmgr="$(vpn-mgr.sh status)"
# OpenVPN
set_status "$vpnmgr" 'OpenVPN status:'
vpnstatus="$status"
# UFW
set_status "$vpnmgr" 'UFW status:'
ufwstatus="$status"
# Internet
set_status "$vpnmgr" 'Internet status:'
internet="$status"
# server
server='Current server:'
[[ "$vpnmgr" =~ $server[[:space:]]+([[:alnum:].]+) ]]
server="${BASH_REMATCH[1]}"

echo "
				<li>$vpnstatus</li>
				<li>$ufwstatus</li>
				<li>$internet</li>
				<li>Selected server: \"$server\"</li>
"
