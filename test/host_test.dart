import 'dart:io';

import 'package:test/test.dart';
import 'package:xprs_server/host/file_key_value_store.dart';
import 'package:xprs_server/station.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('xprs_kv'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('settings survive a reopen, every type', () async {
    final path = '${dir.path}/s.json';
    final a = await FileKeyValueStore.open(path);
    await a.setBool('b', true);
    await a.setInt('i', 42);
    await a.setDouble('d', 1.5);
    await a.setString('s', 'x');
    await a.setStringList('l', ['p', 'q']);
    await a.remove('s');
    final b = await FileKeyValueStore.open(path);
    expect(b.getBool('b'), true);
    expect(b.getInt('i'), 42);
    expect(b.getDouble('d'), 1.5);
    expect(b.getString('s'), isNull);
    expect(b.getStringList('l'), ['p', 'q']);
    expect(File('$path.tmp').existsSync(), isFalse);
  });

  test('writes that overlap all land, none races another', () async {
    final path = '${dir.path}/s.json';
    final a = await FileKeyValueStore.open(path);
    final futures = <Future<bool>>[];
    for (var i = 0; i < 50; i++) {
      futures.add(a.setInt('k$i', i));
      if (i % 7 == 0) await Future<void>.delayed(Duration.zero);
    }
    await Future.wait(futures);
    final b = await FileKeyValueStore.open(path);
    for (var i = 0; i < 50; i++) {
      expect(b.getInt('k$i'), i);
    }
  });

  test('a damaged file is kept aside and the store starts empty', () async {
    final path = '${dir.path}/s.json';
    File(path).writeAsStringSync('{not json');
    final s = await FileKeyValueStore.open(path);
    expect(s.getKeys(), isEmpty);
    expect(File('$path.damaged').existsSync(), isTrue);
  });

  test('hub entries', () {
    expect(parseHostPort('hub.example:4965'), ('hub.example', 4965));
    expect(parseHostPort('hub.example'), ('hub.example', 4242));
    expect(parseHostPort('  '), isNull);
  });
}
