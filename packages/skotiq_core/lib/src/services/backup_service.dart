import 'dart:io';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';
import '../database/database.dart';
import '../database/integrity_check.dart';
import '../database/daos/settings_dao.dart';
import '../models/sequence/sequence_models.dart';
import 'logging_service.dart';
import 'sequence_file_service.dart';
import 'local_sequence_repository.dart';
import 'backup_service/backup_archive.dart';

export 'backup_service/backup_archive.dart' show backupArchiveVersion;

part 'backup_service/sequence_codec.dart';
part 'backup_service/backup_models.dart';
part 'backup_service/backup_value_codecs.dart';
part 'backup_service/table_registry.dart';
part 'backup_service/restore_validation.dart';
part 'backup_service/schema_tables.dart';
part 'backup_service/merge.dart';
part 'backup_service/replace.dart';

/// The isolate entry points. Top-level so what they close over is only what
/// they are given.
Future<Map<String, int>> Function(void Function(double)) _archiveWriter({
  required String databasePath,
  required String outputPath,
  required Map<String, Object?> head,
  required List<String> tables,
}) =>
    (report) async => writeBackupArchive(
      databasePath: databasePath,
      outputPath: outputPath,
      head: head,
      tables: tables,
      omitSettings: const {BackupService.backupDirectorySettingKey},
      report: report,
    );

Future<BackupArchiveContents> Function(void Function(double)) _archiveReader({
  required String archivePath,
  required String databasePath,
  required Set<String> never,
}) =>
    (report) => readBackupArchive(
      archivePath: archivePath,
      databasePath: databasePath,
      never: never,
      omitSettings: const {BackupService.backupDirectorySettingKey},
      report: report,
    );

class BackupService {
  final SkotiqDatabase database;
  final LoggingService _logger;
  final Future<Directory> Function()? _backupDirectoryProvider;

  /// 3.x holds every table of the schema in `tables` (see
  /// [backupExcludedTables]); 2.x backups carry a hand-picked set under their
  /// own keys and are still restored.
  static const String backupVersion = backupArchiveVersion;

  /// Fallback for isolated tests/embedders that do not inject package info.
  /// Production providers always supply appVersionProvider.
  static const String appVersion = 'unknown';

  /// Settings key holding the time of the most recent successful backup.
  ///
  /// Owned here rather than by the auto-save timer because it answers "when was
  /// this database last backed up", which is equally true of a manual backup.
  /// Every successful backup writes it, scheduled or manual.
  static const String lastBackupSettingKey = 'autosave.last_backup_at';

  /// Settings key holding the operator's chosen backup folder, empty/absent
  /// meaning [resolveDefaultBackupDirectory].
  ///
  /// Backups belong on the drive the operator actually backs up: an observatory
  /// PC's system volume is routinely the smallest one on the machine, and the
  /// default folder follows the database onto it.
  ///
  /// Never written into a backup and never taken from one: a bundle from
  /// another machine would otherwise repoint this install's backup folder,
  /// and its retention deletes, at a path that machine chose.
  static const String backupDirectorySettingKey = 'backup.directory';
  final String runtimeAppVersion;

  BackupService({
    required this.database,
    required LoggingService logger,
    String? appVersion,
    Future<Directory> Function()? backupDirectoryProvider,
  }) : runtimeAppVersion = appVersion?.trim().isNotEmpty == true
           ? appVersion!.trim()
           : BackupService.appVersion,
       _backupDirectoryProvider = backupDirectoryProvider,
       _logger = logger;

  /// Create a full backup of the database: the settings and every table the
  /// schema has except [backupExcludedTables].
  ///
  /// The database is copied to a scratch file in one step (so the backup is
  /// one moment in time and the live database is held only for the copy),
  /// and the archive is written from the copy on another isolate.
  Future<BackupResult> createBackup({
    String? customPath,
    void Function(double fraction)? onProgress,
  }) async {
    File? snapshot;
    File? tempFile;
    try {
      _logger.debug('Starting full backup...', source: 'BackupService');
      final filePath = customPath ?? await _getBackupFilePath();
      if (filePath == null) {
        return BackupResult(
          success: false,
          errorMessage: 'No backup file path specified',
          timestamp: DateTime.now(),
        );
      }
      final file = File(filePath);
      await file.parent.create(recursive: true);
      await _sweepScratch();
      snapshot = await _scratchFile('snapshot');
      await database.customStatement('VACUUM INTO ?', [snapshot.path]);

      // Written beside the destination and renamed once complete, so a crash
      // or a full disk leaves the previous file there, not a truncated one.
      tempFile = File(
        path.join(
          file.parent.path,
          '.${path.basename(file.path)}.'
          '${DateTime.now().microsecondsSinceEpoch}.tmp',
        ),
      );
      final counts = await runWithProgress(
        _archiveWriter(
          databasePath: snapshot.path,
          outputPath: tempFile.path,
          head: {
            'createdAt': DateTime.now().toIso8601String(),
            'appVersion': runtimeAppVersion,
            'platform': Platform.operatingSystem,
            'schemaVersion': database.schemaVersion,
          },
          tables: _backedUpTableNames.toList(),
        ),
        onProgress,
      );
      try {
        await tempFile.rename(file.path);
      } on FileSystemException {
        // Windows does not rename over an existing file.
        if (await file.exists()) await file.delete();
        await tempFile.rename(file.path);
      }

      final totalItems = counts.values.fold<int>(0, (sum, n) => sum + n);
      _logger.info(
        'Backup completed successfully\n'
        '  File: $filePath\n'
        '  Tables: ${counts.length} (rows: $totalItems, settings included)',
        source: 'BackupService',
      );

      final completedAt = DateTime.now();
      await _recordLastBackupTime(completedAt);

      return BackupResult(
        success: true,
        filePath: filePath,
        timestamp: completedAt,
        itemsBackedUp: totalItems,
      );
    } catch (e, stackTrace) {
      _logger.error('Backup failed: $e\n$stackTrace', source: 'BackupService');
      return BackupResult(
        success: false,
        errorMessage: e.toString(),
        timestamp: DateTime.now(),
      );
    } finally {
      await _deleteQuietly(snapshot);
      await _deleteQuietly(tempFile);
    }
  }

  /// Restore the backup at [filePath].
  ///
  /// The backup is first read into a database file of its own, so a file
  /// that is damaged, truncated or from a newer Skotiq fails here with this
  /// database untouched. A [RestoreMode.merge] then adds its records to this
  /// database in one transaction ([_BackupMerge._mergeFrom]); a
  /// [RestoreMode.replace] makes that file the database at the next start
  /// ([_BackupReplace._replaceWith]).
  Future<RestoreResult> restoreBackup({
    required String filePath,
    RestoreMode mode = RestoreMode.merge,
    void Function(RestoreProgress progress)? onProgress,
  }) async {
    File? staged;
    try {
      _logger.debug('Starting ${mode.name} restore from: $filePath');
      final file = File(filePath);
      if (!await file.exists()) {
        return RestoreResult(
          success: false,
          errorMessage: 'Backup file not found',
          timestamp: DateTime.now(),
          mode: mode,
        );
      }
      await _sweepScratch();
      staged = await _scratchFile('restore');
      final replace = mode == RestoreMode.replace;
      final contents = await _stage(
        file,
        staged,
        (fraction) => onProgress?.call(
          RestoreProgress(
            'Reading the backup',
            fraction * (replace ? 0.7 : 0.5),
          ),
        ),
      );

      final RestoreResult result;
      if (replace) {
        result = await _replaceWith(
          staged,
          backupName: path.basename(file.path),
          backupCreatedAt: contents.sections['createdAt'],
          onProgress: (step, fraction) =>
              onProgress?.call(RestoreProgress(step, 0.7 + 0.3 * fraction)),
        );
        // The file is now the database the next start opens.
        if (result.success) staged = null;
      } else {
        final outcome = await _mergeFrom(
          staged,
          (step, fraction) => onProgress?.call(
            RestoreProgress('Adding $step', 0.5 + 0.5 * fraction),
          ),
        );
        result = RestoreResult(
          success: true,
          timestamp: DateTime.now(),
          itemsRestored: outcome.added.values.fold<int>(0, (s, n) => s + n),
          categoryCounts: outcome.added,
          alreadyHere: outcome.alreadyHere,
          notRestored: outcome.notRestored,
          leftOut: outcome.leftOut,
        );
      }
      onProgress?.call(const RestoreProgress('Done', 1));
      _logger.info(
        'Restore from $filePath: ${result.success ? result.report : result.errorMessage}',
        source: 'BackupService',
      );
      return result;
    } on BackupArchiveException catch (e) {
      _logger.error(
        'Restore stopped before this database was touched: ${e.message}',
        source: 'BackupService',
      );
      return RestoreResult(
        success: false,
        errorMessage: e.message,
        timestamp: DateTime.now(),
        mode: mode,
      );
    } catch (e, stackTrace) {
      _logger.error('Restore failed: $e\n$stackTrace', source: 'BackupService');
      return RestoreResult(
        success: false,
        errorMessage: e.toString(),
        timestamp: DateTime.now(),
        mode: mode,
      );
    } finally {
      await _deleteQuietly(staged);
    }
  }

  /// Build in [staged] the database the backup [archive] describes: this
  /// build's schema, the archive's table rows as they are, and its settings.
  /// Nothing of the live database is read or written.
  Future<BackupArchiveContents> _stage(
    File archive,
    File staged,
    void Function(double fraction) onProgress,
  ) async {
    var db = SkotiqDatabase.onFile(staged);
    try {
      await db.customSelect('SELECT 1').get();
    } finally {
      await db.close();
    }
    final contents = await runWithProgress(
      _archiveReader(
        archivePath: archive.path,
        databasePath: staged.path,
        never: {...backupExcludedTables.keys, ...backupOwnSectionTables.keys},
      ),
      onProgress,
    );
    if (contents.sections['schemaVersion'] case final int schema
        when schema > database.schemaVersion) {
      throw BackupArchiveException(
        'This backup is of a newer database (version $schema) than this '
        'Skotiq reads (version ${database.schemaVersion}). Update Skotiq '
        'before restoring it.',
      );
    }
    for (final name in contents.tablesSkipped) {
      _logger.warning(
        'Backup table "$name" is not restored: '
        '${backupExcludedTables[name] ?? 'this version has no such table'}',
        source: 'BackupService',
      );
    }
    // What a backup older than 3.1 holds under keys of its own goes in
    // through the importers of its day.
    if (_hasOwnSections(contents.sections)) {
      db = SkotiqDatabase.onFile(staged);
      try {
        // A 2.x section can hold rows of a session the backup does not; what
        // they point at is settled by the merge or the replace, not here.
        await db.customStatement('PRAGMA foreign_keys = OFF');
        await BackupService(
          database: db,
          logger: _logger,
        )._applySections(contents.sections);
      } finally {
        await db.close();
      }
    }
    return contents;
  }

  /// Where the database is, asked once: the answers below are read from
  /// files beside it and must not wait behind a restore that holds the
  /// connection.
  late final Future<Directory?> _databaseDirectory = database
      .databaseDirectory();

  /// The replace that waits for the next start, or null.
  Future<PendingReplace?> pendingReplace() async {
    final directory = await _databaseDirectory;
    if (directory == null) return null;
    final request = await readPendingRestoreRequest(directory);
    final label = request?.label;
    if (request == null || label == null) return null;
    return PendingReplace(
      backupName: label,
      safetyBackupName: request.safetyBackup == null
          ? null
          : path.basename(request.safetyBackup!),
    );
  }

  /// Withdraws the replace that waits for the next start: this database
  /// stays. The safety backup written for it is kept.
  Future<void> cancelPendingReplace() async {
    final directory = await _databaseDirectory;
    if (directory == null) return;
    final request = await readPendingRestoreRequest(directory);
    if (request == null || request.label == null) return;
    await cancelPendingRestore(directory);
    if (path.basename(request.source).startsWith(_BackupReplace._readyPrefix)) {
      await _deleteQuietly(File(request.source));
    }
  }

  /// What the last start did with a replace that was waiting, until
  /// [dismissReplaceOutcome].
  Future<DatabaseRestoreOutcome?> replaceOutcome() async {
    final directory = await _databaseDirectory;
    return directory == null ? null : readRestoreOutcome(directory);
  }

  Future<void> markReplaceOutcomeAnnounced() async {
    final directory = await _databaseDirectory;
    if (directory != null) await markRestoreOutcomeAnnounced(directory);
  }

  Future<void> dismissReplaceOutcome() async {
    final directory = await _databaseDirectory;
    if (directory != null) await clearRestoreOutcome(directory);
  }

  /// Read metadata from a backup file without restoring
  Future<BackupMetadata?> readBackupMetadata(String filePath) async {
    try {
      if (!await File(filePath).exists()) return null;
      final head = await readBackupArchiveHead(filePath);
      return head == null ? null : BackupMetadata.fromJson(head);
    } catch (e) {
      _logger.debug('Failed to read backup metadata: $e');
      return null;
    }
  }

  static const String _scratchPrefix = '.skotiq-backup-work-';

  /// Where the copies a backup or restore works on are written: beside the
  /// database (the same disk, so a replace is a rename) or, for a database
  /// with no file, in the system's temporary folder.
  Future<Directory> _scratchDirectory() async =>
      await _databaseDirectory ?? Directory.systemTemp;

  Future<File> _scratchFile(String purpose) async => File(
    path.join(
      (await _scratchDirectory()).path,
      '$_scratchPrefix$purpose-${DateTime.now().microsecondsSinceEpoch}.db',
    ),
  );

  /// Removes the scratch files a backup or restore that was killed left,
  /// and a database built for a replace that no request names any more (the
  /// swap refused it, or it was withdrawn).
  Future<void> _sweepScratch() async {
    final cutoff = DateTime.now().subtract(const Duration(hours: 6));
    try {
      final directory = await _scratchDirectory();
      final waiting = (await readPendingRestoreRequest(directory))?.source;
      await for (final entry in directory.list()) {
        if (entry is! File) continue;
        final name = path.basename(entry.path);
        final abandoned =
            name.startsWith(_scratchPrefix) &&
            name.endsWith('.db') &&
            (await entry.stat()).modified.isBefore(cutoff);
        final refused =
            name.startsWith(_BackupReplace._readyPrefix) &&
            name.endsWith('.db') &&
            entry.path != waiting;
        if (abandoned || refused) await _deleteQuietly(entry);
      }
    } on FileSystemException {
      // The folder is listed again by the next backup.
    }
  }

  Future<void> _deleteQuietly(File? file) async {
    if (file == null) return;
    for (final suffix in const ['', '-journal', '-wal', '-shm']) {
      try {
        final target = File('${file.path}$suffix');
        if (await target.exists()) await target.delete();
      } on FileSystemException catch (e) {
        _logger.warning(
          'Could not remove the work file ${file.path}$suffix: ${e.message}',
          source: 'BackupService',
        );
      }
    }
  }

  /// List all backups in the default backup directory
  Future<List<File>> listBackups() async {
    final backupDir = await _getBackupDirectory();
    if (!await backupDir.exists()) {
      return [];
    }

    final candidates = await backupDir
        .list()
        .where(
          (entity) =>
              entity is File &&
              (entity.path.endsWith('.skbackup') ||
                  // `.nsbackup` is the pre-rename extension; backups made
                  // before it must stay restorable.
                  entity.path.endsWith('.nsbackup') ||
                  entity.path.endsWith('.json')),
        )
        .cast<File>()
        .toList();
    final dated = <({File file, DateTime modified})>[];
    for (final file in candidates) {
      try {
        dated.add((file: file, modified: (await file.stat()).modified));
      } on FileSystemException catch (error) {
        // A file may disappear during retention cleanup. Keep the other valid
        // backups visible, but record which individual entry was skipped.
        _logger.warning(
          'Skipping backup that could not be inspected (${file.path}): $error',
          source: 'BackupService',
        );
      }
    }
    dated.sort((a, b) => b.modified.compareTo(a.modified));
    return [for (final entry in dated) entry.file];
  }

  /// Persist the time of a successful backup.
  ///
  /// Best-effort: a settings-write failure must not turn a backup that is
  /// already safely on disk into a reported failure. It is logged instead, so
  /// the displayed time can lag but can never claim a backup that did not
  /// happen.
  Future<void> _recordLastBackupTime(DateTime completedAt) async {
    try {
      await SettingsDao(
        database,
      ).setSetting(lastBackupSettingKey, completedAt.toIso8601String());
    } catch (e) {
      _logger.warning(
        'Backup succeeded but the last-backup time could not be recorded: $e',
        source: 'BackupService',
      );
    }
  }

  /// Auto-save a backup with timestamp
  Future<BackupResult> autoSaveBackup() async {
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final backupDir = await _getBackupDirectory();
    await backupDir.create(recursive: true);

    final filePath = path.join(
      backupDir.path,
      'skotiq_autosave_$timestamp.skbackup',
    );

    return createBackup(customPath: filePath);
  }

  /// The per-table sections of a 2.x backup, by their keys there. Frozen: a
  /// 3.x backup holds every table in `tables`.
  late final Map<String, Future<void> Function(List<dynamic>)>
  _legacyTableImporters = {
    'darkLibrary': (rows) => _importRows(
      rows,
      (json) => DarkLibraryEntry.fromJson(json),
      database.darkLibrary,
    ),
    'flatHistory': (rows) => _importRows(
      rows,
      (json) => FlatHistoryEntry.fromJson(json),
      database.flatHistory,
    ),
    'defectMaps': (rows) => _importRows(
      rows,
      (json) => DefectMapEntry.fromJson(json),
      database.defectMaps,
    ),
    'sequenceRuns': (rows) => _importRows(
      rows,
      (json) => SequenceRun.fromJson(json),
      database.sequenceRuns,
    ),
    'notesJournal': (rows) => _importRows(
      rows,
      (json) => ObservationLogEntry.fromJson(json),
      database.observationLogs,
    ),
    'polarAlignmentHistory': (rows) => _importRows(
      rows,
      (json) => PolarAlignmentHistoryEntry.fromJson(json),
      database.polarAlignmentHistory,
    ),
    'guideRmsHistory': (rows) => _importRows(
      rows,
      (json) => GuideRmsHistoryEntry.fromJson(json),
      database.guideRmsHistory,
    ),
    'scienceSessionConfig': (rows) => _importRows(
      rows,
      (json) => ScienceSessionConfigRow.fromJson(json),
      database.scienceSessionConfig,
    ),
    'photometryMeasurements': (rows) => _importRows(
      rows,
      (json) => PhotometryMeasurementRow.fromJson(json),
      database.photometryMeasurements,
    ),
    'framePhotometricCalibration': (rows) => _importRows(
      rows,
      (json) => FramePhotometricCalibrationRow.fromJson(json),
      database.framePhotometricCalibration,
    ),
    'transparencySamples': (rows) => _importRows(
      rows,
      (json) => TransparencySampleRow.fromJson(json),
      database.transparencySamples,
    ),
    'psfFieldTiles': (rows) => _importRows(
      rows,
      (json) => PsfFieldTileRow.fromJson(json),
      database.psfFieldTiles,
    ),
    'scienceFrameQualityMetrics': (rows) => _importRows(
      rows,
      (json) => ScienceFrameQualityMetricsRow.fromJson(json),
      database.scienceFrameQualityMetrics,
    ),
    'scienceTileMetrics': (rows) => _importRows(
      rows,
      (json) => ScienceTileMetricRow.fromJson(json),
      database.scienceTileMetrics,
    ),
    'astrometryResidualVectors': (rows) => _importRows(
      rows,
      (json) => AstrometryResidualVectorRow.fromJson(json),
      database.astrometryResidualVectors,
    ),
    'movingObjectCandidates': (rows) => _importRows(
      rows,
      (json) => MovingObjectCandidateRow.fromJson(json),
      database.movingObjectCandidates,
    ),
    'photometricTransforms': (rows) => _importRows(
      rows,
      (json) => PhotometricTransformRow.fromJson(json),
      database.photometricTransforms,
    ),
    'lineRatioProducts': (rows) => _importRows(
      rows,
      (json) => LineRatioProductRow.fromJson(json),
      database.lineRatioProducts,
    ),
    'focusModels': (rows) => _importRows(
      rows,
      (json) => FocusModelEntry.fromJson(json),
      database.focusModels,
    ),
    'weatherSettings': (rows) async {
      if (rows.isEmpty) return;
      final raw = rows.first;
      if (raw is! Map) {
        throw const FormatException('row 0 is not an object');
      }
      await _importWeatherSettings(
        WeatherSettingRow.fromJson(raw.cast<String, dynamic>()),
      );
    },
  };

  Future<String?> _getBackupFilePath() async {
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final backupDir = await _getBackupDirectory();
    await backupDir.create(recursive: true);
    return path.join(backupDir.path, 'skotiq_backup_$timestamp.skbackup');
  }

  Future<Directory> _getBackupDirectory() async {
    final override = _backupDirectoryProvider;
    if (override != null) return override();
    final configured = await getConfiguredBackupDirectory();
    if (configured != null) return Directory(configured);
    return resolveDefaultBackupDirectory();
  }

  /// The operator's chosen backup folder, or null when backups still follow the
  /// database. Distinct from [getBackupDirectory], which always answers with a
  /// concrete directory — this one answers "did anyone move it?".
  Future<String?> getConfiguredBackupDirectory() async {
    final value = await SettingsDao(
      database,
    ).getSetting(backupDirectorySettingKey);
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  /// The folder backups are written to, read, and pruned from — the one choke
  /// point every caller goes through (create, auto-save, list, retention, the
  /// headless handlers, sync).
  Future<Directory> getBackupDirectory() => _getBackupDirectory();

  /// Point backups at [directoryPath]; pass null or blank to return to the
  /// default beside the database.
  ///
  /// Deliberately does NOT move or copy the bundles already written elsewhere:
  /// silently relocating an archive on a settings change is not something the
  /// operator asked for, and the old folder keeps whatever it holds. It IS
  /// created eagerly, so a path that cannot be written to fails here — while
  /// the operator is looking at the picker — instead of at 3am when the
  /// scheduled backup fires.
  Future<void> setBackupDirectory(String? directoryPath) async {
    final dao = SettingsDao(database);
    final trimmed = directoryPath?.trim() ?? '';
    if (trimmed.isEmpty) {
      await dao.deleteSetting(backupDirectorySettingKey);
      return;
    }
    await Directory(trimmed).create(recursive: true);
    await dao.setSetting(backupDirectorySettingKey, trimmed);
  }
}
