/*
 * The server's options, layered: built-in default < config file < command
 * line. Every value remembers which layer it came from (`print-config`).
 *
 * The file is YAML so people can comment it. Keys are snake_case; the
 * matching command-line flags are the same words with dashes (http_port ->
 * --http-port). An unknown key is an error, not ignored: a typo in a config
 * file should not silently run the server on the wrong port.
 */
import 'dart:io';

import 'package:yaml/yaml.dart';

class ConfigException implements Exception {
  ConfigException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ServerConfig {
  const ServerConfig._({
    required this.httpPort,
    required this.httpAddress,
    required this.rnsPort,
    required this.hubs,
    required this.page,
    required this.nickname,
    required this.dataDir,
    required this.publicArchiver,
    required this.logFile,
    required this.sources,
  });

  final int httpPort;
  final String httpAddress;
  final int rnsPort;

  /// Uplinks as `host[:port]`. Empty: the core's own list.
  final List<String> hubs;

  /// A web chat page file to serve instead of the built-in one. Null: built in.
  final String? page;
  final String nickname;

  /// The server's own HOME (identity, archive). Null: whatever HOME is.
  final String? dataDir;

  /// Keep public history for others (XPRS.md 12.9.4).
  final bool publicArchiver;

  /// Also append the log here. Null: stdout only (the journal under systemd).
  final String? logFile;

  /// key -> 'default' | the config file's path | 'command line'.
  final Map<String, String> sources;

  static const keys = <String>[
    'http_port',
    'http_address',
    'rns_port',
    'hubs',
    'page',
    'nickname',
    'data_dir',
    'public_archiver',
    'log_file',
  ];

  static const _defaults = <String, Object?>{
    'http_port': 80,
    'http_address': '0.0.0.0',
    'rns_port': 4242,
    'hubs': <String>[],
    'page': null,
    'nickname': 'XPRS server',
    'data_dir': null,
    'public_archiver': true,
    'log_file': null,
  };

  /// Layers [file] then [cli] over the defaults. Both maps use the snake_case
  /// keys; [fileName] names the file in messages and in [sources].
  static ServerConfig resolve({
    Map<String, Object?> file = const {},
    String fileName = 'config file',
    Map<String, Object?> cli = const {},
  }) {
    final values = Map<String, Object?>.of(_defaults);
    final src = {for (final k in keys) k: 'default'};
    void layer(Map<String, Object?> m, String from) {
      final clean = _validate(m, from);
      for (final e in clean.entries) {
        values[e.key] = e.value;
        src[e.key] = from;
      }
    }

    layer(file, fileName);
    layer(cli, 'command line');
    return ServerConfig._(
      httpPort: values['http_port'] as int,
      httpAddress: values['http_address'] as String,
      rnsPort: values['rns_port'] as int,
      hubs: List<String>.unmodifiable(values['hubs'] as List<String>),
      page: values['page'] as String?,
      nickname: values['nickname'] as String,
      dataDir: values['data_dir'] as String?,
      publicArchiver: values['public_archiver'] as bool,
      logFile: values['log_file'] as String?,
      sources: Map.unmodifiable(src),
    );
  }

  /// One line per option with where it came from, for `print-config`.
  String describe() {
    final v = <String, Object?>{
      'http_port': httpPort,
      'http_address': httpAddress,
      'rns_port': rnsPort,
      'hubs': hubs.isEmpty ? "[] (the core's list)" : hubs,
      'page': page ?? '(built into the program)',
      'nickname': nickname,
      'data_dir': dataDir ?? '(HOME as it is)',
      'public_archiver': publicArchiver,
      'log_file': logFile ?? '(stdout only)',
    };
    final w = keys.fold<int>(0, (m, k) => k.length > m ? k.length : m);
    return [
      for (final k in keys) '${k.padRight(w)}  ${v[k]}   [${sources[k]}]',
    ].join('\n');
  }
}

Map<String, Object?> _validate(Map<String, Object?> m, String from) {
  final out = <String, Object?>{};
  for (final e in m.entries) {
    final k = e.key;
    final v = e.value;
    if (!ServerConfig.keys.contains(k)) {
      throw ConfigException(
        "$from: unknown option '$k' "
        '(valid: ${ServerConfig.keys.join(', ')})',
      );
    }
    if (v == null) continue; // `page:` left empty means "not set"
    ConfigException bad(String want) =>
        ConfigException("$from: '$k' must be $want, got '$v'");
    switch (k) {
      case 'http_port':
      case 'rns_port':
        if (v is! int || v < 1 || v > 65535) throw bad('a port, 1-65535');
        out[k] = v;
      case 'public_archiver':
        if (v is! bool) throw bad('true or false');
        out[k] = v;
      case 'hubs':
        final list = v is List ? v : [v];
        final hubs = <String>[];
        for (final h in list) {
          if (h is! String || h.trim().isEmpty) {
            throw bad('a list of host or host:port');
          }
          hubs.add(h.trim());
        }
        out[k] = hubs;
      case 'http_address':
      case 'nickname':
        if (v is! String || v.trim().isEmpty) throw bad('a non-empty string');
        out[k] = v.trim();
      default: // page, data_dir, log_file
        if (v is! String) throw bad('a path');
        if (v.trim().isNotEmpty) out[k] = v.trim();
    }
  }
  return out;
}

/// Reads a YAML config file into the snake_case map [ServerConfig.resolve]
/// takes. An empty file is an empty map.
Map<String, Object?> loadConfigFile(String path) {
  final String text;
  try {
    text = File(path).readAsStringSync();
  } on FileSystemException catch (e) {
    throw ConfigException(
      'cannot read $path: ${e.osError?.message ?? e.message}',
    );
  }
  final Object? doc;
  try {
    doc = loadYaml(text);
  } on YamlException catch (e) {
    throw ConfigException('$path: ${e.message}');
  }
  if (doc == null) return {};
  if (doc is! Map) throw ConfigException('$path: expected "key: value" lines');
  return {for (final e in doc.entries) '${e.key}': _plain(e.value)};
}

Object? _plain(Object? v) => v is YamlList ? [for (final x in v) _plain(x)] : v;

/// Where a config file is looked for, first match wins.
List<String> configSearchPaths({Map<String, String>? env, String? home}) {
  final e = env ?? Platform.environment;
  final h = home ?? e['HOME'];
  final xdg = e['XDG_CONFIG_HOME'];
  return [
    if (xdg != null && xdg.isNotEmpty) '$xdg/xprs-server/config.yaml',
    if (h != null && h.isNotEmpty) '$h/.config/xprs-server/config.yaml',
    '/etc/xprs-server/config.yaml',
  ];
}

/// The config file to use: [explicit] (--config) or $XPRS_SERVER_CONFIG must
/// exist; otherwise the first of [configSearchPaths] that does. Null: none,
/// which is fine — the defaults and the command line are enough.
String? findConfigFile({String? explicit, Map<String, String>? env}) {
  final e = env ?? Platform.environment;
  final named = explicit ?? e['XPRS_SERVER_CONFIG'];
  if (named != null && named.isNotEmpty) {
    if (!File(named).existsSync()) {
      throw ConfigException('config file not found: $named');
    }
    return named;
  }
  for (final p in configSearchPaths(env: e)) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

/// A commented starting file. [httpPort] and [dataDir] are written live when
/// given (the service installer does); everything else is shown as a comment
/// with its default, so the file documents every option.
String defaultConfigYaml({int httpPort = 80, String? dataDir}) =>
    '''
# XPRS server configuration.
#
# Precedence: command-line flags > this file > built-in defaults.
# Every key has a matching flag (http_port -> --http-port).
# See what is in effect with:  xprs-server print-config

# Web chat: the port and the address it listens on. Ports below 1024 need
# the service's CAP_NET_BIND_SERVICE (the system service has it) or setcap.
http_port: $httpPort
# http_address: 0.0.0.0        # 127.0.0.1 to listen on this machine only

# Reticulum TCP port: accepts Reticulum clients and speaks XPRS as text.
# rns_port: 4242

# Uplinks to other Reticulum hubs, host or host:port (default port 4242).
# Leave empty to use the core's built-in list.
# hubs:
#   - rns.example.org:4242

# The station's name, used when its identity is first made.
# nickname: XPRS server

# Keep public history for other stations (an archiver).
# public_archiver: true

# The server's own data directory (identity, archive, settings). The core
# keeps its tree under HOME, so the server sets HOME to this.
${dataDir == null ? '# data_dir: /var/lib/xprs-server' : 'data_dir: $dataDir'}

# Serve this HTML file instead of the page built into the program (to
# customise it). Default: the built-in page.
# page: /etc/xprs-server/chat_page.html

# Also append the log to this file. Default: standard output (the journal
# under systemd). Under the system service it must be inside the data dir.
# log_file: /var/lib/xprs-server/server.log
''';
