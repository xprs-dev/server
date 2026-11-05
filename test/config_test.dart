import 'dart:io';

import 'package:test/test.dart';
import 'package:xprs_server/autostart/autostart.dart';
import 'package:xprs_server/autostart/systemd.dart';
import 'package:xprs_server/cli/cli.dart';
import 'package:xprs_server/config/server_config.dart';
import 'package:xprs_server/web/embedded_page.dart';

void main() {
  group('ServerConfig', () {
    test('public name options: defaults, file, flags, validation', () {
      final d = ServerConfig.resolve();
      expect(d.publicName, isTrue);
      expect(d.httpsPort, 443);
      expect(d.upnp, isTrue);
      expect(d.acmeEmail, isNull);
      expect(d.acmeStaging, isFalse);
      expect(d.httpAddress, '::');
      final c = ServerConfig.resolve(
        file: {'public_name': false, 'acme_email': 'op@example.org'},
        cli: parseInvocation(
                ['--https-port', '8443', '--no-upnp', '--acme-staging'])
            .overrides,
      );
      expect(c.publicName, isFalse);
      expect(c.acmeEmail, 'op@example.org');
      expect(c.httpsPort, 8443);
      expect(c.upnp, isFalse);
      expect(c.acmeStaging, isTrue);
      expect(() => ServerConfig.resolve(file: {'acme_email': 'nope'}),
          throwsA(isA<ConfigException>()));
      expect(() => ServerConfig.resolve(file: {'https_port': 0}),
          throwsA(isA<ConfigException>()));
      expect(defaultConfigYaml(), contains('# public_name: true'));
    });

    test('defaults', () {
      final c = ServerConfig.resolve();
      expect(c.httpPort, 80);
      expect(c.rnsPort, 4242);
      expect(c.hubs, isEmpty);
      expect(c.publicArchiver, isTrue);
      expect(c.sources['http_port'], 'default');
    });

    test('command line beats file beats default, sources recorded', () {
      final c = ServerConfig.resolve(
        file: {'http_port': 8080, 'nickname': 'From file'},
        fileName: '/etc/x.yaml',
        cli: {'http_port': 9000},
      );
      expect(c.httpPort, 9000);
      expect(c.nickname, 'From file');
      expect(c.sources['http_port'], 'command line');
      expect(c.sources['nickname'], '/etc/x.yaml');
      expect(c.sources['rns_port'], 'default');
    });

    test('unknown key and bad values are errors that name the problem', () {
      expect(
        () => ServerConfig.resolve(file: {'http_prot': 1}, fileName: 'f'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains("unknown option 'http_prot'"),
          ),
        ),
      );
      expect(
        () => ServerConfig.resolve(file: {'http_port': 70000}),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => ServerConfig.resolve(file: {'http_port': '80'}),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => ServerConfig.resolve(file: {'public_archiver': 'yes'}),
        throwsA(isA<ConfigException>()),
      );
    });

    test('there is no option to serve another page', () {
      expect(() => ServerConfig.resolve(file: {'page': '/tmp/x.html'}),
          throwsA(isA<ConfigException>()));
      expect(() => parseInvocation(['--page', '/tmp/x.html']),
          throwsA(isA<FormatException>()));
    });

    test('a key left empty is "not set"; one hub string becomes a list', () {
      final c = ServerConfig.resolve(
        file: {'log_file': null, 'hubs': 'a.example:4242'},
      );
      expect(c.logFile, isNull);
      expect(c.hubs, ['a.example:4242']);
    });
  });

  group('config files', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('xprs_cfg'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('the generated default file parses and means the defaults', () {
      final f = File('${dir.path}/c.yaml')
        ..writeAsStringSync(defaultConfigYaml());
      final c = ServerConfig.resolve(file: loadConfigFile(f.path));
      expect(c.httpPort, 80);
      expect(c.dataDir, isNull);
    });

    test('service config sets port and data_dir live', () {
      final f = File('${dir.path}/c.yaml')
        ..writeAsStringSync(defaultConfigYaml(httpPort: 8080, dataDir: '/d'));
      final c = ServerConfig.resolve(file: loadConfigFile(f.path));
      expect(c.httpPort, 8080);
      expect(c.dataDir, '/d');
    });

    test('hubs list, empty file, and broken yaml', () {
      final f = File('${dir.path}/c.yaml');
      f.writeAsStringSync('hubs:\n  - a:1\n  - b\n');
      expect(loadConfigFile(f.path)['hubs'], ['a:1', 'b']);
      f.writeAsStringSync('');
      expect(loadConfigFile(f.path), isEmpty);
      f.writeAsStringSync('just a string');
      expect(() => loadConfigFile(f.path), throwsA(isA<ConfigException>()));
      f.writeAsStringSync('a: [unclosed');
      expect(() => loadConfigFile(f.path), throwsA(isA<ConfigException>()));
    });

    test('lookup: explicit must exist; env; search order', () {
      final f = File('${dir.path}/c.yaml')..writeAsStringSync('');
      expect(findConfigFile(explicit: f.path, env: {}), f.path);
      expect(
        () => findConfigFile(explicit: '${dir.path}/nope', env: {}),
        throwsA(isA<ConfigException>()),
      );
      expect(findConfigFile(env: {'XPRS_SERVER_CONFIG': f.path}), f.path);
      expect(configSearchPaths(env: {'XDG_CONFIG_HOME': '/x'}, home: '/h'), [
        '/x/xprs-server/config.yaml',
        '/h/.config/xprs-server/config.yaml',
        '/etc/xprs-server/config.yaml',
      ]);
    });
  });

  group('command line', () {
    test('no command is run; only typed flags become overrides', () {
      final i = parseInvocation([
        '--http-port',
        '8080',
        '--hub',
        'a',
        '--hub',
        'b',
      ]);
      expect(i.command, 'run');
      expect(i.overrides, {
        'http_port': 8080,
        'hubs': ['a', 'b'],
      });
    });

    test('flags map to config keys', () {
      final i = parseInvocation([
        'print-config',
        '--no-public-archiver',
        '--data-dir',
        '/d',
        '--log-file',
        '/l',
        '--config',
        '/c.yaml',
      ]);
      expect(i.command, 'print-config');
      expect(i.overrides['public_archiver'], false);
      expect(i.overrides['data_dir'], '/d');
      expect(i.overrides['log_file'], '/l');
      expect(i.configPath, '/c.yaml');
    });

    test('bad port, unknown command, system+user are errors', () {
      expect(
        () => parseInvocation(['--http-port', 'x']),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => parseInvocation(['--rns-port', '0']),
        throwsA(isA<ConfigException>()),
      );
      expect(() => parseInvocation(['dance']), throwsA(isA<ConfigException>()));
      expect(
        () => parseInvocation(['install-service', '--system', '--user']),
        throwsA(isA<ConfigException>()),
      );
      expect(() => parseInvocation(['--nope']), throwsFormatException);
    });

    test('service scope', () {
      expect(parseInvocation(['install-service']).scope, isNull);
      expect(
        parseInvocation(['install-service', '--user']).scope,
        ServiceScope.user,
      );
    });
  });

  group('systemd', () {
    test('system unit: own user, capability, sandbox, boot target', () {
      final l = SystemdLayout.system();
      final u = renderUnit(
        l,
        exe: '/opt/xprs-server/xprs-server',
        configPath: l.configPath,
      );
      expect(u, contains('User=xprs'));
      expect(u, contains('Environment=HOME=/var/lib/xprs-server'));
      expect(
        u,
        contains(
          'ExecStart=/opt/xprs-server/xprs-server --config /etc/xprs-server/config.yaml',
        ),
      );
      expect(u, contains('AmbientCapabilities=CAP_NET_BIND_SERVICE'));
      expect(u, contains('WantedBy=multi-user.target'));
    });

    test('user unit: no User, no capabilities, default.target, quoted path', () {
      final l = SystemdLayout.user('/home/a b');
      final u = renderUnit(
        l,
        exe: '/home/a b/xprs-server',
        configPath: l.configPath,
      );
      expect(u, isNot(contains('User=')));
      expect(u, isNot(contains('CAP_NET_BIND_SERVICE')));
      expect(u, contains('WantedBy=default.target'));
      expect(
        u,
        contains(
          'ExecStart="/home/a b/xprs-server" --config "/home/a b/.config/xprs-server/config.yaml"',
        ),
      );
      expect(l.defaultHttpPort, 8080);
      expect(l.unitPath, '/home/a b/.config/systemd/user/xprs-server.service');
    });

    test('dry run lists steps and touches nothing', () async {
      final steps = await SystemdBackend().installSteps(
        const ServiceOptions(
          scope: ServiceScope.user,
          exePath: '/x/xprs-server',
          dryRun: true,
        ),
      );
      expect(
        steps.map((s) => s.description).join('\n'),
        allOf(contains('write'), contains('enable at boot')),
      );
    });
  });

  test('the page inside the program is web/chat_page.html (run '
      'tool/sync_web_chat.sh if this fails)', () {
    expect(embeddedPage(), File('web/chat_page.html').readAsBytesSync());
  });
}
