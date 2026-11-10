// Files by reference over HTTP (API-HTTP.md): an upload is streamed into the
// store and checked against its reference, a download answers Range:, and a
// stranger keeps the visitor's limit.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:reticulum/reticulum.dart' show MediaArchive;
import 'package:test/test.dart';
import 'package:xprs_core/src/services/web_chat_api.dart';
import 'package:xprs_server/http/web_chat_server.dart';

String _ref(List<int> b, String ext) =>
    '${base64Url.encode(crypto.sha256.convert(b).bytes).replaceAll('=', '')}.$ext';

void main() {
  late Directory dir;
  late WebChatServer srv;
  late HttpClient http;

  Future<void> start(int fileMax) async {
    final store = MediaArchive.forDirectory(dir.path);
    final api = WebChatApi(
      publicRows: ({sinceMs, untilMs, required types, from, visitor, room, required limit}) => [],
      held: (t) => 0,
      receive: (_) {},
      mayAir: (_) => true,
      selfCallsign: () => 'X3TEST',
      keyOf: (_) => null,
      appPath: () => null,
      fileStore: () => store,
      fileMax: fileMax,
    );
    srv = WebChatServer(api: api, page: Uint8List.fromList(utf8.encode('<html></html>')));
    await srv.start(port: 0, address: '127.0.0.1');
  }

  Future<(int, List<int>, HttpHeaders)> req(String method, String path,
      {List<int>? body, String? range}) async {
    final r = await http.openUrl(method, Uri.parse('http://127.0.0.1:${srv.port}$path'));
    if (range != null) r.headers.set(HttpHeaders.rangeHeader, range);
    if (body != null) {
      r.contentLength = body.length;
      for (var at = 0; at < body.length; at += 100000) {
        r.add(body.sublist(at, (at + 100000).clamp(0, body.length)));
      }
    }
    final res = await r.close();
    final out = <int>[];
    await for (final c in res) {
      out.addAll(c);
    }
    return (res.statusCode, out, res.headers);
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('file_stream_');
    http = HttpClient();
  });
  tearDown(() async {
    http.close(force: true);
    await srv.stop();
    dir.deleteSync(recursive: true);
  });

  test('a large file goes in streamed, comes back whole and by range', () async {
    await start(64 << 20);
    final data = List<int>.generate(9 << 20, (i) => i * 31 & 0xff);
    final ref = _ref(data, 'mp4');
    final (st, body, _) = await req('POST', '/api/xprs/file/$ref', body: data);
    expect(st, 200, reason: utf8.decode(body));
    final (st2, all, h2) = await req('GET', '/api/xprs/file/$ref');
    expect(st2, 200);
    expect(all.length, data.length);
    expect(all, data);
    expect(h2.value(HttpHeaders.acceptRangesHeader), 'bytes');
    expect(h2.contentType!.mimeType, 'video/mp4');
    final (st3, part, h3) = await req('GET', '/api/xprs/file/$ref', range: 'bytes=5000000-5000099');
    expect(st3, 206);
    expect(part, data.sublist(5000000, 5000100));
    expect(h3.value(HttpHeaders.contentRangeHeader), 'bytes 5000000-5000099/${data.length}');
    final (st4, tail, _) = await req('GET', '/api/xprs/file/$ref', range: 'bytes=-10');
    expect(st4, 206);
    expect(tail, data.sublist(data.length - 10));
  });

  test('bytes that are not the reference are refused; a stranger keeps the limit', () async {
    await start(1 << 20);
    final data = List<int>.filled(2 << 20, 7);
    final (st, _, _) = await req('POST', '/api/xprs/file/${_ref(data, 'jpg')}', body: data);
    expect(st, 413);
    final small = List<int>.filled(1000, 1);
    final (st2, _, _) = await req('POST', '/api/xprs/file/${_ref(List<int>.filled(1000, 2), 'jpg')}', body: small);
    expect(st2, 400);
    final (st3, _, _) = await req('GET', '/api/xprs/file/${_ref(small, 'jpg')}');
    expect(st3, 404);
  });
}
