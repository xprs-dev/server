/*
 * systemd backend (Linux).
 *
 *  --system  /etc/systemd/system/xprs-server.service, a dedicated `xprs` user,
 *            the binary copied to /opt/xprs-server, data in /var/lib/xprs-server,
 *            config in /etc/xprs-server/config.yaml, port 80, sandboxed.
 *  --user    ~/.config/systemd/user/xprs-server.service, no root: runs the
 *            binary where it is, data in ~/.local/share/xprs-server, port
 *            8080 (a user cannot bind 80).
 *
 * The unit is generated from the binary's own path, so installing needs
 * nothing but the binary: the web page is compiled into it.
 *
 * Beside the service, a timer (xprs-server-update.timer) runs
 * `xprs-server update` every six hours so the installation follows the
 * releases on GitHub (lib/update/updater.dart, config `auto_update`).
 */
import 'dart:io';

import '../config/server_config.dart';
import 'autostart.dart';

const _unitName = 'xprs-server.service';
const _updateService = 'xprs-server-update.service';
const _updateTimer = 'xprs-server-update.timer';

/// Where each scope keeps its files. Pure, so tests can check them.
class SystemdLayout {
  SystemdLayout.system()
    : scope = ServiceScope.system,
      unitPath = '/etc/systemd/system/$_unitName',
      configPath = '/etc/xprs-server/config.yaml',
      dataDir = '/var/lib/xprs-server',
      installDir = '/opt/xprs-server',
      defaultHttpPort = 80;

  SystemdLayout.user(String home, {String? xdgConfig})
    : scope = ServiceScope.user,
      unitPath = '${_xdg(xdgConfig, home)}/systemd/user/$_unitName',
      configPath = '${_xdg(xdgConfig, home)}/xprs-server/config.yaml',
      dataDir = '$home/.local/share/xprs-server',
      installDir = null,
      defaultHttpPort = 8080;

  final ServiceScope scope;
  final String unitPath;
  final String configPath;
  final String dataDir;

  /// Where the binary is copied (system only; user runs in place).
  final String? installDir;
  final int defaultHttpPort;

  String get _unitDir => unitPath.substring(0, unitPath.lastIndexOf('/'));
  String get updateServicePath => '$_unitDir/$_updateService';
  String get updateTimerPath => '$_unitDir/$_updateTimer';

  static String _xdg(String? xdg, String home) =>
      (xdg != null && xdg.isNotEmpty) ? xdg : '$home/.config';
}

String _q(String s) => s.contains(' ') ? '"$s"' : s;

/// The unit file for [l], running [exe] with [configPath].
String renderUnit(
  SystemdLayout l, {
  required String exe,
  required String configPath,
}) {
  final system = l.scope == ServiceScope.system;
  return '''
[Unit]
Description=XPRS server edition (Reticulum transport, LAN bridge, web chat)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
${system ? 'User=xprs\nGroup=xprs\n' : ''}# The core keeps its tree under \$HOME/.local/share/xprs: give the server its own.
Environment=HOME=${l.dataDir}
${system ? 'StateDirectory=xprs-server\nStateDirectoryMode=0700\n' : ''}WorkingDirectory=${l.dataDir}
ExecStart=${_q(exe)} --config ${_q(configPath)}
NoNewPrivileges=true
PrivateTmp=true
${system ? '''# Port 80 without running as root.
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
ProtectSystem=strict
ProtectHome=true
MemoryMax=1G
''' : ''}Restart=on-failure
RestartSec=5

[Install]
WantedBy=${system ? 'multi-user.target' : 'default.target'}
''';
}

/// The oneshot unit the timer starts: `xprs-server update`, as the user that
/// owns the binary (root for the system scope, since it writes /opt).
String renderUpdateService(
  SystemdLayout l, {
  required String exe,
  required String configPath,
}) =>
    '''
[Unit]
Description=XPRS server: install a newer release (xprs-server update)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${_q(exe)} update --config ${_q(configPath)}
''';

/// Every six hours, half an hour of jitter, and once ten minutes after boot.
String renderUpdateTimer(SystemdLayout l) => '''
[Unit]
Description=XPRS server: look for a newer release every six hours

[Timer]
OnBootSec=10min
OnUnitActiveSec=6h
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
''';

class SystemdBackend implements AutostartBackend {
  @override
  String get name => 'systemd';

  SystemdLayout _layout(ServiceScope s) {
    if (s == ServiceScope.system) return SystemdLayout.system();
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw ServiceException('HOME is not set; cannot place a --user service');
    }
    return SystemdLayout.user(
      home,
      xdgConfig: Platform.environment['XDG_CONFIG_HOME'],
    );
  }

  List<String> _ctl(ServiceScope s, List<String> args) => [
    if (s == ServiceScope.user) '--user',
    ...args,
  ];

  Future<void> _systemctl(
    ServiceScope s,
    List<String> args, {
    bool allowFail = false,
  }) async {
    final r = await Process.run('systemctl', _ctl(s, args));
    if (r.exitCode != 0 && !allowFail) {
      throw ServiceException(
        'systemctl ${_ctl(s, args).join(' ')} failed: ${r.stderr}'.trim(),
      );
    }
  }

  static Future<void> _writeFile(String path, String text, int mode) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    await f.writeAsString(text);
    await Process.run('chmod', [mode.toRadixString(8), path]);
  }

  /// Copy through a temp name so a running binary can be replaced.
  static Future<void> _copyAtomic(String from, String to, int mode) async {
    await Directory(File(to).parent.path).create(recursive: true);
    await File(from).copy('$to.new');
    await Process.run('chmod', [mode.toRadixString(8), '$to.new']);
    await File('$to.new').rename(to);
  }

  @override
  Future<List<ServiceStep>> installSteps(ServiceOptions o) async {
    final l = _layout(o.scope);
    final system = o.scope == ServiceScope.system;
    if (!o.dryRun) {
      if (system && !_isRoot()) {
        throw ServiceException(
          'installing the system service needs root: sudo ${o.exePath} '
          'install-service --system   (or use --user)',
        );
      }
      if (_isDartVm(o.exePath)) {
        throw ServiceException(
          'this is the Dart VM, not the compiled server: '
          'run dart compile exe bin/xprs_server.dart -o build/xprs-server, '
          'then ./build/xprs-server install-service',
        );
      }
    }
    final exe = system ? '${l.installDir}/xprs-server' : o.exePath;
    final cfg = o.configPath ?? l.configPath;
    return [
      if (system)
        ServiceStep('create system user xprs (if missing)', () async {
          final id = await Process.run('id', ['-u', 'xprs']);
          if (id.exitCode == 0) return;
          final r = await Process.run('useradd', [
            '--system',
            '--home-dir',
            l.dataDir,
            '--shell',
            '/usr/sbin/nologin',
            'xprs',
          ]);
          if (r.exitCode != 0) {
            throw ServiceException('useradd failed: ${r.stderr}'.trim());
          }
        }),
      if (system)
        ServiceStep('copy ${o.exePath} to $exe', () async {
          await _copyAtomic(o.exePath, exe, 493); // 0755
        }),
      ServiceStep(
        'write $cfg with port ${l.defaultHttpPort} (kept if it exists)',
        () async {
          if (File(cfg).existsSync()) return;
          await _writeFile(
            cfg,
            defaultConfigYaml(httpPort: l.defaultHttpPort, dataDir: l.dataDir),
            420,
          );
        },
      ),
      ServiceStep('write ${l.unitPath}', () async {
        await _writeFile(
          l.unitPath,
          renderUnit(l, exe: exe, configPath: cfg),
          420,
        );
      }),
      ServiceStep('write ${l.updateServicePath} and ${l.updateTimerPath}',
          () async {
        await _writeFile(
          l.updateServicePath,
          renderUpdateService(l, exe: exe, configPath: cfg),
          420,
        );
        await _writeFile(l.updateTimerPath, renderUpdateTimer(l), 420);
      }),
      if (!system)
        ServiceStep('create data directory ${l.dataDir}', () async {
          await Directory(l.dataDir).create(recursive: true);
        }),
      ServiceStep(
        'systemctl ${_ctl(o.scope, ['daemon-reload']).join(' ')}',
        () => _systemctl(o.scope, ['daemon-reload']),
      ),
      ServiceStep('enable at boot and (re)start the service', () async {
        await _systemctl(o.scope, ['enable', _unitName]);
        await _systemctl(o.scope, ['restart', _unitName]);
      }),
      ServiceStep('enable the update timer (every six hours)', () async {
        await _systemctl(o.scope, ['enable', '--now', _updateTimer]);
      }),
    ];
  }

  @override
  Future<List<ServiceStep>> uninstallSteps(ServiceOptions o) async {
    final l = _layout(o.scope);
    if (!o.dryRun && o.scope == ServiceScope.system && !_isRoot()) {
      throw ServiceException(
        'removing the system service needs root: '
        'sudo ${o.exePath} uninstall-service --system',
      );
    }
    return [
      ServiceStep('stop and disable the service and the update timer',
          () async {
        await _systemctl(o.scope, [
          'disable',
          '--now',
          _unitName,
        ], allowFail: true);
        await _systemctl(o.scope, [
          'disable',
          '--now',
          _updateTimer,
        ], allowFail: true);
      }),
      ServiceStep('remove ${l.unitPath} and the update units', () async {
        for (final p in [l.unitPath, l.updateServicePath, l.updateTimerPath]) {
          final f = File(p);
          if (f.existsSync()) await f.delete();
        }
      }),
      ServiceStep(
        'systemctl daemon-reload',
        () => _systemctl(o.scope, ['daemon-reload']),
      ),
    ];
  }

  @override
  Future<int> status(ServiceScope scope) async {
    final p = await Process.start(
      'systemctl',
      _ctl(scope, ['status', _unitName, '--no-pager']),
      mode: ProcessStartMode.inheritStdio,
    );
    return p.exitCode;
  }

  @override
  List<String> notes(ServiceScope scope, {required bool installing}) {
    final l = _layout(scope);
    if (!installing) {
      return [
        'Kept: ${l.configPath} and the data in ${l.dataDir} '
            '(identity and archive). Delete them by hand to start fresh.',
      ];
    }
    return [
      'Config: ${l.configPath}  (edit it, then: '
          '${scope == ServiceScope.user ? 'systemctl --user' : 'systemctl'} '
          'restart xprs-server)',
      'Logs:   ${scope == ServiceScope.user ? 'journalctl --user' : 'journalctl'}'
          ' -u xprs-server -f',
      'Updates: newer releases install themselves every six hours '
          '(auto_update in the config; xprs-server update --dry-run to look)',
      if (scope == ServiceScope.user)
        'To start at boot without logging in: loginctl enable-linger '
            '\$USER',
    ];
  }

  @override
  Future<ServiceScope?> installedScope(String exePath) async {
    final sys = SystemdLayout.system();
    if (exePath == '${sys.installDir}/xprs-server' &&
        File(sys.unitPath).existsSync()) {
      return ServiceScope.system;
    }
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    final user = SystemdLayout.user(
      home,
      xdgConfig: Platform.environment['XDG_CONFIG_HOME'],
    );
    final f = File(user.unitPath);
    if (f.existsSync() && f.readAsStringSync().contains(exePath)) {
      return ServiceScope.user;
    }
    return null;
  }

  @override
  Future<void> restart(ServiceScope scope) =>
      _systemctl(scope, ['restart', _unitName]);

  @override
  Future<bool> isActive(ServiceScope scope) async {
    final r = await Process.run('systemctl', _ctl(scope, ['is-active', _unitName]));
    return r.exitCode == 0 && (r.stdout as String).trim() == 'active';
  }

  /// True for `dart` / `dartaotruntime`: the program was not compiled.
  static bool isDartVm(String exe) => _isDartVm(exe);

  static bool _isRoot() {
    final r = Process.runSync('id', ['-u']);
    return r.exitCode == 0 && (r.stdout as String).trim() == '0';
  }

  static bool _isDartVm(String exe) {
    final base = exe.split('/').last;
    return base == 'dart' || base == 'dartaotruntime';
  }
}
