import 'tutorial_models.dart';

/// Describes a single step of the first-night wizard with everything the
/// UI needs to render it as a SkotiqDialog: the underlying
/// [TutorialStep] (title, description, ordering, id), a route to deep-link
/// into via the "Show me" button, and an icon identifier resolved by the
/// widget layer.
///
/// Why a separate model: [TutorialStep] is reused by every other tutorial
/// (overlay tours, contextual prompts, screen tours). The first-night
/// wizard needs extra data — the target route and an icon — that doesn't
/// belong on every overlay step. Splitting it keeps the broad
/// [TutorialStep] lean while still letting the wizard render rich content.
class FirstNightWizardStep {
  /// The underlying tutorial step (title, description, id, order).
  /// All persistence and progress tracking flow through [TutorialStep.id],
  /// so the wizard never invents a parallel identity for steps.
  final TutorialStep step;

  /// go_router path to navigate to when the user clicks "Show me".
  /// Empty string means the step has no deep-link target (e.g. the
  /// welcome and completion steps that don't correspond to a screen).
  final String deepLinkRoute;

  /// Lucide icon name — the wizard widget maps this to an `IconData`
  /// at render time so this model stays free of Flutter imports.
  /// Keeps the model layer pure Dart and unit-testable.
  final String iconName;

  const FirstNightWizardStep({
    required this.step,
    required this.deepLinkRoute,
    required this.iconName,
  });

  /// Convenience accessors that forward to the underlying [TutorialStep].
  /// These exist so the wizard widget can `wizardStep.id` without having
  /// to reach through `.step.id` on every reference.
  String get id => step.id;
  String get title => step.title;
  String get description => step.description;
  int get order => step.order;
  TutorialCategory get category => step.category;

  /// True if this step has a screen to deep-link into.
  /// The welcome step intentionally has none — clicking "Show me" on the
  /// welcome step makes no sense, so the wizard hides the button when this
  /// is false.
  bool get hasDeepLink => deepLinkRoute.isNotEmpty;
}

/// The seven-step first-night wizard as the wizard widget consumes it.
///
/// This is the single source of truth for the route mapping and icon
/// assignment. The actual step content (title, description, order) lives
/// inside [TutorialDefinitions.firstNight] so all tutorials share one
/// persistence/lookup path.
class FirstNightWizard {
  /// Lookup the wizard steps in display order. Throws [StateError] if
  /// the underlying [TutorialDefinitions.firstNight] doesn't have exactly
  /// the expected seven entries — the wizard is a fixed-length walkthrough,
  /// and rendering fewer than seven steps is a gap the user cannot see.
  static List<FirstNightWizardStep> get steps {
    final source = TutorialDefinitions.getStepsForCategory(
      TutorialCategory.firstNight,
    );
    if (source.length != _expectedStepCount) {
      throw StateError(
        'FirstNightWizard expected $_expectedStepCount steps from '
        'TutorialDefinitions.firstNight but found ${source.length}. '
        'Update tutorial_step.dart route/icon mappings if the wizard '
        'has been intentionally resized.',
      );
    }
    return [
      FirstNightWizardStep(
        step: source[0],
        deepLinkRoute: '',
        iconName: 'sparkles',
      ),
      FirstNightWizardStep(
        step: source[1],
        deepLinkRoute: '/equipment',
        iconName: 'plug',
      ),
      FirstNightWizardStep(
        step: source[2],
        deepLinkRoute: '/polar-alignment',
        iconName: 'compass',
      ),
      FirstNightWizardStep(
        step: source[3],
        deepLinkRoute: '/imaging',
        iconName: 'snowflake',
      ),
      FirstNightWizardStep(
        step: source[4],
        deepLinkRoute: '/framing',
        iconName: 'crop',
      ),
      FirstNightWizardStep(
        step: source[5],
        deepLinkRoute: '/guiding',
        iconName: 'crosshair',
      ),
      FirstNightWizardStep(
        step: source[6],
        deepLinkRoute: '/sequencer',
        iconName: 'play',
      ),
    ];
  }

  /// The number of steps the wizard advertises. Used by the progress bar
  /// in the UI without round-tripping through [steps] (which throws if the
  /// definition list is mis-sized).
  static const int totalSteps = _expectedStepCount;

  static const int _expectedStepCount = 7;
}
