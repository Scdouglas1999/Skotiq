import 'dart:typed_data';


/// The database backups a linked imaging host keeps and restores.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostBackups {
  Future<Map<String, dynamic>> createBackup({bool autoSave = false});

  Future<void> deleteBackup(String backupId);

  Future<Uint8List> downloadBackup(String backupId);

  Future<List<Map<String, dynamic>>> listBackups();

  Future<Map<String, dynamic>> restoreBackupById(
    String backupId, {
    bool replaceExisting = false,
  });

  Future<Map<String, dynamic>> uploadBackupAndRestore(
    Uint8List bytes,
    String fileName, {
    bool replaceExisting = false,
  });
}
