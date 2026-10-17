/// First-real-use action steps, surfaced *after* the readiness checklist is
/// green.
///
/// Where the readiness checklist tracks how to make the rig *ready* (connect
/// hardware, set location, install a solver, …), these steps nudge the user
/// toward their first *productive* actions once readiness is satisfied: plan a
/// night, frame a target, capture first light, and so on.
///
/// This model is intentionally pure Dart — no Flutter, no Riverpod, no
/// go_router types — so it can be unit-tested in isolation and reused by any
/// presentation layer. To stay Flutter-free it stores a stable [iconKey]
/// string rather than an `IconData`; the presentation layer maps that key to a
/// concrete `lucide_icons` glyph. This mirrors the pure stance of the readiness
/// model in `skotiq_core`.
library;

/// Identifies a single first-real-use action the app suggests after onboarding.
///
/// Each id appears exactly once in [kNextUseSteps]; [stepFor] and the tests
/// enforce that, so adding an id without a step is a surfaced error rather than
/// a silent gap.
enum NextUseActionId {
  /// Auto-build a full imaging plan for tonight (Smart Night).
  buildSmartNight,

  /// Frame a target against a real sky survey before committing.
  frameTarget,

  /// Confirm the plate solver is detected and configured.
  configurePlateSolver,

  /// Run an autofocus pass so the optics are sharp before capture.
  runAutofocus,

  /// Take the first light frame.
  captureFirstLight,
}

/// Rich, presentation-layer content for one first-real-use action step.
///
/// Maps a single [NextUseActionId] to the human-facing copy, a stable icon key,
/// and the deep-link target the presentation layer navigates to.
class NextUseStep {
  /// The action this step represents.
  final NextUseActionId id;

  /// Short, action-oriented heading (e.g. `Plan tonight automatically`).
  final String title;

  /// One-line explanation of what the action does, written in the second
  /// person and kept to a single sentence so it reads cleanly in a card.
  final String body;

  /// Short call-to-action label for the step's primary button
  /// (e.g. `Build Smart Night`).
  final String actionLabel;

  /// Stable, Flutter-free icon identifier. The presentation layer maps this to
  /// a concrete `lucide_icons` glyph; keeping it a plain string lets this model
  /// live in `skotiq_core` without importing Flutter.
  final String iconKey;

  /// go_router location to navigate to when the user takes the action.
  ///
  /// Any `?section=` query value here is verified by tests to be a non-empty
  /// string, so a malformed deep link fails the build rather than silently
  /// routing nowhere.
  final String deepLinkRoute;

  const NextUseStep({
    required this.id,
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.iconKey,
    required this.deepLinkRoute,
  });
}

/// The ordered set of first-real-use action steps.
///
/// Order is the teaching order the app walks the user through after readiness
/// is green: plan the night, frame a target, confirm solving, focus, then
/// capture first light. The list MUST cover every [NextUseActionId] exactly
/// once — [stepFor] and the tests both enforce this, so adding a new action id
/// without a step is a surfaced error rather than a silent gap.
const List<NextUseStep> kNextUseSteps = <NextUseStep>[
  NextUseStep(
    id: NextUseActionId.buildSmartNight,
    title: 'Plan tonight automatically',
    body:
        'Smart Night builds a full imaging plan for tonight from your rig and the targets that are well placed.',
    actionLabel: 'Build Smart Night',
    iconKey: 'sparkles',
    deepLinkRoute: '/planner?tab=scheduler',
  ),
  NextUseStep(
    id: NextUseActionId.frameTarget,
    title: 'Frame your target',
    body:
        'Compose your shot against a real sky survey so you know exactly what the sensor will capture.',
    actionLabel: 'Open framing',
    iconKey: 'crop',
    deepLinkRoute: '/framing',
  ),
  NextUseStep(
    id: NextUseActionId.configurePlateSolver,
    title: 'Confirm your plate solver',
    body:
        'Check that your solver is detected so the app can center every target precisely.',
    actionLabel: 'Review solving',
    iconKey: 'crosshair',
    deepLinkRoute: '/settings?section=plate-solving',
  ),
  NextUseStep(
    id: NextUseActionId.runAutofocus,
    title: 'Run autofocus',
    body:
        'Sharpen the optics with a focus run so the app has a known star size to monitor all night.',
    actionLabel: 'Open equipment',
    iconKey: 'focus',
    deepLinkRoute: '/equipment',
  ),
  NextUseStep(
    id: NextUseActionId.captureFirstLight,
    title: 'Capture first light',
    body: 'Take your first frame and watch it land in the live capture view.',
    actionLabel: 'Capture first light',
    iconKey: 'camera',
    deepLinkRoute: '/imaging?firstLight=1',
  ),
];

/// Returns the next-use step for [id].
///
/// Throws a [StateError] if no step is defined for [id]. The list is required
/// to be exhaustive over [NextUseActionId], so a missing step is a programming
/// error that must surface immediately rather than be papered over with a
/// silent fallback.
NextUseStep stepFor(NextUseActionId id) {
  for (final step in kNextUseSteps) {
    if (step.id == id) {
      return step;
    }
  }
  throw StateError(
    'No NextUseStep defined for NextUseActionId.${id.name}. '
    'kNextUseSteps must cover every NextUseActionId.',
  );
}
