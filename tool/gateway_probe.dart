// A Reticulum client through a gateway, as the browser will be one
// (portal/docs/plan-browser-reticulum.md): connect to ws(s)://<host>/rns,
// resolve a station's callsign, open a link to it and call its API.
//
//   dart run tool/gateway_probe.dart ws://127.0.0.1/rns X3PTZM
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:reticulum/reticulum.dart';

Future<void> main(List<String> args) async {
  final url = args.isNotEmpty ? args[0] : 'ws://127.0.0.1/rns';
  final call = (args.length > 1 ? args[1] : 'X3PTZM').toUpperCase();
  final sw = Stopwatch()..start();
  String t() => '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(2)}s';
  final ws = await WebSocket.connect(url);
  final control = StreamController<Map<String, dynamic>>.broadcast();
  final gw = RnsGatewayClient((f) => ws.add(f), log: (m) => stdout.writeln('  rns: $m'));
  ws.listen((m) {
    if (m is List<int>) {
      gw.onFrame(Uint8List.fromList(m));
    } else if (m is String) {
      control.add(jsonDecode(m) as Map<String, dynamic>);
    }
  });
  Future<Map<String, dynamic>> ask(Map<String, Object?> j) async {
    final f = control.stream.first;
    ws.add(jsonEncode(j));
    return f.timeout(const Duration(seconds: 10));
  }

  final hello = await ask({'op': 'hello'});
  stdout.writeln('${t()} gateway: $hello');
  final r = await ask({'op': 'resolve', 'call': call});
  stdout.writeln('${t()} resolved: rns ${r['rns'] == null ? 'unknown' : '${(r['rns'] as String).substring(0, 16)}..'}'
      ', identity ${r['identity'] == null ? 'none' : 'yes'}, beacon ${r['beacon'] == null ? 'none' : 'yes'}');
  if (r['rns'] == null) {
    stdout.writeln('the gateway does not know $call on Reticulum');
    exit(1);
  }
  final pub = Uint8List.fromList(List.generate(64, (i) => int.parse((r['rns'] as String).substring(2 * i, 2 * i + 2), radix: 16)));
  final c = gw.client(RnsIdentity.fromPublicKey(pub));
  final ok = await c.open();
  stdout.writeln('${t()} link: ${ok ? 'open' : 'FAILED'}');
  if (!ok) exit(1);
  final nonce = 'n${DateTime.now().microsecondsSinceEpoch}';
  final proof = await c.request('/xprs/prove', nonce);
  final linkHex = c.linkId!.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  if (proof is Map) {
    final sess = '${proof['session']}';
    stdout.writeln('${t()} proof: ${sess.contains('m:$linkHex.$nonce') ? 'names this link and nonce' : 'DOES NOT name this link'}: ${sess.substring(0, 60)}..');
    stdout.writeln('${t()} identity: ${'${proof['identity']}'.substring(0, 60)}..');
  } else {
    stdout.writeln('${t()} proof: none');
  }
  for (final path in ['/api/services', '/api/xprs/history']) {
    final s0 = sw.elapsedMilliseconds;
    final resp = await c.request('/xprs/api', {'m': 'GET', 'p': path, 'q': {'limit': '20'}});
    if (resp is! Map) {
      stdout.writeln('${t()} $path: no answer');
      continue;
    }
    final body = resp['b'];
    final text = body is List<int> ? utf8.decode(body, allowMalformed: true) : '$body';
    stdout.writeln('${t()} $path: ${resp['s']} ${text.length} bytes in ${sw.elapsedMilliseconds - s0} ms: '
        '${text.substring(0, text.length < 100 ? text.length : 100)}');
  }
  gw.drop(c);
  await ws.close();
  exit(0);
}
