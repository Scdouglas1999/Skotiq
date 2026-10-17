import 'package:skotiq_core/skotiq_core.dart';

/// Where each tour lives.
///
/// A tour is a set of instructions about one screen ("Click the Profiles tab",
/// "Check the status indicators for each device"). Starting one from Settings >
/// Help left the coach mark on the Settings screen, naming controls that only
/// exist elsewhere. The overlay routes here before showing a step.
///
/// `firstNight` is absent on purpose: it is the modal first-night wizard, not
/// an anchored tour, and it must not yank the operator off their screen.
const Map<TutorialCategory, String> _tourHomeRoutes = {
  TutorialCategory.firstLight: '/equipment',
  TutorialCategory.equipmentSetup: '/equipment',
  TutorialCategory.targetPlanning: '/planetarium',
  TutorialCategory.automatedImaging: '/sequencer',
  TutorialCategory.calibrationFrames: '/flat-wizard',
  TutorialCategory.advancedFeatures: '/analytics',
  TutorialCategory.dashboardTour: '/dashboard',
  TutorialCategory.equipmentTour: '/equipment',
  TutorialCategory.imagingTour: '/imaging',
  TutorialCategory.guidingTour: '/guiding',
  TutorialCategory.sequencerTour: '/sequencer',
  TutorialCategory.planetariumTour: '/planetarium',
  TutorialCategory.framingTour: '/framing',
  TutorialCategory.analyticsTour: '/analytics',
  TutorialCategory.flatWizardTour: '/flat-wizard',
  TutorialCategory.weatherTour: '/weather',
  TutorialCategory.settingsTour: '/settings',
  TutorialCategory.polarAlignmentTour: '/polar-alignment',
};

/// Steps that describe a different screen than their tour's home — the
/// workflow tours deliberately walk across screens.
const Map<String, String> _stepRoutes = {
  'fl_take_snapshot': '/imaging',
  'fl_success': '/imaging',
  'tp_framing': '/framing',
  'af_weather': '/weather',
  'af_history': '/analytics',
  'af_settings': '/settings',
};

/// The route the overlay should be showing [step] on, or null to stay put.
String? tutorialRouteForStep(TutorialStep step) =>
    _stepRoutes[step.id] ?? _tourHomeRoutes[step.category];
