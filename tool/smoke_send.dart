/*
 * Post a signed message to a running server as a web chat visitor would, and
 * read it back from the public history.
 *
 *   dart run tool/smoke_send.dart [http://127.0.0.1:80]
 *
 * The key is made here and thrown away, like a browser's: the server never
 * sees it, only the signed wire.
 */
import 'dart:convert';
import 'dart:io';

import 'package:hex/hex.dart';
import 'package:reticulum/reticulum.dart' show NostrCrypto;
import 'package:reticulum/src/util/nostr_key_generator.dart';
import 'package:xprs_core/src/services/xprs/xprs_packet.dart';
import 'package:xprs_core/src/services/xprs/xprs_sig.dart';
import 'package:xprs_core/src/services/xprs/xprs_vocab.dart' show xprsNowTs;

Future<void> main(List<String> argv) async {
  final base = argv.isEmpty ? 'http://127.0.0.1:80' : argv.first;
  final keys = NostrKeyGenerator.generateKeyPair();
  var d = BigInt.zero;
  for (final b in HEX.decode(NostrCrypto.decodeNsec(keys.nsec))) {
    d = (d << 8) | BigInt.from(b);
  }
  final text = 'smoke ${DateTime.now().millisecondsSinceEpoch}';
  final c = HttpClient();

  Future<Map<String, dynamic>> call(String method, String path,
      [String? body]) async {
    final req = await c.openUrl(method, Uri.parse('$base$path'));
    if (body != null) req.write(body);
    final res = await req.close();
    final s = await utf8.decodeStream(res);
    return {'status': res.statusCode, ...jsonDecode(s) as Map<String, dynamic>};
  }

  // An identity first, so the station can bind the callsign to its key.
  final id = xprsSign(
      XprsPacket.parse('t:identity f:${keys.callsign} ts:${xprsNowTs()} '
          'k:${keys.npub}')!,
      d);
  final r1 = await call('POST', '/api/xprs/send', id.encode());
  stdout.writeln('identity -> ${r1['status']} ${r1['ok']} ${r1['error'] ?? ''}');

  final msg = xprsSign(
      XprsPacket.parse('t:message f:${keys.callsign} ts:${xprsNowTs()} '
          'm:$text')!,
      d);
  final r2 = await call('POST', '/api/xprs/send', msg.encode());
  stdout.writeln('message  -> ${r2['status']} ${r2['ok']} ${r2['error'] ?? ''}');

  // The archive writes in batches (XprsArchive's flush timer): poll.
  var rows = <Map<String, dynamic>>[];
  var found = false;
  for (var i = 0; i < 30 && !found; i++) {
    await Future<void>.delayed(const Duration(seconds: 1));
    final h = await call('GET', '/api/xprs/history?kind=message&limit=50');
    rows = (h['rows'] as List).cast<Map<String, dynamic>>();
    found = rows.any((r) => jsonEncode(r).contains(text));
  }
  stdout.writeln('history  -> ${rows.length} rows, ours ${found ? 'FOUND' : 'MISSING'}');
  c.close();
  exit(found && r2['ok'] == true ? 0 : 1);
}
