part of '../network_backend.dart';

/// The database backups a linked imaging host keeps and restores.
final class HostBackups {
  HostBackups(this._host);

  final NetworkBackend _host;

  Future<Map<String, dynamic>> createBackup({bool autoSave = false}) async {
    final response = await _host._post(
      BackupApi.createBackup,
      body: {'autoSave': autoSave},
      timeout: _backupTimeout,
    );
    return response;
  }

  Future<void> deleteBackup(String backupId) async {
    await _host._delete(BackupApi.deleteBackup, path: {'id': backupId});
  }

  Future<Uint8List> downloadBackup(String backupId) async {
    return _host._downloadBytes(BackupApi.downloadBackup, path: {'id': backupId});
  }

  Future<List<Map<String, dynamic>>> listBackups() async {
    final response = await _host._get(BackupApi.listBackups);
    final backupsList = response['backups'];
    if (backupsList is! List) {
      throw const FormatException(
        'GET /api/backup/list returned a missing or non-list `backups` field',
      );
    }
    return backupsList
        .whereType<Map>()
        .map(
          (row) => Map<String, dynamic>.fromEntries(
            row.entries
                .where((entry) => entry.key is String)
                .map((entry) => MapEntry(entry.key as String, entry.value)),
          ),
        )
        .toList(growable: false);
  }

  /// Restore from a backup identified by its stable [backupId]: the host
  /// resolves it to a file inside its own backup directory, so no server
  /// path crosses the wire.
  Future<Map<String, dynamic>> restoreBackupById(
    String backupId, {
    required RestoreMode mode,
  }) async {
    final response = await _host._post(
      BackupApi.restoreBackup,
      body: {'id': backupId, 'mode': mode.wireName},
      timeout: _backupTimeout,
    );
    return response;
  }

  Future<Map<String, dynamic>> uploadBackupAndRestore(
    Uint8List bytes,
    String fileName, {
    required RestoreMode mode,
  }) async {
    return _host._postRaw(
      BackupApi.uploadRestoreBackup,
      query: {'fileName': fileName, 'mode': mode.wireName},
      bytes: bytes,
      contentType: 'application/octet-stream',
      timeout: _backupTimeout,
      // A restore is never sent twice.
      maxAttempts: 1,
    );
  }

  Future<Map<String, dynamic>> restoreState() => _host._get(BackupApi.restoreState);

  Future<void> cancelReplace() async {
    await _host._post(BackupApi.cancelReplace);
  }

  Future<void> acknowledgeReplace() async {
    await _host._post(BackupApi.acknowledgeReplace);
  }
}
