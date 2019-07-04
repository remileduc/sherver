#!/bin/bash

set -efu

init_environment

if [ "$REQUEST_METHOD" = 'POST' ]; then
	add_header 'Content-Type' 'text/plain'
	send_response 200 "You just sent me '$REQUEST_BODY'!
	How kind of you <3"
elif [ "$REQUEST_METHOD" != 'GET' ]; then
	send_error 405
fi

all_params=''
for key in "${!URL_PARAMETERS[@]}"; do
	all_params=$"$all_params$key: ${URL_PARAMETERS[$key]}
"
done

HEAD_TEMPLATE=$(cat <<EOF
	<title>Sherver example</title>
	<meta name="description" content="Sherver example">
EOF
)

HEADER_TEMPLATE='<h1>Sherver example</h1>'

BODY_TEMPLATE=$(cat <<EOF
	<section>
		<h2>Link to awesome page</h2>
		<ul>
			<li><a href="/page.sh?page=page.html">awesome page via script</a></li>
			<li><a href="/file/pages/page.html">awesome page via direct access to file</a></li>
		</ul>
	</section>

	<section>
		<h2>Script parameters</h2>
		Requested URL (try with <a href="/index.sh?test=youpi&answer=42"><code>index.sh?test=youpi&answer=42</code></a>):
		<pre>
	REQUESTED URL:
$REQUEST_URL
	BASE URL:
$URL_BASE
	PARAMETERS:
$all_params
	FULL REQUEST:
$REQUEST_FULL_STRING
		</pre>
	</section>

	<section>
		<h2>POST request</h2>
		<p>Fill the input below and click on the <em>"Send"</em> button, and check the result!</p>
		<input type="text" placeholder="Enter something" name="post-input" />
		<input type="submit" value="Send POST request" name="post-button" />
		<pre name="post-pre">
		</pre>
	</section>

	<section>
		<h2>Image example</h2>
		<p>Below you can find an example image that is automatically streamed by <em>Sherver</em>. Click to see full size.</p>
		<figure>
			<a href="/file/venise.webp"><img src="/file/venise.webp" alt="" style="width:40%"></a>
			<figcaption>Venise, Italy. CC-BY</figcaption>
		</figure> 
	</section>
EOF
)

FOOTER_TEMPLATE=''

INLINE_SCRIPT=$(cat <<EOF
	document.addEventListener("DOMContentLoaded", function() {
		var textInput = document.querySelector("[name='post-button']");
		textInput.addEventListener("click", function() {
			fetch("/", {
				method: "POST",
				headers: { "Content-Type": "text/plain" },
				body: document.querySelector("[name='post-input']").value
			}).then(function(response) {
				return response.text()
			}).then(function(contents) {
				document.querySelector("[name='post-pre']").textContent = contents;
			})
		});
	});
EOF
)

export HEAD_TEMPLATE HEADER_TEMPLATE BODY_TEMPLATE FOOTER_TEMPLATE INLINE_SCRIPT

html=$(envsubst < 'templates/template.html')

add_header 'Content-Type' 'text/html; charset=utf-8'
send_response 200 "$html"
