import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _FailingSettingsDao extends SettingsDao {
  _FailingSettingsDao(super.db);

  @override
  Future<void> setSetting(String key, String value) async {
    throw StateError('write failed');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase database;
  late ProviderContainer container;

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

  test('concurrent annotation edits merge in invocation order', () async {
    await container.read(annotationSettingsProvider.future);
    final notifier = container.read(annotationSettingsProvider.notifier);

    await Future.wait([
      notifier.setShowLabels(false),
      notifier.setShowMagnitudes(true),
    ]);

    final settings = container.read(annotationSettingsProvider).value!;
    expect(settings.showLabels, isFalse);
    expect(settings.showMagnitudes, isTrue);
    final stored = await database.settingsDao.getSetting('annotation_settings');
    final json = jsonDecode(stored!) as Map<String, dynamic>;
    expect(json['showLabels'], isFalse);
    expect(json['showMagnitudes'], isTrue);
  });

  test('concurrent marker-style edits do not overwrite each other', () async {
    await container.read(annotationMarkerStyleProvider.future);
    final notifier = container.read(annotationMarkerStyleProvider.notifier);

    await Future.wait([
      notifier.setGalaxyColor(0xFF112233),
      notifier.setNebulaColor(0xFF445566),
    ]);

    final style = container.read(annotationMarkerStyleProvider).value!;
    expect(style.galaxyColor, 0xFF112233);
    expect(style.nebulaColor, 0xFF445566);
  });

  test('concurrent preset saves retain every named preset', () async {
    await container.read(annotationSettingsProvider.future);
    await container.read(annotationPresetsProvider.future);
    final notifier = container.read(annotationPresetsProvider.notifier);

    await Future.wait([
      notifier.saveCurrentAsPreset('Emission'),
      notifier.saveCurrentAsPreset('Galaxy'),
    ]);

    final names = container
        .read(annotationPresetsProvider)
        .value!
        .map((preset) => preset.name);
    expect(names, containsAll(['Emission', 'Galaxy']));
  });

  test(
    'failed persistence leaves confirmed annotation state unchanged',
    () async {
      container.dispose();
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          settingsDaoProvider.overrideWithValue(_FailingSettingsDao(database)),
        ],
      );
      await container.read(annotationSettingsProvider.future);
      final notifier = container.read(annotationSettingsProvider.notifier);

      await expectLater(notifier.setShowLabels(false), throwsStateError);

      expect(
        container.read(annotationSettingsProvider).value!.showLabels,
        isTrue,
      );
    },
  );

  test(
    'corrupt annotation settings cannot be overwritten from defaults',
    () async {
      await database.settingsDao.setSetting('annotation_settings', '{bad json');

      await expectLater(
        container.read(annotationSettingsProvider.future),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        container
            .read(annotationSettingsProvider.notifier)
            .setShowLabels(false),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('refusing to overwrite them with defaults'),
          ),
        ),
      );
      expect(
        await database.settingsDao.getSetting('annotation_settings'),
        '{bad json',
      );
    },
  );

  test('corrupt marker style cannot be reset over stored data', () async {
    await database.settingsDao.setSetting(
      'annotation_marker_style',
      '{bad json',
    );

    await expectLater(
      container.read(annotationMarkerStyleProvider.future),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      container.read(annotationMarkerStyleProvider.notifier).reset(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('refusing to overwrite it with defaults'),
        ),
      ),
    );
    expect(
      await database.settingsDao.getSetting('annotation_marker_style'),
      '{bad json',
    );
  });

  test(
    'corrupt preset library cannot be overwritten as an empty list',
    () async {
      await database.settingsDao.setSetting('annotation_presets', '{bad json');
      await container.read(annotationSettingsProvider.future);

      await expectLater(
        container.read(annotationPresetsProvider.future),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        container
            .read(annotationPresetsProvider.notifier)
            .saveCurrentAsPreset('Galaxy'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('refusing to overwrite them with an empty list'),
          ),
        ),
      );
      expect(
        await database.settingsDao.getSetting('annotation_presets'),
        '{bad json',
      );
    },
  );

  test(
    'saving a preset refuses unavailable source annotation settings',
    () async {
      await database.settingsDao.setSetting('annotation_settings', '{bad json');
      await expectLater(
        container.read(annotationSettingsProvider.future),
        throwsA(isA<StateError>()),
      );
      await container.read(annotationPresetsProvider.future);

      await expectLater(
        container
            .read(annotationPresetsProvider.notifier)
            .saveCurrentAsPreset('Manufactured'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('refusing to save a preset from defaults'),
          ),
        ),
      );
      expect(
        await database.settingsDao.getSetting('annotation_presets'),
        isNull,
      );
    },
  );
}
