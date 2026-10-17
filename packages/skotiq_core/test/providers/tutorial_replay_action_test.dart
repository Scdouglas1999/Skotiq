import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _FailingTutorialProgressDao extends TutorialProgressDao {
  _FailingTutorialProgressDao(super.db);

  @override
  Future<void> restartProgress(String category) async {
    throw StateError('restart failed');
  }
}

class _ToggleFailTutorialProgressDao extends TutorialProgressDao {
  _ToggleFailTutorialProgressDao(super.db);

  bool failSave = false;
  bool failDismiss = false;

  @override
  Future<void> saveProgress(String category, int stepIndex) {
    if (failSave) throw StateError('progress write failed');
    return super.saveProgress(category, stepIndex);
  }

  @override
  Future<void> markDismissed(String category) {
    if (failDismiss) throw StateError('dismiss write failed');
    return super.markDismissed(category);
  }
}

class _ToggleFailSettingsDao extends SettingsDao {
  _ToggleFailSettingsDao(super.db);

  bool failWrites = false;

  @override
  Future<void> setSetting(String key, String value) {
    if (failWrites) throw StateError('write failed');
    return super.setSetting(key, value);
  }
}

class _FailingFirstLaunchTourDao extends FirstLaunchTourDao {
  _FailingFirstLaunchTourDao(super.progressDao);

  @override
  Future<void> reset() async {
    throw StateError('tour reset failed');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase database;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => database.close());

  test(
    'restarting a completed tutorial atomically starts a fresh run',
    () async {
      const category = TutorialCategory.equipmentSetup;
      await database.tutorialProgressDao.markCompleted(category.name);

      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      addTearDown(container.dispose);
      container.read(tutorialProvider);
      await pumpEventQueue();

      final notifier = container.read(tutorialProvider.notifier);
      expect(notifier.isCategoryCompletedSync(category), isTrue);

      await notifier.startTutorial(category);

      final persisted = await database.tutorialProgressDao.getProgress(
        category.name,
      );
      expect(persisted, isNotNull);
      expect(persisted!.lastStepIndex, 0);
      expect(persisted.completed, isFalse);
      expect(persisted.dismissed, isFalse);
      expect(container.read(tutorialProvider).activeCategory, category);
      expect(notifier.isCategoryCompletedSync(category), isFalse);
    },
  );

  test('failed tutorial restart leaves the visible state unchanged', () async {
    final failingDao = _FailingTutorialProgressDao(database);
    final notifier = TutorialNotifier(failingDao);
    addTearDown(notifier.dispose);
    final before = notifier.state;

    await expectLater(
      notifier.restartTutorial(TutorialCategory.targetPlanning),
      throwsStateError,
    );

    expect(notifier.state, before);
  });

  test('failed equipment draft reset preserves the current draft', () async {
    final settingsDao = _ToggleFailSettingsDao(database);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        settingsDaoProvider.overrideWithValue(settingsDao),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(onboardingDraftProvider.notifier);
    await notifier.loaded;
    await notifier.setCaptureDirectory('/captures/keep-me');
    final before = container.read(onboardingDraftProvider);
    settingsDao.failWrites = true;

    await expectLater(notifier.reset(), throwsStateError);

    expect(container.read(onboardingDraftProvider), before);
    expect(
      container.read(onboardingDraftProvider).captureDirectory,
      '/captures/keep-me',
    );
  });

  test(
    'failed onboarding-tour reset preserves its in-memory pointer',
    () async {
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          firstLaunchTourDaoProvider.overrideWithValue(
            _FailingFirstLaunchTourDao(database.tutorialProgressDao),
          ),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(onboardingTourProvider.notifier);
      notifier.goToStep(3);
      notifier.unlockDefectMapStep();
      final stepBefore = notifier.currentStepIndex;

      await expectLater(notifier.reset(), throwsStateError);

      expect(notifier.currentStepIndex, stepBefore);
      expect(notifier.defectMapStepUnlocked, isTrue);
    },
  );

  test(
    'failed Next persistence does not advance visible tutorial state',
    () async {
      final dao = _ToggleFailTutorialProgressDao(database);
      final notifier = TutorialNotifier(dao);
      addTearDown(notifier.dispose);
      await notifier.startTutorial(TutorialCategory.equipmentSetup);
      final before = notifier.state;
      dao.failSave = true;

      await expectLater(notifier.nextStep(), throwsStateError);

      expect(notifier.state, before);
      expect(
        (await dao.getProgress(
          TutorialCategory.equipmentSetup.name,
        ))!.lastStepIndex,
        0,
      );
    },
  );

  test(
    'rapid tutorial navigation is serialized in persistence order',
    () async {
      final dao = _ToggleFailTutorialProgressDao(database);
      final notifier = TutorialNotifier(dao);
      addTearDown(notifier.dispose);
      await notifier.startTutorial(TutorialCategory.equipmentSetup);

      await Future.wait([notifier.nextStep(), notifier.nextStep()]);

      expect(notifier.state.currentStepIndex, 2);
      expect(
        (await dao.getProgress(
          TutorialCategory.equipmentSetup.name,
        ))!.lastStepIndex,
        2,
      );
    },
  );

  test('failed tutorial dismissal leaves the active tour available', () async {
    final dao = _ToggleFailTutorialProgressDao(database);
    final notifier = TutorialNotifier(dao);
    addTearDown(notifier.dispose);
    await notifier.startTutorial(TutorialCategory.equipmentSetup);
    dao.failDismiss = true;

    await expectLater(notifier.dismissTutorial(), throwsStateError);

    expect(notifier.state.activeCategory, TutorialCategory.equipmentSetup);
  });

  test(
    'partial progress rehydrates as resumable after provider recreation',
    () async {
      const category = TutorialCategory.equipmentSetup;
      await database.tutorialProgressDao.restartProgress(category.name);
      await database.tutorialProgressDao.saveProgress(category.name, 2);

      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      addTearDown(container.dispose);
      container.read(tutorialProvider);
      await pumpEventQueue();
      final notifier = container.read(tutorialProvider.notifier);

      expect(notifier.hasCategoryProgress(category), isTrue);
      expect(notifier.isCategoryCompletedSync(category), isFalse);

      await notifier.resumeTutorial(category);
      expect(notifier.state.activeCategory, category);
      expect(notifier.state.currentStepIndex, 2);
    },
  );
}
