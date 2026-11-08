/*
 * Command line: `xprs-server [command] [options]`. No command means `run`,
 * so every pre-config invocation (`xprs-server --http-port 8080`) still works.
 *
 * Only flags the person actually typed become overrides (wasParsed), so a
 * flag's default never hides a value from the config file.
 */
import 'package:args/args.dart';

import '../autostart/autostart.dart';
import '../config/server_config.dart';

const commands = <String, String>{
  'run': 'run the server (the default)',
  'init-config': 'write a commented config file (--config PATH, --force)',
  'print-config': 'show the options in effect and where each came from',
  'install-service': 'start at boot (--system or --user, --dry-run)',
  'uninstall-service': 'remove the boot service (--system or --user)',
  'service-status': 'show whether the boot service is running',
  'update': 'install a newer release from GitHub (--dry-run: only look)',
  'names-release': 'free a station name whose key was lost: names-release X3ABCD',
};

/// Commands that take one argument after their name.
const _withArgument = {'names-release'};

class Invocation {
  Invocation({
    required this.command,
    required this.overrides,
    required this.configPath,
    required this.help,
    required this.dryRun,
    required this.force,
    required this.scope,
    required this.version,
    this.argument,
  });

  final String command;

  /// Config keys (snake_case) given on the command line.
  final Map<String, Object?> overrides;
  final String? configPath;
  final bool help;
  final bool dryRun;
  final bool force;

  /// Null when neither --system nor --user was given.
  final ServiceScope? scope;

  /// --version: print the version and stop.
  final bool version;

  /// The argument of a command that takes one (names-release X3ABCD).
  final String? argument;
}

ArgParser buildParser() => ArgParser()
  ..addOption('config', help: 'config file (default: search, see init-config)')
  ..addOption('http-port', help: 'web chat port (default 80)')
  ..addOption('http-address', help: 'web chat address (default ::, IPv4 and IPv6)')
  ..addOption('rns-port', help: 'Reticulum TCP port (default 4242)')
  ..addMultiOption(
    'hub',
    help: 'uplink host[:port], repeatable (default: the core list)',
  )
  ..addOption('nickname', help: 'station name (default "XPRS server")')
  ..addOption('data-dir', help: "the server's own HOME (identity, archive)")
  ..addFlag(
    'public-archiver',
    help: 'keep public history for others (default on)',
    defaultsTo: null,
  )
  ..addOption('log-file', help: 'also append the log to this file')
  ..addFlag('public-name',
      help: 'nip.io name + Let\'s Encrypt HTTPS when reachable (default on)')
  ..addOption('https-port', help: 'HTTPS port (default 443)')
  ..addFlag('upnp', help: 'ask the router to open ports 80/443 (default on)')
  ..addOption('acme-email', help: "Let's Encrypt contact (optional)")
  ..addFlag('acme-staging',
      negatable: false, help: "Let's Encrypt staging CA (testing)")
  ..addOption('auto-update',
      allowed: ['stable', 'beta', 'off'],
      help: 'which releases `update` installs (default stable)')
  ..addOption('update-repo',
      help: 'GitHub repository with the releases (default xprs-dev/server)')
  ..addOption('names-keeper',
      help: 'the keeper that names this station (default https://names.xprs.dev; "" for none)')
  ..addFlag('version', negatable: false, help: 'print the version')
  ..addFlag('system', negatable: false, help: 'service for the whole machine')
  ..addFlag('user', negatable: false, help: 'service for this user only')
  ..addFlag('dry-run', negatable: false, help: 'show what would change')
  ..addFlag('force',
      negatable: false,
      help: 'init-config: overwrite an existing file; update: install although '
          'Administration switched updates off')
  ..addFlag('help', abbr: 'h', negatable: false);

String usage() {
  final cmds = commands.entries
      .map((e) => '  ${e.key.padRight(18)}${e.value}')
      .join('\n');
  return 'xprs-server [command] [options]\n\nCommands:\n$cmds\n\n'
      'Options:\n${buildParser().usage}';
}

/// Throws [ConfigException] (bad value, unknown command) or
/// [FormatException] (unknown flag, from package:args).
Invocation parseInvocation(List<String> argv) {
  final r = buildParser().parse(argv);
  final command = r.rest.isEmpty ? 'run' : r.rest.first;
  if (!commands.containsKey(command)) {
    throw ConfigException("unknown command '$command' (try --help)");
  }
  final takesOne = _withArgument.contains(command);
  if (r.rest.length > (takesOne ? 2 : 1)) {
    throw ConfigException('one command at a time, got: ${r.rest.join(' ')}');
  }
  if (takesOne && r.rest.length != 2) {
    throw ConfigException('$command needs one argument: ${commands[command]}');
  }
  if ((r['system'] as bool) && (r['user'] as bool)) {
    throw ConfigException('--system and --user exclude each other');
  }

  final o = <String, Object?>{};
  int port(String flag, String key) {
    final s = r[flag] as String;
    final n = int.tryParse(s);
    if (n == null || n < 1 || n > 65535) {
      throw ConfigException("--$flag must be a port, 1-65535, got '$s'");
    }
    return o[key] = n;
  }

  if (r.wasParsed('http-port')) port('http-port', 'http_port');
  if (r.wasParsed('rns-port')) port('rns-port', 'rns_port');
  if (r.wasParsed('http-address')) o['http_address'] = r['http-address'];
  if (r.wasParsed('hub')) o['hubs'] = r['hub'];
  if (r.wasParsed('nickname')) o['nickname'] = r['nickname'];
  if (r.wasParsed('data-dir')) o['data_dir'] = r['data-dir'];
  if (r.wasParsed('public-archiver')) {
    o['public_archiver'] = r['public-archiver'];
  }
  if (r.wasParsed('log-file')) o['log_file'] = r['log-file'];
  if (r.wasParsed('https-port')) port('https-port', 'https_port');
  for (final (flag, key) in [
    ('public-name', 'public_name'),
    ('upnp', 'upnp'),
    ('acme-staging', 'acme_staging'),
  ]) {
    if (r.wasParsed(flag)) o[key] = r[flag];
  }
  if (r.wasParsed('acme-email')) o['acme_email'] = r['acme-email'];
  if (r.wasParsed('auto-update')) o['auto_update'] = r['auto-update'];
  if (r.wasParsed('update-repo')) o['update_repo'] = r['update-repo'];
  if (r.wasParsed('names-keeper')) o['names_keeper'] = r['names-keeper'];

  return Invocation(
    command: command,
    overrides: o,
    configPath: r['config'] as String?,
    help: r['help'] as bool,
    dryRun: r['dry-run'] as bool,
    force: r['force'] as bool,
    scope: (r['system'] as bool)
        ? ServiceScope.system
        : (r['user'] as bool)
        ? ServiceScope.user
        : null,
    version: r['version'] as bool,
    argument: takesOne ? r.rest[1] : null,
  );
}
