import '../db/hub_database.dart';

/// Append-only audit trail. Every request that resolves to a handler is logged
/// with method, path, status, the acting account (if any), and a short detail.
/// Mirrors the headless server's audit discipline; never records secrets.
class AuditLog {
  AuditLog(this._db);

  final HubDatabase _db;

  void record({
    required String method,
    required String path,
    required int status,
    String? accountId,
    String? detail,
  }) {
    _db.db.execute(
      'INSERT INTO audit_log (at, account_id, method, path, status, detail) '
      'VALUES (?, ?, ?, ?, ?, ?);',
      <Object?>[
        DateTime.now().toUtc().toIso8601String(),
        accountId,
        method,
        path,
        status,
        detail,
      ],
    );
  }

  /// Most recent [limit] audit entries, newest first (admin diagnostics).
  List<Map<String, Object?>> recent({int limit = 100}) {
    final rows = _db.db.select(
      'SELECT at, account_id, method, path, status, detail FROM audit_log '
      'ORDER BY id DESC LIMIT ?;',
      <Object?>[limit],
    );
    return rows
        .map(
          (r) => <String, Object?>{
            'at': r['at'],
            'accountId': r['account_id'],
            'method': r['method'],
            'path': r['path'],
            'status': r['status'],
            'detail': r['detail'],
          },
        )
        .toList();
  }
}
