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
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:reticulum/reticulum.dart' show NostrCrypto;
import 'package:xprs_core/src/services/log_service.dart';
import 'package:xprs_core/src/services/names/desec_dns_io.dart';
import 'package:xprs_core/src/services/names/names_client_io.dart';
import 'package:xprs_core/src/services/names/names_keeper.dart';
import 'package:xprs_core/src/services/names/xprs_port_probe_io.dart';
import 'package:xprs_core/src/services/preferences_service.dart';
import 'package:xprs_core/src/platform/core_host.dart';
import 'package:xprs_core/src/profile/profile_service.dart';
import 'package:xprs_core/src/profile/storage_paths.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_sig.dart';
import 'package:xprs_core/src/services/web_chat_api.dart';
import 'package:xprs_core/src/services/xprs/xprs_publisher.dart';
import 'package:xprs_server/autostart/autostart.dart';
import 'package:xprs_server/cli/cli.dart';
import 'package:xprs_server/config/server_config.dart';
import 'package:xprs_server/host/file_key_value_store.dart';
import 'package:xprs_server/host/zx_names_store.dart';
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

/// The station's settings file under its HOME (the administrator's settings
/// among them; FileKeyValueStore).
String settingsPathFor(String home) =>
    '$home/.local/share/xprs/server_settings.json';

/// The names keeper's files under its HOME: the record store and the
/// operator's release requests (`names-release`, bin only, never the network).
String namesDirFor(String home) => '$home/.local/share/xprs/names';

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
  if (inv.command == 'names-release') return _namesRelease(inv, config);
  if (inv.command == 'sign') return _sign(config);
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
  // The one web chat page, from the portal repo, compiled into the program
  // (tool/sync_web_chat.sh). There is no option to serve another: every
  // station serves the same page (test/web_page_test.dart).
  final Uint8List pageBytes = embeddedPage();

  final station = Station(
    StationConfig(
      settingsPath: settingsPathFor(home),
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

  // The names keeper (XPRS.md 13.0.3): this server keeps <callsign>.<zone>
  // for every station that proves its key. One server does this.
  NamesKeeper? keeper;
  ZxNamesStore? namesStore;
  DesecDns? desec;
  Timer? namesTimer;
  final zone = config.namesZone, token = config.namesToken;
  if (zone != null && token != null) {
    final npub = station.ownNpub;
    if (npub == null) {
      LogService.instance.add('names: this station has no key yet; keeper off');
    } else {
      namesStore = ZxNamesStore.open('${namesDirFor(home)}/names.zx');
      desec = DesecDns(zone: zone, token: token);
      keeper = NamesKeeper(
        zone: zone,
        store: namesStore,
        dns: desec,
        ownCallsign: station.callsign,
        ownKeyHex: NostrCrypto.decodeNpub(npub).toLowerCase(),
        log: LogService.instance.add,
      );
      api.names = keeper;
      // Every claimant is tested from outside on 13.4's port: a ping that
      // must come back signed by the claimant (xprs_port_probe_io.dart).
      keeper.probePort = (address, call, keyHex) => xprsPortAnswers(
          address, NamesKeeper.rnsPort,
          asker: station.callsign, call: call, keyHex: keyHex);
      final k = keeper;
      namesTimer = Timer.periodic(const Duration(minutes: 1), (_) async {
        await _namesReleaseRequests(k, namesDirFor(home));
        await k.sweep();
      });
      LogService.instance.add(
          'names: keeping $zone (${namesStore.length} names) for other stations');
    }
  }

  PublicName? publicName;
  if (config.publicName) {
    publicName = PublicName(
      options: PublicNameOptions(
        dir: '$home/.local/share/xprs/tls',
        httpPort: config.httpPort,
        // The Reticulum node (XPRS.md 13.4) is asked for with the web ports.
        extraPorts: [config.rnsPort],
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
    final pn = publicName;
    // The page's Station view: where the internet reaches this web chat and
    // which names still wait for the router.
    // The Reticulum node is dialable when the keeper reached it from
    // outside: then its name goes out as `dial:` (13.0.2) on the station's
    // announcements, and comes off again when the port closes.
    bool? rnsOpen;
    DateTime? portAskedAt;
    void setDial(List<String> names, bool? open) {
      rnsOpen = open;
      portAskedAt = DateTime.now();
      final prefs = PreferencesService.instanceSync;
      if (prefs == null || open == null) return;
      final port = config.rnsPort == NamesKeeper.rnsPort ? '' : ':${config.rnsPort}';
      final dial = open && names.isNotEmpty ? '${names.first}$port' : '';
      if (prefs.xprsDial != dial) {
        prefs.xprsDial = dial;
        LogService.instance.add(dial.isEmpty
            ? 'server: not reachable on tcp ${config.rnsPort} from outside; no dial: announced'
            : 'server: Reticulum node reachable at $dial (announced as dial:)');
      }
    }

    api.addresses = () {
      final d = PreferencesService.instanceSync?.xprsDial ?? '';
      return WebAddresses(
        urls: pn.urls,
        pending: pn.pending,
        rnsPort: config.rnsPort,
        rnsOpen: rnsOpen,
        dial: d.isEmpty ? null : d,
      );
    };
    // While the port is not reachable, ask again every half hour, so a
    // router rule made today is noticed today, not at next week's claim.
    pn.askNamesAgain = () =>
        rnsOpen != true &&
        portAskedAt != null &&
        DateTime.now().difference(portAskedAt!) > const Duration(minutes: 30);
    // Its own name: from the keeper it is, or from the keeper it asks.
    if (keeper != null) {
      final k = keeper;
      pn.extraNames = ({v4, v6}) async {
        final names = await k.keepOwn(v4: v4, v6: v6);
        setDial(names, k.ownPortOpen);
        return names;
      };
    } else if (config.namesKeeper.isNotEmpty) {
      final client = NamesClient(
        NamesClientOptions(
          keeper: config.namesKeeper,
          callsign: () => station.callsign,
          npub: () => station.ownNpub ?? '',
          sign: (p) {
            final d = xprsProfileScalar();
            return d == null ? null : xprsSign(p, d);
          },
        ),
        log: LogService.instance.add,
      );
      pn.extraNames = ({v4, v6}) async {
        final names = await client.claim(v4: v4, v6: v6);
        setDial(names, client.portOpen);
        return names;
      };
    }
    await publicName.start();
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
  namesTimer?.cancel();
  namesStore?.close();
  desec?.close();
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
  final home = config.dataDir ?? Platform.environment['HOME'] ?? '.';
  if (!inv.force && !await _adminAllowsUpdates(settingsPathFor(home))) {
    stdout.writeln('automatic updates are switched off in Administration '
        '(xprs-server update --force installs anyway)');
    return;
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

/// `xprs-server names-release X3ABCD`: the operator frees a label whose key
/// was lost. A local command: it leaves a request in the keeper's directory,
/// which the running keeper acts on within a minute (the record store is the
/// keeper's alone). Nothing on the network can do this.
Future<void> _namesRelease(Invocation inv, ServerConfig config) async {
  if (config.namesZone == null) {
    throw ConfigException('this server keeps no names (names_zone is not set)');
  }
  final call = (inv.argument ?? '').trim().toUpperCase().split('-').first;
  if (!RegExp(r'^X[1-5][0-9A-Z]{2,5}$').hasMatch(call)) {
    throw ConfigException("'${inv.argument}' is not a callsign");
  }
  final home = config.dataDir ?? Platform.environment['HOME'] ?? '.';
  final f = File('${namesDirFor(home)}/release.txt');
  if (inv.dryRun) {
    stdout.writeln('[dry run] would ask the keeper to free ${call.toLowerCase()}.${config.namesZone}');
    return;
  }
  try {
    await f.parent.create(recursive: true);
    await f.writeAsString('$call\n', mode: FileMode.append, flush: true);
  } on FileSystemException catch (e) {
    throw ConfigException('cannot write ${f.path}: ${e.osError?.message ?? e.message}'
        ' (the system service keeps its files as root: sudo)');
  }
  stdout.writeln('asked the keeper to free ${call.toLowerCase()}.${config.namesZone}; '
      'it acts within a minute (journalctl -u xprs-server)');
}

/// The keeper reads the operator's release requests and frees each label.
Future<void> _namesReleaseRequests(NamesKeeper k, String dir) async {
  final f = File('$dir/release.txt');
  if (!f.existsSync()) return;
  final List<String> lines;
  try {
    lines = await f.readAsLines();
    await f.delete();
  } on FileSystemException catch (e) {
    LogService.instance.add('names: cannot read release requests: $e');
    return;
  }
  for (final l in lines) {
    final call = l.trim();
    if (call.isEmpty) continue;
    final done = await k.release(call);
    LogService.instance.add(
        'names: operator release of $call: ${done ? 'freed' : 'no such name'}');
  }
}

/// The administrator's switch (Administration, Updates): the `auto_update`
/// host switch the station keeps with its settings (WebChatApi.hostSwitches).
/// No file, no setting, or a damaged one: on.
Future<bool> _adminAllowsUpdates(String settingsPath) async {
  if (!File(settingsPath).existsSync()) return true;
  final store = await FileKeyValueStore.open(settingsPath);
  final raw = store.getString(WebChatApi.settingsKey);
  if (raw == null) return true;
  try {
    return (jsonDecode(raw) as Map)['auto_update'] != false;
  } catch (_) {
    return true;
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

/// `xprs-server sign`: the operator signs as the station (its key is the
/// station's own, in the data directory): one canonical wire a line on
/// stdin, the signed wire on stdout, an empty line for one that does not
/// parse. Run as the service's user with its HOME. What it signs then goes
/// through the station's API like anything else; whoever holds this key is
/// the station's operator (API-HTTP.md, /api/admin).
Future<void> _sign(ServerConfig config) async {
  final store = await FileKeyValueStore.open(
      settingsPathFor(Platform.environment['HOME'] ?? '.'));
  CoreHost.openPreferences = () async => store;
  await initStorageRoot();
  await PreferencesService.instance();
  await ProfileService.instance.load();
  final d = xprsProfileScalar();
  if (d == null) {
    stderr.writeln('no station identity in this data directory');
    exitCode = 1;
    return;
  }
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final p = XprsPacket.parse(line.trim());
    stdout.writeln(p == null ? '' : xprsSign(p, d).encode());
  }
}
