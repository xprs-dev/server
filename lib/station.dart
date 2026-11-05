/*
 * The station: the core brought up with no screen, in the order the app's
 * boot uses (lib/main.dart, PermissionGate.startGatedServices,
 * rns_autostart.dart), minus everything that is a wapp, a widget or a radio.
 *
 *   1. CoreHost: the server's answers (a JSON settings file, a heartbeat
 *      for the catch-up poll; everything else keeps its headless default —
 *      no keychain, no battery, no BLE).
 *   2. Storage root and profile: this station's OWN identity (an X3, a fixed
 *      station), made on first run, never the operator's phone profile.
 *   3. The mesh core (archive, custody, the XPRS LAN bearer, the bridge).
 *   4. Reticulum: a transport node accepting clients on TCP, with uplinks to
 *      the public hubs, kept topped up.
 *   5. The web chat (WebChatServer), wired to the core like the app's share
 *      server.
 */
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xprs_core/src/platform/core_host.dart';
import 'package:xprs_core/src/platform/heartbeat_keep_alive.dart';
import 'package:xprs_core/src/profile/profile_service.dart';
import 'package:xprs_core/src/profile/storage_paths.dart';
import 'package:xprs_core/src/services/log_service.dart';
import 'package:xprs_core/src/services/mesh/mesh_service.dart';
import 'package:xprs_core/src/services/preferences_service.dart';
import 'package:xprs_core/src/services/receive/packet_gateway.dart';
import 'package:xprs_core/src/services/reticulum/rns_service.dart';
import 'package:xprs_core/src/services/web_chat_api.dart';
import 'package:xprs_core/src/services/xprs/xprs_archive.dart';
import 'package:xprs_core/src/services/xprs/xprs_identity_adopt.dart';
import 'package:xprs_core/src/services/xprs/xprs_publisher.dart';

import 'host/file_key_value_store.dart';

class StationConfig {
  /// Where the settings file lives (the core's tree is under $HOME, see
  /// bin/xprs_server.dart).
  final String settingsPath;
  final int rnsPort;
  final List<String>? hubs; // null: the core's default list
  final String nickname;

  /// Keep public history for others (XPRS.md 12.9.4).
  final bool publicArchiver;

  const StationConfig({
    required this.settingsPath,
    this.rnsPort = 4242,
    this.hubs,
    this.nickname = 'XPRS server',
    this.publicArchiver = true,
  });
}

class Station {
  Station(this.config);
  final StationConfig config;
  Timer? _hubTick;
  FileKeyValueStore? _store;

  String get callsign => MeshService.instance.tableCallsign;

  Future<void> start() async {
    final store = await FileKeyValueStore.open(config.settingsPath);
    _store = store;
    CoreHost.openPreferences = () async => store;
    // The heartbeat the core's catch-up poll runs on (XPRS.md 12.10.1): the
    // server asks reachable stations and archivers for the history it missed.
    CoreHost.keepAlive = HeartbeatKeepAlive(every: const Duration(seconds: 2));

    await initStorageRoot();
    final prefs = await PreferencesService.instance();
    await ProfileService.instance.load();
    await _ensureIdentity();
    if (config.hubs != null) prefs.rnsBootstrapServers = config.hubs!;

    // An always-on, mains-powered station is a public archiver that keeps
    // history for others (XPRS.md 12.9.4) unless the config says otherwise.
    await store.setBool('xprs.public', config.publicArchiver);
    await prefs.setXprsAlwaysOn(config.publicArchiver);

    xprsBindWireCallsign();
    await MeshService.instance.start(canAdvertise: false);
    LogService.instance.add('server: mesh core up as $callsign');
  }

  /// Reticulum and the hub uplinks. Separate from [start] because dialling
  /// the hubs takes seconds per hub: the web chat comes up first.
  Future<void> startNetwork() async {
    await _startRns();
    // The same net the app keeps under its uplinks: re-dial hubs that dropped.
    _hubTick = Timer.periodic(const Duration(minutes: 5), (_) => _topUpHubs());
    RnsService.instance.onLinkDown = () => unawaited(_topUpHubs());
  }

  Future<void> _ensureIdentity() async {
    if (ProfileService.instance.activeProfile != null) return;
    final svc = ProfileService.instance;
    final seed = svc.generatePreview();
    final profile = svc.buildFromNsec(
      seed.nsec,
      nickname: config.nickname,
      kind: CallsignKind.station,
    );
    // No keychain on a server: the profile is protected by the data
    // directory's permissions (0700, a dedicated user), not a device key.
    await svc.saveAndActivate(profile, encrypt: false);
    LogService.instance.add('server: new station identity ${profile.callsign}');
  }

  Future<void> _startRns() async {
    final rns = RnsService.instance;
    // The node's files, where the app keeps them (rns_autostart.dart): above
    // all the identity, which peers learn paths by and must survive a restart.
    final ws = wappsDataStorage(PreferencesService.instanceSync!);
    rns
      ..identityPath = ws.getAbsolutePath('rns_identity.key')
      ..relayStorePath = ws.getAbsolutePath('social.sqlite3')
      ..callPeersPath = ws.getAbsolutePath('call_peers.json')
      ..partialStoreDir = ws.getAbsolutePath('partials')
      ..folderStorePath = ws.getAbsolutePath('folders.json')
      ..diskFoldersPath = ws.getAbsolutePath('disk_folders.json')
      ..subscriptionsPath = ws.getAbsolutePath('folder_subscriptions.json')
      ..folderExportDir = ws.getAbsolutePath('opened')
      ..serveStatsPath = ws.getAbsolutePath('serve_stats.sqlite3')
      ..popularityPath = ws.getAbsolutePath('folder_popularity.sqlite3')
      ..followsPath = ws.getAbsolutePath('host_follows.json')
      ..diskIndexPath = ws.getAbsolutePath('disk_index.sqlite3')
      ..observedStorePath = ws.getAbsolutePath('observed.sqlite3');
    final name = callsign.isNotEmpty ? callsign : 'xprs';
    // A server always accepts clients: tcpserver mode makes it a transport
    // node for whoever dials in (and speaks XPRS text on the same port).
    final ok = await rns.start(
      mode: 'tcpserver',
      port: config.rnsPort,
      announceName: name,
    );
    LogService.instance.add(
      ok
          ? 'server: Reticulum transport on tcp :${config.rnsPort}'
          : 'server: Reticulum did not start',
    );
    await _topUpHubs();
  }

  Future<void> _topUpHubs() async {
    final rns = RnsService.instance;
    if (!rns.isUp) return;
    final servers = PreferencesService.instanceSync?.rnsBootstrapServers ?? [];
    for (final entry in servers) {
      final hp = parseHostPort(entry);
      if (hp == null) continue;
      if (rns.connectedHubs.contains('${hp.$1}:${hp.$2}')) continue;
      try {
        await rns.connectUplink(hp.$1, hp.$2);
      } catch (e) {
        LogService.instance.add('server: uplink ${hp.$1}:${hp.$2} failed: $e');
      }
    }
  }

  /// The visitor API, wired exactly as the app's share server wires it:
  /// posts go in through the one receive door, reads come from the archive.
  WebChatApi webChatApi() {
    unawaited(_readPrefixes()); // so the first visitor is judged right
    return _webChatApi();
  }

  WebChatApi _webChatApi() => WebChatApi(
    publicRows: archivePublicRows,
    held: (t) => XprsArchive.instance.countOf(types: t, undirected: true),
    receive: (w) => PacketGateway.instance.receive(
      Uint8List.fromList(utf8.encode(w)),
      bearer: 'wifi',
      lane: RxLane.datagram,
    ),
    mayAir: XprsPublisher.instance.mayAir,
    selfCallsign: () => MeshService.instance.tableCallsign,
    keyOf: (c) => XprsArchive.instance.keyResolver?.call(c),
    appPath: () => null,
    // The administrator and the visitor settings live with the station's.
    store: _store,
    isLocalPeer: isLocalPeer,
  );

  /// The station's own network: private addresses, plus the IPv6 /64s this
  /// machine has public addresses in (an IPv6 LAN hands out public ones).
  /// The interface list is read at most once a minute.
  bool isLocalPeer(String peer) {
    if (isPrivateAddress(peer)) return true;
    if (alsoLocal?.call(peer) ?? false) return true;
    final ip = InternetAddress.tryParse(peer.split('%').first);
    if (ip == null || ip.type != InternetAddressType.IPv6) return false;
    if (DateTime.now().difference(_prefixesAt) > const Duration(minutes: 1)) {
      unawaited(_readPrefixes());
    }
    return _prefixes.contains(_prefix64(ip));
  }

  Future<void> _readPrefixes() async {
    _prefixesAt = DateTime.now();
    try {
      final l = await NetworkInterface.list(type: InternetAddressType.IPv6);
      _prefixes = {
        for (final nic in l)
          for (final a in nic.addresses)
            if (!a.isLinkLocal && !a.isLoopback) _prefix64(a),
      };
    } catch (_) {}
  }

  /// More of the station's own network, from the host: the public IPv4 a
  /// device behind this router comes back as when it opens the public name
  /// (hairpin NAT); only machines behind that NAT share it.
  bool Function(String peer)? alsoLocal;

  Set<String> _prefixes = {};
  DateTime _prefixesAt = DateTime.fromMillisecondsSinceEpoch(0);
  static String _prefix64(InternetAddress a) =>
      a.rawAddress.sublist(0, 8).join('.');

  Future<void> stop() async {
    _hubTick?.cancel();
  }
}

/// "host:port" (port optional, 4242). Null for a blank entry.
(String, int)? parseHostPort(String entry) {
  final s = entry.trim();
  if (s.isEmpty) return null;
  final i = s.lastIndexOf(':');
  if (i <= 0 || i == s.length - 1) return (s, 4242);
  final host = s.substring(0, i).trim();
  final port = int.tryParse(s.substring(i + 1).trim()) ?? 4242;
  if (host.isEmpty) return null;
  return (host, port);
}
