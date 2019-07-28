#!/bin/bash

set -efu

init_environment

result=''

# $1 - sudo password
# $@ - arguments for vpn-mgr.sh
# Store result in `$result`
function run_vpn_mgr()
{
	local password
	password="$1"
	shift
	if echo "$password" | sudo -S vpn-mgr.sh "$@" &> /dev/null; then
		result=$(cat <<EOF
	<section class="result good">
		<h2>Result</h2>
		<p>VPN $1</p>
	</section>
EOF
)
	else
		result=$(cat <<EOF
	<section class="result bad">
		<h2>Bad request</h2>
	</section>
EOF
)
	fi
}

if [ "$REQUEST_METHOD" = 'POST' ]; then
	if [ ! -v "REQUEST_BODY_PARAMETERS['password']" ] \
			|| [ ! -v "REQUEST_BODY_PARAMETERS['action']" ] \
			|| ([ "${REQUEST_BODY_PARAMETERS['action']}" == 'set' ] && [ ! -v "REQUEST_BODY_PARAMETERS['server']" ]); then
		result=$(cat <<EOF
	<section class="result bad">
		<h2>Bad request</h2>
	</section>
EOF
)
	elif [ "${REQUEST_BODY_PARAMETERS['action']}" == 'start' ] \
			|| [ "${REQUEST_BODY_PARAMETERS['action']}" == 'stop' ] \
			|| [ "${REQUEST_BODY_PARAMETERS['action']}" == 'restart' ]; then
		run_vpn_mgr "${REQUEST_BODY_PARAMETERS['password']}" "${REQUEST_BODY_PARAMETERS['action']}"
	elif [ "${REQUEST_BODY_PARAMETERS['action']}" == 'set' ]; then
		run_vpn_mgr "${REQUEST_BODY_PARAMETERS['password']}" 'set' "${REQUEST_BODY_PARAMETERS['server']}"
	else
		result=$(cat <<EOF
	<section class="result bad">
		<h2>Bad request</h2>
	</section>
EOF
)
	fi
elif [ "$REQUEST_METHOD" != 'GET' ]; then
	send_error 405
fi

HEAD_TEMPLATE=$(cat <<EOF
	<title>Zotac VPN manager</title>
	<meta name="description" content="Zotac VPN manager">
EOF
)

BODY_TEMPLATE=$(cat <<EOF
$result
	<section>
		<h2>VPN manager</h2>
		<p>Your IP is: <code>$SOCAT_PEERADDR</code></p>
		<form method="post">
			<fieldset>
				<legend>Chose the action to perform</legend>
				<div><label for="pwd">Password</label> <input id="pwd" type="password" placeholder="zotac password" name="password" autofocus required /></div>
				<br />
				<div><input id="rstart" type="radio" name="action" value="start" /><label for="rstart">Start VPN</label></div>
				<div><input id="rstop" type="radio" name="action" value="stop" /><label for="rstop">Stop VPN</label></div>
				<div><input id="rrestart" type="radio" name="action" value="restart" checked /><label for="rrestart">Restart VPN</label></div>
				<div>
					<input id="rset" type="radio" name="action" value="set" /><label for="rset">Set VPN server:</label>
					<input id="server" type="text" placeholder="server name: ch111" name="server" pattern="[a-z]{2}[0-9]{1,3}" />
					see: <a href="https://nordvpn.com/servers/tools/" target="_blank" rel="noopener noreferrer">nordvpn.com/servers/tools/</a>
				</div>
				<br />
				<div><button type="submit">Send...</button></div>
			</fieldset>
		</form>
	</section>
EOF
)

export HEAD_TEMPLATE BODY_TEMPLATE

html=$(envsubst < 'templates/template.html')

add_header 'Content-Type' 'text/html; charset=utf-8'
send_response 200 "$html"
