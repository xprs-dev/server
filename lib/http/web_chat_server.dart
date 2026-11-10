/*
 * The web chat over HTTP: the page from xprs-dev/portal at `/`, and the
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
import 'rns_gateway.dart';
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
  /// The Reticulum gateway at /rns, when this server is one.
  RnsGateway? gateway;
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
      } else if (path == '/rns' && gateway != null) {
        // Reticulum for browsers (rns_gateway.dart), on HTTP and HTTPS alike.
        await gateway!.serve(req);
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

  /// A file by reference, streamed both ways (API-HTTP.md): an upload goes
  /// into the store a part at a time, a download is read a part at a time and
  /// answers `Range:`, so a film plays and seeks without the server ever
  /// holding it whole.
  Future<bool> _file(HttpRequest req, String peer) async {
    final res = req.response;
    final ref = req.uri.path.substring(WebChatApi.filePath.length);
    if (req.method == 'POST') {
      final up = api.beginFilePut(ref, req.uri.queryParameters, peer,
          req.contentLength < 0 ? 0 : req.contentLength);
      if (up.reply != null) {
        await _json(res, up.reply!);
        return true;
      }
      try {
        await for (final c in req) {
          up.add(c);
        }
      } catch (_) {
        up.abort();
        rethrow;
      }
      await _json(res, up.finish());
      return true;
    }
    if (req.method != 'GET' && req.method != 'HEAD') return false;
    final f = api.openFile(ref);
    if (f.reply != null) {
      await _json(res, f.reply!);
      return true;
    }
    var start = 0, end = f.size - 1;
    final range = req.headers.value(HttpHeaders.rangeHeader);
    final m = range == null ? null : RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range.trim());
    if (m != null && f.size > 0) {
      final a = m.group(1)!, b = m.group(2)!;
      if (a.isEmpty && b.isNotEmpty) {
        start = (f.size - int.parse(b)).clamp(0, f.size - 1);
      } else if (a.isNotEmpty) {
        start = int.parse(a);
        if (b.isNotEmpty) end = int.parse(b).clamp(start, f.size - 1);
      }
      if (start >= f.size) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */${f.size}');
        await res.close();
        return true;
      }
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/${f.size}');
    } else {
      res.statusCode = HttpStatus.ok;
    }
    res.headers.set(HttpHeaders.contentTypeHeader, f.contentType);
    res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    res.headers.set('Access-Control-Allow-Origin', '*');
    f.headers.forEach(res.headers.set);
    res.contentLength = f.size == 0 ? 0 : end - start + 1;
    if (req.method != 'HEAD') {
      const step = 256 << 10;
      for (var at = start; at <= end; at += step) {
        final n = (end - at + 1).clamp(0, step);
        final part = f.read(at, n);
        if (part == null) break;
        res.add(part);
        await res.flush();
      }
    }
    await res.close();
    return true;
  }

  Future<void> _json(HttpResponse res, WebChatReply reply) async {
    final bytes = utf8.encode(jsonEncode(reply.json));
    res
      ..statusCode = reply.status
      ..headers.contentType = ContentType.json
      ..headers.set('Access-Control-Allow-Origin', '*')
      ..contentLength = bytes.length
      ..add(bytes);
    await res.close();
  }

  Future<void> _api(HttpRequest req) async {
    final res = req.response;
    var body = '';
    Uint8List? raw;
    // Behind a reverse proxy the socket's peer is the proxy; the per-visitor
    // rate limit wants the visitor. Trusted only from loopback.
    var peer = req.connectionInfo?.remoteAddress.address ?? '';
    final fwd = req.headers.value('x-forwarded-for');
    if (fwd != null && (peer == '127.0.0.1' || peer == '::1')) {
      peer = fwd.split(',').first.trim();
    }
    // A file by reference (API-HTTP.md) is bytes, streamed.
    final isFile = req.uri.path.startsWith(WebChatApi.filePath);
    if (isFile && api.fileStore != null && await _file(req, peer)) return;
    final cap = isFile ? api.fileMax : maxBody;
    if (req.method == 'POST') {
      if (req.contentLength > cap) {
        res.statusCode = HttpStatus.requestEntityTooLarge;
        await res.close();
        return;
      }
      final chunks = <int>[];
      await for (final c in req) {
        chunks.addAll(c);
        if (chunks.length > cap) {
          res.statusCode = HttpStatus.requestEntityTooLarge;
          await res.close();
          return;
        }
      }
      if (isFile) {
        raw = Uint8List.fromList(chunks);
      } else {
        body = utf8.decode(chunks, allowMalformed: true);
      }
    }
    final reply = await api.handle(
        req.method, req.uri.path, req.uri.queryParameters, body,
        peer: peer, raw: raw);
    if (reply.bytes != null) {
      res.statusCode = reply.status;
      res.headers.set(HttpHeaders.contentTypeHeader, reply.contentType!);
      res.headers.set('Access-Control-Allow-Origin', '*');
      reply.headers.forEach(res.headers.set);
      res.contentLength = reply.bytes!.length;
      if (req.method != 'HEAD') res.add(reply.bytes!);
      await res.close();
      return;
    }
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
