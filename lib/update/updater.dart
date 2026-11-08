/*
 * Keeping the server current from its GitHub releases (README "Update").
 *
 * The service installer adds a timer that runs `xprs-server update` every six
 * hours as the owner of the binary (root for the system service). The command
 * asks GitHub for the newest release on the channel the config names
 * (`auto_update`):
 *
 *   stable   the release GitHub marks as latest: not a draft, not a pre-release
 *   beta     the newest release of any kind
 *   off      nothing
 *
 * compares it with the running version (lib/version.dart), downloads the
 * binary for this machine (`xprs-server-linux-<arch>`) and its `.sha256`,
 * checks the digest, replaces the installed file through a temporary name in
 * the same directory (atomic; the running process keeps the old inode), keeps
 * the old binary as `.prev`, restarts the service and, when the service is not
 * running fifteen seconds later, puts the old binary back and restarts again.
 *
 * Nothing here is XPRS: it is how a headless host keeps itself current.
 * The API host can be redirected with XPRS_UPDATE_API (tests, mirrors).
 */
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

/// Where releases are asked for unless XPRS_UPDATE_API says otherwise.
const defaultUpdateApi = 'https://api.github.com';

/// The repository whose releases carry the server binary.
const defaultUpdateRepo = 'xprs-dev/server';

/// Which releases an installation follows (config `auto_update`).
enum UpdateChannel {
  stable,
  beta,
  off;

  static const names = ['stable', 'beta', 'off'];

  /// Null when [s] is not a channel name.
  static UpdateChannel? parse(String s) {
    for (final c in values) {
      if (c.name == s.trim().toLowerCase()) return c;
    }
    return null;
  }
}

class UpdateException implements Exception {
  UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Compare two version strings, pre-release aware (semver §11). Build
/// metadata (`+N`) is ignored. The same function as the app's
/// update_models.dart; a candidate for the core when a third host needs it.
int compareSemver(String a, String b) {
  a = a.split('+').first;
  b = b.split('+').first;
  final ap = a.split('-');
  final bp = b.split('-');
  List<int> core(String s) =>
      s.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  final ac = core(ap.first), bc = core(bp.first);
  for (var i = 0; i < 3; i++) {
    final x = i < ac.length ? ac[i] : 0;
    final y = i < bc.length ? bc[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  final aPre = ap.length > 1, bPre = bp.length > 1;
  if (aPre && !bPre) return -1; // 1.0.0-beta < 1.0.0
  if (!aPre && bPre) return 1;
  if (!aPre && !bPre) return 0;
  final aId = ap.sublist(1).join('-').split('.');
  final bId = bp.sublist(1).join('-').split('.');
  for (var i = 0; i < aId.length && i < bId.length; i++) {
    final an = int.tryParse(aId[i]), bn = int.tryParse(bId[i]);
    int c;
    if (an != null && bn != null) {
      c = an.compareTo(bn);
    } else if (an != null) {
      c = -1; // numeric identifiers rank lower than alphanumeric
    } else if (bn != null) {
      c = 1;
    } else {
      c = aId[i].compareTo(bId[i]);
    }
    if (c != 0) return c < 0 ? -1 : 1;
  }
  return aId.length.compareTo(bId.length).clamp(-1, 1);
}

/// The release asset name for a machine: `uname -m` says aarch64 or x86_64,
/// the release says arm64 or x64.
String machineArch([String? unameM]) {
  final m = (unameM ?? _uname()).trim();
  switch (m) {
    case 'aarch64':
    case 'arm64':
      return 'arm64';
    case 'x86_64':
    case 'amd64':
      return 'x64';
    default:
      return m;
  }
}

String _uname() {
  try {
    final r = Process.runSync('uname', ['-m']);
    if (r.exitCode == 0) return r.stdout as String;
  } on ProcessException {
    // no uname: fall through to the Dart VM's view
  }
  return Platform.version.contains('arm64') ? 'aarch64' : 'x86_64';
}

String assetName(String arch) => 'xprs-server-linux-$arch';

/// One GitHub release, the fields the updater reads.
class ReleaseInfo {
  const ReleaseInfo({
    required this.tag,
    required this.prerelease,
    required this.draft,
    required this.assets,
  });

  /// `v0.4.0`.
  final String tag;
  final bool prerelease;
  final bool draft;

  /// asset name -> download URL.
  final Map<String, String> assets;

  /// The tag without its `v`.
  String get version => tag.startsWith('v') ? tag.substring(1) : tag;

  static ReleaseInfo fromJson(Map<String, dynamic> j) {
    final assets = <String, String>{};
    for (final a in (j['assets'] as List? ?? const [])) {
      if (a is Map && a['name'] is String && a['browser_download_url'] is String) {
        assets[a['name'] as String] = a['browser_download_url'] as String;
      }
    }
    return ReleaseInfo(
      tag: (j['tag_name'] as String?) ?? '',
      prerelease: j['prerelease'] == true,
      draft: j['draft'] == true,
      assets: assets,
    );
  }
}

/// The newest release on [channel] from a list GitHub returns newest first;
/// null when there is none. Drafts never count.
ReleaseInfo? pickRelease(List<ReleaseInfo> releases, UpdateChannel channel) {
  for (final r in releases) {
    if (r.draft || r.tag.isEmpty) continue;
    if (channel == UpdateChannel.stable && r.prerelease) continue;
    if (channel == UpdateChannel.off) return null;
    return r;
  }
  return null;
}

/// What a check found.
class UpdateCheck {
  const UpdateCheck({
    required this.current,
    required this.release,
    required this.assetUrl,
    required this.shaUrl,
  });

  final String current;
  final ReleaseInfo? release;

  /// The binary for this machine and its digest file; null when the release
  /// has none.
  final String? assetUrl;
  final String? shaUrl;

  bool get newer =>
      release != null && compareSemver(release!.version, current) > 0;

  String describe(String arch) {
    final r = release;
    if (r == null) return 'running $current; no release on this channel';
    if (!newer) return 'running $current; newest is ${r.version}: up to date';
    if (assetUrl == null || shaUrl == null) {
      return 'running $current; ${r.version} is newer but has no '
          '${assetName(arch)} with its .sha256';
    }
    return 'running $current; ${r.version} is newer';
  }
}

class Updater {
  Updater({
    required this.channel,
    required this.current,
    required this.exePath,
    this.repo = defaultUpdateRepo,
    String? api,
    String? arch,
    this.log = print,
    this.settleTime = const Duration(seconds: 15),
    HttpClient? client,
  })  : api = api ?? Platform.environment['XPRS_UPDATE_API'] ?? defaultUpdateApi,
        arch = arch ?? machineArch(),
        _client = client ?? HttpClient();

  final UpdateChannel channel;
  final String current;
  final String exePath;
  final String repo;
  final String api;
  final String arch;
  final void Function(String) log;

  /// How long the restarted service gets before its health is judged.
  final Duration settleTime;
  final HttpClient _client;

  Uri _releasesUri() => Uri.parse(
        channel == UpdateChannel.stable
            ? '$api/repos/$repo/releases/latest'
            : '$api/repos/$repo/releases?per_page=20',
      );

  /// Asks GitHub; never touches the disk.
  Future<UpdateCheck> check() async {
    if (channel == UpdateChannel.off) {
      return UpdateCheck(
          current: current, release: null, assetUrl: null, shaUrl: null);
    }
    final body = await _get(_releasesUri(), accept: 'application/vnd.github+json');
    final Object? doc;
    try {
      doc = jsonDecode(utf8.decode(body));
    } on FormatException catch (e) {
      throw UpdateException('GitHub answered something that is not JSON: $e');
    }
    final list = doc is List
        ? [for (final r in doc) if (r is Map<String, dynamic>) ReleaseInfo.fromJson(r)]
        : doc is Map<String, dynamic>
            ? [ReleaseInfo.fromJson(doc)]
            : <ReleaseInfo>[];
    final r = pickRelease(list, channel);
    final name = assetName(arch);
    return UpdateCheck(
      current: current,
      release: r,
      assetUrl: r?.assets[name],
      shaUrl: r?.assets['$name.sha256'],
    );
  }

  /// Installs [c] over [exePath]. [restart] restarts the service (null: no
  /// service to restart) and [healthy] says whether it runs afterwards; when
  /// it does not, the old binary comes back. Returns true when the new binary
  /// stays installed.
  Future<bool> apply(
    UpdateCheck c, {
    Future<void> Function()? restart,
    Future<bool> Function()? healthy,
  }) async {
    final r = c.release;
    if (r == null || !c.newer) return false;
    final assetUrl = c.assetUrl, shaUrl = c.shaUrl;
    if (assetUrl == null || shaUrl == null) {
      throw UpdateException(
          '${r.version} has no ${assetName(arch)} with its .sha256; nothing installed');
    }
    final newPath = '$exePath.new';
    final prevPath = '$exePath.prev';
    try {
      await File(newPath).writeAsBytes(const [], flush: true);
    } on FileSystemException catch (e) {
      throw UpdateException(
          'cannot write ${File(exePath).parent.path}: ${e.osError?.message ?? e.message}'
          ' (the system service updates as root: sudo $exePath update)');
    }

    log('downloading ${r.version} ($assetUrl)');
    final want = (utf8.decode(await _get(Uri.parse(shaUrl))).trim().split(RegExp(r'\s+')))
        .first
        .toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(want)) {
      await _rm(newPath);
      throw UpdateException('the .sha256 file does not hold a digest');
    }
    final bytes = await _get(Uri.parse(assetUrl), timeout: const Duration(minutes: 10));
    final got = crypto.sha256.convert(bytes).toString();
    if (got != want) {
      await _rm(newPath);
      throw UpdateException(
          'digest mismatch for ${r.version}: got $got, release says $want; nothing installed');
    }
    await File(newPath).writeAsBytes(bytes, flush: true);
    await Process.run('chmod', ['755', newPath]);

    await _rm(prevPath);
    await File(exePath).rename(prevPath);
    try {
      await File(newPath).rename(exePath);
    } catch (_) {
      await File(prevPath).rename(exePath);
      rethrow;
    }
    log('installed ${r.version} at $exePath (the old binary is $prevPath)');

    if (restart == null) return true;
    log('restarting the service');
    await restart();
    if (healthy == null) return true;
    await Future<void>.delayed(settleTime);
    if (await healthy()) {
      log('${r.version} is running');
      return true;
    }
    log('the service is not running after the update: putting $current back');
    await _rm('$exePath.failed');
    await File(exePath).rename('$exePath.failed');
    await File(prevPath).rename(exePath);
    await restart();
    throw UpdateException(
        '${r.version} did not start; $current is back and the failed binary is $exePath.failed');
  }

  Future<List<int>> _get(
    Uri uri, {
    String? accept,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final HttpClientResponse res;
    try {
      final req = await _client.getUrl(uri).timeout(timeout);
      req.headers.set(HttpHeaders.userAgentHeader, 'xprs-server/$current');
      if (accept != null) req.headers.set(HttpHeaders.acceptHeader, accept);
      res = await req.close().timeout(timeout);
    } on Exception catch (e) {
      throw UpdateException('cannot reach $uri: $e');
    }
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw UpdateException('$uri answered ${res.statusCode}');
    }
    final out = <int>[];
    await res.listen(out.addAll).asFuture<void>().timeout(timeout);
    return out;
  }

  static Future<void> _rm(String path) async {
    final f = File(path);
    if (f.existsSync()) await f.delete();
  }

  void close() => _client.close(force: true);
}
