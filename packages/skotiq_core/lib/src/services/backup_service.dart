import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import '../database/database.dart' hide Sequence, SequenceNode;
import '../database/daos/settings_dao.dart';
import '../database/daos/equipment_profiles_dao.dart';
import '../database/daos/targets_dao.dart';
import '../providers/database_provider.dart';
import '../providers/app_version_provider.dart';
import '../models/sequence/sequence_models.dart';
import 'logging_service.dart';
import 'sequence_file_service.dart';
import 'sequence_repository.dart';

part 'backup_service/sequence_codec.dart';
part 'backup_service/backup_models.dart';
part 'backup_service/backup_value_codecs.dart';
part 'backup_service/table_registry.dart';
part 'backup_service/restore_validation.dart';

/// Comprehensive backup and restore service for Skotiq data
class BackupService {
  final SkotiqDatabase database;
  final SequenceRepository sequenceRepository;
  final LoggingService _logger;
  final Future<Directory> Function()? _backupDirectoryProvider;

  // Bumped from '2.0' to '2.1' when we broadened backup coverage to
  // include dark_library, flat_history, defect_maps, polar_alignment_history,
  // guide_rms_history, sequence_runs, observation_logs (notes journal),
  // and the science_* tables. Restore is idempotent (insertOrIgnore) so
  // older v2.0 backups remain restorable on the new code path.
  static const String backupVersion = '2.1';

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
  /// Deliberately excluded from [_exportSettings]: a bundle restored from
  /// another machine would otherwise repoint THIS install's backup folder — and
  /// its retention deletes — at a path that machine chose.
  static const String backupDirectorySettingKey = 'backup.directory';
  final String runtimeAppVersion;

  BackupService({
    required this.database,
    required this.sequenceRepository,
    required LoggingService logger,
    String? appVersion,
    Future<Directory> Function()? backupDirectoryProvider,
  }) : runtimeAppVersion = appVersion?.trim().isNotEmpty == true
           ? appVersion!.trim()
           : BackupService.appVersion,
       _backupDirectoryProvider = backupDirectoryProvider,
       _logger = logger;

  /// Create a full backup of all application data
  ///
  /// Backs up:
  /// - Application settings
  /// - Equipment profiles
  /// - Sequences (both regular and templates)
  /// - Targets
  ///
  /// Returns [BackupResult] with backup file path if successful
  Future<BackupResult> createBackup({
    String? customPath,
    bool humanReadable = true,
  }) async {
    try {
      _logger.debug('Starting full backup...', source: 'BackupService');

      // Read every table from one Drift transaction so a capture/session
      // update cannot land halfway through the archive and produce counts or
      // foreign-key relationships from different moments in time.
      final snapshot = await database.transaction(() async {
        return (
          settings: await _exportSettings(),
          profiles: await _exportProfiles(),
          sequences: await _exportSequences(),
          targets: await _exportTargets(),
          extendedTables: await _exportExtendedTables(),
        );
      });
      final settings = snapshot.settings;
      final profiles = snapshot.profiles;
      final sequences = snapshot.sequences;
      final targets = snapshot.targets;

      // Extended coverage: each entry is the literal table name and a list of
      // rows. Restore round-trips through `_genericTableImport`.
      final extendedTables = snapshot.extendedTables;

      // Build backup data structure
      final backup = <String, dynamic>{
        'version': backupVersion,
        'createdAt': DateTime.now().toIso8601String(),
        'appVersion': runtimeAppVersion,
        'platform': Platform.operatingSystem,
        'metadata': {
          'settingsCount': settings.length,
          'profilesCount': profiles.length,
          'sequencesCount': sequences.length,
          'targetsCount': targets.length,
          // Per-extended-table row counts so an operator can spot
          // a partial backup (a table with unexpected 0 rows) before
          // committing to a restore.
          for (final entry in extendedTables.entries)
            '${entry.key}Count': entry.value.length,
        },
        'settings': settings,
        'equipmentProfiles': profiles,
        'sequences': sequences,
        'targets': targets,
        // Flatten the extended tables into top-level keys so a JSON
        // viewer surfaces the same structure as the original four keys.
        for (final entry in extendedTables.entries) entry.key: entry.value,
      };

      // Determine save location
      final filePath = customPath ?? await _getBackupFilePath();
      if (filePath == null) {
        return BackupResult(
          success: false,
          errorMessage: 'No backup file path specified',
          timestamp: DateTime.now(),
        );
      }

      // Write to a sibling temporary file and rename only after a flushed,
      // complete JSON payload exists. A crash or full disk therefore leaves
      // the previous destination intact rather than a plausible-looking
      // truncated backup.
      final file = File(filePath);
      await file.parent.create(recursive: true);
      final tempFile = File(
        path.join(
          file.parent.path,
          '.${path.basename(file.path)}.'
          '${DateTime.now().microsecondsSinceEpoch}.tmp',
        ),
      );
      try {
        await _writeJsonArchive(
          tempFile,
          backup,
          indent: humanReadable ? '  ' : null,
        );
        try {
          await tempFile.rename(file.path);
        } on FileSystemException {
          // Windows does not replace an existing destination via rename.
          // The complete temp file already exists, so only now remove the old
          // destination and perform the final same-directory rename.
          if (await file.exists()) await file.delete();
          await tempFile.rename(file.path);
        }
      } finally {
        if (await tempFile.exists()) await tempFile.delete();
      }

      final extendedItems = extendedTables.values.fold<int>(
        0,
        (sum, rows) => sum + rows.length,
      );
      final totalItems =
          settings.length +
          profiles.length +
          sequences.length +
          targets.length +
          extendedItems;

      _logger.info(
        'Backup completed successfully\n'
        '  File: $filePath\n'
        '  Settings: ${settings.length}\n'
        '  Profiles: ${profiles.length}\n'
        '  Sequences: ${sequences.length}\n'
        '  Targets: ${targets.length}\n'
        '  Extended tables: ${extendedTables.length} '
        '(rows: $extendedItems)\n'
        '  Total items: $totalItems',
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
    }
  }

  /// Restore data from a backup file
  ///
  /// Restores all backed up data, optionally merging with existing data
  /// or replacing it completely.
  ///
  /// DATA-LOSS GUARD (P1): when [replaceExisting] is true the live database
  /// is wiped before the backup is imported. To avoid destroying the user's
  /// data behind a corrupt or truncated backup file, the ENTIRE payload is
  /// read and validated *before* any destructive operation runs. If the
  /// payload is missing its version, isn't a JSON object, has a
  /// wrong-shaped top-level section, or any typed row fails to decode, the
  /// restore aborts with the live data fully intact (`_clearAllData` is
  /// never reached). The clear + import runs only after validation passes.
  Future<RestoreResult> restoreBackup({
    required String filePath,
    bool replaceExisting = false,
  }) async {
    try {
      _logger.debug('Starting restore from: $filePath');

      // Read and parse backup file
      final file = File(filePath);
      if (!await file.exists()) {
        return RestoreResult(
          success: false,
          errorMessage: 'Backup file not found',
          timestamp: DateTime.now(),
        );
      }

      final jsonString = await file.readAsString();

      // PHASE 1 — Validate & stage. Nothing below this block touches the
      // live database. Any failure returns a non-destructive error.
      final _ValidatedBackup staged;
      try {
        staged = _validateBackupPayload(jsonString);
      } on _BackupValidationException catch (e) {
        _logger.error(
          'Restore aborted before touching live data: ${e.message}',
          source: 'BackupService',
        );
        return RestoreResult(
          success: false,
          errorMessage: e.message,
          timestamp: DateTime.now(),
        );
      }

      _logger.debug('Restoring backup version: ${staged.version}');

      final backup = staged.backup;

      // PHASE 2 — Apply. The payload is now known to be structurally
      // sound and every typed section decodes, so the destructive clear
      // can run without risking unrecoverable data loss against garbage.

      // Apply every database mutation in one transaction. A malformed late
      // extended-table row or write failure must roll back the earlier clear,
      // settings, profiles, and sequences instead of returning a plausible
      // partial restore.
      final categoryCounts = await database.transaction(() async {
        if (replaceExisting) {
          _logger.debug('Clearing existing data...');
          await _clearAllData();
        }

        // Restore data in order
        final categoryCounts = <String, int>{};

        // Restore settings — re-use the validated copy so we never re-parse.
        if (staged.settings != null) {
          final count = await _importSettings(
            staged.settings!,
            replace: replaceExisting,
          );
          categoryCounts['settings'] = count;
          _logger.debug('Restored $count settings');
        }

        // Restore equipment profiles. No `replace` flag: profiles are re-keyed
        // on name rather than on the bundle's row ids, so the importer updates
        // or inserts on its own terms. A replace-restore has already emptied
        // the table above, which is the state _importProfiles reads to decide
        // whether the bundle's default/active flags may be honoured.
        if (staged.profiles != null) {
          final count = await _importProfiles(staged.profiles!);
          categoryCounts['profiles'] = count;
          _logger.debug('Restored $count profiles');
        }

        // Restore sequences — the staged list holds fully-decoded sequences
        // so a malformed node can't slip past validation into a half-wiped DB.
        if (staged.sequences != null) {
          var count = 0;
          for (final sequence in staged.sequences!) {
            await sequenceRepository.saveSequence(sequence);
            count++;
          }
          categoryCounts['sequences'] = count;
          _logger.debug('Restored $count sequences');
        }

        // Restore targets
        if (staged.targets != null) {
          final count = await _importTargets(
            staged.targets!,
            replace: replaceExisting,
          );
          categoryCounts['targets'] = count;
          _logger.debug('Restored $count targets');
        }

        // Restore the extended-coverage tables. Idempotent:
        // insertOrIgnore on the row's primary key. We never overwrite
        // existing rows, even when `replaceExisting` is true — the
        // `_clearAllData` step that runs before this branch wipes the
        // tables that the legacy backup pass owns, and the extended
        // tables (calibration / science / forensics / notes / runs /
        // alignments / guide history) are intentionally NOT cleared so
        // a corrupted-payload restore can never destroy field-collected
        // data.
        for (final entry in _extendedTableImporters.entries) {
          final key = entry.key;
          if (!backup.containsKey(key)) continue;
          final rows = backup[key];
          if (rows is! List) {
            throw FormatException(
              'Extended backup table "$key" must be a JSON array',
            );
          }
          final count = await entry.value(rows);
          categoryCounts[key] = count;
          _logger.debug('Restored $count rows into "$key"');
        }
        return categoryCounts;
      });

      final totalItems = categoryCounts.values.fold<int>(
        0,
        (sum, count) => sum + count,
      );

      _logger.info(
        'Restore completed successfully\n'
        '  Total items restored: $totalItems',
        source: 'BackupService',
      );

      return RestoreResult(
        success: true,
        timestamp: DateTime.now(),
        itemsRestored: totalItems,
        categoryCounts: categoryCounts,
      );
    } catch (e, stackTrace) {
      _logger.error('Restore failed: $e\n$stackTrace', source: 'BackupService');
      return RestoreResult(
        success: false,
        errorMessage: e.toString(),
        timestamp: DateTime.now(),
      );
    }
  }

  /// Read metadata from a backup file without restoring
  Future<BackupMetadata?> readBackupMetadata(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;

      final jsonString = await file.readAsString();
      final backup = jsonDecode(jsonString) as Map<String, dynamic>;

      return BackupMetadata.fromJson(backup);
    } catch (e) {
      _logger.debug('Failed to read backup metadata: $e');
      return null;
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
              (entity.path.endsWith('.nsbackup') ||
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
      'skotiq_autosave_$timestamp.nsbackup',
    );

    // Unattended archive: nobody reads it in an editor, and the indentation
    // roughly doubles both the bytes written and the peak encode cost on a
    // host that may be mid-session.
    return createBackup(customPath: filePath, humanReadable: false);
  }

  /// Rows read per `_dumpTable` page.
  static const int _dumpPageSize = 2000;

  /// Encode [archive] straight into [file] in chunks.
  ///
  /// The archive holds every row of every table; building it as one indented
  /// `String` (and then again as one byte list) stalled the calling isolate for
  /// seconds and was a plausible OOM on an appliance, and this runs unattended
  /// off the auto-backup timer mid-session.
  static Future<void> _writeJsonArchive(
    File file,
    Object? archive, {
    String? indent,
  }) async {
    final sink = file.openWrite();
    try {
      final encoder = JsonUtf8Encoder(
        indent,
        null,
        64 * 1024,
      ).startChunkedConversion(_IOSinkBytes(sink));
      encoder.add(archive);
      encoder.close();
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  /// Importer signature used by [_extendedTableImporters]. Returns the
  /// number of rows that were successfully inserted (rejected duplicates
  /// don't count).
  late final Map<String, Future<int> Function(List<dynamic>)>
  _extendedTableImporters = {
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
    'weatherSettings': _importWeatherSettings,
  };

  // Private utility methods

  Future<String?> _getBackupFilePath() async {
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final backupDir = await _getBackupDirectory();
    await backupDir.create(recursive: true);
    return path.join(backupDir.path, 'skotiq_backup_$timestamp.nsbackup');
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

/// Provider for BackupService
final backupServiceProvider = Provider<BackupService>((ref) {
  final database = ref.watch(databaseProvider);
  final sequenceRepo = ref.watch(sequenceRepositoryProvider);
  final logger = ref.watch(loggingServiceProvider);
  final appVersion = ref.watch(appVersionProvider).version;

  return BackupService(
    database: database,
    sequenceRepository: sequenceRepo,
    logger: logger,
    appVersion: appVersion,
  );
});
