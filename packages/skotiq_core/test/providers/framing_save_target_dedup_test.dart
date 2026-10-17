// Verifies that the Framing "Save target" path no longer stacks duplicate rows
// in the targets library. framingProvider.saveTarget() routes through
// TargetLibraryService.ensureCatalogTarget, which dedups against existing rows
// by catalog id / name / coordinates. Saving the SAME target twice must yield a
// single library row.
//
// Note: setTarget() kicks off a fire-and-forget survey-image fetch and a
// last-framed-target settings write; neither is awaited here and neither needs
// the network for this assertion. We exercise saveTarget() — the explicit save
// path — directly against an in-memory database.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/framing_provider.dart';
import 'package:drift/native.dart';

void main() {
  late SkotiqDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test(
    'saveTarget on the same target does not create duplicate rows',
    () async {
      final notifier = container.read(framingProvider.notifier);
      final targetsDao = container.read(targetsDaoProvider);

      const target = FramingTarget(
        name: 'M42',
        catalogId: 'M42',
        raHours: 5.59,
        decDegrees: -5.39,
      );

      notifier.setTarget(target);

      await notifier.saveTarget();
      await notifier.saveTarget();

      final rows = await targetsDao.getAllTargets();
      final m42Rows = rows.where((t) => t.catalogId == 'M42').toList();
      expect(
        m42Rows,
        hasLength(1),
        reason: 'ensureCatalogTarget must dedup repeated explicit saves',
      );
    },
  );

  test('saveTarget dedups by name when catalogId is absent', () async {
    final notifier = container.read(framingProvider.notifier);
    final targetsDao = container.read(targetsDaoProvider);

    const target = FramingTarget(
      name: 'Custom Nebula',
      raHours: 12.0,
      decDegrees: 40.0,
    );

    notifier.setTarget(target);
    await notifier.saveTarget();
    await notifier.saveTarget();

    final rows = await targetsDao.getAllTargets();
    expect(rows.where((t) => t.name == 'Custom Nebula'), hasLength(1));
  });

  test(
    'selecting a target writes NO targets row, only the settings key',
    () async {
      final notifier = container.read(framingProvider.notifier);
      final targetsDao = container.read(targetsDaoProvider);
      final settingsDao = container.read(settingsDaoProvider);

      const target = FramingTarget(
        name: 'IC 1396',
        catalogId: 'IC1396',
        raHours: 21.6,
        decDegrees: 57.5,
      );

      // Mirror Framing's _selectTarget: set the target (which remembers it) but
      // do NOT call saveTarget(). This must not pollute the targets library.
      notifier.setTarget(target);
      await notifier.persistLastFramedTarget(target);

      expect(
        await targetsDao.getAllTargets(),
        isEmpty,
        reason: 'selection must not create a library row',
      );

      final stored = await settingsDao.getSetting('framing.lastTarget');
      expect(
        stored,
        isNotNull,
        reason: 'last framed target is persisted to a single settings key',
      );
    },
  );

  test(
    'loadMostRecentTarget restores from the settings key, not the table',
    () async {
      final notifier = container.read(framingProvider.notifier);

      const original = FramingTarget(
        name: 'Veil Nebula',
        catalogId: 'NGC6960',
        raHours: 20.76,
        decDegrees: 30.7,
      );

      await notifier.persistLastFramedTarget(original);

      // Fresh notifier (simulating an app restart) restores from settings.
      final restored = container.read(framingProvider.notifier);
      await restored.loadMostRecentTarget();

      final state = container.read(framingProvider);
      expect(state.target, isNotNull);
      expect(state.target!.name, 'Veil Nebula');
      expect(state.target!.catalogId, 'NGC6960');
      expect(state.target!.raHours, closeTo(20.76, 1e-9));
      expect(state.target!.decDegrees, closeTo(30.7, 1e-9));
    },
  );

  test(
    'loadMostRecentTarget is a no-op when the settings key is absent',
    () async {
      final notifier = container.read(framingProvider.notifier);
      await notifier.loadMostRecentTarget();
      expect(container.read(framingProvider).target, isNull);
    },
  );
}
