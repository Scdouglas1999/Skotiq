part 'tutorial_models_parts/onboarding_definitions.dart';
part 'tutorial_models_parts/workflow_tours.dart';
part 'tutorial_models_parts/screen_tours.dart';

/// Shape of the spotlight cutout
enum SpotlightShape { circle, roundedRect, pill }

/// Tutorial step definition
class TutorialStep {
  /// Unique identifier for this step
  final String id;

  /// Title of this step
  final String title;

  /// Description/instruction for the user
  final String description;

  /// GlobalKey identifier to find the target widget (null = no spotlight)
  final String? targetKey;

  /// Position of the tooltip relative to the target
  final TooltipPosition position;

  /// Whether this step can be skipped
  final bool canSkip;

  /// Order in the tutorial sequence
  final int order;

  /// Tutorial category this step belongs to
  final TutorialCategory category;

  /// Optional action to highlight (e.g., "Click here")
  final String? action;

  /// Type of required action: "click", "input", "navigate", or null for passive
  final String? requiredAction;

  /// Widget key that completes the step (for interactive steps)
  final String? actionTarget;

  /// Can user click through the spotlight? Default true
  final bool isInteractive;

  /// Shape of the spotlight cutout
  final SpotlightShape spotlightShape;

  const TutorialStep({
    required this.id,
    required this.title,
    required this.description,
    this.targetKey,
    this.position = TooltipPosition.bottom,
    this.canSkip = true,
    required this.order,
    required this.category,
    this.action,
    this.requiredAction,
    this.actionTarget,
    this.isInteractive = true,
    this.spotlightShape = SpotlightShape.roundedRect,
  });
}

/// Position of the tutorial tooltip
enum TooltipPosition { top, bottom, left, right, center }

/// Tutorial categories - focused mini-tours
enum TutorialCategory {
  // Workflow tours (existing)

  /// New-user "First Night Wizard" — 7-step modal walkthrough covering the
  /// minimum-viable path from cold app launch to a running imaging sequence.
  /// This is the wizard that auto-opens on first launch when no tutorial
  /// progress exists; existing users can replay it from Settings → Help.
  firstNight,

  /// Connect -> Expose -> View (5 steps max)
  firstLight,

  /// Profiles -> Drivers -> Connect (4 steps max)
  equipmentSetup,

  /// Planetarium -> Search -> Slew -> Frame (4 steps max)
  targetPlanning,

  /// Sequencer basics -> Build -> Run (5 steps max)
  automatedImaging,

  /// Flat wizard workflow (3 steps max)
  calibrationFrames,

  /// Optional: Analytics, weather (4 steps max)
  advancedFeatures,

  // Screen-specific tours (12 screens)

  /// Dashboard screen deep tour (12 steps)
  dashboardTour,

  /// Equipment screen deep tour (10 steps)
  equipmentTour,

  /// Imaging screen deep tour (15 steps)
  imagingTour,

  /// Guiding screen deep tour (10 steps)
  guidingTour,

  /// Sequencer screen deep tour (12 steps)
  sequencerTour,

  /// Planetarium screen deep tour (10 steps)
  planetariumTour,

  /// Framing screen deep tour (10 steps)
  framingTour,

  /// Analytics screen deep tour (8 steps)
  analyticsTour,

  /// Flat Wizard screen deep tour (8 steps)
  flatWizardTour,

  /// Weather screen deep tour (8 steps)
  weatherTour,

  /// Settings screen deep tour (10 steps)
  settingsTour,

  /// Polar Alignment screen deep tour (10 steps)
  polarAlignmentTour,
}

/// Tutorial progress state
class TutorialProgress {
  /// Completed tutorial step IDs
  final Set<String> completedSteps;

  /// Whether the initial tour has been shown
  final bool hasSeenInitialTour;

  /// Whether tutorials are globally enabled
  final bool tutorialsEnabled;

  /// Currently active tutorial (null = none)
  final TutorialCategory? activeCategory;

  /// Current step index in active tutorial
  final int currentStepIndex;

  const TutorialProgress({
    this.completedSteps = const {},
    this.hasSeenInitialTour = false,
    this.tutorialsEnabled = true,
    this.activeCategory,
    this.currentStepIndex = 0,
  });

  TutorialProgress copyWith({
    Set<String>? completedSteps,
    bool? hasSeenInitialTour,
    bool? tutorialsEnabled,
    TutorialCategory? activeCategory,
    int? currentStepIndex,
    bool clearActiveCategory = false,
  }) {
    return TutorialProgress(
      completedSteps: completedSteps ?? this.completedSteps,
      hasSeenInitialTour: hasSeenInitialTour ?? this.hasSeenInitialTour,
      tutorialsEnabled: tutorialsEnabled ?? this.tutorialsEnabled,
      activeCategory: clearActiveCategory
          ? null
          : (activeCategory ?? this.activeCategory),
      currentStepIndex: currentStepIndex ?? this.currentStepIndex,
    );
  }

  bool isStepCompleted(String stepId) => completedSteps.contains(stepId);
}

/// Built-in tutorial definitions
/// Built-in tutorial definitions
class TutorialDefinitions {
  static const List<TutorialStep> firstNight = _firstNight;
  static const List<TutorialStep> firstLight = _firstLight;
  static const List<TutorialStep> equipmentSetup = _equipmentSetup;
  static const List<TutorialStep> targetPlanning = _targetPlanning;
  static const List<TutorialStep> automatedImaging = _automatedImaging;
  static const List<TutorialStep> calibrationFrames = _calibrationFrames;
  static const List<TutorialStep> advancedFeatures = _advancedFeatures;
  static const List<TutorialStep> dashboardTour = _dashboardTour;
  static const List<TutorialStep> equipmentTour = _equipmentTour;
  static const List<TutorialStep> imagingTour = _imagingTour;
  static const List<TutorialStep> guidingTour = _guidingTour;
  static const List<TutorialStep> sequencerTour = _sequencerTour;
  static const List<TutorialStep> planetariumTour = _planetariumTour;
  static const List<TutorialStep> framingTour = _framingTour;
  static const List<TutorialStep> analyticsTour = _analyticsTour;
  static const List<TutorialStep> flatWizardTour = _flatWizardTour;
  static const List<TutorialStep> weatherTour = _weatherTour;
  static const List<TutorialStep> settingsTour = _settingsTour;
  static const List<TutorialStep> polarAlignmentTour = _polarAlignmentTour;

  static List<TutorialStep> getStepsForCategory(TutorialCategory category) {
    switch (category) {
      case TutorialCategory.firstNight:
        return firstNight;
      case TutorialCategory.firstLight:
        return firstLight;
      case TutorialCategory.equipmentSetup:
        return equipmentSetup;
      case TutorialCategory.targetPlanning:
        return targetPlanning;
      case TutorialCategory.automatedImaging:
        return automatedImaging;
      case TutorialCategory.calibrationFrames:
        return calibrationFrames;
      case TutorialCategory.advancedFeatures:
        return advancedFeatures;
      // Screen-specific tours
      case TutorialCategory.dashboardTour:
        return dashboardTour;
      case TutorialCategory.equipmentTour:
        return equipmentTour;
      case TutorialCategory.imagingTour:
        return imagingTour;
      case TutorialCategory.guidingTour:
        return guidingTour;
      case TutorialCategory.sequencerTour:
        return sequencerTour;
      case TutorialCategory.planetariumTour:
        return planetariumTour;
      case TutorialCategory.framingTour:
        return framingTour;
      case TutorialCategory.analyticsTour:
        return analyticsTour;
      case TutorialCategory.flatWizardTour:
        return flatWizardTour;
      case TutorialCategory.weatherTour:
        return weatherTour;
      case TutorialCategory.settingsTour:
        return settingsTour;
      case TutorialCategory.polarAlignmentTour:
        return polarAlignmentTour;
    }
  }
}
