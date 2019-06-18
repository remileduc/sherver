#!/bin/bash

set -efu

init_environment

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

export HEAD_TEMPLATE HEADER_TEMPLATE BODY_TEMPLATE FOOTER_TEMPLATE

html=$(cat 'templates/template.html' | envsubst)

add_header 'Content-Type' 'text/html; charset=utf-8'
send_response 200 "$html"
