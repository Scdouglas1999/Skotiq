import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/onboarding/next_use_steps.dart';
import 'package:skotiq_core/src/models/readiness/readiness_models.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/next_use_prompt_provider.dart';
import 'package:skotiq_core/src/providers/readiness_provider.dart';
import 'package:skotiq_core/src/providers/tutorial_provider.dart'
    show tutorialProgressDaoProvider;

// Helpers for building readiness reports of a known overall level.
//
// selectNextUseStep only consumes ReadinessReport.isReadyToImage (and, in the
// completion provider, individual item levels). For the pure-function tests we
// just need a report that is, or is not, ready to image.

/// A ready-to-image report: every item green, so `isReadyToImage` is true.
ReadinessReport _readyReport() => buildReadinessReport(
  cameraConnected: true,
  mountConnected: true,
  hasProfile: true,
  locationSet: true,
  outputPathSet: true,
  plateSolverReady: true,
  darkLibraryHasCoverage: true,
  focusKnown: true,
  hasActiveProfile: true,
  assignedProfileDeviceCount: 4,
  otherAssignedProfileDeviceCount: 2,
);

/// A blocked report: no profile -> criticalDevices blocked -> overall blocked.
ReadinessReport _blockedReport() => buildReadinessReport(
  cameraConnected: false,
  mountConnected: false,
  hasProfile: false,
  locationSet: false,
  outputPathSet: false,
  plateSolverReady: false,
  darkLibraryHasCoverage: false,
  focusKnown: false,
  hasActiveProfile: false,
  assignedProfileDeviceCount: 0,
  otherAssignedProfileDeviceCount: 0,
);

void main() {
  group('selectNextUseStep (pure)', () {
    test('returns null when readiness is blocked, regardless of steps', () {
      final step = selectNextUseStep(
        readiness: _blockedReport(),
        completedActions: const {},
        dismissedActions: const {},
      );
      expect(step, isNull);
    });

    test('returns the first step when ready, nothing complete or '
        'dismissed', () {
      final step = selectNextUseStep(
        readiness: _readyReport(),
        completedActions: const {},
        dismissedActions: const {},
      );
      expect(step, isNotNull);
      // The first step in teaching order is buildSmartNight.
      expect(step!.id, kNextUseSteps.first.id);
      expect(step.id, NextUseActionId.buildSmartNight);
    });

    test('skips completed steps and returns the first incomplete one', () {
      final step = selectNextUseStep(
        readiness: _readyReport(),
        completedActions: const {
          NextUseActionId.buildSmartNight,
          NextUseActionId.frameTarget,
        },
        dismissedActions: const {},
      );
      expect(step, isNotNull);
      // The first two are complete, so the third in order is surfaced.
      expect(step!.id, NextUseActionId.configurePlateSolver);
    });

    test('skips dismissed steps and returns the first undismissed one', () {
      final step = selectNextUseStep(
        readiness: _readyReport(),
        completedActions: const {},
        dismissedActions: const {NextUseActionId.buildSmartNight},
      );
      expect(step, isNotNull);
      expect(step!.id, NextUseActionId.frameTarget);
    });

    test('skips a step that is both completed and dismissed', () {
      final step = selectNextUseStep(
        readiness: _readyReport(),
        completedActions: const {NextUseActionId.buildSmartNight},
        dismissedActions: const {NextUseActionId.buildSmartNight},
      );
      expect(step, isNotNull);
      expect(step!.id, NextUseActionId.frameTarget);
    });

    test('returns null when every step is completed', () {
      final step = selectNextUseStep(
        readiness: _readyReport(),
        completedActions: NextUseActionId.values.toSet(),
        dismissedActions: const {},
      );
      expect(step, isNull);
    });

    test('returns null when every step is dismissed', () {
      final step = selectNextUseStep(
        readiness: _readyReport(),
        completedActions: const {},
        dismissedActions: NextUseActionId.values.toSet(),
      );
      expect(step, isNull);
    });

    test('returns null when steps are split between completed and dismissed '
        'with full coverage', () {
      final step = selectNextUseStep(
        readiness: _readyReport(),
        completedActions: const {
          NextUseActionId.buildSmartNight,
          NextUseActionId.frameTarget,
          NextUseActionId.configurePlateSolver,
        },
        dismissedActions: const {
          NextUseActionId.runAutofocus,
          NextUseActionId.captureFirstLight,
        },
      );
      expect(step, isNull);
    });

    test('walks in kNextUseSteps order — surfaces the last remaining step '
        'when all earlier ones are done', () {
      final allButLast = kNextUseSteps
          .take(kNextUseSteps.length - 1)
          .map((s) => s.id)
          .toSet();
      final step = selectNextUseStep(
        readiness: _readyReport(),
        completedActions: allButLast,
        dismissedActions: const {},
      );
      expect(step, isNotNull);
      expect(step!.id, kNextUseSteps.last.id);
      expect(step.id, NextUseActionId.captureFirstLight);
    });
  });

  group('screen-id round-trip helpers (pure)', () {
    test('nextUsePromptScreenId uses the next_use. prefix + action name', () {
      expect(
        nextUsePromptScreenId(NextUseActionId.buildSmartNight),
        'next_use.buildSmartNight',
      );
      expect(
        nextUsePromptScreenId(NextUseActionId.captureFirstLight),
        'next_use.captureFirstLight',
      );
    });

    test('every action id round-trips screenId -> actionId', () {
      for (final id in NextUseActionId.values) {
        final screenId = nextUsePromptScreenId(id);
        expect(
          nextUseActionIdFromScreenId(screenId),
          id,
          reason: '$screenId must map back to $id',
        );
      }
    });

    test('non-next_use screen ids are ignored (return null)', () {
      expect(nextUseActionIdFromScreenId('firstLaunchTour'), isNull);
      expect(nextUseActionIdFromScreenId('equipmentOnboarding'), isNull);
      expect(nextUseActionIdFromScreenId('some_other_prompt'), isNull);
      expect(nextUseActionIdFromScreenId(''), isNull);
    });

    test('a next_use-prefixed but unknown suffix returns null (stale row)', () {
      // A dismissal row from a removed/renamed step must not crash or be
      // mismapped — it simply does not resolve to a known action.
      expect(nextUseActionIdFromScreenId('next_use.someRemovedStep'), isNull);
      expect(nextUseActionIdFromScreenId('next_use.'), isNull);
    });
  });

  group('nextUsePromptProvider (wiring + fail-closed)', () {
    // Drives nextUsePromptProvider through its public input providers. Each
    // input is overridden so the prompt can be exercised without a database or
    // live devices. selectNextUseStep itself is covered above; here we verify
    // the wiring forwards inputs correctly and fails closed on loading inputs.

    ProviderContainer buildContainer({
      required ReadinessReport readiness,
      Set<NextUseActionId> completed = const {},
      Set<NextUseActionId>? dismissed = const {},
    }) {
      final container = ProviderContainer(
        overrides: [
          readinessReportProvider.overrideWithValue(readiness),
          nextUseCompletedActionsProvider.overrideWithValue(completed),
          nextUseDismissedActionsProvider.overrideWith(
            (ref) => dismissed == null
                ? const Stream<Set<NextUseActionId>>.empty()
                : Stream.value(dismissed),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    /// Resolves the async inputs the prompt depends on, then reads it.
    Future<NextUseStep?> resolvePrompt(
      ProviderContainer container, {
      bool awaitDismissed = true,
    }) async {
      if (awaitDismissed) {
        // Drive the dismissed-actions stream to its first value.
        await container.read(nextUseDismissedActionsProvider.future);
      }
      return container.read(nextUsePromptProvider);
    }

    test('blocked readiness -> null', () async {
      final container = buildContainer(readiness: _blockedReport());
      expect(await resolvePrompt(container), isNull);
    });

    test(
      'dismissed-actions stream still loading -> null (fail-closed)',
      () async {
        // An empty stream never emits, so valueOrNull stays null.
        final container = buildContainer(
          readiness: _readyReport(),
          dismissed: null,
        );
        final step = await resolvePrompt(container, awaitDismissed: false);
        expect(step, isNull);
      },
    );

    test('ready + nothing complete/dismissed -> first step', () async {
      final container = buildContainer(readiness: _readyReport());
      final step = await resolvePrompt(container);
      expect(step?.id, NextUseActionId.buildSmartNight);
    });

    test('completed signals are forwarded and skipped', () async {
      final container = buildContainer(
        readiness: _readyReport(),
        completed: const {NextUseActionId.buildSmartNight},
      );
      final step = await resolvePrompt(container);
      expect(step?.id, NextUseActionId.frameTarget);
    });

    test('dismissed signals are forwarded and skipped', () async {
      final container = buildContainer(
        readiness: _readyReport(),
        dismissed: const {NextUseActionId.buildSmartNight},
      );
      final step = await resolvePrompt(container);
      expect(step?.id, NextUseActionId.frameTarget);
    });
  });

  group('nextUseDismissedActionsProvider (real tutorial_progress round-trip)', () {
    // Proves dismissals persist through the SAME mechanism the rest of the app
    // uses (TutorialProgressDao.dismissPromptForScreen on the tutorial_progress
    // table) and surface back through the provider, keyed by next_use.<id>.
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

    test('fresh database -> no dismissed next-use actions', () async {
      final dismissed = await container.read(
        nextUseDismissedActionsProvider.future,
      );
      expect(dismissed, isEmpty);
    });

    test('dismissing a step persists and surfaces as its action id', () async {
      final dao = container.read(tutorialProgressDaoProvider);
      await dao.dismissPromptForScreen(
        nextUsePromptScreenId(NextUseActionId.configurePlateSolver),
      );

      final dismissed = await container.read(
        nextUseDismissedActionsProvider.future,
      );
      expect(dismissed, {NextUseActionId.configurePlateSolver});
    });

    test(
      'multiple dismissals all surface; non-next_use rows are ignored',
      () async {
        final dao = container.read(tutorialProgressDaoProvider);
        await dao.dismissPromptForScreen(
          nextUsePromptScreenId(NextUseActionId.buildSmartNight),
        );
        await dao.dismissPromptForScreen(
          nextUsePromptScreenId(NextUseActionId.captureFirstLight),
        );
        // A dismissal from an unrelated namespace must be filtered out.
        await dao.dismissPromptForScreen('some_other_screen');
        // A dismissal from an unrelated category lives in the same table but is
        // not a next-use row, so it must be filtered out too.
        await dao.markDismissed('someOtherCategory');

        final dismissed = await container.read(
          nextUseDismissedActionsProvider.future,
        );
        expect(dismissed, {
          NextUseActionId.buildSmartNight,
          NextUseActionId.captureFirstLight,
        });
      },
    );

    test(
      'dismissal survives a fresh container over the same database',
      () async {
        await container
            .read(tutorialProgressDaoProvider)
            .dismissPromptForScreen(
              nextUsePromptScreenId(NextUseActionId.runAutofocus),
            );

        final second = ProviderContainer(
          overrides: [databaseProvider.overrideWithValue(db)],
        );
        try {
          final dismissed = await second.read(
            nextUseDismissedActionsProvider.future,
          );
          expect(dismissed, {NextUseActionId.runAutofocus});
        } finally {
          second.dispose();
        }
      },
    );
  });
}
