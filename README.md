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
| **Web chat** | serves the page from [portal](https://github.com/xprs-dev/portal) on HTTP (port 80 by default) with the core's `WebChatApi`: a browser that reaches the server chats with no install. The browser holds the key and signs; the server never sees it |

It has its own identity, an `X3` (fixed station) callsign made on first run,
never the operator's phone profile. No wapps, no BLE yet (`../xprs/docs/plan-server.md`
has the phases).

## Install

The whole setup, with the home router and the name under xprs.dev, step by
step: **https://xprs.dev/server**.


Download `xprs-server` from the [releases](https://github.com/xprs-dev/server/releases),
make it executable, and start it at boot:

```sh
chmod +x xprs-server
sudo ./xprs-server install-service        # system service, web chat on port 80
```

That is the whole install: the program carries its web page and its
database engine (zx, pure Dart) inside itself, so there is nothing else to
download and no library to install.

**Update:** it happens by itself. The installer adds a timer that runs
`xprs-server update` every six hours: when a newer release is on GitHub,
the binary for this machine is downloaded, its `.sha256` checked, installed
in place and the service restarted; if the new program does not stay up,
the old one comes back and the failed binary is kept as `xprs-server.failed`.
`auto_update` in the config picks `stable` (releases marked latest, the
default), `beta` (every release) or `off`, and the administrator can switch
automatic updates off from the page (Administration, Updates). By hand at
any time:

```sh
xprs-server --version
sudo xprs-server update --dry-run     # what is on GitHub, change nothing
sudo xprs-server update               # install it now (--force: even when switched off in Administration)
```

Downloading a release and running `sudo ./xprs-server install-service`
again still works and keeps your config file and data.

To just try it without installing:

```sh
./xprs-server --data-dir ~/xprs-data --http-port 8080
```

## A name of its own: `<callsign>.xprs.dev`

Every station can have a name that does not change with its address. The
station asks the names keeper (`names_keeper`, default
`https://names.xprs.dev`) with a signed claim; its callsign is derived from
its key, so the claim alone proves the right to the label and nobody
registers anything (XPRS.md 13.0.3). The name is tested from outside, gets
its certificate and becomes the station's published link. A label stays
with its first key for six months after that key's last claim.

One server keeps the zone for everybody: `names_zone` and `names_token`
(a deSEC token) in its config make it the keeper, reachable at
`names.<zone>`. Records live in a zxdb store under its data directory. An
operator frees a label whose key was lost with:

```sh
sudo xprs-server names-release X3ABCD
```

## A Reticulum node

Every server is a Reticulum transport node on TCP 4242 (`rns_port`), IPv4 and
IPv6 on one socket, and the same port speaks XPRS as text (XPRS.md 13.4). The
server asks the router for 4242 with its web ports; the names keeper pings it
from outside with each claim, and once the ping comes back the server
announces itself as `dial:<callsign>.xprs.dev` so other stations and phones
can connect to it. A stock Reticulum client uses it as a `TCPClientInterface`
with `target_host = x3abcd.xprs.dev` and `target_port = 4242`.

## Build from source

Checked out next to `core`, `reticulum-dart` and `portal`:

```sh
dart pub get
dart compile exe bin/xprs_server.dart -o build/xprs-server
```

The web chat page is built into the program from `lib/web/embedded_page.dart`
(committed). After the page changes in `portal`, run `tool/sync_web_chat.sh`
to rebuild `web/chat_page.html` and that file.

## Run

The core keeps its tree under `$HOME/.local/share/xprs`, so the server needs
its own HOME. `--data-dir` (or `data_dir` in the config file) makes the server
restart itself with that HOME; the service does the same through its unit. The
same machine's desktop app then keeps its own profile. The log goes to stdout,
and also to `log_file` if set.

Port 80 without root: use the system service (it has `AmbientCapabilities`),
or `sudo setcap cap_net_bind_service=+ep xprs-server`.

## Options and the config file

Every option can be a flag or a line in a YAML file. Precedence: **flag >
config file > built-in default**.

| Config key | Flag | Default | |
|---|---|---|---|
| `http_port` | `--http-port` | 80 | web chat port |
| `http_address` | `--http-address` | 0.0.0.0 | `127.0.0.1` for this machine only |
| `rns_port` | `--rns-port` | 4242 | Reticulum TCP port |
| `hubs` | `--hub host[:port]` (repeat) | the core's list | uplinks |
| `nickname` | `--nickname` | XPRS server | name given to a new identity |
| `public_archiver` | `--[no-]public-archiver` | on | keep public history for others |
| `data_dir` | `--data-dir` | HOME as it is | identity, archive, settings |
| `log_file` | `--log-file` | stdout only | also append the log here |

The file is found in this order: `--config PATH`, `$XPRS_SERVER_CONFIG`,
`$XDG_CONFIG_HOME` or `~/.config/xprs-server/config.yaml`,
`/etc/xprs-server/config.yaml`. No file is fine. An unknown key or a bad value
stops the server with a clear message (exit 2).

```sh
xprs-server init-config        # write a commented starting file
xprs-server print-config       # every option in effect, and where it came from
```

## Start at boot

```sh
sudo ./xprs-server install-service         # system: port 80, user xprs, sandboxed
./xprs-server install-service --user       # this user only: port 8080, no root
xprs-server install-service --dry-run       # show what would change, do nothing
xprs-server service-status [--user]
xprs-server uninstall-service [--user]      # keeps your config and data
xprs-server update [--dry-run]              # install a newer release now
```

| System | Status |
|---|---|
| Linux with systemd | done. `--system`: unit in `/etc/systemd/system`, binary in `/opt/xprs-server`, config `/etc/xprs-server/config.yaml`, data `/var/lib/xprs-server`. `--user`: unit in `~/.config/systemd/user`, runs the binary in place; run `loginctl enable-linger $USER` to start at boot without logging in |
| Linux without systemd | prints how to run it from your init system |
| macOS (launchd), Windows | not yet; the same `install-service` command will do it. Prints the manual steps meanwhile |

Installing again updates the binary and restarts the service; your config file
is never overwritten. Newer releases install themselves (see Update above). After editing the config: `systemctl restart xprs-server`
(`systemctl --user restart ...` for a user service).

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
