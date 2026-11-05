# Reusable code (server)

Read this before writing something new. The bulk of what the server reuses is
the core; `../core/docs/reusable.md` lists it.

| What | Where | Reuse it for |
|---|---|---|
| `FileKeyValueStore` | `lib/host/file_key_value_store.dart` | any host of the core with no shared_preferences: the core's `KeyValueStore` over one JSON file, atomic replace, writes coalesced per event-loop turn, a damaged file kept aside |
| `WebChatServer` | `lib/http/web_chat_server.dart` | serving the webchat page (gzipped once) and `WebChatApi` over `dart:io`. The app's `ShareAppService` has the same socket half plus the APK download; a candidate to move to core as one class both use |
| `Station.webChatApi()` | `lib/station.dart` | wiring `WebChatApi` to the core (archive rows, receive door, publisher). Identical to `ShareAppService._liveApi()` in the app; also a candidate for core |
| `parseHostPort` | `lib/station.dart` | `host[:port]` hub entries, default 4242. Duplicates `_parseHostPort` in the app's `rns_autostart.dart`: move both to core when either changes |
| `LogService.onLine` | core `services/log_service.dart` | a host that prints the log (console, journal) |
| `tool/smoke_send.dart` | | signing an XPRS packet with a throwaway key and posting it as a visitor; the pattern for any API smoke test |
