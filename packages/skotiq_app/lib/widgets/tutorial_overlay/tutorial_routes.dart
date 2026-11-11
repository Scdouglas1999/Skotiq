import 'package:skotiq_core/skotiq_core.dart';

import '../../router/app_routes.dart';

/// Where each tour lives.
///
/// A tour is a set of instructions about one screen ("Click the Profiles tab",
/// "Check the status indicators for each device"). Starting one from Settings >
/// Help left the coach mark on the Settings screen, naming controls that only
/// exist elsewhere. The overlay routes here before showing a step.
///
/// `firstNight` is absent on purpose: it is the modal first-night wizard, not
/// an anchored tour, and it must not yank the operator off their screen.
const Map<TutorialCategory, AppRoute> _tourHomeRoutes = {
  TutorialCategory.firstLight: AppRoute.equipment,
  TutorialCategory.equipmentSetup: AppRoute.equipment,
  TutorialCategory.targetPlanning: AppRoute.planetarium,
  TutorialCategory.automatedImaging: AppRoute.sequencer,
  TutorialCategory.calibrationFrames: AppRoute.flatWizard,
  TutorialCategory.advancedFeatures: AppRoute.analytics,
  TutorialCategory.dashboardTour: AppRoute.tonight,
  TutorialCategory.equipmentTour: AppRoute.equipment,
  TutorialCategory.imagingTour: AppRoute.imaging,
  TutorialCategory.guidingTour: AppRoute.guiding,
  TutorialCategory.sequencerTour: AppRoute.sequencer,
  TutorialCategory.planetariumTour: AppRoute.planetarium,
  TutorialCategory.framingTour: AppRoute.framing,
  TutorialCategory.analyticsTour: AppRoute.analytics,
  TutorialCategory.flatWizardTour: AppRoute.flatWizard,
  TutorialCategory.weatherTour: AppRoute.weather,
  TutorialCategory.settingsTour: AppRoute.settings,
  TutorialCategory.polarAlignmentTour: AppRoute.polarAlignment,
};

/// Steps that describe a different screen than their tour's home — the
/// workflow tours deliberately walk across screens.
const Map<String, AppRoute> _stepRoutes = {
  'fl_take_snapshot': AppRoute.imaging,
  'fl_success': AppRoute.imaging,
  'tp_framing': AppRoute.framing,
  'af_weather': AppRoute.weather,
  'af_history': AppRoute.analytics,
  'af_settings': AppRoute.settings,
};

/// The route the overlay should be showing [step] on, or null to stay put.
String? tutorialRouteForStep(TutorialStep step) =>
    (_stepRoutes[step.id] ?? _tourHomeRoutes[step.category])?.path;
