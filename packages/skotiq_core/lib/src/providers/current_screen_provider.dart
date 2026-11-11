import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Enum representing major screens in the app for notification filtering.
///
/// Used by [SmartNotificationService] to determine whether to show
/// notifications based on the user's current screen location.
enum AppScreen {
  dashboard,
  equipment,
  imaging,
  guiding,
  sequencer,
  planetarium,
  framing,
  analytics,
  darkroom,
  science,
  flatWizard,
  weather,
  suggestions,
  transients,
  planner,
  diagnostics,
  settings,
  unknown,
}

/// Provider tracking the currently visible screen.
///
/// The app shell sets it from the route table whenever the operator moves to
/// another screen. [SmartNotificationService] reads it to show a notification
/// only when the operator is not already looking at the screen it is about.
final currentScreenProvider = StateProvider<AppScreen>(
  (ref) => AppScreen.dashboard,
);
