// The server's half of the names keeper (XPRS.md 13.0.3): the config keys
// (the token never printed), the operator's release command, and the zxdb
// record store the core's NamesKeeper runs on.
import 'dart:io';

import 'package:test/test.dart';
import 'package:xprs_core/src/services/names/names_keeper.dart';
import 'package:xprs_server/cli/cli.dart';
import 'package:xprs_server/config/server_config.dart';
import 'package:xprs_server/host/zx_names_store.dart';

void main() {
  group('config', () {
    test('names_zone, names_token, names_keeper: defaults, validation, '
        'the token masked', () {
      final d = ServerConfig.resolve();
      expect(d.namesZone, isNull);
      expect(d.namesToken, isNull);
      expect(d.namesKeeper, 'https://names.xprs.dev');
      final c = ServerConfig.resolve(file: {
        'names_zone': 'XPRS.dev',
        'names_token': 'secret-token-value',
        'names_keeper': 'https://names.example.org/',
      });
      expect(c.namesZone, 'xprs.dev');
      expect(c.namesToken, 'secret-token-value');
      expect(c.namesKeeper, 'https://names.example.org');
      expect(c.describe(), isNot(contains('secret-token-value')));
      expect(c.describe(), contains('(set)'));
      expect(ServerConfig.resolve(file: {'names_keeper': ''}).namesKeeper, '');
      expect(
        ServerConfig.resolve(
          cli: parseInvocation(['--names-keeper', 'http://127.0.0.1:8099']).overrides,
        ).namesKeeper,
        'http://127.0.0.1:8099',
      );
      expect(() => ServerConfig.resolve(file: {'names_zone': 'nodots'}),
          throwsA(isA<ConfigException>()));
      expect(() => ServerConfig.resolve(file: {'names_keeper': 'names.xprs.dev'}),
          throwsA(isA<ConfigException>()));
      expect(() => ServerConfig.resolve(file: {'names_token': ''}),
          throwsA(isA<ConfigException>()));
      expect(defaultConfigYaml(), contains('# names_keeper: https://names.xprs.dev'));
      expect(defaultConfigYaml(), contains('# names_zone: xprs.dev'));
    });

    test('names-release takes exactly one argument', () {
      final i = parseInvocation(['names-release', 'X3ABCD']);
      expect(i.command, 'names-release');
      expect(i.argument, 'X3ABCD');
      expect(() => parseInvocation(['names-release']),
          throwsA(isA<ConfigException>()));
      expect(() => parseInvocation(['names-release', 'a', 'b']),
          throwsA(isA<ConfigException>()));
      expect(() => parseInvocation(['update', 'extra']),
          throwsA(isA<ConfigException>()));
      expect(parseInvocation(['update']).argument, isNull);
    });
  });

  test('ZxNamesStore keeps records across a reopen and lists them', () async {
    final dir = await Directory.systemTemp.createTemp('xprs-names');
    final path = '${dir.path}/names/names.zx';
    try {
      var s = ZxNamesStore.open(path);
      expect(s.get('x3abcd'), isNull);
      expect(s.all(), isEmpty);
      s.put(NamesRecord(
          label: 'x3abcd', key: 'ab' * 32, first: 1, last: 2, lastTs: 3, v4: '93.184.216.9'));
      s.put(NamesRecord(
          label: 'x1zzz', key: 'cd' * 32, first: 4, last: 5, lastTs: 6, v6: '2a02::1', dnsDirty: true));
      expect(s.get('x3abcd')!.v4, '93.184.216.9');
      expect(s.length, 2);
      s.close();
      s = ZxNamesStore.open(path);
      final all = s.all()..sort((a, b) => a.label.compareTo(b.label));
      expect(all.map((r) => r.label), ['x1zzz', 'x3abcd']);
      expect(all.first.dnsDirty, isTrue);
      expect(all.first.v6, '2a02::1');
      expect(all.last.lastTs, 3);
      final r = s.get('x3abcd')!;
      r.last = 9;
      s.put(r);
      s.remove('x1zzz');
      s.close();
      s = ZxNamesStore.open(path);
      expect(s.get('x3abcd')!.last, 9);
      expect(s.get('x1zzz'), isNull);
      expect(s.length, 1);
      s.close();
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
