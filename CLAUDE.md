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
3. **The page comes from `../webchat`.** `web/chat_page.html` is built by
   `tool/sync_web_chat.sh`, never hand-edited.
4. **Its own identity.** The server runs with HOME set to its data directory
   and makes an `X3` station callsign; it never runs under an operator profile.
5. **Compiles are capped at 2 GB** on the development laptop:
   `systemd-run --user --scope -p MemoryMax=2G dart compile exe ...`.

## Before committing

```sh
dart analyze && dart test
cd ../xprs && dart tool/arch_guard.dart     # when the core changed
```

## Reusable code

Keep `docs/reusable.md` current.
