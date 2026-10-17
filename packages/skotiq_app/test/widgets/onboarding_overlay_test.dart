// Widget tests for the first-launch onboarding tour.
//
// The tests drive [OnboardingOverlay] through its key states: initial render,
// step advancement, skip-marks-as-completed, and the Settings "Re-run tutorial"
// reset. An in-memory Drift database exercises the underlying
// [TutorialProgressDao] path end-to-end without touching the production sqlite
// file.
//
// The tour itself is replay-only (Settings → Help & Tutorials → "Re-run
// onboarding tour"), so there is no auto-launch gating to cover here.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/onboarding/onboarding_overlay.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/database/daos/tutorial_progress_dao.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/tutorial_provider.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

SkotiqDatabase _newInMemoryDb() {
  return SkotiqDatabase.forTesting(NativeDatabase.memory());
}

class _FailingFirstLaunchTourDao extends FirstLaunchTourDao {
  _FailingFirstLaunchTourDao(super.progressDao);

  @override
  Future<void> markSkipped() async {
    throw StateError('skip persistence failed');
  }

  @override
  Future<void> markCompleted() async {
    throw StateError('completion persistence failed');
  }
}

Future<void> _pumpOverlayDirect(
  WidgetTester tester, {
  required SkotiqDatabase db,
  FirstLaunchTourDao? tourDaoOverride,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1200, 800);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        if (tourDaoOverride != null)
          firstLaunchTourDaoProvider.overrideWithValue(tourDaoOverride),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: OnboardingOverlay(),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OnboardingOverlay step advancement', () {
    testWidgets('Next button advances welcome → equipment step',
        (tester) async {
      final db = _newInMemoryDb();
      addTearDown(() async => db.close());

      await _pumpOverlayDirect(tester, db: db);

      // Welcome step is visible.
      expect(find.text('Welcome to Skotiq'), findsOneWidget);

      // "Show me around" advances to step 2 (Equipment).
      await tester.tap(find.text('Show me around'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Welcome to Skotiq'), findsNothing);
      expect(find.text('Connect your gear'), findsOneWidget);
    });

    testWidgets('reaches completion card after walking through all core steps',
        (tester) async {
      final db = _newInMemoryDb();
      addTearDown(() async => db.close());

      await _pumpOverlayDirect(tester, db: db);

      // Welcome → step 1 (Equipment).
      await tester.tap(find.text('Show me around'));
      await tester.pumpAndSettle();
      // Steps 1..5: tap Next five times to reach the completion card
      // (welcome=0, equipment=1, profiles=2, sequencer=3, scheduler=4,
      // plate solving=5, completion=6).
      for (var i = 0; i < 5; i++) {
        expect(find.text('Next'), findsOneWidget,
            reason: 'Next button missing at step $i');
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
      }

      // Completion card has a "Done" primary button and the optional
      // secondary "Show me about defect maps".
      expect(find.text("You're set"), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Show me about defect maps'), findsOneWidget);
    });
  });

  group('OnboardingOverlay skip + completion persistence', () {
    testWidgets('Skip button marks tour as skipped in DAO', (tester) async {
      final db = _newInMemoryDb();
      addTearDown(() async => db.close());

      await _pumpOverlayDirect(tester, db: db);

      // Advance off the welcome card so the ghost Skip button shows.
      await tester.tap(find.text('Show me around'));
      await tester.pumpAndSettle();
      // Skip from the equipment step.
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();

      // DAO row must show dismissed=true so the launcher won't re-mount
      // the overlay on the next launch.
      final dao = TutorialProgressDao(db);
      final progress = await dao.getProgress(firstLaunchTourCategory);
      expect(progress, isNotNull,
          reason: 'Skip must persist a row to suppress re-launch');
      expect(progress!.dismissed, isTrue,
          reason: 'Skip is recorded as dismissed, not completed');
      expect(progress.completed, isFalse,
          reason: 'Skip is distinct from completion');
    });

    testWidgets(
        "Welcome card's secondary skip also persists the dismissal flag",
        (tester) async {
      final db = _newInMemoryDb();
      addTearDown(() async => db.close());

      await _pumpOverlayDirect(tester, db: db);
      await tester.tap(find.text("Skip — I know what I'm doing"));
      await tester.pumpAndSettle();

      final dao = TutorialProgressDao(db);
      final progress = await dao.getProgress(firstLaunchTourCategory);
      expect(progress, isNotNull);
      expect(progress!.dismissed, isTrue);
    });

    testWidgets('Done on completion card marks tour as completed',
        (tester) async {
      final db = _newInMemoryDb();
      addTearDown(() async => db.close());

      await _pumpOverlayDirect(tester, db: db);

      // Walk to the completion card.
      await tester.tap(find.text('Show me around'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      final dao = TutorialProgressDao(db);
      final progress = await dao.getProgress(firstLaunchTourCategory);
      expect(progress, isNotNull);
      expect(progress!.completed, isTrue,
          reason: 'Done must persist completion=true');
      expect(progress.dismissed, isFalse,
          reason: 'Completion is distinct from skip');
    });

    testWidgets('failed Skip stays open, remains retryable, and reports error',
        (tester) async {
      final db = _newInMemoryDb();
      addTearDown(() async => db.close());
      await _pumpOverlayDirect(
        tester,
        db: db,
        tourDaoOverride: _FailingFirstLaunchTourDao(
          db.tutorialProgressDao,
        ),
      );

      await tester.tap(find.text('Show me around'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();

      expect(find.text('Connect your gear'), findsOneWidget);
      expect(find.text('Skip'), findsOneWidget);
      expect(
        find.text('Could not save tour progress. Please try again.'),
        findsOneWidget,
      );
      expect(
        await db.tutorialProgressDao.getProgress(firstLaunchTourCategory),
        isNull,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('OnboardingOverlay defect-map follow-up', () {
    testWidgets('"Show me about defect maps" unlocks the optional eighth step',
        (tester) async {
      final db = _newInMemoryDb();
      addTearDown(() async => db.close());

      await _pumpOverlayDirect(tester, db: db);

      // Walk to the completion card.
      await tester.tap(find.text('Show me around'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Show me about defect maps'));
      await tester.pumpAndSettle();

      expect(find.text('Defect maps and calibration'), findsOneWidget);
      // The defect-map step is now the last step; primary button is Done.
      expect(find.text('Done'), findsOneWidget);
    });
  });

  group('Settings "Re-run tutorial" reset flow', () {
    testWidgets('reset clears completion flag so launcher re-fires overlay',
        (tester) async {
      final db = _newInMemoryDb();
      addTearDown(() async => db.close());

      // Seed the DAO with a completed row. This represents a user who
      // already finished the tour on a previous launch.
      final dao = TutorialProgressDao(db);
      await dao.markCompleted(firstLaunchTourCategory);

      // Sanity: status reads as completed before reset.
      final daoWrapper = FirstLaunchTourDao(dao);
      expect(await daoWrapper.getStatus(),
          equals(FirstLaunchTourStatus.completed));

      // Run the reset path through the same DAO wrapper the notifier
      // uses. We exercise the persistence path directly (not the
      // notifier) because the notifier holds an auto-disposing Riverpod
      // timer that interacts badly with the widget tester's pending-timer
      // assertion. The notifier delegates to FirstLaunchTourDao.reset
      // for all persistence — covering that here gives equivalent
      // coverage without the timer flake.
      await daoWrapper.reset();

      // After reset, an explicit replay request is on record — the launcher's
      // gate resolves to pending and re-mounts the overlay on next render.
      expect(
          await daoWrapper.getStatus(), equals(FirstLaunchTourStatus.pending));
    });

    testWidgets('a fresh install reads as notStarted, never pending',
        (tester) async {
      // The coach-mark tour is replay-only. With no row at all nobody has
      // asked for it, and mapping that to `pending` is what made it auto-fire
      // on top of the equipment-onboarding wizard on every fresh install.
      final db = _newInMemoryDb();
      addTearDown(() async => db.close());

      final daoWrapper = FirstLaunchTourDao(TutorialProgressDao(db));

      expect(await daoWrapper.getStatus(),
          equals(FirstLaunchTourStatus.notStarted));

      // Only an explicit replay request flips it to pending.
      await daoWrapper.reset();
      expect(
          await daoWrapper.getStatus(), equals(FirstLaunchTourStatus.pending));
    });
  });

  // "Reset All Progress" re-arms this tour, so the very next click the operator
  // makes lands on a scrim they did not ask for. Reading that as a Skip costs
  // them the click AND the tour, leaving only the symptom "the nav rail did
  // nothing and a second identical click worked". A modal that stays up
  // explains itself.
  group('a stray click on the scrim does not silently kill the tour', () {
    testWidgets('tapping the dim area leaves the tour on screen',
        (tester) async {
      final db = _newInMemoryDb();
      addTearDown(() async => db.close());

      await _pumpOverlayDirect(tester, db: db);
      expect(find.text('Welcome to Skotiq'), findsOneWidget);

      // Top-left corner: dim scrim, far from the card and any cutout — where
      // the nav rail sits under the overlay.
      await tester.tapAt(const Offset(40, 60));
      await tester.pumpAndSettle();

      expect(
        find.text('Welcome to Skotiq'),
        findsOneWidget,
        reason: 'the click is absorbed by the modal, not turned into a Skip',
      );
      expect(
        await FirstLaunchTourDao(TutorialProgressDao(db)).getStatus(),
        isNot(FirstLaunchTourStatus.skipped),
        reason: 'nothing may be persisted from a stray tap',
      );
    });

    testWidgets('Escape still leaves the tour', (tester) async {
      final db = _newInMemoryDb();
      addTearDown(() async => db.close());

      await _pumpOverlayDirect(tester, db: db);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      // This harness mounts the overlay directly (the launcher is what tears
      // it down in the app), so the pin is on the persisted intent.
      expect(
        await FirstLaunchTourDao(TutorialProgressDao(db)).getStatus(),
        FirstLaunchTourStatus.skipped,
      );
    });
  });
}
