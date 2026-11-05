/*
 * The web chat over HTTP: the page from xprs-dev/webchat at `/`, and the
 * core's WebChatApi at `/api/...`. The socket half only; every rule about what
 * a visitor may read or post lives in WebChatApi (core), which the app's share
 * server uses too.
 *
 * Plain HTTP, or HTTPS with [startSecure]. Two transport chores live here
 * too, no rules of the visitor API: answering ACME HTTP-01 challenges
 * ([acmeChallenges], for the server's own certificate) and sending a visitor
 * who came by the public name to HTTPS once there is a certificate
 * ([redirectHosts]).
 */
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xprs_core/src/connections/internet/public_name/public_name.dart';
import 'package:xprs_core/src/services/log_service.dart';
import 'package:xprs_core/src/services/web_chat_api.dart';

class WebChatServer implements AcmeWebServer {
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

  // AcmeWebServer (core public_name): the public-name service drives these.
  @override
  final Map<String, String> acmeChallenges = {};
  @override
  Set<String> redirectHosts = {};
  @override
  int httpsPort = 443;
  @override
  bool challengesViaHttps = false;
  bool _tls = false;

  Future<void> start({required int port, String address = '0.0.0.0'}) =>
      _bind(HttpServer.bind(address, port, shared: false), address);

  /// HTTPS with a PEM certificate chain and private key.
  @override
  Future<void> startSecure({
    required int port,
    required String address,
    required List<int> certificateChain,
    required List<int> privateKey,
  }) {
    final ctx = SecurityContext()
      ..useCertificateChainBytes(certificateChain)
      ..usePrivateKeyBytes(privateKey);
    return _bind(HttpServer.bindSecure(address, port, ctx, shared: false),
        address, tls: true);
  }

  Future<void> _bind(Future<HttpServer> bind, String address,
      {bool tls = false}) async {
    final s = await bind;
    _tls = tls;
    // A browser that went away leaves a socket behind; do not keep it long.
    s.idleTimeout = const Duration(seconds: 20);
    s.listen(_handle, onError: (_) {});
    _server = s;
    LogService.instance
        .add('web chat: serving ${tls ? 'https' : 'http'} on $address:${s.port}');
  }

  @override
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      final read = req.method == 'GET' || req.method == 'HEAD';
      const acme = '/.well-known/acme-challenge/';
      final host = (req.headers.host ?? '').toLowerCase();
      if (read && path.startsWith(acme)) {
        final ka = acmeChallenges[path.substring(acme.length)];
        if (ka != null && challengesViaHttps && !_tls) {
          await res.redirect(Uri.parse('https://$host${req.uri}'));
          return;
        }
        res.statusCode = ka == null ? HttpStatus.notFound : HttpStatus.ok;
        res.headers.contentType = ContentType.text;
        if (ka != null) res.write(ka);
        await res.close();
      } else if (read && redirectHosts.contains(host)) {
        final port = httpsPort == 443 ? '' : ':$httpsPort';
        await res.redirect(Uri.parse('https://$host$port${req.uri}'),
            status: HttpStatus.movedPermanently);
      } else if (read && (path == '/' || path == '/index.html')) {
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
