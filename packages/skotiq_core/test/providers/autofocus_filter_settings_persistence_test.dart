import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
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
    'concurrent field and filter updates merge from the latest JSON',
    () async {
      final notifier = container.read(appSettingsProvider.notifier);

      final writes = <Future<void>>[
        notifier.updateFilterAutofocusConfig(
          'L',
          (current) => current.copyWith(gain: 100),
        ),
        notifier.updateFilterAutofocusConfig(
          'L',
          (current) => current.copyWith(offset: 20),
        ),
        notifier.updateFilterAutofocusConfig(
          'R',
          (current) => current.copyWith(afExposureTime: 2.5),
        ),
      ];
      await Future.wait(writes);

      final encoded = container
          .read(appSettingsProvider)
          .value!
          .afFilterSettingsJson;
      final settings = AutofocusSettings.parseFilterSettingsJson(encoded);
      expect(settings['L']!.gain, 100);
      expect(settings['L']!.offset, 20);
      expect(settings['R']!.afExposureTime, 2.5);
    },
  );

  test(
    'invalid per-filter runtime values are rejected without persistence',
    () async {
      final notifier = container.read(appSettingsProvider.notifier);

      await expectLater(
        notifier.updateFilterAutofocusConfig(
          'L',
          (current) => current.copyWith(afExposureTime: double.nan),
        ),
        throwsArgumentError,
      );
      await expectLater(
        notifier.updateFilterAutofocusConfig(
          'L',
          (current) => current.copyWith(gain: -1),
        ),
        throwsArgumentError,
      );

      final encoded = container
          .read(appSettingsProvider)
          .value!
          .afFilterSettingsJson;
      expect(AutofocusSettings.parseFilterSettingsJson(encoded), isEmpty);
    },
  );

  test('merged per-filter settings survive provider reload', () async {
    final notifier = container.read(appSettingsProvider.notifier);
    await notifier.updateFilterAutofocusConfig(
      'L',
      (current) => current.copyWith(gain: 120, offset: 15),
    );

    container.invalidate(appSettingsProvider);
    final reloaded = await container.read(appSettingsProvider.future);
    final settings = AutofocusSettings.parseFilterSettingsJson(
      reloaded.afFilterSettingsJson,
    );
    expect(settings['L']!.gain, 120);
    expect(settings['L']!.offset, 15);
  });
}
