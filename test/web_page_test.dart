// The page the server gives visitors must be the webchat repo's page, byte
// for byte: one page for every station (firmware, app, server), maintained
// in ONE place. This fails when ../webchat changed and the server was not
// re-synced (fix: tool/sync_web_chat.sh, then rebuild).
import 'dart:io';

import 'package:test/test.dart';
import 'package:xprs_server/web/embedded_page.dart';

void main() {
  final build = File('../webchat/tool/build.py');
  test('the embedded page is the webchat build, byte for byte', () async {
    final out = await Directory.systemTemp.createTemp('webchat');
    try {
      final r = await Process.run(
          'python3', [build.path, '--out', out.path]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final fresh = File('${out.path}/chat_page.html').readAsBytesSync();
      expect(embeddedPage(), fresh,
          reason: 'the server carries a stale web chat page: '
              'run tool/sync_web_chat.sh and rebuild');
      expect(File('web/chat_page.html').readAsBytesSync(), fresh,
          reason: 'web/chat_page.html is stale: run tool/sync_web_chat.sh');
    } finally {
      await out.delete(recursive: true);
    }
  }, skip: build.existsSync() ? false : 'webchat is not checked out next to this repo');
}
