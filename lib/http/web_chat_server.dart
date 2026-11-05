/*
 * The web chat over HTTP: the page from xprs-dev/webchat at `/`, and the
 * core's WebChatApi at `/api/...`. The socket half only; every rule about what
 * a visitor may read or post lives in WebChatApi (core), which the app's share
 * server uses too.
 *
 * Plain HTTP. On a public address, put TLS in front (deploy/README.md).
 */
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xprs_core/src/services/log_service.dart';
import 'package:xprs_core/src/services/web_chat_api.dart';

class WebChatServer {
  WebChatServer({required this.api, required Uint8List page})
      : _html = page,
        _gz = Uint8List.fromList(gzip.encode(page));

  final WebChatApi api;
  final Uint8List _html;
  final Uint8List _gz;
  HttpServer? _server;

  /// Largest body a visitor may post: a signed wire is well under this.
  static const int maxBody = 8192;

  int get port => _server?.port ?? 0;

  Future<void> start({required int port, String address = '0.0.0.0'}) async {
    final s = await HttpServer.bind(address, port, shared: false);
    // A browser that went away leaves a socket behind; do not keep it long.
    s.idleTimeout = const Duration(seconds: 20);
    s.listen(_handle, onError: (_) {});
    _server = s;
    LogService.instance.add('web chat: serving on $address:${s.port}');
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      final read = req.method == 'GET' || req.method == 'HEAD';
      if (read && (path == '/' || path == '/index.html')) {
        await _page(req);
      } else if (path.startsWith('/api/')) {
        await _api(req);
      } else {
        res.statusCode = HttpStatus.notFound;
        await res.close();
      }
    } catch (_) {
      try {
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> _page(HttpRequest req) async {
    final res = req.response;
    final takesGzip = (req.headers.value(HttpHeaders.acceptEncodingHeader) ?? '')
        .toLowerCase()
        .contains('gzip');
    final body = takesGzip ? _gz : _html;
    res.headers
      ..contentType = ContentType('text', 'html', charset: 'utf-8')
      ..contentLength = body.length
      ..set(HttpHeaders.cacheControlHeader, 'no-cache');
    if (takesGzip) res.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
    if (req.method != 'HEAD') res.add(body);
    await res.close();
  }

  Future<void> _api(HttpRequest req) async {
    final res = req.response;
    var body = '';
    if (req.method == 'POST') {
      if (req.contentLength > maxBody) {
        res.statusCode = HttpStatus.requestEntityTooLarge;
        await res.close();
        return;
      }
      final chunks = <int>[];
      await for (final c in req) {
        chunks.addAll(c);
        if (chunks.length > maxBody) {
          res.statusCode = HttpStatus.requestEntityTooLarge;
          await res.close();
          return;
        }
      }
      body = utf8.decode(chunks, allowMalformed: true);
    }
    // Behind a reverse proxy the socket's peer is the proxy; the per-visitor
    // rate limit wants the visitor. Trusted only from loopback.
    var peer = req.connectionInfo?.remoteAddress.address ?? '';
    final fwd = req.headers.value('x-forwarded-for');
    if (fwd != null && (peer == '127.0.0.1' || peer == '::1')) {
      peer = fwd.split(',').first.trim();
    }
    final reply = await api.handle(
        req.method, req.uri.path, req.uri.queryParameters, body,
        peer: peer);
    final bytes = utf8.encode(jsonEncode(reply.json));
    res
      ..statusCode = reply.status
      ..headers.contentType = ContentType.json
      ..headers.set('Access-Control-Allow-Origin', '*')
      ..contentLength = bytes.length
      ..add(bytes);
    await res.close();
  }
}
