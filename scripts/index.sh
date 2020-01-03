#!/bin/bash

set -efu

init_environment

if [ "$REQUEST_METHOD" != 'GET' ] && [ "$REQUEST_METHOD" != 'POST' ]; then
	send_error 405
fi

middle=''

function createForm()
{
	local class=''
	local text=''
	if [ "$1" == true ]; then
		class='incorrect'
		text='WRONG'
	fi
	middle=$(cat <<EOF
		<form method="post">
			<input type="text" name="username" id="username" placeholder="Your Name" value="$2" required="required" autocomplete="username" /><br />
			<input type="password" name="password" id="password" class="$class" placeholder="password" required="required" autocomplete="new-password" autofocus />
			<p class="$class">$text</p>
			<button type="submit">Send...</button>
		</form>
EOF
)
}

if [ "$REQUEST_METHOD" == 'POST' ]; then
	if [ ! -v "REQUEST_BODY_PARAMETERS['password']" ] || [ ! -v "REQUEST_BODY_PARAMETERS['username']" ]; then
		createForm true ""
	else
		username="${REQUEST_BODY_PARAMETERS['username']}"
		password="${REQUEST_BODY_PARAMETERS['password']}"
		password="${password,,}" # to lower
		echo "$(date) - $username : $password" >> '/var/log/sherver.log'
		# Inês
		# Jan
		# Kacper
		# Maria
		# Przemek
		if [ "${#password}" != 5 ] \
				|| [[ "$password" != *i*  ]]  \
				|| [[ "$password" != *j*  ]] \
				|| [[ "$password" != *k*  ]] \
				|| [[ "$password" != *m*  ]] \
				|| [[ "$password" != *p*  ]]; then
			createForm true "$username"
		else
			middle=$(cat <<EOF
			<p class="answer">CESAR looks under his colleagues desks.</p>
			<!-- Cesar code +3 -->
EOF
)
		fi
	fi
else # GET
	createForm false ""
fi

HEAD_TEMPLATE=$(cat <<EOF
	<title>Treasure Hunt</title>
	<meta name="description" content="Treasure Hunt">
	<script src="/file/resources/events.js"></script>
EOF
)

BODY_TEMPLATE=$(cat <<EOF
	<section id="lol">
$middle
	</section>
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
		// drag and drop
		var events = new Events();
		events.initDandD();

		// handle bad input
		var input = document.querySelector("#password");
		if (input !== null)
			input.addEventListener("input", () => { input.classList.remove("incorrect"); });
	});
EOF
)

export HEAD_TEMPLATE BODY_TEMPLATE INLINE_SCRIPT
html=$(envsubst < 'templates/template.html')

add_header 'Content-Type' 'text/html; charset=utf-8'
send_response 200 "$html"
