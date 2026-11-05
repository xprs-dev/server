# server

The XPRS server edition: a headless XPRS station for Linux, in plain Dart.
One binary, no Flutter, no screen. It runs the same core as the
[app](https://github.com/xprs-dev/app) ([core](https://github.com/xprs-dev/core)),
so its rules for delivery, archiving and bridging are the phone's rules.

What it does:

| | |
|---|---|
| **Reticulum transport node** | accepts Reticulum clients (Sideband, NomadNet, XPRS apps, ESP32 stations) on TCP 4242, keeps uplinks to the public hubs and forwards for everything it can reach. The same port speaks XPRS as text (XPRS.md 24.4) |
| **Bridge for local devices** | the XPRS LAN bearer (UDP 4242) and Reticulum LAN discovery, bridged onto the internet path through the core's one receive door |
| **Public archiver** | keeps public history for others (XPRS.md 12.9.4) |
| **Web chat** | serves the page from [webchat](https://github.com/xprs-dev/webchat) on HTTP (port 80 by default) with the core's `WebChatApi`: a browser that reaches the server chats with no install. The browser holds the key and signs; the server never sees it |

It has its own identity, an `X3` (fixed station) callsign made on first run,
never the operator's phone profile. No wapps, no BLE yet (`../xprs/docs/plan-server.md`
has the phases).

## Build

Checked out next to `core`, `reticulum-dart` and `webchat`:

```sh
dart pub get
tool/sync_web_chat.sh                       # web/chat_page.html from ../webchat
dart compile exe bin/xprs_server.dart -o build/xprs-server
```

Needs `libsqlite3` at run time (Debian: `libsqlite3-dev` for the unversioned
`libsqlite3.so` the `sqlite3` package loads).

## Run

```sh
mkdir -p build/web && cp web/chat_page.html build/web/
HOME=/var/lib/xprs-server build/xprs-server --http-port 80
```

The core keeps its tree under `$HOME/.local/share/xprs`, so **set HOME to the
server's own data directory**; the same machine's desktop app then keeps its
own profile. Options: `--http-port`, `--http-address`, `--rns-port`,
`--hub host:port` (repeatable; default the core's hub list), `--page`,
`--nickname`. The log goes to stdout.

Port 80 without root: `sudo setcap cap_net_bind_service=+ep build/xprs-server`,
or the systemd unit's `AmbientCapabilities`.

As a service: `sudo deploy/install.sh` installs `/opt/xprs-server`, a system
user `xprs`, and `deploy/xprs-server.service` (data in `/var/lib/xprs-server`,
port 80, sandboxed).

On a public address, put TLS in front (Caddy, nginx); the server trusts
`X-Forwarded-For` only from loopback.

## Check it

```sh
curl http://127.0.0.1/api/services
dart run tool/smoke_send.dart http://127.0.0.1:80   # sign, post, read back
dart test
```

## License

BSD-3-Clause, copyright Max Brito and XPRS contributors. See [LICENSE](LICENSE).
