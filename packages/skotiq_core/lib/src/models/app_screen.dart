/// Enum representing major screens in the app for notification filtering.
///
/// Used by `SmartNotificationService` to determine whether to show
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
