/*
 * The names keeper's records in a zxdb key-value store (x1watt/zx): one
 * archive file under the station's data directory, the label as the key, the
 * record as JSON. Group commit gathers a burst of claims into one generation;
 * reads see the pending writes. The core's NamesKeeper never sees the file.
 */
import 'dart:convert';
import 'dart:io';

import 'package:xprs_core/src/services/names/names_keeper.dart';
// The synchronous database API; zx.dart exports only the isolate-backed one.
// ignore: implementation_imports
import 'package:zx/src/db/zxdb.dart';

class ZxNamesStore implements NamesStore {
  ZxNamesStore._(this._db)
      : _kv = _db.kvStores.contains('names')
            ? _db.kv('names')
            : _db.createKvStore('names');

  final ZxDatabase _db;
  final ZxKvStore _kv;

  /// Opens (or creates) the store at [path], a `.zx` file.
  static ZxNamesStore open(String path) {
    Directory(File(path).parent.path).createSync(recursive: true);
    final db = ZxDatabase.open(path,
        create: true, groupCommit: const Duration(seconds: 2));
    return ZxNamesStore._(db);
  }

  @override
  NamesRecord? get(String label) {
    final s = _kv.getString(label);
    if (s == null) return null;
    try {
      return NamesRecord.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  @override
  void put(NamesRecord r) => _kv.putString(r.label, jsonEncode(r.toJson()));

  @override
  void remove(String label) => _kv.deleteString(label);

  @override
  List<NamesRecord> all() {
    final out = <NamesRecord>[];
    for (final e in _kv.scan()) {
      try {
        out.add(NamesRecord.fromJson(
            jsonDecode(e.valueString) as Map<String, dynamic>));
      } catch (_) {
        // a damaged row is skipped, not fatal
      }
    }
    return out;
  }

  /// How many labels are kept.
  int get length => _kv.length;

  void close() {
    _db.flush();
    _db.close();
  }
}
