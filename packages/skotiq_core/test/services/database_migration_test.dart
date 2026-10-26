import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';

import '../fixtures/synthetic_old_profile_fixtures.dart';

void main() {
  test('migrates captured_images to include quality_score', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'skotiq_migration_test_',
    );
    final dbFile = File('${tempDir.path}/skotiq.db');

    final setupDb = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    try {
      await setupDb.customStatement('PRAGMA foreign_keys = OFF');
      await setupDb.customStatement('DROP TABLE IF EXISTS captured_images');
      await setupDb.customStatement('''
CREATE TABLE captured_images (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  file_path TEXT NOT NULL,
  file_name TEXT NOT NULL,
  file_format TEXT NOT NULL DEFAULT 'fits',
  file_size INTEGER,
  session_id INTEGER REFERENCES imaging_sessions(id) ON DELETE CASCADE,
  target_id INTEGER REFERENCES targets(id) ON DELETE SET NULL,
  frame_type TEXT NOT NULL DEFAULT 'light',
  exposure_duration REAL NOT NULL,
  gain INTEGER,
  offset INTEGER,
  bin_x INTEGER NOT NULL DEFAULT 1,
  bin_y INTEGER NOT NULL DEFAULT 1,
  filter TEXT,
  sensor_temp REAL,
  cooler_power REAL,
  hfr REAL,
  star_count INTEGER,
  background REAL,
  noise REAL,
  guiding_rms_ra REAL,
  guiding_rms_dec REAL,
  guiding_rms_total REAL,
  mount_ra REAL,
  mount_dec REAL,
  mount_altitude REAL,
  mount_azimuth REAL,
  pier_side TEXT,
  focuser_position INTEGER,
  focuser_temp REAL,
  rotator_angle REAL,
  is_plate_solved INTEGER NOT NULL DEFAULT 0,
  solved_ra REAL,
  solved_dec REAL,
  solved_rotation REAL,
  solved_pixel_scale REAL,
  captured_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
  is_accepted INTEGER NOT NULL DEFAULT 1,
  rejection_reason TEXT
)
''');
      await setupDb.customStatement('PRAGMA user_version = 9');
    } finally {
      await setupDb.close();
    }

    final db = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    try {
      final columns = await db
          .customSelect("PRAGMA table_info('captured_images')")
          .get();
      final hasQualityScore = columns.any(
        (row) => row.data['name'] == 'quality_score',
      );

      expect(
        hasQualityScore,
        isTrue,
        reason: 'captured_images should include quality_score after migration',
      );
    } finally {
      await db.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  });

  test('creates science quality metric tables in latest schema', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    try {
      final tables = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
          .get();
      final tableNames = tables
          .map((row) => row.data['name']?.toString() ?? '')
          .toSet();

      expect(tableNames.contains('science_frame_quality_metrics'), isTrue);
      expect(tableNames.contains('science_tile_metrics'), isTrue);

      final settings = await db.settingsDao.getAllSettings();
      expect(settings['science.feature.frame_quality_maps'], equals('true'));
      expect(settings['science.feature.surface3d'], equals('true'));
      expect(settings['science.overlay.live_grid_rows'], equals('12'));
      expect(settings['science.overlay.live_grid_cols'], equals('16'));
    } finally {
      await db.close();
    }
  });

  test(
    'latest schema keeps imaging sessions when sequences are deleted',
    () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      try {
        final sequenceId = await db
            .into(db.sequences)
            .insert(SequencesCompanion.insert(name: 'Sequence A'));
        final sessionId = await db
            .into(db.imagingSessions)
            .insert(
              ImagingSessionsCompanion.insert(
                startTime: DateTime.now(),
                status: const Value('active'),
                sequenceId: Value(sequenceId),
              ),
            );

        await (db.delete(
          db.sequences,
        )..where((t) => t.id.equals(sequenceId))).go();

        final session = await (db.select(
          db.imagingSessions,
        )..where((t) => t.id.equals(sessionId))).getSingle();
        expect(session.sequenceId, equals(null));
      } finally {
        await db.close();
      }
    },
  );

  test('latest schema cascades polar history on profile delete', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    try {
      final profileId = await db
          .into(db.equipmentProfiles)
          .insert(EquipmentProfilesCompanion.insert(name: 'Profile A'));

      await db
          .into(db.polarAlignmentHistory)
          .insert(
            PolarAlignmentHistoryCompanion.insert(
              equipmentProfileId: Value(profileId),
              initialAzimuthError: 10,
              initialAltitudeError: 11,
              initialTotalError: 15,
              finalAzimuthError: 1,
              finalAltitudeError: 2,
              finalTotalError: 3,
              startedAt: DateTime.now(),
              completedAt: DateTime.now(),
              configJson: '{}',
            ),
          );

      await (db.delete(
        db.equipmentProfiles,
      )..where((t) => t.id.equals(profileId))).go();

      final remaining = await db.select(db.polarAlignmentHistory).get();
      expect(remaining, isEmpty);
    } finally {
      await db.close();
    }
  });

  test(
    'latest schema enforces single science config row per session',
    () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      try {
        final sessionId = await db
            .into(db.imagingSessions)
            .insert(ImagingSessionsCompanion.insert(startTime: DateTime.now()));

        await db
            .into(db.scienceSessionConfig)
            .insert(
              ScienceSessionConfigCompanion.insert(sessionId: Value(sessionId)),
            );

        await expectLater(
          db
              .into(db.scienceSessionConfig)
              .insert(
                ScienceSessionConfigCompanion.insert(
                  sessionId: Value(sessionId),
                ),
              ),
          throwsA(isA<SqliteException>()),
        );
      } finally {
        await db.close();
      }
    },
  );

  test('schema 35 database upgrades to add switch_id column ', () async {
    final tempDir = await Directory.systemTemp.createTemp('skotiq_v35_to_v36_');
    final dbFile = File('${tempDir.path}/skotiq.db');

    // Set up a database at schema version 35 (the version that introduced
    // safety_monitor_id but predates the switch_id column).
    final setupDb = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    try {
      // Drop the switch_id column (and recreate the table) so we look like
      // a real v35 database that never had this column.
      await setupDb.customStatement('PRAGMA foreign_keys = OFF');
      // The freshly-created Drift schema already has switch_id at v36, so
      // we strip it back to simulate an older install.
      await setupDb.customStatement(
        'ALTER TABLE equipment_profiles DROP COLUMN switch_id',
      );
      await setupDb.customStatement('PRAGMA user_version = 35');
    } finally {
      await setupDb.close();
    }

    // Re-open at the current schema version — onUpgrade should add the
    // switch_id column back via the v36 migration.
    final db = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    try {
      final upgradedVersion = await db
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(upgradedVersion.data['user_version'], equals(db.schemaVersion));

      final columns = await db
          .customSelect("PRAGMA table_info('equipment_profiles')")
          .get();
      final hasSwitchId = columns.any((row) => row.data['name'] == 'switch_id');

      expect(
        hasSwitchId,
        isTrue,
        reason:
            'equipment_profiles should include switch_id after '
            'v36 migration ',
      );

      // Existing profiles upgrade cleanly with switch_id = null.
      final profileId = await db
          .into(db.equipmentProfiles)
          .insert(EquipmentProfilesCompanion.insert(name: 'Migrated Profile'));
      final row = await (db.select(
        db.equipmentProfiles,
      )..where((t) => t.id.equals(profileId))).getSingle();
      expect(row.switchId, equals(null));
    } finally {
      await db.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  });

  test('equipment profile round-trips switchId through Drift companion '
      '', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    try {
      const switchId = 'native:zwo-eaf:switch:0';
      final id = await db
          .into(db.equipmentProfiles)
          .insert(
            EquipmentProfilesCompanion.insert(
              name: 'Switch Profile',
              switchId: const Value(switchId),
            ),
          );

      final fetched = await (db.select(
        db.equipmentProfiles,
      )..where((t) => t.id.equals(id))).getSingle();
      expect(fetched.switchId, equals(switchId));

      // copyWith with absent leaves the value intact, present overwrites.
      await db
          .update(db.equipmentProfiles)
          .replace(
            fetched.copyWith(switchId: const Value('alpaca:host:11111:0')),
          );
      final updated = await (db.select(
        db.equipmentProfiles,
      )..where((t) => t.id.equals(id))).getSingle();
      expect(updated.switchId, equals('alpaca:host:11111:0'));

      // Clearing the column.
      await db
          .update(db.equipmentProfiles)
          .replace(updated.copyWith(switchId: const Value(null)));
      final cleared = await (db.select(
        db.equipmentProfiles,
      )..where((t) => t.id.equals(id))).getSingle();
      expect(cleared.switchId, equals(null));
    } finally {
      await db.close();
    }
  });

  test('latest schema enforces at most one active equipment profile', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    try {
      await db
          .into(db.equipmentProfiles)
          .insert(
            EquipmentProfilesCompanion.insert(
              name: 'Profile A',
              isActive: const Value(true),
            ),
          );

      await expectLater(
        db
            .into(db.equipmentProfiles)
            .insert(
              EquipmentProfilesCompanion.insert(
                name: 'Profile B',
                isActive: const Value(true),
              ),
            ),
        throwsA(isA<SqliteException>()),
      );
    } finally {
      await db.close();
    }
  });

  test(
    'fresh and upgraded databases converge on the same default settings',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_settings_migration_',
      );
      final dbFile = File('${tempDir.path}/skotiq.db');

      final setupDb = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        await setupDb.customStatement('DELETE FROM app_settings');
        await setupDb.customStatement('PRAGMA user_version = 21');
      } finally {
        await setupDb.close();
      }

      final upgradedDb = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      final freshDb = SkotiqDatabase.forTesting(NativeDatabase.memory());
      try {
        final upgradedSettings = await upgradedDb.settingsDao.getAllSettings();
        final freshSettings = await freshDb.settingsDao.getAllSettings();

        for (final key in const [
          'theme',
          'auto_connect_equipment',
          'notifications_enabled',
          'af_filter_settings',
          'science.overlay.live_grid_rows',
          'dark_library.temp_tolerance',
        ]) {
          expect(upgradedSettings[key], equals(freshSettings[key]));
        }

        final upgradedTables = await upgradedDb
            .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
            .get();
        final upgradedTableNames = upgradedTables
            .map((row) => row.data['name']?.toString() ?? '')
            .toSet();
        for (final tableName in const [
          'observation_logs',
          'observing_lists',
          'sequence_runs',
        ]) {
          expect(upgradedTableNames.contains(tableName), isTrue);
        }

        final targetsColumns = await upgradedDb
            .customSelect("PRAGMA table_info('targets')")
            .get();
        final photometryColumns = await upgradedDb
            .customSelect("PRAGMA table_info('photometry_measurements')")
            .get();
        expect(
          targetsColumns.any(
            (row) => row.data['name'] == 'goal_integration_secs',
          ),
          isTrue,
        );
        expect(
          photometryColumns.any(
            (row) => row.data['name'] == 'standard_magnitude',
          ),
          isTrue,
        );
      } finally {
        await upgradedDb.close();
        await freshDb.close();
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    },
  );

  test('v62 rewrites the seeded old accent and keeps a real choice', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'skotiq_accent_migration_',
    );
    final seededFile = File('${tempDir.path}/seeded.db');
    final chosenFile = File('${tempDir.path}/chosen.db');
    try {
      // Two databases that both last ran at v61: one still carrying the old
      // seeded accent, one where a different swatch was picked. Both land on
      // the same onUpgrade path.
      final seededSetup = SkotiqDatabase.forTesting(NativeDatabase(seededFile));
      try {
        await seededSetup.customStatement(
          "UPDATE app_settings SET value = '#6EB3EC' "
          "WHERE key = 'accent_color'",
        );
        await seededSetup.customStatement('PRAGMA user_version = 61');
      } finally {
        await seededSetup.close();
      }
      final chosenSetup = SkotiqDatabase.forTesting(NativeDatabase(chosenFile));
      try {
        await chosenSetup.customStatement(
          "UPDATE app_settings SET value = '#43B67A' "
          "WHERE key = 'accent_color'",
        );
        await chosenSetup.customStatement('PRAGMA user_version = 61');
      } finally {
        await chosenSetup.close();
      }

      final seededDb = SkotiqDatabase.forTesting(NativeDatabase(seededFile));
      final chosenDb = SkotiqDatabase.forTesting(NativeDatabase(chosenFile));
      try {
        final seeded = await seededDb.settingsDao.getAllSettings();
        final chosen = await chosenDb.settingsDao.getAllSettings();
        expect(seeded['accent_color'], equals('#A48CF2'));
        expect(chosen['accent_color'], equals('#43B67A'));
      } finally {
        await seededDb.close();
        await chosenDb.close();
      }
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  });

  test('v63 adds the filter columns to the photometry tables', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'skotiq_filter_columns_migration_',
    );
    final file = File('${tempDir.path}/v62.db');
    const added = {
      'photometry_measurements': ['filter'],
      'frame_photometric_calibration': [
        'filter',
        'photometric_band',
        'band_is_standard',
        'zero_point_error',
      ],
      'transparency_samples': ['filter', 'extinction_measured'],
    };
    try {
      final setup = SkotiqDatabase.forTesting(NativeDatabase(file));
      try {
        for (final entry in added.entries) {
          for (final column in entry.value) {
            await setup.customStatement(
              'ALTER TABLE ${entry.key} DROP COLUMN $column',
            );
          }
        }
        await setup.customStatement('PRAGMA user_version = 62');
      } finally {
        await setup.close();
      }

      final db = SkotiqDatabase.forTesting(NativeDatabase(file));
      try {
        for (final entry in added.entries) {
          final columns =
              (await db.customSelect('PRAGMA table_info(${entry.key})').get())
                  .map((row) => row.read<String>('name'))
                  .toSet();
          expect(columns, containsAll(entry.value), reason: entry.key);
        }
      } finally {
        await db.close();
      }
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  });

  test('schema 12 database upgrades to the complete current table set', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'skotiq_schema12_upgrade_',
    );
    final dbFile = File('${tempDir.path}/skotiq.db');

    final setupDb = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    try {
      for (final tableName in _tablesIntroducedAfterSchema12) {
        await setupDb.customStatement('DROP TABLE IF EXISTS $tableName');
      }
      await setupDb.customStatement(
        "DELETE FROM app_settings WHERE key LIKE 'science.%' OR key LIKE 'dark_library.%'",
      );
      await setupDb.customStatement('PRAGMA user_version = 12');
    } finally {
      await setupDb.close();
    }

    final upgradedDb = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    final freshDb = SkotiqDatabase.forTesting(NativeDatabase.memory());
    try {
      final upgradedVersion = await upgradedDb
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(
        upgradedVersion.data['user_version'],
        equals(upgradedDb.schemaVersion),
      );

      final upgradedTables = await _sqliteTableNames(upgradedDb);
      final freshDriftTables = freshDb.allTables
          .map((table) => table.actualTableName)
          .toSet();

      expect(
        upgradedTables,
        containsAll(freshDriftTables),
        reason:
            'Upgraded schema 12 databases must contain every current '
            'Drift-managed table.',
      );

      final upgradedSettings = await upgradedDb.settingsDao.getAllSettings();
      for (final key in const [
        'science.feature.photometry',
        'science.feature.frame_quality_maps',
        'science.overlay.live_grid_rows',
        'dark_library.auto_subtract',
        'dark_library.temp_tolerance',
      ]) {
        expect(
          upgradedSettings[key] != null,
          isTrue,
          reason: '$key should be restored during upgrade.',
        );
      }

      final photometryColumns = await upgradedDb
          .customSelect("PRAGMA table_info('photometry_measurements')")
          .get();
      expect(
        photometryColumns.any(
          (row) => row.data['name'] == 'standard_magnitude',
        ),
        isTrue,
      );
    } finally {
      await upgradedDb.close();
      await freshDb.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  });

  test(
    'synthetic schema 20 profile fixture normalizes active and optics',
    () async {
      final fixture =
          await SyntheticOldProfileFixture.schema20WithDuplicateActiveProfiles();
      final db = SkotiqDatabase.forTesting(NativeDatabase(fixture.dbFile));
      try {
        final upgradedVersion = await db
            .customSelect('PRAGMA user_version')
            .getSingle();
        expect(upgradedVersion.data['user_version'], equals(db.schemaVersion));

        final profiles = await db.select(db.equipmentProfiles).get();
        expect(profiles, hasLength(2));

        final activeProfiles = profiles
            .where((profile) => profile.isActive)
            .toList();
        expect(
          activeProfiles.map((profile) => profile.name),
          equals(['Legacy Observatory']),
          reason: 'Migration v21 should keep only the newest active profile.',
        );

        final indexes = await db
            .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
            .get();
        expect(
          indexes.map((row) => row.data['name']).toSet(),
          contains('idx_profiles_single_active'),
          reason: 'The partial unique active-profile index should be restored.',
        );
        await expectLater(
          db
              .into(db.equipmentProfiles)
              .insert(
                EquipmentProfilesCompanion.insert(
                  name: 'Duplicate Active Profile',
                  isActive: const Value(true),
                ),
              ),
          throwsA(isA<SqliteException>()),
          reason:
              'Upgraded legacy databases should reject another active '
              'profile after migration.',
        );

        final widefield = profiles.singleWhere(
          (profile) => profile.name == 'Legacy Widefield',
        );
        expect(widefield.telescopeFocalLength, equals(250.0));
        expect(widefield.telescopeAperture, equals(60.0));

        final observatory = profiles.singleWhere(
          (profile) => profile.name == 'Legacy Observatory',
        );
        expect(observatory.focalLength, equals(900.0));
        expect(observatory.aperture, equals(120.0));
      } finally {
        await db.close();
        await fixture.dispose();
      }
    },
  );

  test(
    'synthetic schema 20 science fixture deduplicates session configs',
    () async {
      final fixture =
          await SyntheticOldProfileFixture.schema20WithDuplicateScienceSessionConfigs();
      final db = SkotiqDatabase.forTesting(NativeDatabase(fixture.dbFile));
      try {
        final upgradedVersion = await db
            .customSelect('PRAGMA user_version')
            .getSingle();
        expect(upgradedVersion.data['user_version'], equals(db.schemaVersion));

        final configs = await db
            .customSelect(
              'SELECT id, session_id, photometry_enabled, psf_grid_rows '
              'FROM science_session_config WHERE session_id = 1',
            )
            .get();
        expect(
          configs,
          hasLength(1),
          reason: 'Migration v21 should dedupe science session configs.',
        );
        expect(configs.single.data['id'], equals(2));
        expect(configs.single.data['photometry_enabled'], equals(0));
        expect(configs.single.data['psf_grid_rows'], equals(8));

        final indexes = await db
            .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
            .get();
        expect(
          indexes.map((row) => row.data['name']).toSet(),
          contains('idx_science_session_config_session_unique'),
          reason:
              'The partial unique science-session config index should be '
              'restored after dedupe.',
        );

        await expectLater(
          db
              .into(db.scienceSessionConfig)
              .insert(
                ScienceSessionConfigCompanion.insert(sessionId: const Value(1)),
              ),
          throwsA(isA<SqliteException>()),
          reason:
              'Upgraded legacy databases should reject another config for '
              'the same session after migration.',
        );
      } finally {
        await db.close();
        await fixture.dispose();
      }
    },
  );

  test(
    'synthetic schema 20 weather fixture deduplicates singleton settings',
    () async {
      final fixture =
          await SyntheticOldProfileFixture.schema20WithDuplicateWeatherSettings();
      final db = SkotiqDatabase.forTesting(NativeDatabase(fixture.dbFile));
      try {
        final upgradedVersion = await db
            .customSelect('PRAGMA user_version')
            .getSingle();
        expect(upgradedVersion.data['user_version'], equals(db.schemaVersion));

        final settings = await db.weatherSettingsDao.getOrCreateSettings();
        expect(settings.id, equals(1));
        expect(settings.preferredProvider, equals('legacy_primary'));
        expect(settings.triggerDistanceKm, equals(25.0));
        expect(settings.weatherSafetyEnabled, isTrue);

        final rows = await db
            .customSelect('SELECT id FROM weather_settings')
            .get();
        expect(
          rows,
          hasLength(1),
          reason:
              'Upgraded legacy weather settings should collapse to the '
              'primary singleton row on first settings access.',
        );

        await db.weatherSettingsDao.updateSettings(preferredProvider: 'noaa');
        final updated = await db.weatherSettingsDao.getSettings();
        expect(updated?.id, equals(1));
        expect(updated?.preferredProvider, equals('noaa'));
      } finally {
        await db.close();
        await fixture.dispose();
      }
    },
  );

  test(
    'synthetic schema 17 image fixture preserves metadata cascade',
    () async {
      final fixture =
          await SyntheticOldProfileFixture.schema17WithCapturedImageMetadata();
      final db = SkotiqDatabase.forTesting(NativeDatabase(fixture.dbFile));
      try {
        final upgradedVersion = await db
            .customSelect('PRAGMA user_version')
            .getSingle();
        expect(upgradedVersion.data['user_version'], equals(db.schemaVersion));

        final imageRows = await db
            .customSelect('SELECT id, file_name FROM captured_images')
            .get();
        expect(imageRows, hasLength(1));
        expect(imageRows.single.data['file_name'], equals('light-001.fits'));

        final metadataRows = await db
            .customSelect('SELECT "key", value FROM image_metadata')
            .get();
        expect(metadataRows, hasLength(1));
        expect(metadataRows.single.data['key'], equals('FILTER'));
        expect(metadataRows.single.data['value'], equals('L'));

        final foreignKeys = await db
            .customSelect("PRAGMA foreign_key_list('image_metadata')")
            .get();
        expect(
          foreignKeys.any((row) => row.data['on_delete'] == 'CASCADE'),
          isTrue,
          reason: 'Migration v18 should restore image metadata cascade delete.',
        );

        await db.customStatement('DELETE FROM captured_images WHERE id = 1');
        final remainingMetadata = await db
            .customSelect('SELECT COUNT(*) AS count FROM image_metadata')
            .getSingle();
        expect(
          remainingMetadata.data['count'],
          equals(0),
          reason:
              'Upgraded legacy image metadata should cascade on image delete.',
        );
      } finally {
        await db.close();
        await fixture.dispose();
      }
    },
  );

  test('fresh database is at schema 63 with stacked_results table', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    try {
      expect(db.schemaVersion, equals(63));

      // v48 (Night Narrator): the narrator_events table must exist on a
      // fresh install (drift createAll) just like on the upgrade path.
      final narratorRow = await db
          .customSelect(
            "SELECT name FROM sqlite_master "
            "WHERE type='table' AND name='narrator_events'",
          )
          .getSingleOrNull();
      expect(
        narratorRow != null,
        isTrue,
        reason:
            'onCreate must create the narrator_events table for fresh '
            'installs (Night Narrator v48).',
      );

      final tableRow = await db
          .customSelect(
            "SELECT name FROM sqlite_master "
            "WHERE type='table' AND name='stacked_results'",
          )
          .getSingleOrNull();
      expect(
        tableRow != null,
        isTrue,
        reason:
            'onCreate must create the stacked_results table for fresh '
            'installs (Stack-and-Share Loop C3).',
      );
      expect(tableRow!.data['name'], equals('stacked_results'));

      // The provenance indexes must exist so session/target lookups stay fast.
      final indexes = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type='index'")
          .get();
      final indexNames = indexes
          .map((row) => row.data['name']?.toString() ?? '')
          .toSet();
      expect(indexNames, contains('idx_stacked_results_session'));
      expect(indexNames, contains('idx_stacked_results_target'));

      // v58 (7.0 Darkroom data layer): onCreate must raise the same four raw
      // DDL tables the v57 -> v58 upgrade step adds, or a fresh install would
      // run the Darkroom against a schema the upgrade path guarantees and the
      // create path does not. Same table + index set asserted in
      // migration_v57_to_v58_test.dart.
      final darkroomTables = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type='table' AND name IN "
            "('recipes', 'darkroom_jobs', 'delivery_targets', "
            "'delivery_journal')",
          )
          .get();
      expect(
        darkroomTables.map((row) => row.data['name']).toSet(),
        equals({
          'recipes',
          'darkroom_jobs',
          'delivery_targets',
          'delivery_journal',
        }),
        reason:
            'onCreate must create the Darkroom tables for fresh installs '
            '(7.0 Darkroom data layer v58).',
      );
      expect(
        indexNames,
        containsAll(<String>[
          'idx_recipes_target',
          'idx_recipes_session',
          'idx_recipes_master',
          'idx_recipes_parent',
          'idx_recipes_base_master',
          'idx_recipes_created',
          'idx_darkroom_jobs_state',
          'idx_darkroom_jobs_session',
          'idx_darkroom_jobs_created',
          'idx_delivery_targets_enabled',
          'idx_delivery_targets_name',
          'idx_delivery_journal_target',
          'idx_delivery_journal_job',
          'idx_delivery_journal_state',
        ]),
      );
    } finally {
      await db.close();
    }
  });

  test('pre-v38 database upgrades to add stacked_results table', () async {
    final tempDir = await Directory.systemTemp.createTemp('skotiq_v37_to_v38_');
    final dbFile = File('${tempDir.path}/skotiq.db');

    // Set up a database that looks like a real v37 install: the
    // stacked_results table did not exist before v38, so drop it and roll the
    // user_version back to 37.
    final setupDb = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    try {
      await setupDb.customStatement('DROP TABLE IF EXISTS stacked_results');
      await setupDb.customStatement('PRAGMA user_version = 37');
    } finally {
      await setupDb.close();
    }

    // Re-open at the current schema version — onUpgrade should run the v38
    // branch and create stacked_results.
    final db = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    try {
      final upgradedVersion = await db
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(upgradedVersion.data['user_version'], equals(db.schemaVersion));
      expect(db.schemaVersion, equals(63));

      final tableRow = await db
          .customSelect(
            "SELECT name FROM sqlite_master "
            "WHERE type='table' AND name='stacked_results'",
          )
          .getSingleOrNull();
      expect(
        tableRow != null,
        isTrue,
        reason:
            'The v38 migration must create the stacked_results table for '
            'in-place upgrades (Stack-and-Share Loop C3).',
      );

      // The same upgrade pass must also run the v48 branch and create the
      // Night Narrator table on databases coming from any pre-48 version.
      final narratorRow = await db
          .customSelect(
            "SELECT name FROM sqlite_master "
            "WHERE type='table' AND name='narrator_events'",
          )
          .getSingleOrNull();
      expect(
        narratorRow != null,
        isTrue,
        reason:
            'The v48 migration must create the narrator_events table on '
            'in-place upgrades (Night Narrator).',
      );
      expect(tableRow!.data['name'], equals('stacked_results'));

      // A round-trip insert proves the migrated schema matches the DDL the
      // DAO writes against (all NOT NULL columns present, nullables optional).
      final rowId = await db.customInsert(
        'INSERT INTO stacked_results('
        'session_id, target_id, target_name, width, height, '
        'frames_stacked, frames_attempted, integration_secs, '
        'avg_alignment_residual, avg_hfr, filter, exported_image_path, '
        'created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          const Variable<int>(null),
          const Variable<int>(null),
          const Variable<String>('M31'),
          const Variable<int>(4096),
          const Variable<int>(2160),
          const Variable<int>(42),
          const Variable<int>(50),
          const Variable<double>(2520.0),
          const Variable<double>(0.31),
          const Variable<double>(null),
          const Variable<String>('L'),
          const Variable<String>(null),
          Variable<int>(
            DateTime.utc(2026, 5, 28).millisecondsSinceEpoch ~/ 1000,
          ),
        ],
      );
      expect(rowId, greaterThan(0));

      final stored = await db
          .customSelect(
            'SELECT target_name, frames_stacked FROM stacked_results '
            'WHERE id = ?',
            variables: [Variable<int>(rowId)],
          )
          .getSingle();
      expect(stored.data['target_name'], equals('M31'));
      expect(stored.data['frames_stacked'], equals(42));
    } finally {
      await db.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  });

  test('schema 17 captured_images without quality_score migrates', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'skotiq_schema17_no_qs_',
    );
    final dbFile = File('${tempDir.path}/skotiq.db');

    final setupDb = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    try {
      await setupDb.customStatement('PRAGMA foreign_keys = OFF');
      await setupDb.customStatement('DELETE FROM image_metadata');
      await setupDb.customStatement('DROP TABLE captured_images');
      await setupDb.customStatement('''
CREATE TABLE captured_images (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  file_path TEXT NOT NULL,
  file_name TEXT NOT NULL,
  file_format TEXT NOT NULL DEFAULT 'fits',
  file_size INTEGER,
  session_id INTEGER REFERENCES imaging_sessions(id) ON DELETE CASCADE,
  target_id INTEGER REFERENCES targets(id) ON DELETE SET NULL,
  frame_type TEXT NOT NULL DEFAULT 'light',
  exposure_duration REAL NOT NULL,
  gain INTEGER,
  offset INTEGER,
  bin_x INTEGER NOT NULL DEFAULT 1,
  bin_y INTEGER NOT NULL DEFAULT 1,
  filter TEXT,
  sensor_temp REAL,
  cooler_power REAL,
  hfr REAL,
  star_count INTEGER,
  background REAL,
  noise REAL,
  guiding_rms_ra REAL,
  guiding_rms_dec REAL,
  guiding_rms_total REAL,
  mount_ra REAL,
  mount_dec REAL,
  mount_altitude REAL,
  mount_azimuth REAL,
  pier_side TEXT,
  focuser_position INTEGER,
  focuser_temp REAL,
  rotator_angle REAL,
  is_plate_solved INTEGER NOT NULL DEFAULT 0,
  solved_ra REAL,
  solved_dec REAL,
  solved_rotation REAL,
  solved_pixel_scale REAL,
  captured_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
  is_accepted INTEGER NOT NULL DEFAULT 1,
  rejection_reason TEXT
)
''');
      await setupDb.customStatement('DELETE FROM imaging_sessions');
      await setupDb.customStatement('''
INSERT INTO imaging_sessions (id, start_time, status)
VALUES (1, 1700000000, 'completed')
''');
      await setupDb.customStatement('''
INSERT INTO captured_images (
  id, file_path, file_name, file_format, session_id, frame_type,
  exposure_duration, captured_at
) VALUES (
  1, '/legacy/light-001.fits', 'light-001.fits', 'fits', 1, 'light',
  120.0, 1700000001
)
''');
      await setupDb.customStatement('''
INSERT INTO image_metadata (id, image_id, "key", value, comment)
VALUES (1, 1, 'FILTER', 'L', 'legacy FITS metadata')
''');
      await setupDb.customStatement('DROP TABLE photometry_measurements');
      await setupDb.customStatement('''
CREATE TABLE photometry_measurements (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  captured_image_id INTEGER REFERENCES captured_images(id) ON DELETE CASCADE,
  session_id INTEGER REFERENCES imaging_sessions(id) ON DELETE CASCADE,
  object_id TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'target',
  x REAL NOT NULL,
  y REAL NOT NULL,
  flux REAL NOT NULL,
  differential_magnitude REAL,
  snr REAL,
  uncertainty REAL,
  is_outlier INTEGER NOT NULL DEFAULT 0,
  timestamp INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
)
''');
      await setupDb.customStatement('''
INSERT INTO photometry_measurements (
  id, captured_image_id, session_id, object_id, role, x, y, flux,
  differential_magnitude, snr, uncertainty, is_outlier, timestamp
) VALUES (
  1, 1, 1, 'target-a', 'target', 12.0, 13.0, 1000.0,
  1.25, 42.0, 0.05, 0, 1700000002
)
''');
      await setupDb.customStatement('PRAGMA user_version = 17');
    } finally {
      await setupDb.close();
    }

    final db = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
    try {
      final imageRows = await db
          .customSelect(
            'SELECT id, file_name, quality_score FROM captured_images',
          )
          .get();
      expect(imageRows, hasLength(1));
      expect(imageRows.single.data['file_name'], equals('light-001.fits'));
      expect(imageRows.single.data['quality_score'], equals(null));

      final metadataRows = await db
          .customSelect('SELECT "key", value FROM image_metadata')
          .get();
      expect(metadataRows, hasLength(1));
      expect(metadataRows.single.data['key'], equals('FILTER'));
      expect(metadataRows.single.data['value'], equals('L'));

      final photometryRows = await db
          .customSelect(
            'SELECT object_id, standard_magnitude FROM photometry_measurements',
          )
          .get();
      expect(photometryRows, hasLength(1));
      expect(photometryRows.single.data['object_id'], equals('target-a'));
      expect(photometryRows.single.data['standard_magnitude'], equals(null));
    } finally {
      await db.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  });

  test(
    'pre-v30 database lacking guide_rms_history migrates to 38 without crashing '
    '(regression: idx_guide_rms_mount_recent on a missing table)',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_guide_rms_migration_test_',
      );
      final dbFile = File('${tempDir.path}/skotiq.db');

      // Force the DB into the exact shape that crashed on the imaging laptop:
      // schema < 30 with NO guide_rms_history table. The v30 migration step used
      // to create idx_guide_rms_mount_recent unconditionally, throwing
      // "no such table: guide_rms_history" (the table is not created until the
      // v34 step) and aborting the entire migration so the app could not open.
      final setupDb = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        await setupDb.customStatement('DROP TABLE IF EXISTS guide_rms_history');
        await setupDb.customStatement('PRAGMA user_version = 25');
      } finally {
        await setupDb.close();
      }

      // Re-open and force the migration ladder to run from 25. Must NOT throw.
      final db = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        await db.customSelect('SELECT 1').get();

        final tables = await _sqliteTableNames(db);
        expect(
          tables,
          contains('guide_rms_history'),
          reason: 'guide_rms_history must be (re)created by the v34 step',
        );

        final indexes = await db
            .customSelect(
              "SELECT name FROM sqlite_master WHERE type = 'index' "
              "AND name = 'idx_guide_rms_mount_recent'",
            )
            .get();
        expect(
          indexes,
          isNotEmpty,
          reason: 'the mount-recent lookup index must exist after migration',
        );
      } finally {
        await db.close();
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    },
  );
}

const _tablesIntroducedAfterSchema12 = [
  'science_session_config',
  'photometry_measurements',
  'frame_photometric_calibration',
  'transparency_samples',
  'psf_field_tiles',
  'science_frame_quality_metrics',
  'science_tile_metrics',
  'astrometry_residual_vectors',
  'moving_object_candidates',
  'line_ratio_products',
  'photometric_transforms',
  'dark_library',
  'observation_logs',
  'observing_lists',
  'observing_list_items',
  'sequence_runs',
];

Future<Set<String>> _sqliteTableNames(SkotiqDatabase db) async {
  final rows = await db
      .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
      .get();
  return rows.map((row) => row.data['name']?.toString() ?? '').toSet();
}
