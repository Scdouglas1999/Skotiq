/// Skotiq App - Unified application package
library;

export 'app.dart';

export 'router/app_router.dart';
export 'router/page_transitions.dart';

export 'screens/analytics/analytics_screen.dart';
export 'screens/analytics/widgets/science_status_banner.dart';
export 'screens/analytics/widgets/science_session_summary.dart';
export 'screens/analytics/widgets/science_solve_rate_card.dart';
export 'screens/analytics/widgets/science_campaign_strip.dart';
export 'screens/analytics/widgets/image_grader_dialog.dart';
export 'screens/analytics/widgets/campaign_rollup_dialog.dart';
export 'screens/equipment/equipment_screen.dart';
export 'screens/framing/framing_screen.dart';
export 'screens/imaging/imaging_screen.dart';
export 'screens/night_control/night_control_screen.dart';
export 'screens/planetarium/planetarium_screen.dart';
export 'screens/sequencer/sequencer_screen.dart';
export 'screens/settings/settings_screen.dart';
export 'screens/settings/catalog_settings_screen.dart';
export 'screens/equipment/widgets/profiles_manager.dart';
export 'screens/shell/app_shell.dart';
export 'screens/shell/shell_chrome.dart' show ShellChrome;
export 'screens/shell/phone_bar_status.dart';
export 'screens/shell/shell_exit_recorder.dart';
export 'screens/shell/widgets/window_chrome.dart'
    show WindowResizeEdges, WindowChromeState;

export 'screens/shell/widgets/startup_splash_gate.dart';
export 'screens/shell/widgets/sequence_progress_card.dart';
export 'screens/shell/widgets/mobile_sequence_overlay.dart';
export 'startup/session_recovery_dialog.dart';
export 'startup/database_recovery_launcher.dart';
export 'tours/tour.dart';
export 'tours/tour_overlay.dart';
export 'tours/tour_runner.dart';
export 'screens/connection/connection_stale_banner.dart';
export 'screens/shell/widgets/ios_background_banner.dart';
export 'screens/shell/widgets/android_notifications_banner.dart';
export 'screens/connection/remote_connection_indicator.dart';
export 'screens/connection/rig_connect_entry.dart';
export 'screens/imaging/widgets/focus_model_curve_card.dart';

export 'screens/sequencer/widgets/mosaic_wizard_dialog.dart';
export 'screens/sequencer/widgets/flat_wizard_dialog.dart';
export 'screens/sequencer/widgets/trigger_configuration_dialog.dart';

export 'services/app_update.dart';
export 'startup/location_sync_service.dart';
export 'startup/plugin_node_dispatcher_wiring.dart';
export 'startup/plugin_node_palette_wiring.dart';
export 'startup/plugin_enablement_wiring.dart';
export 'startup/plugin_runtime_bootstrap.dart';
