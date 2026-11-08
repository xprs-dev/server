# Reusable code (server)

Read this before writing something new. The bulk of what the server reuses is
the core; `../core/docs/reusable.md` lists it.

| What | Where | Reuse it for |
|---|---|---|
| `FileKeyValueStore` | `lib/host/file_key_value_store.dart` | any host of the core with no shared_preferences: the core's `KeyValueStore` over one JSON file, atomic replace, writes coalesced per event-loop turn, a damaged file kept aside |
| `WebChatServer` | `lib/http/web_chat_server.dart` | serving the webchat page (gzipped once) and `WebChatApi` over `dart:io`, HTTP or HTTPS (`startSecure`); it is the core `PublicName`'s `AcmeWebServer` (ACME challenges, redirect to HTTPS). The app's `ShareAppService` has the same socket half plus the APK download; a candidate to move to core as one class both use |
| `Station.webChatApi()` | `lib/station.dart` | wiring `WebChatApi` to the core (archive rows, receive door, publisher). Identical to `ShareAppService._liveApi()` in the app; also a candidate for core |
| `parseHostPort` | `lib/station.dart` | `host[:port]` hub entries, default 4242. Duplicates `_parseHostPort` in the app's `rns_autostart.dart`: move both to core when either changes |
| `LogService.onLine` | core `services/log_service.dart` | a host that prints the log (console, journal) |
| `tool/smoke_send.dart` | | signing an XPRS packet with a throwaway key and posting it as a visitor; the pattern for any API smoke test |
| `HeartbeatKeepAlive` | core `platform/heartbeat_keep_alive.dart` | the core's heartbeat on a host with no native one; the server and the desktop app both use it (2 s) |
| `ServerConfig` + `loadConfigFile` / `findConfigFile` | `lib/config/server_config.dart` | layered options (default < YAML file < flags) that remember their source, strict on unknown keys. A host with a config file (the desktop app's headless mode, the CLI) can copy the pattern; `defaultConfigYaml` documents every key as comments |
| `parseInvocation` | `lib/cli/cli.dart` | `command [flags]` where only flags actually typed become overrides (`wasParsed`), so defaults never hide the file's values |
| `AutostartBackend` / `ServiceStep` / `runSteps` | `lib/autostart/autostart.dart` | boot integration per OS as dry-runnable steps. Nothing in it is server-specific except names: a candidate for core so the desktop app's "start with the computer" can add launchd and Windows backends to the same interface |
| `SystemdBackend`, `renderUnit` | `lib/autostart/systemd.dart` | a systemd unit (system or user) generated from the binary's own path |
| `tool/embed_page.dart` + `embeddedPage()` | `tool/`, `lib/web/embedded_page.dart` | shipping a data file inside a `dart compile exe` binary (gzip + base64 in a generated const). Any host that must be a single file |
| `tool/public_name_check.dart` | | what the public-name loop sees from a machine (public addresses, nip.io names, the UPnP router), changing nothing |
| `Station.isLocalPeer` | `lib/station.dart` | "is this visitor on our network": private addresses plus the IPv6 /64s the machine holds (read at most once a minute) |
| `Updater` | `lib/update/updater.dart` | a compiled program that follows its GitHub releases: `/releases/latest` (stable) or `/releases` (beta) by channel, the asset for `uname -m`, the `.sha256` beside it, download and digest check, atomic replace through `.new` keeping `.prev`, restart, and rollback when the service is not active afterwards. `XPRS_UPDATE_API` redirects the API host, so a test serves GitHub from a local `HttpServer` (test/update_test.dart). Any single-binary host (the desktop app's headless mode, a future CLI) can reuse it as is |
| `compareSemver` | `lib/update/updater.dart` | the app's `update_models.dart` function, copied: pre-release aware, build metadata ignored. Move to the core when a third host needs it |
| `renderUpdateService` / `renderUpdateTimer` | `lib/autostart/systemd.dart` | a oneshot service plus a timer with boot delay, period, jitter and `Persistent=true`: the shape for any periodic job the installer should set up |
| `tool/update_version.dart` + `lib/version.dart` | | the app's pattern: a generated constant from `pubspec.yaml`, with a test that fails when they differ |
| `ZxNamesStore` | `lib/host/zx_names_store.dart` | the core's `NamesStore` over a zxdb key-value store (one `.zx` file, JSON rows, group commit): the shape for any small keyed table a host keeps for the core without SQLite |
| `_namesRelease` / `_namesReleaseRequests` | `bin/xprs_server.dart` | an operator command that reaches a running service through a request file in the service's own directory, acted on by its tick: the pattern for any local-only administrative act on a sandboxed service |
