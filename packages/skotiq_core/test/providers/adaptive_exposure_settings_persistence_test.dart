import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase database;
  late ProviderContainer container;

  setUp(() async {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    await container.read(appSettingsProvider.future);
  });

  tearDown(() async {
    container.dispose();
    await database.close();
  });

  test(
    'global bounds reject inversion instead of silently defeating adaptation',
    () async {
      final notifier = container.read(appSettingsProvider.notifier);

      await expectLater(
        notifier.setAdaptiveExposureBounds(minSecs: 700, maxSecs: 600),
        throwsArgumentError,
      );

      final settings = container.read(appSettingsProvider).value!;
      expect(settings.adaptiveExposureMinSecs, 5);
      expect(settings.adaptiveExposureMaxSecs, 600);
    },
  );

  test('global bounds persist atomically and survive reload', () async {
    await container
        .read(appSettingsProvider.notifier)
        .setAdaptiveExposureBounds(minSecs: 10, maxSecs: 500);

    final rows = await database
        .customSelect(
          'SELECT key, value FROM app_settings WHERE key IN (?, ?)',
          variables: const [
            Variable<String>('adaptive_exposure_min_secs'),
            Variable<String>('adaptive_exposure_max_secs'),
          ],
        )
        .get();
    final stored = {for (final row in rows) row.data['key']: row.data['value']};
    expect(stored['adaptive_exposure_min_secs'], '10.0');
    expect(stored['adaptive_exposure_max_secs'], '500.0');

    container.invalidate(appSettingsProvider);
    final reloaded = await container.read(appSettingsProvider.future);
    expect(reloaded.adaptiveExposureMinSecs, 10);
    expect(reloaded.adaptiveExposureMaxSecs, 500);
  });

  test(
    'per-filter bounds validate against global fallbacks and copy maps',
    () async {
      final notifier = container.read(appSettingsProvider.notifier);
      await notifier.setAdaptiveExposureBounds(minSecs: 10, maxSecs: 500);

      await expectLater(
        notifier.setAdaptiveExposurePerFilterBounds(
          minSecs: const {'L': 700},
          maxSecs: const {},
        ),
        throwsArgumentError,
      );

      final minMap = <String, double>{'L': 20};
      await notifier.setAdaptiveExposurePerFilterBounds(
        minSecs: minMap,
        maxSecs: const {'L': 300},
      );
      minMap['L'] = 200;

      final settings = container.read(appSettingsProvider).value!;
      expect(settings.adaptiveExposurePerFilterMinSecs, const {'L': 20});
      expect(settings.adaptiveExposurePerFilterMaxSecs, const {'L': 300});
    },
  );
}
