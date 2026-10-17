import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

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

  test(
    'invalid science boolean errors and cannot be overwritten from defaults',
    () async {
      await database.settingsDao.setSetting(
        'science.overlay.enabled',
        'sometimes',
      );

      await expectLater(
        container.read(scienceSettingsProvider.future),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        container
            .read(scienceSettingsProvider.notifier)
            .setOverlayEnabled(false),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('refusing to overwrite them with defaults'),
          ),
        ),
      );
      expect(
        await database.settingsDao.getSetting('science.overlay.enabled'),
        'sometimes',
      );
    },
  );

  test('invalid science identifier remains a visible load error', () async {
    await database.settingsDao.setSetting('science.tns.bot_id', 'operator');

    await expectLater(
      container.read(scienceSettingsProvider.future),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('science.tns.bot_id'),
        ),
      ),
    );
  });

  test('concurrent science edits preserve every loaded field', () async {
    await container.read(scienceSettingsProvider.future);
    final notifier = container.read(scienceSettingsProvider.notifier);

    await Future.wait([
      notifier.setOverlayEnabled(false),
      notifier.setFeatureEnabled(ScienceFeature.movingObjects, true),
      notifier.setObserverName('Night Operator'),
    ]);

    final settings = container.read(scienceSettingsProvider).requireValue;
    expect(settings.overlayEnabled, isFalse);
    expect(settings.movingObjectsEnabled, isTrue);
    expect(settings.observerName, 'Night Operator');
    expect(
      await database.settingsDao.getSetting('science.overlay.enabled'),
      'false',
    );
    expect(
      await database.settingsDao.getSetting('science.feature.moving_objects'),
      'true',
    );
    expect(
      await database.settingsDao.getSetting('science.observer.name'),
      'Night Operator',
    );
  });

  test(
    'corrupt photometry target cannot be replaced from default selection',
    () async {
      await database.settingsDao.setSetting(
        'science.photometry.target_anchor',
        '{bad json',
      );

      await expectLater(
        container.read(sciencePhotometrySelectionProvider.future),
        throwsA(isA<StateError>()),
      );
      final differentialBefore = await database.settingsDao.getSetting(
        'science.photometry.differential_active',
      );
      await expectLater(
        container
            .read(sciencePhotometrySelectionProvider.notifier)
            .setDifferentialEnabled(true),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('refusing to overwrite it with defaults'),
          ),
        ),
      );
      expect(
        await database.settingsDao.getSetting(
          'science.photometry.target_anchor',
        ),
        '{bad json',
      );
      expect(
        await database.settingsDao.getSetting(
          'science.photometry.differential_active',
        ),
        differentialBefore,
      );
    },
  );

  test('concurrent photometry edits merge in invocation order', () async {
    await container.read(sciencePhotometrySelectionProvider.future);
    final notifier = container.read(
      sciencePhotometrySelectionProvider.notifier,
    );
    const target = PhotometryAnchor(
      objectId: 'target',
      label: 'Variable',
      raDegrees: 10,
      decDegrees: 20,
    );
    const comparison = PhotometryAnchor(
      objectId: 'comparison',
      label: 'Comparison',
      raDegrees: 11,
      decDegrees: 21,
    );

    await Future.wait([
      notifier.setTarget(target),
      notifier.toggleComparison(comparison),
      notifier.setDifferentialEnabled(true),
    ]);

    final selection = container
        .read(sciencePhotometrySelectionProvider)
        .requireValue;
    expect(selection.target, target);
    expect(selection.comparisons, [comparison]);
    expect(selection.differentialEnabled, isTrue);
    final storedComparisons =
        jsonDecode(
              (await database.settingsDao.getSetting(
                'science.photometry.comparison_anchors',
              ))!,
            )
            as List<dynamic>;
    expect(storedComparisons.single['objectId'], 'comparison');
  });

  test(
    'corrupt visualization preferences cannot be overwritten by defaults',
    () async {
      await database.settingsDao.setSetting(
        'science.overlay.opacity',
        'mostly opaque',
      );

      await expectLater(
        container.read(scienceVisualizationPrefsProvider.future),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        container
            .read(scienceVisualizationPrefsProvider.notifier)
            .savePrefs(const ScienceVisualizationPrefs(overlayOpacity: 0.5)),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('refusing to overwrite them with defaults'),
          ),
        ),
      );
      expect(
        await database.settingsDao.getSetting('science.overlay.opacity'),
        'mostly opaque',
      );
    },
  );

  test('rapid visualization saves commit in invocation order', () async {
    await container.read(scienceVisualizationPrefsProvider.future);
    final notifier = container.read(scienceVisualizationPrefsProvider.notifier);

    await Future.wait([
      notifier.savePrefs(const ScienceVisualizationPrefs(overlayOpacity: 0.2)),
      notifier.savePrefs(const ScienceVisualizationPrefs(overlayOpacity: 0.7)),
    ]);

    expect(
      container
          .read(scienceVisualizationPrefsProvider)
          .requireValue
          .overlayOpacity,
      0.7,
    );
    expect(
      await database.settingsDao.getSetting('science.overlay.opacity'),
      '0.7',
    );
  });
}
