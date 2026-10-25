import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';
import '../providers/database_provider.dart';

/// Durable Darkroom state that must outlive the process: the master builds
/// and the night-end runs. One JSON document per key, in the profile's own
/// database, so it moves with the profile and a test's in-memory database
/// keeps its own.
///
/// It is not an `app_settings` row on purpose: those are watched as a whole,
/// and a build writing its progress there would rebuild every provider that
/// reads a setting.
class DarkroomStateStore {
  DarkroomStateStore(this._db);

  final SkotiqDatabase _db;
  Future<void>? _ready;

  Future<void> _ensureTable() => _ready ??= _db.customStatement(
    'CREATE TABLE IF NOT EXISTS darkroom_state ('
    'key TEXT NOT NULL PRIMARY KEY, '
    'value TEXT NOT NULL, '
    'updated_at TEXT NOT NULL)',
  );

  /// The document stored under [key], or null when there is none.
  Future<Map<String, dynamic>?> read(String key) async {
    await _ensureTable();
    final row = await _db
        .customSelect(
          'SELECT value FROM darkroom_state WHERE key = ?',
          variables: [Variable.withString(key)],
        )
        .getSingleOrNull();
    if (row == null) return null;
    final value = jsonDecode(row.read<String>('value'));
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  /// Replace the document under [key].
  Future<void> write(String key, Map<String, dynamic> value) async {
    await _ensureTable();
    await _db.customStatement(
      'INSERT INTO darkroom_state (key, value, updated_at) VALUES (?, ?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value, '
      'updated_at = excluded.updated_at',
      [key, jsonEncode(value), DateTime.now().toUtc().toIso8601String()],
    );
  }
}

final darkroomStateStoreProvider = Provider<DarkroomStateStore>(
  (ref) => DarkroomStateStore(ref.watch(databaseProvider)),
);
