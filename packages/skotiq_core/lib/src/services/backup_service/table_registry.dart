part of '../backup_service.dart';

extension _BackupTableRegistry on BackupService {
  // Private export methods

  Future<Map<String, dynamic>> _exportSettings() async {
    final settingsDao = SettingsDao(database);
    final allSettings = await settingsDao.getAllSettings();
    // The backup folder describes THIS machine's disks, not the archive's
    // contents. Carrying it in the bundle would let a restore repoint where a
    // different install writes — and where "Maximum backups" deletes from — at
    // a path chosen on another machine.
    allSettings.remove(BackupService.backupDirectorySettingKey);
    return allSettings;
  }

  Future<List<Map<String, dynamic>>> _exportProfiles() async {
    final profilesDao = EquipmentProfilesDao(database);
    final profiles = await profilesDao.getAllProfiles();

    // Drift's generated JSON codec includes the primary key, default/active
    // flags, timestamps, device display names, and every current profile
    // column, so `id` and `isDefault` survive a restore: without them a
    // replace-restore allocates a new id and loses the startup-profile
    // designation, breaking foreign-key identity.
    return profiles.map((profile) => profile.toJson()).toList();
  }

  Future<List<Map<String, dynamic>>> _exportSequences() async {
    final sequences = await sequenceRepository.loadAllSequences();

    return sequences.map((sequence) {
      return _sequenceToJson(sequence);
    }).toList();
  }

  Future<List<Map<String, dynamic>>> _exportTargets() async {
    final targetsDao = TargetsDao(database);
    final targets = await targetsDao.getAllTargets();

    return targets.map((target) {
      return {
        'name': target.name,
        'catalogId': target.catalogId,
        'ra': target.ra,
        'dec': target.dec,
        'constellation': target.constellation,
        'objectType': target.objectType,
        'magnitude': target.magnitude,
        'sizeArcmin': target.sizeArcmin,
        'notes': target.notes,
        'isFavorite': target.isFavorite,
        'priority': target.priority,
      };
    }).toList();
  }

  // Extended-coverage export/import. Each table is exported as a
  // JSON array of the drift-generated `toJson()` representation. Restore
  // uses the corresponding companion's `fromJson` + InsertMode.insertOrIgnore
  // so existing primary keys round-trip without overwriting current data.

  /// Export every extended-coverage table to a `tableKey -> rows` map.
  /// Keys are the same strings the restore branch looks for in the backup
  /// JSON. Missing dependencies (e.g. an empty table) yield an empty list,
  /// never a missing key, so an old backup file is structurally complete.
  Future<Map<String, List<Map<String, dynamic>>>>
  _exportExtendedTables() async {
    return {
      // Calibration library
      'darkLibrary': await _dumpTable(database.darkLibrary),
      'flatHistory': await _dumpTable(database.flatHistory),
      'defectMaps': await _dumpTable(database.defectMaps),
      // Run history
      'sequenceRuns': await _dumpTable(database.sequenceRuns),
      // Notes journal (observation_logs)
      'notesJournal': await _dumpTable(database.observationLogs),
      // Polar alignment / guide history
      'polarAlignmentHistory': await _dumpTable(database.polarAlignmentHistory),
      'guideRmsHistory': await _dumpTable(database.guideRmsHistory),
      // Science tables.
      'scienceSessionConfig': await _dumpTable(database.scienceSessionConfig),
      'photometryMeasurements': await _dumpTable(
        database.photometryMeasurements,
      ),
      'framePhotometricCalibration': await _dumpTable(
        database.framePhotometricCalibration,
      ),
      'transparencySamples': await _dumpTable(database.transparencySamples),
      'psfFieldTiles': await _dumpTable(database.psfFieldTiles),
      'scienceFrameQualityMetrics': await _dumpTable(
        database.scienceFrameQualityMetrics,
      ),
      'scienceTileMetrics': await _dumpTable(database.scienceTileMetrics),
      'astrometryResidualVectors': await _dumpTable(
        database.astrometryResidualVectors,
      ),
      'movingObjectCandidates': await _dumpTable(
        database.movingObjectCandidates,
      ),
      'photometricTransforms': await _dumpTable(database.photometricTransforms),
      'lineRatioProducts': await _dumpTable(database.lineRatioProducts),
      // Focus models
      'focusModels': await _dumpTable(database.focusModels),
      // Weather-safety configuration. NOT a key/value setting — it lives in
      // its own single-row table, so it has to be enumerated here or a restore
      // leaves every safety threshold (and the master switch) at defaults.
      // Imported by [_importWeatherSettings], which updates the singleton row
      // instead of insert-or-ignoring a second one.
      'weatherSettings': await _dumpTable(database.weatherSettings),
    };
  }

  /// Generic "select * + toJson" dump. Each drift TableInfo exposes a
  /// `map(Map<String, dynamic>)` factory that hydrates a typed
  /// DataClass from a row map. We pair `customSelect` (which gives a
  /// row as `Map<String, dynamic>` keyed by SQL column names) with that
  /// `map()` factory and then call the DataClass's `toJson()` so the
  /// import side can read the same camelCase keys back via
  /// `*.fromJson`. This is the only way to keep the export/import code
  /// table-agnostic without threading a typed generic through every
  /// call site (which trips Dart's `couldn't infer T` due to the
  /// drift-generated multi-level inheritance).
  ///
  /// Rows are read in [_dumpPageSize] pages ordered by `rowid`. The per-frame
  /// science tables (`photometry_measurements`, `guide_rms_history`) run to
  /// hundreds of thousands of rows over a season; an unpaged `SELECT *` holds
  /// the whole driver result set alive at the same time as the whole JSON
  /// projection. The caller reads inside one transaction, so paging observes a
  /// single consistent snapshot.
  Future<List<Map<String, dynamic>>> _dumpTable(TableInfo table) async {
    final out = <Map<String, dynamic>>[];
    var offset = 0;
    while (true) {
      final rows = await database
          .customSelect(
            'SELECT * FROM ${table.actualTableName} '
            'ORDER BY rowid LIMIT ${BackupService._dumpPageSize} OFFSET $offset',
          )
          .get();
      for (final row in rows) {
        // ignore: avoid_dynamic_calls
        final dataClass = (table as dynamic).map(row.data);
        // ignore: avoid_dynamic_calls
        out.add((dataClass as dynamic).toJson() as Map<String, dynamic>);
      }
      if (rows.length < BackupService._dumpPageSize) return out;
      offset += rows.length;
    }
  }

  /// Restore the single weather-safety configuration row.
  ///
  /// Deliberately NOT [_importRows]: this table always already holds a row (the
  /// DAO creates a defaults row on first read), so `insertOrIgnore` would keep
  /// the destination's defaults and silently drop the operator's restored
  /// thresholds — the same silent reset this key was added to fix. Configuration
  /// is exactly the case where the backup must win, so the existing row is
  /// updated in place; the auto-increment `id` from the source machine is
  /// ignored on purpose.
  Future<int> _importWeatherSettings(List<dynamic> rows) async {
    if (rows.isEmpty) return 0;
    final raw = rows.first;
    if (raw is! Map) {
      throw const FormatException(
        'Extended table row 0 of "weatherSettings" is not an object',
      );
    }
    final row = WeatherSettingRow.fromJson(raw.cast<String, dynamic>());
    final current = await database.weatherSettingsDao.getOrCreateSettings();
    await (database.update(
      database.weatherSettings,
    )..where((table) => table.id.equals(current.id))).write(
      WeatherSettingsCompanion(
        triggerDistanceKm: Value(row.triggerDistanceKm),
        cloudDensityThreshold: Value(row.cloudDensityThreshold),
        leadTimeMinutes: Value(row.leadTimeMinutes),
        weatherSafetyEnabled: Value(row.weatherSafetyEnabled),
        maxHumidityPercent: Value(row.maxHumidityPercent),
        maxWindSpeedKph: Value(row.maxWindSpeedKph),
        maxCloudCoverPercent: Value(row.maxCloudCoverPercent),
        autoParkEnabled: Value(row.autoParkEnabled),
        autoResumeEnabled: Value(row.autoResumeEnabled),
        preferredProvider: Value(row.preferredProvider),
        refreshIntervalSeconds: Value(row.refreshIntervalSeconds),
        updatedAt: Value(DateTime.now()),
      ),
    );
    return 1;
  }

  /// Generic per-row import. Each row's JSON is decoded into its companion
  /// via `fromJson`, then inserted with [InsertMode.insertOrIgnore] so
  /// existing primary keys are preserved. We never use `InsertMode.replace`
  /// here — restoring a backup must never destroy field-collected data the
  /// user generated after the backup was taken.
  Future<int> _importRows<T extends Insertable<dynamic>>(
    List<dynamic> rows,
    T Function(Map<String, dynamic>) decoder,
    TableInfo table,
  ) async {
    var count = 0;
    for (var index = 0; index < rows.length; index++) {
      final raw = rows[index];
      if (raw is! Map) {
        throw FormatException('Extended table row $index is not an object');
      }
      final row = decoder(raw.cast<String, dynamic>());
      final inserted = await database
          .into(table)
          .insert(row, mode: InsertMode.insertOrIgnore);
      // `insert` returns the row id on success (or the existing one on
      // conflict). Drift returns 0 specifically when an InsertOrIgnore
      // conflicted and nothing was written.
      if (inserted != 0) {
        count++;
      }
    }
    return count;
  }
}
