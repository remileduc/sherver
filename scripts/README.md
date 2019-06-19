<!-- Documentation partly generated with tomdoc.sh: https://github.com/mlafeldt/tomdoc.sh -->

SHERVER_UTILS.sh
================

Documentation of the library SHERVER_UTILS.sh.


`URL_REQUESTED`
---------------

The requested URL


`URL_BASE`
----------

The base URL, without the query string if any


`URL_PARAMETERS`
----------------

The parameters of the query string if any (in an associative array)

See `parse_url()`.


`REQUEST_HEADERS`
----------------

The headers from the request


`RESPONSE_HEADERS`
------------------

The response headers (in an array)


`HTTP_RESPONSE`
---------------

Generic HTTP response code with their meaning.


`log()`
-------

Log any messages in the error outut of the script (default is console).

Takes as many arguments as needed. they will all be written, separated by newlines.

Examples

```bash
     log "> HTTP/1.0 200 OK
```

will output

     > HTTP/1.0 200 OK


`parse_url()`
-------------

Parse the given URL to exrtact the base URL and the query string.

Takes an optional parameters: the URL to parse. By default, it will take the content of the variable `URL_REQUESTED`.

It will store the base of the URL (without query string) in `URL_BASE`. It will store all the parameters of the query string in the associative array `URL_PARAMETERS`.

* $1 - Optional: URL to parse (default will take content of `URL_REQUESTED`)

Examples

```bash
     parse_url '/index.sh?test=youpi&answer=42'
```

will result in

```bash
     URL_BASE='/index.sh'
     URL_PARAMETERS=(
         ['test']='youpi'
         ['answer']='42'
     )
```


`add_header()`
--------------

Add header for the response.

Takes 2 parameters: header name and header content.

* $1 - header name, one of the HTTP 1.0 standard value
* $2 - value of the header

Examples

```bash
     add_header 'Content-Type' 'text/html; charset=utf-8'
```

will add the following line in the header of the response

     Content-Type: text/html; charset=utf-8


`send_response()`
-----------------

Send the given answer in a HTTP 1.0 format.

Takes the response code as first parameter, then as many parameters as needed to write the answer. They will be sent, separated by newlines.

Note that the headers need to have already been set with `add_header()`.

* $1 - HTTP response code. See `HTTP_RESPONSE`
* $2... - The actual response to send

Examples

```bash
     add_header 'Content-Type' 'text/plain'
     send_response 200 'this is some' 'cool text'
```

will send something like (depends on your default headers, see `RESPONSE_HEADERS`)

```
     HTTP/1.0 200 OK
     Content-Type: text/plain

     this is some
     cool text
 ```


`send_error()`
--------------

Send the given error as an answer.

Takes one parameter: the error code. It will be sent as an answer, along with a very small HTML explaining what is the error.

* $1 - the error code, see `HTTP_RESPONSE`

Examples

```bash
     send_errors 404
```

will create an answer that starts with

     HTTP/1.0 404 Not Found


`send_file()`
-------------

Try to send the given file, or fail with 404.

Takes the path to the file to send as a parameter.

It will automatically create a valid HTTP response that will stream the content of the file, with the correct mime type and all. If the file doesn't exist, send a 404 error.

The path generally comes from the URL (`URL_BASE`). You just need to remove the first `/` to get a relative path.

*Note* that to find the correct mimetypem we use `mimetype` command which is shipped by default in Debian. You can change it to use `file` command instead, but it doesn't work as well...

* $1 - the path to the file to send

Examples

```bash
     parse_url '/file/beautiful.png?dummy=stuff'
     send_file "${URL_BASE:1}"
```

if the file exist, will send a response that starts with (assuming file size is 4 kio)

     HTTP/1.0 200 OK
     Content-Type: image/png
     Content-Length: 4096


`run_script()`
--------------

Try to run the given file (script or executable), or fail with 404.

**Note:** this method is usded by the dispatcher and shouldn't be called manually.

Takes the path to the file to run. The file can be a script in any language, or an executable. But it must have the `x` flag so we can run it.

It will simply run the script if possible. If not, send a 404. If the script fails, send a 500.

It is the script responsibility to send the response and everything...

*Note* that the file is supposed to be in the subfolder `scripts/`. The file will be run inside this folder (we `cd` before running it).

* $1 - the path to the file to run (relative to subfolder `scripts/`)

Examples

```bash
     run_script '/index.sh?dummy=stuff'
```

will do the following

```bash
     cd scripts
     './index.sh' '/index.sh?dummy=stuff'
```


`read_request()`
----------------

Read the client request and set up environment.

**Note:** this method is usded by the dispatcher and shouldn't be called manually.

Reads the input stream and fills the following variables (also run `parse_url()`):

- `REQUEST_METHOD`
- `REQUEST_HTTP_VERSION`
- `REQUEST_HEADERS`
- `URL_REQUESTED`
- `URL_BASE`
- `URL_PARAMETERS`

*Note* that this method is highly inspired by [bashttpd](https://github.com/avleen/bashttpd)


