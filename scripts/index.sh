#!/bin/bash

set -efu

source 'SHERVER_UTILS.sh'

URL="$1"
parse_url "$URL"
all_params=''
for key in "${!URL_PARAMETERS[@]}"; do
	all_params=$"$all_params$key: ${URL_PARAMETERS[$key]}
"
done

html=$(cat <<EOF
<!DOCTYPE html>
<html>

<head>
	<meta charset="utf-8">
	<title>Sherver example</title>
	<meta name="author" content="remileduc">
	<meta name="description" content="Sherver example">
	<link rel="stylesheet" type="text/css" href="/file/resources/ugly.css">
	<link rel="shortcut icon" type="image/png" href="/file/resources/zergian.png"/>
</head>

<body>

<header>
	<h1>Sherver example</h1>
</header>

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
$URL
		BASE URL:
$URL_BASE
		PARAMETERS:
$all_params
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

<footer>
	Example page for Sherver.
</footer>

</body>

</html>
EOF
)

add_header 'Content-Type' 'text/html; charset=utf-8'
send_response 200 "$html"
