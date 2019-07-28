#!/bin/bash

set -efu

init_environment

if [ "$REQUEST_METHOD" != 'GET' ] && [ "$REQUEST_METHOD" != 'POST' ]; then
	send_error 405
fi

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

ulcontent=$(cat <<EOF
				<li>$vpnstatus</li>
				<li>$ufwstatus</li>
				<li>$internet</li>
				<li>Selected server: "$server"</li>
EOF
)

if [ "$REQUEST_METHOD" == 'POST' ]; then
	add_header 'Content-Type' 'text/plain'
	send_response 200 "$ulcontent"
else # GET
	HEAD_TEMPLATE=$(cat <<EOF
		<title>Zotac manager</title>
		<meta name="description" content="Zotac manager">
EOF
)

	BODY_TEMPLATE=$(cat <<EOF
		<section>
			<h2>Status</h2>
			<input type="button" value="Reload..." id="reload" />
			<ul id="status">
$ulcontent
			</ul>
			<pre>
	$(/home/sid/.cowsay_helper.sh)
			</pre>
		</section>
EOF
)

	INLINE_SCRIPT=$(cat <<EOF
		document.addEventListener("DOMContentLoaded", function() {
			var reload = document.querySelector("#reload");
			var text = reload.value;
			reload.addEventListener("click", function() {
				reload.disabled = true;
				reload.value = "Reloading...";
				var list = document.querySelector("#status");
				list.innerHTML = "...";
				fetch(".", {
					method: "POST"
				}).then(function(response) {
					return response.text();
				}).then(function(contents) {
					list.innerHTML = contents;
					reload.disabled = false;
					reload.value = text;
				})
			});
		});
EOF
)

	export HEAD_TEMPLATE BODY_TEMPLATE INLINE_SCRIPT
	html=$(envsubst < 'templates/template.html')

	add_header 'Content-Type' 'text/html; charset=utf-8'
	send_response 200 "$html"
fi
