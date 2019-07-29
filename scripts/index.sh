#!/bin/bash

set -efu

init_environment

if [ "$REQUEST_METHOD" != 'GET' ] && [ "$REQUEST_METHOD" != 'POST' ]; then
	send_error 405
fi

if [ "$REQUEST_METHOD" == 'POST' ]; then
	add_header 'Content-Type' 'text/plain'
	send_response 200 "$(./utils/status.sh)"
else # GET
	HEAD_TEMPLATE=$(cat <<EOF
		<title>Zotac manager</title>
		<meta name="description" content="Zotac manager">
		<script src="/file/resources/status.js"></script>
EOF
)

	BODY_TEMPLATE=$(cat <<EOF
		<section>
			<h2>Status</h2>
			<input type="button" value="Reload..." id="reload" />
			<ul id="status">
$(./utils/status.sh)
			</ul>
			<pre>
	$(/home/sid/.cowsay_helper.sh)
			</pre>
		</section>
EOF
)

	export HEAD_TEMPLATE BODY_TEMPLATE
	html=$(envsubst < 'templates/template.html')

	add_header 'Content-Type' 'text/html; charset=utf-8'
	send_response 200 "$html"
fi
