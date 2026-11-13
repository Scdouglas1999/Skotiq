import 'dart:convert';


import '../database/database.dart';

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

  /// The document stored under [key], or null when there is none.
  Future<Map<String, dynamic>?> read(String key) async {
    final stored = await _db.darkroomStateDao.valueOf(key);
    if (stored == null) return null;
    final value = jsonDecode(stored);
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  /// Replace the document under [key].
  Future<void> write(String key, Map<String, dynamic> value) async {
    await _db.darkroomStateDao.put(
      key,
      jsonEncode(value),
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
  }
}
