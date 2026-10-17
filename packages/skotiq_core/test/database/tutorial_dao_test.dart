import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/tutorial_dao.dart';
import 'package:skotiq_core/src/database/daos/tutorial_progress_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/tutorial/tutorial_models.dart';
import 'package:skotiq_core/src/models/tutorial/tutorial_step.dart';

void main() {
  late SkotiqDatabase db;
  late TutorialDao tutorialDao;

  setUp(() {
    // Use an in-memory database for each test so they don't interfere.
    // forTesting + NativeDatabase.memory is the standard pattern in this
    // codebase (see existing services/database_migration_test.dart).
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    tutorialDao = TutorialDao(TutorialProgressDao(db));
  });

  tearDown(() async {
    await db.close();
  });

  group('TutorialDao - first-night auto-launch logic', () {
    test(
      'shouldShowFirstNightOnLaunch returns true when no progress exists',
      () async {
        // Fresh database — nothing has ever been stored for any tutorial.
        // This is the "first launch" path and the wizard must auto-open.
        final shouldShow = await tutorialDao.shouldShowFirstNightOnLaunch();
        expect(shouldShow, isTrue);
      },
    );

    test(
      'shouldShowFirstNightOnLaunch returns false after completion',
      () async {
        // User finished the wizard. They never see it again automatically.
        await tutorialDao.markFirstNightCompleted();
        final shouldShow = await tutorialDao.shouldShowFirstNightOnLaunch();
        expect(shouldShow, isFalse);
      },
    );

    test(
      'shouldShowFirstNightOnLaunch returns false after dismiss-forever',
      () async {
        // User clicked "Skip forever". Same outcome as completion for the
        // auto-launch check, but recorded as dismissal not completion.
        await tutorialDao.dismissFirstNightForever();
        final shouldShow = await tutorialDao.shouldShowFirstNightOnLaunch();
        expect(shouldShow, isFalse);
      },
    );

    test(
      'shouldShowFirstNightOnLaunch returns false after partial progress',
      () async {
        // User started the wizard, advanced two steps, then closed it
        // (without the soft-reset path). The DAO has a row — the wizard
        // does NOT auto-open. Resume is opt-in from Settings → Help.
        await tutorialDao.saveFirstNightProgress(2);
        final shouldShow = await tutorialDao.shouldShowFirstNightOnLaunch();
        expect(shouldShow, isFalse);
      },
    );

    test('resetFirstNight restores auto-launch behavior', () async {
      // Finish, then reset — auto-launch must resume. This is what the
      // Settings → Help "Restart" path relies on.
      await tutorialDao.markFirstNightCompleted();
      expect(await tutorialDao.shouldShowFirstNightOnLaunch(), isFalse);
      await tutorialDao.resetFirstNight();
      expect(await tutorialDao.shouldShowFirstNightOnLaunch(), isTrue);
    });
  });

  group('TutorialDao - progress persistence', () {
    test('getLastStepIndex returns 0 when nothing has been saved', () async {
      // A user who has never opened the wizard resumes at step 0
      // (the welcome step) — no exception, no null surprise.
      final index = await tutorialDao.getLastStepIndex();
      expect(index, equals(0));
    });

    test(
      'saveFirstNightProgress persists and getLastStepIndex returns it',
      () async {
        await tutorialDao.saveFirstNightProgress(3);
        final index = await tutorialDao.getLastStepIndex();
        expect(index, equals(3));
      },
    );

    test('saveFirstNightProgress overwrites previous progress', () async {
      await tutorialDao.saveFirstNightProgress(2);
      await tutorialDao.saveFirstNightProgress(5);
      final index = await tutorialDao.getLastStepIndex();
      expect(index, equals(5));
    });
  });

  group('TutorialDao - completion + dismissal flags', () {
    test('isFirstNightCompleted is false by default', () async {
      expect(await tutorialDao.isFirstNightCompleted(), isFalse);
    });

    test(
      'isFirstNightCompleted is true after markFirstNightCompleted',
      () async {
        await tutorialDao.markFirstNightCompleted();
        expect(await tutorialDao.isFirstNightCompleted(), isTrue);
      },
    );

    test('isFirstNightDismissed is false by default', () async {
      expect(await tutorialDao.isFirstNightDismissed(), isFalse);
    });

    test(
      'isFirstNightDismissed is true after dismissFirstNightForever',
      () async {
        await tutorialDao.dismissFirstNightForever();
        expect(await tutorialDao.isFirstNightDismissed(), isTrue);
      },
    );

    test('completion and dismissal are distinguishable', () async {
      // We want the Settings UI to be able to tell "user finished" from
      // "user opted out forever". The two operations must not collapse.
      await tutorialDao.markFirstNightCompleted();
      expect(await tutorialDao.isFirstNightCompleted(), isTrue);
      expect(await tutorialDao.isFirstNightDismissed(), isFalse);
    });
  });

  group('TutorialDao - category identity', () {
    test('firstNightCategoryName matches the enum name', () {
      // The string identity in the database must equal the enum's `.name`
      // — that's how TutorialProgressDao keys the row. A divergence here
      // would silently create a second category row and break resume.
      expect(
        TutorialDao.firstNightCategoryName,
        equals(TutorialCategory.firstNight.name),
      );
    });
  });

  group('FirstNightWizard model layer', () {
    test('FirstNightWizard exposes exactly 7 steps', () {
      // The wizard advertises a 7-step flow; the model layer must agree.
      // FirstNightWizard.steps throws StateError if the underlying
      // TutorialDefinitions.firstNight list has the wrong length, which
      // is the invariant this test pins down.
      expect(FirstNightWizard.steps.length, equals(7));
      expect(FirstNightWizard.totalSteps, equals(7));
    });

    test('every wizard step belongs to the firstNight category', () {
      for (final wizardStep in FirstNightWizard.steps) {
        expect(wizardStep.category, equals(TutorialCategory.firstNight));
      }
    });

    test('wizard steps are in monotonically increasing order', () {
      final orders = FirstNightWizard.steps.map((s) => s.order).toList();
      for (var i = 0; i < orders.length; i++) {
        expect(
          orders[i],
          equals(i),
          reason:
              'Step at index $i has order ${orders[i]}; expected $i. '
              'TutorialStep.order must equal its position in the list '
              'so FirstNightWizardNotifier.goToStep math is correct.',
        );
      }
    });

    test('non-welcome wizard steps all have deep-link routes', () {
      // Steps 1..6 deep-link into screens; only step 0 (welcome) is
      // route-free. Catches a future refactor that accidentally drops a
      // route from a navigation step.
      for (var i = 1; i < FirstNightWizard.steps.length; i++) {
        expect(
          FirstNightWizard.steps[i].hasDeepLink,
          isTrue,
          reason:
              'Wizard step $i (${FirstNightWizard.steps[i].id}) must have '
              'a deep-link route; only the welcome step is route-free.',
        );
      }
    });

    test('every wizard step description meets the 80-150 word target', () {
      // The spec mandates 80-150 words of WHY-style content per step.
      // Drift outside that band means a description got truncated or
      // bloated — both are review-worthy and should fail loud.
      for (final wizardStep in FirstNightWizard.steps) {
        final words = wizardStep.description
            .split(RegExp(r'\s+'))
            .where((w) => w.isNotEmpty)
            .length;
        expect(
          words,
          inInclusiveRange(80, 150),
          reason:
              'Step "${wizardStep.id}" description is $words words; '
              'expected 80–150. Either tighten the prose or expand it.',
        );
      }
    });
  });
}
