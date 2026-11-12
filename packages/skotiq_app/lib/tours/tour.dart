/// Every guided tour the app offers, as data.
library;

import 'package:flutter/widgets.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../router/app_routes.dart';
import 'tour_target.dart';

export 'tour_target.dart';

part 'definitions/first_night.dart';
part 'definitions/screen_tours.dart';
part 'definitions/workflow_tours.dart';

/// Which side of its target a step's card sits on when there is room.
enum TourCardSide { top, bottom, left, right }

/// One card of a tour.
@immutable
class TourStep {
  const TourStep({
    required this.id,
    required this.title,
    required this.description,
    this.target,
    this.side = TourCardSide.bottom,
    this.icon,
    this.showMe,
  });

  /// Unique across all tours.
  final String id;

  final String title;

  final String description;

  /// What the step spotlights; null for a card that stands on its own.
  final TourTarget? target;

  final TourCardSide side;

  /// A walkthrough card's icon.
  final IconData? icon;

  /// The screen a walkthrough card offers to open.
  final AppRoute? showMe;
}

/// How a tour is drawn.
enum TourStyle {
  /// A spotlight on each step's target with a small card beside it.
  coachMarks,

  /// A dialog of long-form cards, each able to open the screen it is about.
  walkthrough,
}

/// A guided tour.
enum Tour {
  firstNight(
    'firstNight',
    title: 'First night walkthrough',
    style: TourStyle.walkthrough,
    steps: _firstNight,
  ),
  firstLaunch(
    'firstLaunchTour',
    title: 'Onboarding tour',
    steps: _firstLaunchTour,
  ),

  equipmentSetup(
    'equipmentSetup',
    title: 'Equipment setup',
    icon: LucideIcons.boxes,
    steps: _equipmentSetup,
  ),
  targetPlanning(
    'targetPlanning',
    title: 'Target planning',
    icon: LucideIcons.compass,
    steps: _targetPlanning,
  ),
  automatedImaging(
    'automatedImaging',
    title: 'Automated imaging',
    icon: LucideIcons.listOrdered,
    steps: _automatedImaging,
  ),
  calibrationFrames(
    'calibrationFrames',
    title: 'Calibration frames',
    icon: LucideIcons.sun,
    steps: _calibrationFrames,
  ),
  advancedFeatures(
    'advancedFeatures',
    title: 'Advanced features',
    icon: LucideIcons.barChart3,
    steps: _advancedFeatures,
  ),

  tonight(
    'dashboardTour',
    title: 'Tonight',
    screen: AppRoute.tonight,
    steps: _dashboardTour,
  ),
  equipment(
    'equipmentTour',
    title: 'Equipment',
    screen: AppRoute.equipment,
    steps: _equipmentTour,
  ),
  imaging(
    'imagingTour',
    title: 'Imaging',
    screen: AppRoute.imaging,
    steps: _imagingTour,
  ),
  guiding(
    'guidingTour',
    title: 'Guiding',
    screen: AppRoute.guiding,
    steps: _guidingTour,
  ),
  sequencer(
    'sequencerTour',
    title: 'Sequencer',
    screen: AppRoute.sequencer,
    steps: _sequencerTour,
  ),
  planetarium(
    'planetariumTour',
    title: 'Planetarium',
    screen: AppRoute.planner,
    steps: _planetariumTour,
  ),
  framing(
    'framingTour',
    title: 'Framing',
    screen: AppRoute.planner,
    steps: _framingTour,
  ),
  analytics(
    'analyticsTour',
    title: 'Analytics',
    screen: AppRoute.analytics,
    steps: _analyticsTour,
  ),
  flatWizard(
    'flatWizardTour',
    title: 'Flat wizard',
    screen: AppRoute.flatWizard,
    steps: _flatWizardTour,
  ),
  weather(
    'weatherTour',
    title: 'Weather',
    screen: AppRoute.weather,
    steps: _weatherTour,
  ),
  settings(
    'settingsTour',
    title: 'Settings',
    screen: AppRoute.settings,
    steps: _settingsTour,
  ),
  polarAlignment(
    'polarAlignmentTour',
    title: 'Polar alignment',
    screen: AppRoute.polarAlignment,
    steps: _polarAlignmentTour,
  );

  const Tour(
    this.id, {
    required this.title,
    required this.steps,
    this.icon,
    this.style = TourStyle.coachMarks,
    this.screen,
  });

  /// The `tutorial_progress` category this tour's progress is stored under.
  /// Never changes: a renamed id would orphan what users have already done.
  final String id;

  final String title;

  /// The icon of a tour listed in Settings > Help.
  final IconData? icon;

  final TourStyle style;

  /// The screen this tour is about; the help menu offers it there. Null for a
  /// tour that walks across screens.
  final AppRoute? screen;

  final List<TourStep> steps;

  /// The tours that teach a task across screens, listed in Settings > Help.
  static const List<Tour> workflows = [
    equipmentSetup,
    targetPlanning,
    automatedImaging,
    calibrationFrames,
    advancedFeatures,
  ];

  /// The tours about the screen [route] shows. Two for Plan, whose
  /// Planetarium and Framing tabs each have one.
  static List<Tour> forScreen(AppRoute route) => [
        for (final tour in values)
          if (tour.screen == route) tour,
      ];

  /// Where step [index] is shown, or null to stay put. A step with a target
  /// is shown where the target is; a card that stands on its own stays with
  /// the targeted step before it, or the one after, or on this tour's screen.
  String? locationOfStep(int index) {
    final own = steps[index].target;
    if (own != null) return own.location;
    for (final step in steps.take(index).toList().reversed) {
      if (step.target != null) return step.target!.location;
    }
    for (final step in steps.skip(index + 1)) {
      if (step.target != null) return step.target!.location;
    }
    return screen?.path;
  }
}
