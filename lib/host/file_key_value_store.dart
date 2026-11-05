/*
 * The server's settings: the core's KeyValueStore over one JSON file.
 *
 * Loaded once when opened (reads are synchronous, as the interface wants).
 * A write replaces the file atomically (write a sibling, then rename), so a
 * power cut leaves the old settings or the new ones, never half a file.
 * Writes that land together are coalesced into one: the core sets several
 * keys in a row at start.
 */
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xprs_core/src/platform/key_value_store.dart';

class FileKeyValueStore implements KeyValueStore {
  FileKeyValueStore._(this.file, this._values);

  final File file;
  final Map<String, Object> _values;
  Future<void>? _pending;

  /// Open (or create) the store at [path].
  static Future<FileKeyValueStore> open(String path) async {
    final f = File(path);
    final values = <String, Object>{};
    if (await f.exists()) {
      try {
        final decoded = jsonDecode(await f.readAsString());
        if (decoded is Map) {
          decoded.forEach((k, v) {
            if (v != null) values['$k'] = v is List ? List<String>.from(v.map((e) => '$e')) : v as Object;
          });
        }
      } catch (_) {
        // A damaged file must not stop the station: keep a copy, start empty.
        await f.copy('$path.damaged');
      }
    } else {
      await f.parent.create(recursive: true);
    }
    return FileKeyValueStore._(f, values);
  }

  T? _get<T>(String k) {
    final v = _values[k];
    return v is T ? v : null;
  }

  @override
  bool? getBool(String key) => _get<bool>(key);
  @override
  int? getInt(String key) => _get<int>(key);
  @override
  double? getDouble(String key) {
    final v = _values[key];
    return v is num ? v.toDouble() : null;
  }

  @override
  String? getString(String key) => _get<String>(key);
  @override
  List<String>? getStringList(String key) {
    final v = _values[key];
    return v is List ? List<String>.from(v) : null;
  }

  @override
  bool containsKey(String key) => _values.containsKey(key);
  @override
  Set<String> getKeys() => _values.keys.toSet();

  Future<bool> _set(String k, Object v) async {
    _values[k] = v;
    await _flush();
    return true;
  }

  @override
  Future<bool> setBool(String key, bool value) => _set(key, value);
  @override
  Future<bool> setInt(String key, int value) => _set(key, value);
  @override
  Future<bool> setDouble(String key, double value) => _set(key, value);
  @override
  Future<bool> setString(String key, String value) => _set(key, value);
  @override
  Future<bool> setStringList(String key, List<String> value) =>
      _set(key, List<String>.of(value));
  @override
  Future<bool> remove(String key) async {
    _values.remove(key);
    await _flush();
    return true;
  }

  /// One write for every change made in the same turn of the event loop.
  Future<void> _flush() => _pending ??= Future(() async {
        _pending = null;
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(
            const JsonEncoder.withIndent('  ').convert(_values),
            flush: true);
        await tmp.rename(file.path);
      });
}
