// Two model-level settings contracts:
//
//  * The "disable guiding during autofocus" setting is persisted under the
//    canonical key `af_disable_guiding`. A partial-persistence reader looking
//    for a different key loses the toggle across a save→reload round trip; this
//    test drives the full local round trip.
//
//  * (0,0) — the Gulf of Guinea null island — is treated as UNSET, so
//    pre-flight / scheduler code can block a night planned for coordinates the
//    user never configured.

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('af_disable_guiding canonical key', () {
    late ProviderContainer container;
    late SkotiqDatabase database;

    setUp(() {
      database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
    });

    tearDown(() async {
      container.dispose();
      await database.close();
    });

    test(
      'stored af_disable_guiding=true loads as afDisableGuidingDuringAf',
      () async {
        await database
            .into(database.appSettings)
            .insert(
              AppSettingsCompanion.insert(
                key: 'af_disable_guiding',
                value: 'true',
              ),
              mode: InsertMode.insertOrReplace,
            );

        final settings = await container.read(appSettingsProvider.future);
        expect(
          settings.afDisableGuidingDuringAf,
          isTrue,
          reason: 'stored-snapshot loader must read the canonical key',
        );
      },
    );

    test('setter persists and reloads through the canonical key', () async {
      await container.read(appSettingsProvider.future);

      await container
          .read(appSettingsProvider.notifier)
          .setAfDisableGuidingDuringAf(true);

      // The value must have been written under `af_disable_guiding`.
      final rows = await database
          .customSelect(
            'SELECT value FROM app_settings WHERE key = ?',
            variables: [const Variable<String>('af_disable_guiding')],
          )
          .get();
      expect(rows, hasLength(1));
      expect(rows.single.data['value'], 'true');

      // And a fresh load observes it (no stale-key mismatch).
      container.invalidate(appSettingsProvider);
      final reloaded = await container.read(appSettingsProvider.future);
      expect(reloaded.afDisableGuidingDuringAf, isTrue);
    });
  });

  group('observer location unset detection (Finding #3)', () {
    test('default (0,0) is treated as unset', () {
      const settings = AppSettingsState();
      expect(
        settings.isLocationUnset,
        isTrue,
        reason: 'a never-configured location defaults to the null island',
      );
      expect(settings.isLocationSet, isFalse);
    });

    test('a near-zero coordinate is still unset within epsilon', () {
      const settings = AppSettingsState(latitude: 0.005, longitude: -0.003);
      expect(settings.isLocationUnset, isTrue);
    });

    test('a real configured location is set', () {
      const settings = AppSettingsState(
        latitude: 47.6062,
        longitude: -122.3321,
        elevation: 50.0,
      );
      expect(settings.isLocationSet, isTrue);
      expect(settings.isLocationUnset, isFalse);
    });

    test('zero elevation alone does not mark location unset', () {
      // Sea-level sites are valid; only lat+lon being zero counts as unset.
      const settings = AppSettingsState(
        latitude: 51.4779,
        longitude: 0.0, // Greenwich is genuinely at ~0° longitude
        elevation: 0.0,
      );
      // Longitude is genuinely ~0 here, but latitude is far from 0, so the
      // site is correctly considered SET.
      expect(settings.isLocationSet, isTrue);
    });
  });
}
