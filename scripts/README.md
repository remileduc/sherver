Documentation partially generated with [tomdoc.sh](https://github.com/mlafeldt/tomdoc.sh).

SHERVER_UTILS.sh
================

Documentation of the library SHERVER_UTILS.sh.

`REQUEST_FULL_STRING`
---------------------

Public: The full request string


`REQUEST_METHOD`
----------------

Public: The method of the request (GET, POST...)

`REQUEST_URL`
-------------

Public: The requested URL

`REQUEST_HEADERS`
-----------------

Public: The headers from the request (associative array)

`REQUEST_BODY`
--------------

Public: Body of the request (mainly useful for POST)

`REQUEST_BODY_PARAMETERS`
-------------------------

Public: parameters of the request, in case of POST with `application/x-www-form-urlencoded` content

`URL_BASE`
----------

Public: The base URL, without the query string if any

`URL_PARAMETERS`
----------------

Public: The parameters of the query string if any (in an associative array)

See `parse_url()`.

`RESPONSE_HEADERS`
------------------

Public: The response headers (associative array)

`HTTP_RESPONSE`
---------------

Public: Generic HTTP response code with their meaning (associative array)

`init_environment()`
--------------------

Public: Initialize the environment.

This function should always be ran at the top of any scripts. Once this function has
run, all the following variables will be available:

* `REQUEST_METHOD`
* `REQUEST_URL`
* `REQUEST_HEADERS`
* `REQUEST_BODY`
* `REQUEST_BODY_PARAMETERS`
* `URL_BASE`
* `URL_PARAMETERS`
* `RESPONSE_HEADERS`
* `HTTP_RESPONSE`
* `REQUEST_FULL_STRING`

To do so, ti will read from the standard input the received request, and execute
`read_request` to initialize everything.

Then, it will export the full request in the environment variable `REQUEST_FULL_STRING`
so it can always be reexecuted.

This echanism also allows non bash script to have access to the request through the
environment.

`log()`
-------

Public: Log any messages in the error outut of the script (default is console).

Takes as many arguments as needed. they will all be written, separated by newlines.

Examples

     log "> HTTP/1.0 200 OK

will output

     > HTTP/1.0 200 OK


`parse_url()`
-------------

Public: Parse the given URL to exrtact the base URL and the query string.

Takes an optional parameters: the URL to parse. By default, it will take the content of the variable `REQUEST_URL`.

It will store the base of the URL (without query string) in `URL_BASE`. It will store all the parameters of the query string in the associative array `URL_PARAMETERS`.

* $1 - Optional: URL to parse (default will take content of `REQUEST_URL`)

Examples

     parse_url '/index.sh?test=youpi&answer=42'

will result in

     URL_BASE='/index.sh'
     URL_PARAMETERS=(
         ['test']='youpi'
         ['answer']='42'
     )


`add_header()`
--------------

Public: Add header for the response.

Takes 2 parameters: header name and header content.

* $1 - header name, one of the HTTP 1.0 standard value
* $2 - value of the header

Examples

     add_header 'Content-Type' 'text/html; charset=utf-8'

will add the following line in the header of the response

     Content-Type: text/html; charset=utf-8


`_send_header()`
----------------

Internal: Write the headers to the standard output.

It will write all the headers defined in `RESPONSE_HEADERS`, see `add_header()`. It also automatically add the date header.

Takes one parameter which is the code of the response.

* $1 - The code of the response, must exist in `HTTP_RESPONSE`

Examples

     _send_header 200

will result in:

     HTTP/1.0 200 OK
     Date: Thu, 04 Jul 2019 21:38:23 GMT
     Server: Sherver
     Cache-Control: private, max-age=60
     Expires: Thu, 04 Jul 2019 21:38:23 GMT


`send_response()`
-----------------

Public: Send the given answer in a HTTP 1.0 format.

Takes the response code as first parameter, then as many parameters as needed to write the answer. They will be sent, separated by newlines.

At the end of the function, we call exit to terminate the process.

Note that the headers need to have already been set with `add_header()`.

* $1 - HTTP response code. See `HTTP_RESPONSE`
* $2... - The actual response to send

Examples

     add_header 'Content-Type' 'text/plain'
     send_response 200 'this is some' 'cool text'

will send something like (depends on your default headers, see `RESPONSE_HEADERS`)

```

     HTTP/1.0 200 OK
     Content-Type: text/plain

     this is some
     cool text
 ```


`send_error()`
--------------

Public: Send the given error as an answer.

Takes one parameter: the error code. It will be sent as an answer, along with a very small HTML explaining what is the error.

* $1 - the error code, see `HTTP_RESPONSE`

Examples

     send_errors 404

will create an answer that starts with

     HTTP/1.0 404 Not Found


`send_file()`
-------------

Public: Try to send the given file, or fail with 404.

Takes the path to the file to send as a parameter.

It will automatically create a valid HTTP response that will stream the content of the file, with the correct mime type and all. If the file doesn't exist, send a 404 error.

The path generally comes from the URL (`URL_BASE`). You just need to remove the first `/` to get a relative path.

*Note* that to find the correct mimetypem we use `mimetype -b` command which is shipped by default in Debian. You can change it to use `file --mime-type -b` command instead, but it doesn't work as well...

* $1 - the path to the file to send

Examples

     parse_url '/file/beautiful.png?dummy=stuff'
     send_file "${URL_BASE:1}"

if the file exist, will send a response that starts with (assuming file size is 4 kio)

     HTTP/1.0 200 OK
     Content-Type: image/png
     Content-Length: 4096


`run_script()`
--------------

Public: Try to run the given file (script or executable), or fail with 404.

**Note:** this method is usded by the dispatcher and shouldn't be called manually.

Takes the path to the file to run. The file can be a script in any language, or an executable. But it must have the `x` flag so we can run it.

It will simply run the script if possible. If not, send a 404. If the script fails, send a 500.

It is the script responsibility to send the response and everything...

*Note* that the file is supposed to be in the subfolder `scripts/`. The file will be run inside this folder (we `cd` before running it).

* $1 - the path to the file to run (relative to subfolder `scripts/`)

Examples

     run_script '/index.sh?dummy=stuff'

will do the following

     cd scripts
     './index.sh' '/index.sh?dummy=stuff'


`read_request()`
----------------

Internal: Read the client request and set up environment.

**Note:** this method is used by the dispatcher and shouldn't be called manually.

Reads the input stream and fills the following variables (also run `parse_url()`):

* `REQUEST_METHOD`
* `REQUEST_HTTP_VERSION`
* `REQUEST_HEADERS`
* `REQUEST_BODY`
* `REQUEST_BODY_PARAMETERS`
* `REQUEST_URL`
* `URL_BASE`
* `URL_PARAMETERS`

*Note* that this method is highly inspired by [bashttpd](https://github.com/avleen/bashttpd)

* $1 - if true, logs will be written (whole header, but not the body)


