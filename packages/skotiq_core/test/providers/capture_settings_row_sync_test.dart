// The Imaging capture settings are one JSON row shared by the host's screen
// and every linked client. A change to the row made elsewhere shows on this
// screen, and an edit here stores only the fields it changed.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/host_settings/host_settings_providers.dart';
import 'package:skotiq_core/src/providers/imaging_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';
import '../harness/in_memory_database.dart';

const _profile = EquipmentProfileModel(id: 1, name: 'Rig');
const _key = 'imaging_capture_settings_profile_1';

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  late ProviderContainer container;

  setUp(() async {
    container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        activeEquipmentProfileProvider.overrideWithValue(_profile),
      ],
    );
    addTearDown(container.dispose);
    await container
        .read(settingsDaoProvider)
        .setSetting(
          _key,
          jsonEncode({'exposureTime': 12.0, 'gain': 100, 'offset': 50}),
        );
    container.listen(syncExposureFromProfileProvider, (_, __) {});
    await _settle();
  });

  test('a change to the row made elsewhere shows here', () async {
    expect(container.read(exposureSettingsProvider).exposureTime, 12.0);

    await container
        .read(databaseProvider)
        .settingsDao
        .setSetting(
          _key,
          jsonEncode({'exposureTime': 7.5, 'gain': 222, 'offset': 50}),
        );
    container.read(settingsRowChangesProvider).announce({_key});
    await _settle();

    final settings = container.read(exposureSettingsProvider);
    expect(settings.exposureTime, 7.5);
    expect(settings.gain, 222);
  });

  test('an edit stores only its field, keeping another writer\'s', () async {
    // Another screen changed the gain; this one has not heard yet.
    await container
        .read(databaseProvider)
        .settingsDao
        .setSetting(
          _key,
          jsonEncode({'exposureTime': 12.0, 'gain': 300, 'offset': 50}),
        );

    final current = container.read(exposureSettingsProvider);
    container
        .read(manualExposureSettingsUpdaterProvider)
        .update(current.copyWith(exposureTime: 20));
    await _settle();

    final stored =
        jsonDecode(
              (await container.read(settingsDaoProvider).getSetting(_key))!,
            )
            as Map;
    expect(stored['exposureTime'], 20.0);
    expect(stored['gain'], 300);
    // And the screen takes the merged row once its write has landed.
    expect(container.read(exposureSettingsProvider).gain, 300);
  });

  test(
    'a first edit of a profile with no row stores the whole settings',
    () async {
      await container.read(settingsDaoProvider).deleteSetting(_key);
      final current = container.read(exposureSettingsProvider);
      container
          .read(manualExposureSettingsUpdaterProvider)
          .update(current.copyWith(gain: 5));
      await _settle();

      final stored =
          jsonDecode(
                (await container.read(settingsDaoProvider).getSetting(_key))!,
              )
              as Map;
      expect(stored['gain'], 5);
      expect(stored['exposureTime'], current.exposureTime);
      expect(stored['offset'], current.offset);
      expect(stored.containsKey('binningX'), isTrue);
    },
  );

  test('edits that change nothing write nothing', () async {
    final current = container.read(exposureSettingsProvider);
    await container.read(databaseProvider).settingsDao.setSetting(_key, 'x');
    container.read(manualExposureSettingsUpdaterProvider).update(current);
    await _settle();
    expect(await container.read(settingsDaoProvider).getSetting(_key), 'x');
    expect(container.read(exposureSettingsProvider), isA<ExposureSettings>());
  });
}
