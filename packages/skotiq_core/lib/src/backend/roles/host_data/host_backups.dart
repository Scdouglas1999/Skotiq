import 'dart:typed_data';

import '../../../services/backup_service.dart' show RestoreMode;

/// The database backups a linked imaging host keeps and restores.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostBackups {
  Future<Map<String, dynamic>> createBackup({bool autoSave = false});

  Future<void> deleteBackup(String backupId);

  Future<Uint8List> downloadBackup(String backupId);

  Future<List<Map<String, dynamic>>> listBackups();

  /// The body is `RestoreResult.toWire` with `status` and `message`.
  Future<Map<String, dynamic>> restoreBackupById(
    String backupId, {
    required RestoreMode mode,
  });

  Future<Map<String, dynamic>> uploadBackupAndRestore(
    Uint8List bytes,
    String fileName, {
    required RestoreMode mode,
  });

  /// `progress` of a restore that is running, the `pendingReplace` that
  /// waits for the host's next start, and the `lastReplace` it made.
  Future<Map<String, dynamic>> restoreState();

  /// Withdraws the replace that waits for the host's next start.
  Future<void> cancelReplace();

  /// Clears the record of the last replace.
  Future<void> acknowledgeReplace();
}
