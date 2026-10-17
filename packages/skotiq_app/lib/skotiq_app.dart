/// Skotiq App - Unified application package
library;

// Main App Widget
export 'app.dart';

// Router
export 'router/app_router.dart';
export 'router/page_transitions.dart';

// Screens
export 'screens/analytics/analytics_screen.dart';
export 'screens/analytics/widgets/science_status_banner.dart';
export 'screens/analytics/widgets/science_session_summary.dart';
export 'screens/analytics/widgets/science_solve_rate_card.dart';
export 'screens/analytics/widgets/science_campaign_strip.dart';
export 'screens/analytics/widgets/image_grader_dialog.dart';
export 'screens/analytics/widgets/campaign_rollup_dialog.dart';
export 'screens/dashboard/dashboard_screen.dart';
export 'screens/equipment/equipment_screen.dart';
export 'screens/framing/framing_screen.dart';
export 'screens/imaging/imaging_screen.dart';
export 'screens/planetarium/planetarium_screen.dart';
export 'screens/sequencer/sequencer_screen.dart';
export 'screens/settings/settings_screen.dart';
export 'screens/settings/catalog_settings_screen.dart';
export 'screens/settings/equipment_profiles_screen.dart';
export 'screens/shell/app_shell.dart';
export 'screens/shell/shell_exit_recorder.dart';

// Widgets
export 'widgets/adaptive_shell.dart';
export 'widgets/animated_tab_bar_view.dart';
export 'widgets/animated_tab_indicator.dart';
export 'widgets/catalog_setup_dialog.dart';
export 'widgets/staggered_animation.dart';
export 'widgets/annotation_painter.dart';
export 'widgets/sequence_progress_card.dart';
export 'widgets/mobile_sequence_overlay.dart';
export 'widgets/session_recovery_checker.dart';
export 'widgets/session_recovery_dialog.dart';
export 'widgets/auto_discovery_launcher.dart';
export 'widgets/database_recovery_launcher.dart';
export 'widgets/tutorial_overlay.dart';
export 'widgets/connection_stale_banner.dart';
export 'widgets/equipment_status_indicator.dart';
export 'widgets/ios_background_banner.dart';
export 'widgets/android_notifications_banner.dart';
export 'widgets/remote_connection_indicator.dart';
// Diagnostic cards — phone-friendly cards that the mobile
// companion dashboard surfaces alongside its existing device cards.
export 'widgets/guide_health_card.dart';
export 'widgets/focus_model_curve_card.dart';
export 'screens/sequencer/widgets/run_dashboard/weather_safety_card.dart';

// Sequencer Wizards (Priority 2)
export 'screens/sequencer/widgets/mosaic_wizard_dialog.dart';
export 'screens/sequencer/widgets/flat_wizard_dialog.dart';
export 'screens/sequencer/widgets/trigger_configuration_dialog.dart';

// Services
export 'services/location_sync_service.dart';
export 'screens/session_review/auto_integration_service.dart';
// Plugin-node dispatcher wiring. Exported so the app
// entry point can install the Riverpod override that backs the
// `pluginNodeDispatcherProvider` (defined in skotiq_core) with the
// real PluginNodeExecutor (defined in skotiq_plugins).
export 'services/plugin_node_dispatcher_wiring.dart';
// Plugin sequence-node palette wiring. The app entry point installs this
// override alongside the dispatcher override so the sequencer palette
// surfaces plugin-contributed nodes the moment a plugin registers.
export 'services/plugin_node_palette_wiring.dart';
// C4 — plugin enablement persistence wiring. The app entry point installs
// this override so the bundled-plugin registration honours the user's
// persisted enable/disable choices (a plugin disabled on the Integrations
// page stays disabled across launches instead of silently coming back on).
export 'services/plugin_enablement_wiring.dart';
// Hardware-owning entry points use this before accepting sequence work so
// plugin nodes do not depend on somebody first opening Integrations settings.
export 'services/plugin_runtime_bootstrap.dart';
