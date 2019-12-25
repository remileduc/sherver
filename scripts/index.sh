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
		<title>Treasure Hunt</title>
		<meta name="description" content="Treasure Hunt">
		<script src="/file/resources/events.js"></script>
EOF
)

	BODY_TEMPLATE=$(cat <<EOF
		<form method="post">
			<input type="password" name="password" id="password" placeholder="password" required="required" /><br />
			<button type="submit">Send...</button>
		</form>
		<section id="draggable">
			<p class="draggable">&#x70;&#x61;&#x72;&#x74;&#x69;&#x63;&#x69;&#x70;&#x61;&#x6e;&#x74;.</p>
			<p class="draggable">&#x65;&#x61;&#x63;&#x68;</p>
			<p class="draggable">&#x6f;&#x66;</p>
			<p class="draggable">&#x6e;&#x61;&#x6d;&#x65;</p>
			<p class="draggable">&#x66;&#x69;&#x72;&#x73;&#x74;</p>
			<p class="draggable">&#x6f;&#x66;</p>
			<p class="draggable">&#x6c;&#x65;&#x74;&#x74;&#x65;&#x72;</p>
			<p class="draggable">&#x46;&#x69;&#x72;&#x73;&#x74;</p>
		</section>
EOF
)

	INLINE_SCRIPT=$(cat <<EOF
		document.addEventListener("DOMContentLoaded", function ()
		{
			var events = new Events();
			// drag and drop
			events.initDandD();
		});
EOF
)

	export HEAD_TEMPLATE BODY_TEMPLATE INLINE_SCRIPT
	html=$(envsubst < 'templates/template.html')

	add_header 'Content-Type' 'text/html; charset=utf-8'
	send_response 200 "$html"
fi
