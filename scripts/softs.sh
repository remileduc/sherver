#!/bin/bash

set -efu

init_environment

# $1 - software name
# $2 - port number for URL
function print_soft()
{
	local img="<img src=\"/file/resources/$1.png\" alt=\"$1 logo\" class=\"softlogo\" />"
	local softstatus=''
	if pgrep "$1" &> /dev/null; then
		softstatus='"<span class="active">ON</span>"'
	else
		softstatus='"<span class="inactive">OFF</span>"'
	fi
	echo "<p>$img $1: $softstatus - WebUI: <a href=\"http://$SOCAT_SOCKADDR:$2\" target=\"_blank\" rel=\"noopener noreferrer\">$SOCAT_SOCKADDR:$2</a></p>"
}

if [ "$REQUEST_METHOD" = 'POST' ] \
		&& [ -v "REQUEST_BODY_PARAMETERS['getstatus']" ] \
		&& [ "${REQUEST_BODY_PARAMETERS['getstatus']}" == 'status' ]; then
	add_header 'Content-Type' 'text/plain'
	send_response 200 "$(./utils/status.sh)"
elif [ "$REQUEST_METHOD" != 'GET' ]; then
	send_error 405
fi

HEAD_TEMPLATE=$(cat <<EOF
		<title>Zotac VPN manager</title>
		<meta name="description" content="Zotac VPN manager">
		<script src="/file/resources/status.js"></script>
EOF
)

BODY_TEMPLATE=$(cat <<EOF
	<section>
		<h2>Software manager</h2>
		$(print_soft 'qbittorrent' '8081')
	</section>
	<section>
		<h2>Status</h2>
		<input type="button" value="Reload..." id="reload" />
		<ul id="status">
$(./utils/status.sh)
		</ul>
	</section>
EOF
)

INLINE_SCRIPT=$(cat <<EOF
EOF
)

export HEAD_TEMPLATE BODY_TEMPLATE INLINE_SCRIPT
html=$(envsubst < 'templates/template.html')

add_header 'Content-Type' 'text/html; charset=utf-8'
send_response 200 "$html"
