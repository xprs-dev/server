# Working in server

The XPRS server edition. It is a HOST of the core, like the app: it wires
`CoreHost` and starts core services; it does not implement protocol.

## Rules

1. **No XPRS logic here.** Delivery, admission, bridging, archiving, lanes and
   the web chat's rules are in `../core` (`../core/CLAUDE.md`). If the server
   needs different behaviour, add it to the core behind a setting or a seam
   the app can use too. `lib/station.dart` only wires and starts.
2. **The visitor API is the core's.** `lib/http/web_chat_server.dart` is the
   socket half of `WebChatApi`; it mirrors the app's share server and must not
   grow rules of its own.
3. **The page comes from `../webchat`.** `web/chat_page.html` and
   `lib/web/embedded_page.dart` (the page compiled into the binary) are built
   by `tool/sync_web_chat.sh`, never hand-edited. Users get ONE file, the
   binary: nothing the server needs at run time may live beside it.
4. **Its own identity.** The server runs with HOME set to its data directory
   and makes an `X3` station callsign; it never runs under an operator profile.
5. **Compiles are capped at 2 GB** on the development laptop:
   `systemd-run --user --scope -p MemoryMax=2G dart compile exe ...`.

## The web chat page is one page

The page is developed only in `webchat` (`page/chat_page.html`, built by
`tool/build.py`) and every station serves the identical build: the firmware
(`common/xprs_hotspot/chat_page.c`, `build.py --c`), the server
(`web/chat_page.html` and `lib/web/embedded_page.dart`, `tool/sync_web_chat.sh`)
and the app (`assets/web_chat/chat_page.html`). Never edit a copy. After a
webchat change, regenerate every copy in the same change and check they match.

The only part that differs per implementation is the API engine behind the
page (`/api/...`). Keep it generic and XPRS-compliant: what a station can or
cannot do reaches the page as data (`/api/services`: `page.tabs`, features),
never as a different page or a feature placed somewhere else on one kind of
station. Feature logic belongs in the page's JavaScript.

## Options and boot

An option is added in ONE place: `ServerConfig` (`lib/config/server_config.dart`:
key, default, validation, `describe`, the commented template), its flag in
`lib/cli/cli.dart`, and a test in `test/config_test.dart`. Boot integration
is `lib/autostart/` (one backend per init system); a new OS is a new
`AutostartBackend`, chosen in `forPlatform()`. `install-service` generates
the unit; there is no static unit file to keep in step.

## Before committing

```sh
dart analyze && dart test
cd ../xprs && dart tool/arch_guard.dart     # when the core changed
```

## Reusable code

Keep `docs/reusable.md` current.
