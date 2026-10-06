// Owner decisions of 2026-10-06, as the settings layer carries them:
//
//   * "Failed AF should never park the rig, just notify the user." There is
//     no autofocus failure action any more, so no stored value can ask the
//     engine to park, and none is sent.
//   * "0.7 may be too strict." The eccentricity limit a profile gets when it
//     never set one is 0.8 (see `DEFAULT_ECCENTRICITY_THRESHOLD` in the native
//     `quality::image_grading`, which grades the owner's frames against it).
//   * "Autofocus star selection should be on." A profile that never set it
//     measures the brightest 10 stars, and the v60 upgrade moved every stored
//     0 to 10 once (see migration_v59_to_v60_test.dart).
//
// Values an operator saves are kept as they are.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightshade_core/src/database/database.dart';
import 'package:nightshade_core/src/models/imaging/imaging_models.dart';
import 'package:nightshade_core/src/providers/database_provider.dart';
import 'package:nightshade_core/src/providers/sequence/sequence_executor/sequence_serializer.dart';
import 'package:nightshade_core/src/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File dbFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ns_notify_not_stop_');
    dbFile = File('${tempDir.path}/nightshade.db');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<(ProviderContainer, AppSettingsState)> load(
    NightshadeDatabase database,
  ) async {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(container.dispose);
    final settings = await container.read(appSettingsProvider.future);
    return (container, settings);
  }

  group('a fresh profile', () {
    test('measures autofocus over the brightest 10 stars', () async {
      final database = NightshadeDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(database.close);
      final (container, settings) = await load(database);

      expect(settings.afUseBrightestNStars, 10);
      expect(container.read(autofocusSettingsProvider).useBrightestNStars, 10);
      expect(
        await database.settingsDao.getSetting('af_use_brightest_n_stars'),
        '10',
      );
      expect(const AppSettingsState().afUseBrightestNStars, 10);
      expect(const AutofocusSettings().useBrightestNStars, 10);
    });

    test('grades eccentricity against 0.8', () async {
      final database = NightshadeDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(database.close);
      final (_, settings) = await load(database);

      expect(settings.imageGradingEccentricityThreshold, 0.8);
      expect(const AppSettingsState().imageGradingEccentricityThreshold, 0.8);
    });

    test('has no autofocus failure action to park with', () async {
      final database = NightshadeDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(database.close);
      await load(database);

      final all = await database.settingsDao.getAllSettings();
      expect(all.containsKey('af_failure_action'), isFalse);
    });
  });

  group('a profile written by an older build', () {
    test(
      'keeps a star selection and eccentricity limit saved since v60',
      () async {
        final first = NightshadeDatabase.forTesting(NativeDatabase(dbFile));
        await first.settingsDao.setSetting('af_use_brightest_n_stars', '0');
        await first.settingsDao.setSetting(
          'image_grading_eccentricity_threshold',
          '0.7',
        );
        await first.close();

        final second = NightshadeDatabase.forTesting(NativeDatabase(dbFile));
        addTearDown(second.close);
        final (_, settings) = await load(second);

        expect(settings.afUseBrightestNStars, 0);
        expect(settings.imageGradingEccentricityThreshold, 0.7);
      },
    );

    test('loses its stored AbortAndPark failure action on open', () async {
      final first = NightshadeDatabase.forTesting(NativeDatabase(dbFile));
      await first.settingsDao.setSetting('af_failure_action', 'AbortAndPark');
      expect(
        await first.settingsDao.getSetting('af_failure_action'),
        'AbortAndPark',
        reason: 'precondition: the stale row is really there',
      );
      await first.close();

      final second = NightshadeDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(second.close);
      final all = await second.settingsDao.getAllSettings();
      expect(all.containsKey('af_failure_action'), isFalse);
    });
  });

  test('the autofocus config sent to the engine names no failure action', () {
    final serializer = Provider(
      (ref) => SequenceSerializer(ref: ref, warn: (_) {}),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final config = container
        .read(serializer)
        .autofocusRuntimeConfig(
          const AutofocusSettings(),
          maxDurationSecs: 600,
        );

    expect(config.containsKey('failure_action'), isFalse);
    expect(config['use_brightest_n_stars'], 10);
  });
}
