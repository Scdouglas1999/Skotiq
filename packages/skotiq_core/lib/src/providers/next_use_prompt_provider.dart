/// Provider layer that decides which first-real-use action step (if any) to
/// surface to the user once their rig is ready to image.
///
/// Where [readinessReportProvider] answers "is the rig *ready*?", this layer
/// answers the next question: "now that you're ready, what should you *do*
/// first?" It walks [kNextUseSteps] in teaching order and surfaces the first
/// action the user has neither completed nor explicitly dismissed.
///
/// ## Pure core + thin wiring
///
/// All eligibility *rules* live in [selectNextUseStep], a pure function with no
/// Riverpod / I/O dependencies, so they are exhaustively unit-testable in
/// isolation (mirroring the pure stance of `buildReadinessReport`). The
/// [nextUsePromptProvider] below is the only place that touches live providers;
/// it collects the same inputs [selectNextUseStep] expects and forwards them.
///
/// ## Fail-closed contract
///
/// This layer adopts the same posture as [readinessReportProvider]: absence of
/// positive evidence is treated as "not eligible". Concretely, any async input
/// that is still loading or has errored collapses to "not eligible"
/// ([nextUsePromptProvider] returns `null`). We never optimistically surface a
/// prompt — or optimistically mark a step complete — on the strength of data we
/// have not actually read. A genuinely unknown signal must surface as the
/// conservative outcome, not silently degrade.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/onboarding/next_use_steps.dart';
import '../models/readiness/readiness_models.dart';
import 'database_provider.dart';
import 'readiness_provider.dart';
import 'sequence/sequence_catalog_sync.dart';
import 'sequence/sequence_selection.dart';
import 'session_provider.dart';
import 'smart_night_draft_provider.dart';

/// Stable screen-id prefix used to persist next-use step dismissals in the
/// `tutorial_progress` table via [TutorialProgressDao.dismissPromptForScreen].
///
/// Dismissals reuse the existing contextual-prompt mechanism rather than
/// introducing a new table: each dismissed step is stored under the category
/// `'next_use.<actionId>'`. The prefix is intentionally distinct from any
/// tutorial category so next-use dismissals never collide with them.
const String kNextUsePromptScreenIdPrefix = 'next_use.';

/// Builds the stable persistence screen id for [id]'s dismissal row.
///
/// Round-trips with [nextUseActionIdFromScreenId]: the latter maps the result
/// back to [id]. Centralising the spelling here means the prefix convention
/// lives in exactly one place.
String nextUsePromptScreenId(NextUseActionId id) =>
    '$kNextUsePromptScreenIdPrefix${id.name}';

/// Parses a [NextUseActionId] from a persisted dismissal screen id, or returns
/// `null` if [screenId] is not a next-use dismissal row.
///
/// Rows in `tutorial_progress` are a shared namespace: tutorial categories
/// and contextual-prompt screen ids all live there. This
/// function ignores anything that does not carry the [kNextUsePromptScreenIdPrefix]
/// prefix, and ignores a next-use-prefixed id whose suffix does not name a
/// known [NextUseActionId] (e.g. a step that was removed in a later release).
/// That tolerance is deliberate: an unknown suffix is simply not mapped to an
/// action, it does not throw — a stale dismissal row must not crash the app.
NextUseActionId? nextUseActionIdFromScreenId(String screenId) {
  if (!screenId.startsWith(kNextUsePromptScreenIdPrefix)) {
    return null;
  }
  final actionName = screenId.substring(kNextUsePromptScreenIdPrefix.length);
  for (final id in NextUseActionId.values) {
    if (id.name == actionName) {
      return id;
    }
  }
  return null;
}

/// Pure decision function: selects the next first-real-use step to surface, or
/// `null` when none should be shown.
///
/// Eligibility gate (must hold, else returns `null`):
/// 1. [readiness] reports the rig is ready to image
///    ([ReadinessReport.isReadyToImage], i.e. overall is not
///    [ReadinessLevel.blocked]). We do not nudge the user toward "frame a
///    target" while their camera is disconnected.
///
/// When eligible, walks [kNextUseSteps] in order and returns the first step
/// whose action is in neither [completedActions] nor [dismissedActions].
/// Returns `null` when every step is complete or dismissed.
///
/// This function is intentionally input-only — it makes no assumptions about
/// where [completedActions] / [dismissedActions] come from. [nextUsePromptProvider]
/// derives them from live signals; tests drive them directly.
NextUseStep? selectNextUseStep({
  required ReadinessReport readiness,
  required Set<NextUseActionId> completedActions,
  required Set<NextUseActionId> dismissedActions,
}) {
  if (!readiness.isReadyToImage) {
    return null;
  }
  for (final step in kNextUseSteps) {
    final done = completedActions.contains(step.id);
    final dismissed = dismissedActions.contains(step.id);
    if (!done && !dismissed) {
      return step;
    }
  }
  return null;
}

/// Reactive set of next-use actions the user has explicitly dismissed.
///
/// Derived from [TutorialProgressDao.watchDismissedPromptScreenIds]: every
/// dismissed `tutorial_progress` row whose category carries the
/// [kNextUsePromptScreenIdPrefix] prefix maps back to its [NextUseActionId].
/// Rows for other prompt/tutorial namespaces, and next-use-prefixed rows whose
/// suffix is not a known action, are filtered out by
/// [nextUseActionIdFromScreenId].
///
/// Exposed as a [StreamProvider] so the prompt re-resolves the instant the user
/// dismisses a step, without any manual invalidation.
final nextUseDismissedActionsProvider = StreamProvider<Set<NextUseActionId>>((
  ref,
) {
  final dao = ref.watch(tutorialProgressDaoProvider);
  return dao.watchDismissedPromptScreenIds().map((screenIds) {
    final actions = <NextUseActionId>{};
    for (final screenId in screenIds) {
      final action = nextUseActionIdFromScreenId(screenId);
      if (action != null) {
        actions.add(action);
      }
    }
    return actions;
  });
});

/// Reactive set of next-use actions that are already satisfied by live app
/// state, so they never need to be surfaced as a prompt.
///
/// Completion is derived from the same kinds of signals readiness uses, each
/// fail-closed: a still-loading or errored input contributes *nothing* to the
/// set (the action is treated as not-yet-complete), which is the conservative
/// outcome — at worst we surface a prompt for something already done, never the
/// reverse where we hide a genuinely-needed nudge.
///
/// Each per-action signal is a live-state read, not a stored "done" flag.
final nextUseCompletedActionsProvider = Provider<Set<NextUseActionId>>((ref) {
  final completed = <NextUseActionId>{};

  // Planning the night: a loaded plan a run can start, a saved sequence, or a
  // Smart Night draft, however it was made. Suggesting Smart Night over a
  // plan the operator already has would offer to replace it.
  // Loading/error -> valueOrNull null/empty -> not complete (fail-closed).
  final planLoaded = ref.watch(
    currentSequenceProvider.select((s) => s?.launchable ?? false),
  );
  final draftCount = ref.watch(_smartNightDraftCountProvider).valueOrNull ?? 0;
  final savedCount =
      ref.watch(savedSequenceSummariesProvider).valueOrNull?.length ?? 0;
  if (planLoaded || draftCount > 0 || savedCount > 0) {
    completed.add(NextUseActionId.buildSmartNight);
  }

  // Framing: a non-empty session target name means the user has framed/chosen a
  // target, and a loaded plan with a target header has one. Watched via
  // `select` so this only recomputes when the boolean flips.
  final hasTarget = ref.watch(
    sessionStateProvider.select((s) => (s.targetName ?? '').trim().isNotEmpty),
  );
  final planHasTarget = ref.watch(
    currentSequenceProvider.select((s) => s?.targetHeaders.isNotEmpty ?? false),
  );
  if (hasTarget || planHasTarget) {
    completed.add(NextUseActionId.frameTarget);
  }

  // Plate solver + focus: read straight off the readiness report so the single
  // source of truth for "is the solver ready / is focus known" stays the
  // readiness model, not a second copy of those rules.
  final readiness = ref.watch(readinessReportProvider);
  if (readiness.itemFor(ReadinessItemId.plateSolver)?.isReady ?? false) {
    completed.add(NextUseActionId.configurePlateSolver);
  }
  if (readiness.itemFor(ReadinessItemId.focusState)?.isReady ?? false) {
    completed.add(NextUseActionId.runAutofocus);
  }

  // First light: at least one captured image on disk/db.
  // Loading/error -> not complete (fail-closed).
  if (ref.watch(hasCapturedImagesProvider).valueOrNull ?? false) {
    completed.add(NextUseActionId.captureFirstLight);
  }

  return completed;
});

/// The count of stored Smart Night drafts, again each time the store changes.
///
/// A non-empty draft store is the "user has engaged with Smart Night" signal
/// for [nextUseCompletedActionsProvider]. Watching the store, not reading it
/// once, is what retires the step as soon as the first plan is built.
final _smartNightDraftCountProvider = StreamProvider<int>((ref) {
  return ref
      .watch(smartNightDraftServiceProvider)
      .watchAll()
      .map((drafts) => drafts.length)
      .distinct();
});

/// The next first-real-use step to surface, or `null` when none should show.
///
/// Wires the live readiness / completion / dismissal signals into the pure
/// [selectNextUseStep]. Fail-closed: while the dismissed-actions stream is
/// still loading (or has errored), this collapses to `null` (not eligible) —
/// matching [readinessReportProvider]'s stance that unknown evidence must
/// resolve to the conservative outcome.
///
/// Because every input is itself reactive, this recomputes automatically when
/// readiness changes, a step is completed, or a step is dismissed — there is no
/// manual invalidation to maintain.
final nextUsePromptProvider = Provider<NextUseStep?>((ref) {
  final readiness = ref.watch(readinessReportProvider);

  final completedActions = ref.watch(nextUseCompletedActionsProvider);

  // Dismissals are async (a DB watch). A loading/errored stream yields null;
  // fail closed by treating the dismissed set as empty would *over*-surface, so
  // instead we suppress the prompt entirely until dismissals are known — a
  // user who dismissed a step must never see it flash back on a cold start.
  final dismissedAsync = ref.watch(nextUseDismissedActionsProvider);
  final dismissedActions = dismissedAsync.valueOrNull;
  if (dismissedActions == null) {
    return null;
  }

  return selectNextUseStep(
    readiness: readiness,
    completedActions: completedActions,
    dismissedActions: dismissedActions,
  );
});
