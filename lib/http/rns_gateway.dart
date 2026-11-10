/*
 * The gateway (portal/docs/plan-browser-reticulum.md): a browser connects by
 * WebSocket to /rns and becomes a client of this server's Reticulum node.
 * A binary message is one Reticulum packet each way; the browser is a quiet
 * interface (no announce flood), so it gets what it asks for and nothing
 * else. A text message is a JSON control frame:
 *
 *   {"op":"hello"}               -> {"op":"gateway","station":"X3PTZM"}
 *   {"op":"resolve","call":"X3PTZM"}
 *       -> {"op":"resolved","call":..,"rns":<64-byte public key hex>|null,
 *           "identity":<its signed t:identity wire>|null,
 *           "beacon":<its latest signed beacon carrying lx:>|null}
 *
 * The browser checks what `resolved` says (the wires' signatures against the
 * callsign's key, `lx:` against the Reticulum identity): a gateway cannot
 * hand it another station. Limits per client keep one browser from taking
 * the node.
 */
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:reticulum/reticulum.dart' show RnsDestination;
import 'package:xprs_core/src/services/log_service.dart';
import 'package:xprs_core/src/services/reticulum/rns_service.dart';
import 'package:xprs_core/src/services/web_chat_api.dart';

class RnsGateway {
  RnsGateway({required this.api, required this.station, this.maxClients = 32});

  final WebChatApi api;
  final String Function() station;
  final int maxClients;

  /// Per client: frames and bytes in a minute.
  static const int framesPerMinute = 3000;
  static const int bytesPerMinute = 8 << 20;

  int _seq = 0;
  int get clients => _open;
  int _open = 0;

  Future<void> serve(HttpRequest req) async {
    final res = req.response;
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      res.statusCode = HttpStatus.badRequest;
      res.write('a WebSocket for Reticulum frames');
      await res.close();
      return;
    }
    if (_open >= maxClients) {
      res.statusCode = HttpStatus.serviceUnavailable;
      await res.close();
      return;
    }
    final WebSocket ws;
    try {
      ws = await WebSocketTransformer.upgrade(req);
    } catch (_) {
      return;
    }
    ws.pingInterval = const Duration(seconds: 30);
    final label = 'ws#${++_seq}';
    final fc = RnsService.instance.attachFrameClient(label, (f) {
      if (ws.readyState == WebSocket.open) ws.add(f);
    });
    if (fc == null) {
      await ws.close(1013, 'Reticulum is not up');
      return;
    }
    _open++;
    LogService.instance.add('gateway: $label connected ($_open open)');
    var windowStart = DateTime.now().millisecondsSinceEpoch, frames = 0, bytes = 0;
    ws.listen((m) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - windowStart > 60000) {
        windowStart = now;
        frames = 0;
        bytes = 0;
      }
      if (m is List<int>) {
        frames++;
        bytes += m.length;
        if (frames > framesPerMinute || bytes > bytesPerMinute) return; // dropped
        await fc.deliver(Uint8List.fromList(m));
      } else if (m is String) {
        final reply = await _control(m);
        if (reply != null && ws.readyState == WebSocket.open) {
          ws.add(jsonEncode(reply));
          // Asked for this very station: hand the client its announce now,
          // so its path is there without waiting on the hubs' budget.
          if (reply['op'] == 'resolved' && reply['call'] == station().toUpperCase()) {
            final a = await RnsService.instance.ownWappAnnounce();
            if (a != null) fc.iface.send(a);
          }
        }
      }
    }, onDone: () {
      fc.detach();
      _open--;
      LogService.instance.add('gateway: $label gone (${fc.framesIn} in, ${fc.iface.framesOut} out)');
    }, onError: (_) {}, cancelOnError: true);
  }

  Future<Map<String, Object?>?> _control(String text) async {
    Map<String, dynamic> j;
    try {
      j = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
    switch (j['op']) {
      case 'hello':
        return {'op': 'gateway', 'station': station()};
      case 'resolve':
        final call = '${j['call'] ?? ''}'.trim().toUpperCase();
        if (call.isEmpty) return {'op': 'resolved', 'call': call};
        final rns = RnsService.instance;
        final id = rns.stationIdentity(call);
        // A station elsewhere: ask for its path now and answer once it is
        // held (up to 12 s), so the client's own path request finds it here.
        if (id != null && call != station().toUpperCase()) {
          final dest = _hex(RnsDestination.hash(id, 'xprs', const ['wapp']));
          if (!rns.hasPathTo(dest)) {
            rns.requestPathIfUnknown(dest);
            for (var i = 0; i < 40 && !rns.hasPathTo(dest); i++) {
              await Future<void>.delayed(const Duration(milliseconds: 300));
            }
          }
        }
        final r = await api.handle('GET', '/api/xprs/history',
            {'call': call, 'kind': 'identity,observation', 'limit': '60'}, '',
            peer: 'gateway');
        String? identity, beacon;
        final rows = r.json['rows'];
        if (rows is List) {
          for (final row in rows) {
            final w = row is Map ? '${row['wire'] ?? ''}' : '';
            if (identity == null && w.startsWith('t:identity ') && w.contains(' sig:')) identity = w;
            if (beacon == null && w.contains(' lx:') && w.contains(' sig:')) beacon = w;
          }
        }
        return {
          'op': 'resolved',
          'call': call,
          'rns': id == null ? null : _hex(id.getPublicKey()),
          'identity': identity,
          'beacon': beacon,
        };
    }
    return null;
  }

  static String _hex(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
