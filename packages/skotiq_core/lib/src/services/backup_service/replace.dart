part of '../backup_service.dart';

/// A replace that is built and waits for the next start.
class PendingReplace {
  const PendingReplace({required this.backupName, this.safetyBackupName});

  /// The backup file this database becomes.
  final String backupName;

  /// The backup of the database as it was when the replace was asked for.
  final String? safetyBackupName;

  Map<String, Object?> toJson() => {
    'backupName': backupName,
    'safetyBackup': ?safetyBackupName,
  };
}

extension _BackupReplace on BackupService {
  static const String _readyPrefix = 'skotiq-restore-ready-';

  /// Make [staged] the database the next start opens.
  ///
  /// In order: rows of [staged] that point at a record the backup does not
  /// hold are removed and counted; this machine's own settings are carried
  /// into it; it is checked; a backup of the live database is written; and
  /// only then is the swap asked for. The live database is not written at any
  /// step but its last-backup time, so a failure at any of them leaves it as
  /// it was. The swap itself is the start-up's ([applyPendingRestore]): it
  /// moves the live file aside, never deletes it, and puts it back if the
  /// new one cannot take its place.
  Future<RestoreResult> _replaceWith(
    File staged, {
    required String backupName,
    required Object? backupCreatedAt,
    required void Function(String step, double fraction) onProgress,
  }) async {
    RestoreResult failed(String message) => RestoreResult(
      success: false,
      errorMessage: message,
      timestamp: DateTime.now(),
      mode: RestoreMode.replace,
    );
    final dbFile = await database.databaseFile();
    if (dbFile == null) {
      return failed('This database is not a file, so it cannot be replaced.');
    }

    onProgress('Checking the backup', 0);
    final settings = SettingsDao(database);
    final mine = <String, String>{
      // Where this machine keeps its backups is not a backup's to say.
      for (final key in const [BackupService.backupDirectorySettingKey])
        if (await settings.getSetting(key) case final value?) key: value,
      // The database this becomes was last backed up when the backup was
      // made.
      if (backupCreatedAt is String &&
          DateTime.tryParse(backupCreatedAt) != null)
        BackupService.lastBackupSettingKey: backupCreatedAt,
    };
    final counts = <String, int>{};
    final leftOut = <String, int>{};
    final db = SkotiqDatabase.onFile(staged);
    try {
      await db.customStatement('PRAGMA foreign_keys = OFF');
      await db.transaction(() async {
        // Removing a row can orphan the rows that pointed at it.
        while (true) {
          final broken = await db
              .customSelect('PRAGMA foreign_key_check')
              .get();
          if (broken.isEmpty) break;
          for (final row in broken) {
            final table = row.read<String>('table');
            final removed = await db.customUpdate(
              'DELETE FROM "$table" WHERE rowid = ?',
              variables: [Variable.withInt(row.read<int>('rowid'))],
            );
            if (removed > 0) {
              leftOut.update(
                table,
                (n) => n + removed,
                ifAbsent: () => removed,
              );
            }
          }
        }
        final staging = SettingsDao(db);
        for (final MapEntry(:key, :value) in mine.entries) {
          await staging.setSetting(key, value);
        }
      });
      for (final table in db.allTables) {
        final name = table.actualTableName;
        final n =
            (await db
                    .customSelect('SELECT count(*) AS n FROM "$name"')
                    .getSingle())
                .read<int>('n');
        if (n > 0) counts[name == 'app_settings' ? 'settings' : name] = n;
      }
    } finally {
      await db.close();
    }
    final check = await inspectQuarantinedDatabase(staged.path);
    if (!check.integrityOk) {
      return failed(
        'The database built from the backup did not pass its check '
        '(${check.detail}). This database was not changed.',
      );
    }

    onProgress('Saving this database first', 0.2);
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final safety = await createBackup(
      customPath: path.join(
        (await getBackupDirectory()).path,
        'skotiq-backup-before-replace-$stamp-${const Uuid().v4()}.skbackup',
      ),
      onProgress: (fraction) =>
          onProgress('Saving this database first', 0.2 + 0.7 * fraction),
    );
    if (!safety.success) {
      return failed(
        'The safety backup of this database could not be written '
        '(${safety.errorMessage}), so it was not replaced.',
      );
    }

    await cancelPendingReplace();
    final ready = File(path.join(dbFile.parent.path, '$_readyPrefix$stamp.db'));
    await staged.rename(ready.path);
    try {
      await stageDatabaseRestore(
        dbFile: dbFile,
        backupPath: ready.path,
        label: backupName,
        safetyBackup: safety.filePath,
      );
    } on Object {
      await _deleteQuietly(ready);
      rethrow;
    }
    onProgress('Ready', 1);
    return RestoreResult(
      success: true,
      timestamp: DateTime.now(),
      mode: RestoreMode.replace,
      itemsRestored: counts.values.fold<int>(0, (sum, n) => sum + n),
      categoryCounts: counts,
      notRestored: leftOut,
      leftOut: {
        if (leftOut.isNotEmpty)
          RestoreLeftOut.ownerNotInBackup: leftOut.values.fold<int>(
            0,
            (sum, n) => sum + n,
          ),
      },
      pendingRestart: true,
      safetyBackupPath: safety.filePath,
    );
  }
}
