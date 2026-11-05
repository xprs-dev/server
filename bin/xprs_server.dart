/*
 * xprs-server: the XPRS server edition.
 *
 *   xprs-server [--http-port 80] [--rns-port 4242] [--hub host:port ...]
 *               [--page web/chat_page.html]
 *
 * The core keeps its files under $HOME/.local/share/xprs (storage_paths.dart),
 * so the server runs with HOME set to its own data directory (the systemd
 * unit does this): its identity and archive never mix with an operator's
 * phone or desktop profile on the same machine.
 */
import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:xprs_core/src/services/log_service.dart';
import 'package:xprs_server/http/web_chat_server.dart';
import 'package:xprs_server/station.dart';

/// A station runs unattended: an error nobody awaited is logged, not fatal.
/// A failure before the station is up still ends the process (exit 1), so a
/// supervisor sees it and restarts.
bool _up = false;

Future<void> main(List<String> argv) async {
  await runZonedGuarded(() => _main(argv), (e, st) {
    LogService.instance.add('server: uncaught $e');
    stderr.writeln(st);
    if (!_up) exit(1);
  });
}

Future<void> _main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('http-port', defaultsTo: '80', help: 'web chat port')
    ..addOption('http-address', defaultsTo: '0.0.0.0')
    ..addOption('rns-port', defaultsTo: '4242', help: 'Reticulum TCP port')
    ..addMultiOption('hub', help: 'uplink host:port (default: the core list)')
    ..addOption('page', help: 'the built web chat page')
    ..addOption('nickname', defaultsTo: 'XPRS server')
    ..addFlag('help', abbr: 'h', negatable: false);
  final args = parser.parse(argv);
  if (args['help'] as bool) {
    stdout.writeln(parser.usage);
    return;
  }

  LogService.instance.onLine = (l) => stdout.writeln(l);

  final home = Platform.environment['HOME'] ?? '.';
  final page = File(args['page'] as String? ?? _defaultPage());
  if (!page.existsSync()) {
    stderr.writeln('web chat page not found: ${page.path} '
        '(build it with tool/sync_web_chat.sh, or pass --page)');
    exit(2);
  }

  final hubs = args['hub'] as List<String>;
  final station = Station(StationConfig(
    settingsPath: '$home/.local/share/xprs/server_settings.json',
    rnsPort: int.parse(args['rns-port'] as String),
    hubs: hubs.isEmpty ? null : hubs,
    nickname: args['nickname'] as String,
  ));
  await station.start();

  final web = WebChatServer(
      api: station.webChatApi(), page: await page.readAsBytes());
  await web.start(
      port: int.parse(args['http-port'] as String),
      address: args['http-address'] as String);

  LogService.instance.add('server: ${station.callsign} web chat ready');
  _up = true;
  unawaited(station.startNetwork());

  final done = Completer<void>();
  for (final sig in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    sig.watch().listen((_) {
      if (!done.isCompleted) done.complete();
    });
  }
  await done.future;
  LogService.instance.add('server: stopping');
  await web.stop();
  await station.stop();
  exit(0);
}

/// web/chat_page.html next to the executable, else in the source tree.
String _defaultPage() {
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  for (final p in [
    '$exeDir/web/chat_page.html',
    '$exeDir/../share/xprs-server/chat_page.html',
    'web/chat_page.html',
  ]) {
    if (File(p).existsSync()) return p;
  }
  return 'web/chat_page.html';
}
