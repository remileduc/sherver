HTTPS
=====

How to serve over HTTPS, so that someone sniffing the network (typically your wifi) sees an
encrypted stream instead of your requests and pages.

The design makes this almost free: `sherver.sh` `exec`s `socat`, and each `dispatcher.sh` only ever
reads plain text on its stdin and writes plain text on its stdout. TLS is terminated entirely inside
`socat` by switching the listening address from `TCP6-LISTEN` to `OPENSSL-LISTEN` — the dispatcher,
the library and every script are untouched and never see the encryption layer.

What it protects, what it doesn't
---------------------------------

- **It encrypts the transport, nothing more.** A *passive* sniffer on the wifi can no longer read
  your URLs, parameters or pages. It still sees that your device talks to the server's IP, when,
  and roughly how much.
- **Against an *active* attacker, the protection is only as good as the client's certificate
  check.** If you click through the browser warning every time, anyone on the network can sit in
  the middle with their own certificate and you won't notice. Import the certificate on your
  devices (see below) and the warning disappears along with that window.
- **It does not make Sherver safe to expose.** The parser is still naive and anything executable
  under `scripts/` is still an endpoint. **Do not expose Sherver on Internet**, HTTPS or not (see
  [About security](../README.md#about-security)).

Requirements
------------

- `socat` built with OpenSSL — Debian's is. `socat -V | grep OPENSSL` must print
  `#define WITH_OPENSSL 1`.
- the `openssl` command line tool, once, to generate the certificate.

Generate the certificate
------------------------

A self-signed certificate is the right tool here: there is no public CA for a private LAN name,
and you control every client. From the repository root:

```bash
mkdir certs
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
	-keyout certs/key.pem -out certs/cert.pem -days 825 -nodes \
	-subj '/CN=sherver.lan' \
	-addext 'subjectAltName=DNS:sherver.lan,IP:192.168.1.10'
chmod 600 certs/key.pem
```

Adapt two things:

- **`subjectAltName` must list every name and IP you will type in the URL bar** (`https://192.168.1.10:8080`
  needs the `IP:` entry). Browsers only look at the SAN; the `CN` is decoration nowadays.
- the IP and hostname of your server, obviously.

Why these options:

- `-newkey ec ... prime256v1`: an EC P-256 key — the current default choice, smaller and faster
  than RSA. `-nodes` leaves the key unencrypted, since no one will be there to type a passphrase
  when the service starts.
- `-days 3650` a renewal cadence that is fine if you rather not think about it for a decade.
- OpenSSL 3 marks a self-signed certificate `CA:TRUE` on its own, which is what lets Android
  import it as a trusted authority.

Two placement rules:

- the `certs/` folder lives at the repository root, **not** under `file/` or `scripts/` — those two
  are the served directories, everything else is unreachable through HTTP by construction.
- it is in `.gitignore`; the private key never gets committed.

Enable it in sherver.sh
-----------------------

The listening address is one line in the `socat_options` array of [sherver.sh](../sherver.sh).
Comment the `TCP6-LISTEN` line and uncomment the three `OPENSSL-*` ones:

```bash
#socat_options+=("TCP6-LISTEN:${1:-8080}" 'ipv6only=0')
socat_options+=("OPENSSL-LISTEN:${1:-8080}" 'pf=ip6' 'ipv6only=0')
socat_options+=("cert=$PWD/certs/cert.pem" "key=$PWD/certs/key.pem")
socat_options+=('verify=0' 'min-proto-version=TLS1.3')
```

What each option does:

- `pf=ip6` + `ipv6only=0` recreate what `TCP6-LISTEN` implied: one dual-stack socket answering
  IPv4 and IPv6. Replace both with `pf=ip4` for an IPv4-only listener. `max-children`, `backlog`,
  `reuseaddr`, `fork` and `end-close` are unchanged — they apply to the underlying TCP listener.
- `verify=0` is **required**: socat's TLS listener demands a *client* certificate by default and
  drops browsers that don't present one. Leaving verification on is the mutual TLS setup below.
- `min-proto-version=TLS1.3` refuses SSLv3 and TLS 1.0/1.1/1.2 outright. It also refuses anything
  older than Android 10, iOS 12.2 or OpenSSL 1.1.1 — drop to `TLS1.2` if such a client must connect.
  The option needs socat 1.7.4 or later.

Restart, and the same port now talks HTTPS — plain `http://` requests to it will fail, there is no
redirect (socat is one listener, not a web server).

Nothing changes for [the service](../systemd/sherver.service) but the ownership of the key: it sits
in the checkout, which `ProtectHome=read-only` still allows reading, yet `chmod 600` means a
certificate generated as root is unreadable by `User=sherver`. Then socat dies at startup on
`SSL_CTX_use_certificate_file()` and `Restart=always` loops on it, so `chown -R sherver:sherver certs`
after generating.

The test suite follows the configured mode on its own: `tests/server.bats` — the only suite that
opens a port — reads the listening line from `sherver.sh` and talks TLS to it when the
`OPENSSL-LISTEN` one is active (with `curl -k`: the certificate's names don't have to include
`localhost`). The other suites drive the dispatcher directly and never see the socket.

Test it:

```bash
curl --cacert certs/cert.pem --resolve sherver.lan:8080:127.0.0.1 https://sherver.lan:8080/
openssl s_client -connect localhost:8080 -brief < /dev/null
```

The first must print the index page with no `-k`/`--insecure` in sight — if it only works with
`-k`, the certificate does not match the name and a MITM would not be noticed either. The second
prints the negotiated protocol and cipher.

Trust the certificate on your clients
-------------------------------------

This is the step that actually delivers the security: a client that *verifies* the certificate is
what turns "encrypted" into "encrypted with the right server". Get `certs/cert.pem` onto each
device (it is public, mail it to yourself) and import it:

- **Firefox**: Settings → Privacy & Security → Certificates → View Certificates → Authorities →
  Import. Or just visit the site once and add a permanent exception — same effect, per name.
- **Chrome / anything using the OS store on Linux**: `sudo cp certs/cert.pem
  /usr/local/share/ca-certificates/sherver.crt && sudo update-ca-certificates` (Debian family).
- **Android**: Settings → Security → More → Install certificate → CA certificate.
- **iOS / macOS**: open the file, then mark the profile trusted in the settings.

The one thing *not* to do is get used to clicking through the warning: that habit is precisely the
active-MITM hole described at the top.

When the certificate expires, generate a new one the same way and re-import it everywhere — with
3650 days validity that is a once-a-decade chore.

Going further: mutual TLS
-------------------------

For a server whose scripts run privileged things, you can invert the logic: require a *client*
certificate, so a device without one cannot even open a connection, let alone reach an endpoint.
Generate a second certificate/key pair per the same recipe, install it on your devices, and replace
the `verify=0` line — socat ignores `cafile` as long as verification is off, so leaving it in gives
a listener that never asks for a client certificate:

```bash
#socat_options+=('verify=0' 'min-proto-version=TLS1.3')
socat_options+=("cafile=$PWD/certs/clients.pem" 'min-proto-version=TLS1.3')
```

where `clients.pem` is the concatenation of the client certificates you accept. Browsers will
prompt which identity to present. This is the strongest option socat offers here, at the cost of
importing a key (not just a certificate) on every device.
