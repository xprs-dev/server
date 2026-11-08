/*
 * xprs-server: the XPRS server edition.
 *
 *   xprs-server [command] [options]       (xprs-server --help)
 *
 * Commands: run (default), init-config, print-config, install-service,
 * uninstall-service, service-status, update. Options come from the command line, a
 * YAML config file and built-in defaults, in that order (lib/config).
 *
 * The core keeps its files under $HOME/.local/share/xprs (storage_paths.dart),
 * so the server runs with HOME set to its own data directory (the service
 * unit does this, or `data_dir` / --data-dir makes the server restart itself
 * that way): its identity and archive never mix with an operator's phone or
 * desktop profile on the same machine.
 */
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:xprs_core/src/services/log_service.dart';
import 'package:xprs_core/src/services/xprs/xprs_publisher.dart';
import 'package:xprs_server/autostart/autostart.dart';
import 'package:xprs_server/cli/cli.dart';
import 'package:xprs_server/config/server_config.dart';
import 'package:xprs_server/http/web_chat_server.dart';
import 'package:xprs_core/src/connections/internet/public_name/public_name.dart';
import 'package:xprs_server/autostart/systemd.dart';
import 'package:xprs_server/station.dart';
import 'package:xprs_server/update/updater.dart';
import 'package:xprs_server/version.dart';
import 'package:xprs_server/web/embedded_page.dart';

/// A station runs unattended: an error nobody awaited is logged, not fatal.
/// A failure before the station is up still ends the process (exit 1), so a
/// supervisor sees it and restarts.
bool _up = false;

/// Set in the child when the server re-launched itself with a new HOME.
const _childMark = 'XPRS_SERVER_CHILD';

Future<void> main(List<String> argv) async {
  await runZonedGuarded(
    () async {
      // Mistakes by the person at the keyboard get a one-line message, not a
      // stack trace; only a real bug reaches the zone handler below.
      try {
        await _main(argv);
      } on ConfigException catch (e) {
        stderr.writeln('xprs-server: $e');
        exit(2);
      } on ServiceException catch (e) {
        stderr.writeln('xprs-server: $e');
        exit(1);
      } on UpdateException catch (e) {
        stderr.writeln('xprs-server: $e');
        exit(1);
      }
    },
    (e, st) {
      LogService.instance.add('server: uncaught $e');
      stderr.writeln(st);
      if (!_up) exit(1);
    },
  );
}

Future<void> _main(List<String> argv) async {
  final Invocation inv;
  try {
    inv = parseInvocation(argv);
  } on FormatException catch (e) {
    stderr.writeln('xprs-server: ${e.message}\n\n${usage()}');
    exit(2);
  }
  if (inv.help) {
    stdout.writeln(usage());
    return;
  }
  if (inv.version) {
    stdout.writeln('xprs-server $kServerVersion');
    return;
  }

  switch (inv.command) {
    case 'init-config':
      return _initConfig(inv);
    case 'install-service':
    case 'uninstall-service':
    case 'service-status':
      return _service(inv);
  }

  final configPath = findConfigFile(explicit: inv.configPath);
  final config = ServerConfig.resolve(
    file: configPath == null ? const {} : loadConfigFile(configPath),
    fileName: configPath ?? 'config file',
    cli: inv.overrides,
  );
  if (inv.command == 'print-config') {
    stdout.writeln(
      configPath == null
          ? 'config file: none found (searched ${configSearchPaths().join(', ')})'
          : 'config file: $configPath',
    );
    stdout.writeln(config.describe());
    return;
  }
  if (inv.command == 'update') return _update(inv, config);
  await _run(config, argv, configPath);
}

Future<void> _run(
  ServerConfig config,
  List<String> argv,
  String? configPath,
) async {
  // The core reads HOME once. If data_dir names another one, start again as a
  // child with it (once; the mark stops a loop), passing the resolved config
  // path because HOME also moves the config search.
  final dataDir = config.dataDir;
  if (dataDir != null &&
      dataDir != Platform.environment['HOME'] &&
      Platform.environment[_childMark] == null) {
    await Directory(dataDir).create(recursive: true);
    exit(await _relaunch(dataDir, argv, configPath));
  }

  final log = config.logFile == null
      ? null
      : File(config.logFile!).openWrite(mode: FileMode.append);
  LogService.instance.onLine = (l) {
    stdout.writeln(l);
    log?.writeln(l);
  };

  final home = Platform.environment['HOME'] ?? '.';
  // The one web chat page, from the webchat repo, compiled into the program
  // (tool/sync_web_chat.sh). There is no option to serve another: every
  // station serves the same page (test/web_page_test.dart).
  final Uint8List pageBytes = embeddedPage();

  final station = Station(
    StationConfig(
      settingsPath: '$home/.local/share/xprs/server_settings.json',
      rnsPort: config.rnsPort,
      hubs: config.hubs.isEmpty ? null : config.hubs,
      nickname: config.nickname,
      publicArchiver: config.publicArchiver,
    ),
  );
  await station.start();

  final api = station.webChatApi();
  final web = WebChatServer(api: api, page: pageBytes);
  var address = config.httpAddress;
  try {
    await web.start(port: config.httpPort, address: address);
  } on SocketException catch (e) {
    // "::" on a machine with IPv6 switched off: IPv4 only.
    if (address != '::') rethrow;
    LogService.instance.add('web chat: no IPv6 ($e); IPv4 only');
    address = '0.0.0.0';
    await web.start(port: config.httpPort, address: address);
  }

  LogService.instance.add(
      'server: $kServerVersion, ${station.callsign} web chat ready');
  _up = true;
  unawaited(station.startNetwork());

  PublicName? publicName;
  if (config.publicName) {
    publicName = PublicName(
      options: PublicNameOptions(
        dir: '$home/.local/share/xprs/tls',
        httpPort: config.httpPort,
        httpsPort: config.httpsPort,
        address: address,
        upnp: config.upnp,
        staging: config.acmeStaging,
        email: config.acmeEmail,
      ),
      http: web,
      newServer: () => WebChatServer(api: api, page: pageBytes),
      log: LogService.instance.add,
      // The address goes in the station's signed decoration (XPRS.md 6.3.2
      // url:), so apps find the web chat by callsign. https:// whenever the
      // internet reaches port 443, http:// only when it reaches just 80.
      onUrl: XprsPublisher.instance.setPublicUrl,
    );
    await publicName.start();
    final pn = publicName;
    station.alsoLocal = (peer) {
      final v4 = pn.publicIPv4;
      return v4 != null && peer.replaceFirst('::ffff:', '') == v4;
    };
  }

  final done = Completer<void>();
  for (final sig in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    sig.watch().listen((_) {
      if (!done.isCompleted) done.complete();
    });
  }
  await done.future;
  LogService.instance.add('server: stopping');
  await publicName?.stop();
  await web.stop();
  await station.stop();
  await log?.close();
  exit(0);
}

/// Runs this same program again with HOME=[home]; returns its exit code.
Future<int> _relaunch(
  String home,
  List<String> argv,
  String? configPath,
) async {
  final args = [
    ...argv,
    if (configPath != null &&
        !argv.any((a) => a == '--config' || a.startsWith('--config='))) ...[
      '--config',
      File(configPath).absolute.path,
    ],
  ];
  final p = await Process.start(
    Platform.resolvedExecutable,
    args,
    environment: {...Platform.environment, 'HOME': home, _childMark: '1'},
    mode: ProcessStartMode.inheritStdio,
  );
  for (final sig in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    sig.watch().listen((s) => p.kill(s));
  }
  return p.exitCode;
}

/// `xprs-server update [--dry-run]`: the timer's job, also runnable by hand.
/// The channel and repository come from the config (auto_update, update_repo).
Future<void> _update(Invocation inv, ServerConfig config) async {
  final channel = UpdateChannel.parse(config.autoUpdate)!;
  if (channel == UpdateChannel.off) {
    stdout.writeln('auto_update is off; nothing to do');
    return;
  }
  final exe = Platform.resolvedExecutable;
  if (SystemdBackend.isDartVm(exe)) {
    throw UpdateException(
        'this is the Dart VM, not the compiled server; nothing to update');
  }
  final updater = Updater(
    channel: channel,
    current: kServerVersion,
    exePath: exe,
    repo: config.updateRepo,
    log: stdout.writeln,
  );
  try {
    final check = await updater.check();
    stdout.writeln('${check.describe(updater.arch)} (${channel.name} channel)');
    if (!check.newer) return;
    if (inv.dryRun) {
      stdout.writeln('[dry run] would install ${check.release!.version} over $exe');
      return;
    }
    final backend = AutostartBackend.forPlatform();
    final scope = await backend.installedScope(exe);
    final ok = await updater.apply(
      check,
      restart: scope == null ? null : () => backend.restart(scope),
      healthy: scope == null ? null : () => backend.isActive(scope),
    );
    if (ok && scope == null) {
      stdout.writeln('no service runs $exe: restart the server yourself');
    }
  } finally {
    updater.close();
  }
}

Future<void> _initConfig(Invocation inv) async {
  final target = inv.configPath ?? configSearchPaths().first;
  final f = File(target);
  if (f.existsSync() && !inv.force) {
    throw ConfigException('$target exists; use --force to overwrite it');
  }
  if (inv.dryRun) {
    stdout.writeln('[dry run] would write $target');
    return;
  }
  await f.parent.create(recursive: true);
  await f.writeAsString(defaultConfigYaml());
  stdout.writeln('wrote $target');
}

Future<void> _service(Invocation inv) async {
  final backend = AutostartBackend.forPlatform();
  final scope = inv.scope ?? ServiceScope.system;
  if (inv.command == 'service-status') {
    exit(await backend.status(scope));
  }
  final installing = inv.command == 'install-service';
  final opts = ServiceOptions(
    scope: scope,
    exePath: Platform.resolvedExecutable,
    configPath: inv.configPath,
    dryRun: inv.dryRun,
  );
  final steps = installing
      ? await backend.installSteps(opts)
      : await backend.uninstallSteps(opts);
  await runSteps(steps, dryRun: inv.dryRun);
  if (!inv.dryRun) {
    stdout.writeln(
      installing ? 'installed (${backend.name}, ${scope.name}).' : 'removed.',
    );
    for (final n in backend.notes(scope, installing: installing)) {
      stdout.writeln(n);
    }
  }
}
