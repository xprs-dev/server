// The updater (lib/update/updater.dart): which release a channel picks, the
// version compare, and the whole install against a local stand-in for
// GitHub: download, digest check, atomic replace, restart, and the rollback
// when the new binary does not stay up. No network, no systemd.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:test/test.dart';
import 'package:xprs_server/autostart/autostart.dart';
import 'package:xprs_server/autostart/systemd.dart';
import 'package:xprs_server/cli/cli.dart';
import 'package:xprs_server/config/server_config.dart';
import 'package:xprs_server/update/updater.dart';
import 'package:xprs_server/version.dart';

void main() {
  test('lib/version.dart matches pubspec.yaml (dart run tool/update_version.dart)',
      () {
    final line = File('pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((l) => l.startsWith('version:'));
    expect(kServerVersion, line.split(':')[1].trim().split('+').first);
  });

  test('compareSemver: numbers, pre-releases, build metadata', () {
    expect(compareSemver('0.4.0', '0.3.0'), 1);
    expect(compareSemver('0.3.10', '0.3.9'), 1);
    expect(compareSemver('1.0.0', '1.0.0+7'), 0);
    expect(compareSemver('1.0.0-beta.2', '1.0.0'), -1);
    expect(compareSemver('1.0.0-beta.10', '1.0.0-beta.9'), 1);
    expect(compareSemver('1.0.0-rc.1', '1.0.0-beta.9'), 1);
  });

  test('machineArch maps uname to the release names', () {
    expect(machineArch('aarch64'), 'arm64');
    expect(machineArch('x86_64'), 'x64');
    expect(machineArch('riscv64'), 'riscv64');
    expect(assetName('arm64'), 'xprs-server-linux-arm64');
  });

  test('pickRelease: stable skips pre-releases, beta takes them, drafts never',
      () {
    final list = [
      _rel('v0.6.0', draft: true),
      _rel('v0.5.0-beta.1', prerelease: true),
      _rel('v0.4.0'),
      _rel('v0.3.0'),
    ];
    expect(pickRelease(list, UpdateChannel.stable)!.version, '0.4.0');
    expect(pickRelease(list, UpdateChannel.beta)!.version, '0.5.0-beta.1');
    expect(pickRelease(list, UpdateChannel.off), isNull);
    expect(pickRelease([_rel('v1.0.0', draft: true)], UpdateChannel.beta),
        isNull);
    expect(UpdateChannel.parse('Beta'), UpdateChannel.beta);
    expect(UpdateChannel.parse('nightly'), isNull);
  });

  test('ReleaseInfo.fromJson reads tag, flags and the assets', () {
    final r = ReleaseInfo.fromJson(jsonDecode('''
      {"tag_name":"v0.4.0","prerelease":false,"draft":false,
       "assets":[{"name":"xprs-server-linux-arm64","browser_download_url":"u1"},
                 {"name":"xprs-server-linux-arm64.sha256","browser_download_url":"u2"},
                 {"name":"notes.txt"}]}''') as Map<String, dynamic>);
    expect(r.version, '0.4.0');
    expect(r.assets, {
      'xprs-server-linux-arm64': 'u1',
      'xprs-server-linux-arm64.sha256': 'u2',
    });
  });

  group('config and flags', () {
    test('auto_update and update_repo: defaults, validation, flags', () {
      final d = ServerConfig.resolve();
      expect(d.autoUpdate, 'stable');
      expect(d.updateRepo, 'xprs-dev/server');
      final c = ServerConfig.resolve(
        file: {'auto_update': 'off'},
        cli: parseInvocation(['update', '--update-repo', 'me/fork']).overrides,
      );
      expect(c.autoUpdate, 'off');
      expect(c.updateRepo, 'me/fork');
      expect(
        ServerConfig.resolve(
          cli: parseInvocation(['--auto-update', 'beta']).overrides,
        ).autoUpdate,
        'beta',
      );
      expect(() => ServerConfig.resolve(file: {'auto_update': 'nightly'}),
          throwsA(isA<ConfigException>()));
      expect(() => ServerConfig.resolve(file: {'update_repo': 'no slash'}),
          throwsA(isA<ConfigException>()));
      expect(defaultConfigYaml(), contains('# auto_update: stable'));
      expect(parseInvocation(['update', '--dry-run']).dryRun, isTrue);
      expect(parseInvocation(['--version']).version, isTrue);
      expect(d.describe(), contains('auto_update'));
    });

    test('the update units run the binary with the config, every six hours',
        () {
      final l = SystemdLayout.system();
      final svc = renderUpdateService(
        l,
        exe: '/opt/xprs-server/xprs-server',
        configPath: l.configPath,
      );
      expect(svc, contains('Type=oneshot'));
      expect(
        svc,
        contains(
          'ExecStart=/opt/xprs-server/xprs-server update --config /etc/xprs-server/config.yaml',
        ),
      );
      expect(svc, isNot(contains('User=')));
      final timer = renderUpdateTimer(l);
      expect(timer, contains('OnUnitActiveSec=6h'));
      expect(timer, contains('WantedBy=timers.target'));
      expect(l.updateTimerPath, '/etc/systemd/system/xprs-server-update.timer');
      expect(
        SystemdLayout.user('/home/a').updateServicePath,
        '/home/a/.config/systemd/user/xprs-server-update.service',
      );
    });

    test('install and uninstall steps carry the timer', () async {
      const o = ServiceOptions(
        scope: ServiceScope.user,
        exePath: '/x/xprs-server',
        dryRun: true,
      );
      final b = SystemdBackend();
      final inst =
          (await b.installSteps(o)).map((s) => s.description).join('\n');
      expect(inst, contains('xprs-server-update.timer'));
      expect(inst, contains('enable the update timer'));
      final un =
          (await b.uninstallSteps(o)).map((s) => s.description).join('\n');
      expect(un, contains('update'));
    });
  });

  group('Updater against a local GitHub', () {
    late HttpServer srv;
    late Directory dir;
    late String exe;
    final newBytes = utf8.encode('the new server binary');
    var shaBody = '';
    var releasesJson = '';

    String url(String p) => 'http://127.0.0.1:${srv.port}$p';

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('xprs-upd');
      exe = '${dir.path}/xprs-server';
      File(exe).writeAsStringSync('the old server binary');
      srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      shaBody =
          '${crypto.sha256.convert(newBytes)}  xprs-server-linux-arm64\n';
      releasesJson = jsonEncode({
        'tag_name': 'v0.4.0',
        'prerelease': false,
        'draft': false,
        'assets': [
          {
            'name': 'xprs-server-linux-arm64',
            'browser_download_url': url('/dl/xprs-server-linux-arm64'),
          },
          {
            'name': 'xprs-server-linux-arm64.sha256',
            'browser_download_url': url('/dl/xprs-server-linux-arm64.sha256'),
          },
        ],
      });
      srv.listen((req) {
        final p = req.uri.path;
        if (p == '/repos/o/r/releases/latest') {
          expect(req.headers.value(HttpHeaders.userAgentHeader),
              startsWith('xprs-server/'));
          req.response.write(releasesJson);
        } else if (p == '/dl/xprs-server-linux-arm64') {
          req.response.add(newBytes);
        } else if (p == '/dl/xprs-server-linux-arm64.sha256') {
          req.response.write(shaBody);
        } else {
          req.response.statusCode = 404;
        }
        req.response.close();
      });
    });

    tearDown(() async {
      await srv.close(force: true);
      await dir.delete(recursive: true);
    });

    Updater make({String current = '0.3.0'}) => Updater(
          channel: UpdateChannel.stable,
          current: current,
          exePath: exe,
          repo: 'o/r',
          api: url(''),
          arch: 'arm64',
          log: (_) {},
          settleTime: Duration.zero,
        );

    test('a newer release is installed, the old binary kept, the service '
        'restarted', () async {
      final u = make();
      final c = await u.check();
      expect(c.newer, isTrue);
      expect(c.describe('arm64'), contains('0.4.0 is newer'));
      var restarts = 0;
      final ok = await u.apply(
        c,
        restart: () async => restarts++,
        healthy: () async => true,
      );
      expect(ok, isTrue);
      expect(restarts, 1);
      expect(File(exe).readAsBytesSync(), newBytes);
      expect(File('$exe.prev').readAsStringSync(), 'the old server binary');
      expect(File('$exe.new').existsSync(), isFalse);
      final mode = (await Process.run('stat', ['-c', '%a', exe])).stdout;
      expect((mode as String).trim(), '755');
    });

    test('the same or an older version installs nothing', () async {
      final u = make(current: '0.4.0');
      final c = await u.check();
      expect(c.newer, isFalse);
      expect(c.describe('arm64'), contains('up to date'));
      expect(await u.apply(c, restart: () async {}), isFalse);
      expect(File(exe).readAsStringSync(), 'the old server binary');
      expect((await make(current: '0.5.0').check()).newer, isFalse);
    });

    test('a digest mismatch installs nothing', () async {
      shaBody = '${'0' * 64}  xprs-server-linux-arm64\n';
      final u = make();
      final c = await u.check();
      await expectLater(
        u.apply(c, restart: () async {}),
        throwsA(isA<UpdateException>()
            .having((e) => e.message, 'message', contains('digest mismatch'))),
      );
      expect(File(exe).readAsStringSync(), 'the old server binary');
      expect(File('$exe.new').existsSync(), isFalse);
      expect(File('$exe.prev').existsSync(), isFalse);
    });

    test('a release without the binary for this machine installs nothing',
        () async {
      final u = Updater(
        channel: UpdateChannel.stable,
        current: '0.3.0',
        exePath: exe,
        repo: 'o/r',
        api: url(''),
        arch: 'x64',
        log: (_) {},
      );
      final c = await u.check();
      expect(c.newer, isTrue);
      expect(c.assetUrl, isNull);
      expect(c.describe('x64'), contains('has no xprs-server-linux-x64'));
      await expectLater(u.apply(c), throwsA(isA<UpdateException>()));
      expect(File(exe).readAsStringSync(), 'the old server binary');
    });

    test('when the service does not come up the old binary returns', () async {
      final u = make();
      final c = await u.check();
      var restarts = 0;
      await expectLater(
        u.apply(
          c,
          restart: () async => restarts++,
          healthy: () async => false,
        ),
        throwsA(isA<UpdateException>()
            .having((e) => e.message, 'message', contains('did not start'))),
      );
      expect(restarts, 2);
      expect(File(exe).readAsStringSync(), 'the old server binary');
      expect(File('$exe.failed').readAsBytesSync(), newBytes);
    });

    test('channel off asks nothing', () async {
      final u = Updater(
        channel: UpdateChannel.off,
        current: '0.3.0',
        exePath: exe,
        api: 'http://127.0.0.1:1',
        arch: 'arm64',
        log: (_) {},
      );
      expect((await u.check()).release, isNull);
    });
  });
}

ReleaseInfo _rel(String tag, {bool prerelease = false, bool draft = false}) =>
    ReleaseInfo(tag: tag, prerelease: prerelease, draft: draft, assets: const {});
