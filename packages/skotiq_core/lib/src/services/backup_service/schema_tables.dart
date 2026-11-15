part of '../backup_service.dart';

/// The tables a backup leaves out, each with why. Every other table of the
/// schema is in the backup's `tables` section, so a table added later is in
/// the next backup without anyone listing it.
const Map<String, String> backupExcludedTables = {
  'sequence_checkpoints':
      "a run's crash-recovery point on this machine; restored, it would offer "
      'to resume a run that never ran here',
  'darkroom_jobs':
      'the Darkroom work queue; a queued or running job restored from a '
      'backup would start by itself',
  'delivery_journal':
      'the send log of darkroom_jobs rows, which a backup does not hold',
};

/// The tables a backup holds in a section of their own, not row by row.
const Map<String, String> backupOwnSectionTables = {
  'app_settings':
      "\"settings\": key and value, without this machine's backup folder",
};

extension _BackupSchemaTables on BackupService {
  Iterable<String> get _backedUpTableNames => database.allTables
      .map((table) => table.actualTableName)
      .where(
        (name) =>
            !backupExcludedTables.containsKey(name) &&
            !backupOwnSectionTables.containsKey(name),
      );
}
