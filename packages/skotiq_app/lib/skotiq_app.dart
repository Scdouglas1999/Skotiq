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
export 'screens/settings/equipment_profiles_screen.dart';
export 'screens/shell/app_shell.dart';
export 'screens/shell/shell_chrome.dart' show ShellChrome;
export 'screens/shell/shell_exit_recorder.dart';
export 'screens/shell/widgets/window_chrome.dart'
    show WindowResizeEdges, WindowChromeState;

export 'widgets/animated_tab_bar_view.dart';
export 'widgets/startup_splash_gate.dart';
export 'widgets/sequence_progress_card.dart';
export 'widgets/mobile_sequence_overlay.dart';
export 'widgets/session_recovery_dialog.dart';
export 'widgets/database_recovery_launcher.dart';
export 'widgets/tutorial_overlay.dart';
export 'widgets/connection_stale_banner.dart';
export 'widgets/ios_background_banner.dart';
export 'widgets/android_notifications_banner.dart';
export 'widgets/remote_connection_indicator.dart';
export 'widgets/focus_model_curve_card.dart';

export 'screens/sequencer/widgets/mosaic_wizard_dialog.dart';
export 'screens/sequencer/widgets/flat_wizard_dialog.dart';
export 'screens/sequencer/widgets/trigger_configuration_dialog.dart';

export 'services/app_update.dart';
export 'services/location_sync_service.dart';
export 'screens/session_review/auto_integration_service.dart';
export 'services/plugin_node_dispatcher_wiring.dart';
export 'services/plugin_node_palette_wiring.dart';
export 'services/plugin_enablement_wiring.dart';
export 'services/plugin_runtime_bootstrap.dart';
