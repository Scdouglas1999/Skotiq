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
/// This is updated by [AppShell] whenever the user navigates to a new screen.
/// Used by [SmartNotificationService] to conditionally show notifications
/// only when the user is NOT viewing the relevant screen.
final currentScreenProvider = StateProvider<AppScreen>(
  (ref) => AppScreen.dashboard,
);

/// Maps a route location string to an [AppScreen] enum value.
AppScreen locationToAppScreen(String location) {
  // Handle both exact matches and nested routes
  if (location.startsWith('/dashboard')) return AppScreen.dashboard;
  if (location.startsWith('/equipment')) return AppScreen.equipment;
  if (location.startsWith('/imaging')) return AppScreen.imaging;
  if (location.startsWith('/guiding')) return AppScreen.guiding;
  if (location.startsWith('/sequencer')) return AppScreen.sequencer;
  if (location.startsWith('/planetarium')) return AppScreen.planetarium;
  if (location.startsWith('/framing')) return AppScreen.framing;
  if (location.startsWith('/analytics')) return AppScreen.analytics;
  // The Darkroom editor. Without this arm it reads as `unknown`, and the smart
  // notification filter would pop "your draft is ready" over the very screen
  // showing that draft.
  if (location.startsWith('/darkroom')) return AppScreen.darkroom;
  // Transients folds into Science → Observing Alerts (the standalone route
  // redirects to /science?tab=transients), so it highlights the Science host.
  if (location.startsWith('/science')) return AppScreen.science;
  if (location.startsWith('/flat-wizard')) return AppScreen.flatWizard;
  if (location.startsWith('/weather')) return AppScreen.weather;
  if (location.startsWith('/suggestions')) return AppScreen.suggestions;
  if (location.startsWith('/transients')) return AppScreen.transients;
  if (location.startsWith('/planner')) return AppScreen.planner;
  if (location.startsWith('/diagnostics')) return AppScreen.diagnostics;
  if (location.startsWith('/settings')) return AppScreen.settings;
  return AppScreen.unknown;
}
