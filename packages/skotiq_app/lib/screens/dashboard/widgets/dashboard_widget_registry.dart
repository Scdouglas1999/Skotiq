import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/tutorial_keys/dashboard_keys.dart';
import '../../../widgets/weather/dashboard_weather_widget.dart';
import '../dashboard_layout.dart';
import 'live_preview_card.dart';
import 'capture_settings_card.dart';
import 'session_progress_card.dart';
import 'guiding_card.dart';
import 'equipment_status_card.dart';
import 'quick_actions_card.dart';
import 'mount_control_card.dart';
import 'focus_card.dart';
import 'alerts_card.dart';
import 'quick_stats_card.dart';
import 'tonight_card.dart';
import 'storage_card.dart';
import '../../sequencer/widgets/run_dashboard/target_header_panel.dart';
import '../../sequencer/widgets/run_dashboard/live_frame_panel.dart';
import '../../sequencer/widgets/run_dashboard/exposure_progress_panel.dart';
import '../../sequencer/widgets/run_dashboard/filter_integration_panel.dart';
import '../../sequencer/widgets/run_dashboard/equipment_telemetry_panel.dart';
import '../../sequencer/widgets/run_dashboard/guiding_panel_card.dart';
import '../../sequencer/widgets/run_dashboard/weather_safety_card.dart';
import '../../sequencer/widgets/run_dashboard/session_warnings_panel.dart';
import '../../sequencer/widgets/run_dashboard/trigger_feed_panel.dart';
import '../../sequencer/widgets/run_dashboard/scheduler_panel.dart';
import '../../sequencer/widgets/run_dashboard/cloud_motion_panel.dart';
import '../../sequencer/widgets/run_dashboard/adaptive_conditions_panel.dart';
import '../../sequencer/widgets/run_dashboard/light_curve_panel.dart';
import '../../sequencer/widgets/run_dashboard/observatory_panel.dart';
import '../../sequencer/widgets/run_dashboard/quality_panel.dart';
import '../../sequencer/widgets/run_dashboard/forensics_panel.dart';
import '../../sequencer/widgets/secondary_rig_card.dart';
import 'cockpit_recent_frames.dart';
import 'cockpit_now_imaging.dart';
import 'tonight/tonight_equipment_panel.dart';
import 'tonight/tonight_guiding_panel.dart';
import 'tonight/tonight_preview_panel.dart';
import 'tonight/tonight_progress_panel.dart';
import 'tonight/tonight_safety_panel.dart';
import 'cockpit_frames.dart';
import 'cockpit_session_vitals.dart';
import 'cockpit_sky_context.dart';
import 'cockpit_narrator.dart';
import 'cockpit_morning_report.dart';

typedef DashboardWidgetBuilder = Widget Function(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
);

/// Which family a dashboard tile belongs to.
///
/// The registry holds two generations of tiles that overlap in subject matter
/// (guiding, weather, equipment). Presented as one flat list the picker offered
/// two rows with the same name and no way to tell them apart, so the family is
/// part of the definition and the picker renders it as a section.
enum DashboardWidgetGroup {
  /// Transplanted run-dashboard panels: live during a sequence run, and the
  /// default dashboard.
  liveRun,

  /// The pre-cockpit control/info cards. Off by default, kept for operators who
  /// prefer them.
  classic;

  String get label => switch (this) {
        DashboardWidgetGroup.liveRun => 'Live run panels',
        DashboardWidgetGroup.classic => 'Classic cards',
      };

  String get description => switch (this) {
        DashboardWidgetGroup.liveRun =>
          'The default cockpit. Each panel reads the active run and stays quiet '
              'when nothing is running.',
        DashboardWidgetGroup.classic =>
          'The original dashboard cards. They overlap the panels above — enable '
              'them only if you prefer the older layout.',
      };
}

/// Widget definition with zone-aware metadata for the command center layout.
class DashboardWidgetDefinition {
  final DashboardWidgetId id;
  final String title;
  final String subtitle;
  final IconData icon;
  final DashboardZone defaultZone;
  final DashboardWidgetBuilder builder;

  /// Which family this tile belongs to. Defaults to the cockpit generation;
  /// the pre-cockpit cards mark themselves [DashboardWidgetGroup.classic].
  final DashboardWidgetGroup group;

  /// When true, the panel renders its own chrome (SkotiqCard / banner) and
  /// the dashboard tile frame must NOT draw a resting border/background — only
  /// the editing / drop-target / hero highlight border and the edit-mode
  /// affordances. Avoids double borders on the transplanted cockpit panels.
  final bool selfChromed;

  const DashboardWidgetDefinition({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.defaultZone,
    required this.builder,
    this.selfChromed = false,
    this.group = DashboardWidgetGroup.liveRun,
  });
}

const dashboardWidgetRegistry = <DashboardWidgetDefinition>[
  // The Observatory Tonight grid (06 §Tonight). Self-chromed: each one is a
  // SkotiqPanel, so the tile frame must not draw a second container round
  // it.
  DashboardWidgetDefinition(
    id: DashboardWidgetId.tonightPreview,
    title: 'Live preview',
    subtitle: 'The newest sub with its quality readouts and a thumbnail strip',
    icon: LucideIcons.image,
    defaultZone: DashboardZone.primary,
    selfChromed: true,
    builder: _buildTonightPreview,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.tonightEquipment,
    title: 'Equipment',
    subtitle: 'One row per device with its live readouts',
    icon: LucideIcons.plug,
    defaultZone: DashboardZone.primary,
    selfChromed: true,
    builder: _buildTonightEquipment,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.tonightGuiding,
    title: 'Guiding',
    subtitle: 'RA/Dec trace with RMS and guide-star SNR',
    icon: LucideIcons.crosshair,
    defaultZone: DashboardZone.primary,
    selfChromed: true,
    builder: _buildTonightGuiding,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.tonightProgress,
    title: 'Progress',
    subtitle: 'Run percentage, per-filter integration and what is left',
    icon: LucideIcons.activity,
    defaultZone: DashboardZone.primary,
    selfChromed: true,
    builder: _buildTonightProgress,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.tonightSafety,
    title: 'Safety & events',
    subtitle: 'Conditions against your limits, and the latest run events',
    icon: LucideIcons.shieldCheck,
    defaultZone: DashboardZone.primary,
    selfChromed: true,
    builder: _buildTonightSafety,
  ),

  // Merged cockpit tiles (density pass). self-chromed like the rest.
  DashboardWidgetDefinition(
    id: DashboardWidgetId.cockpitNowImaging,
    title: 'Now imaging',
    subtitle: 'Active target, altitude, and run progress in one strip',
    icon: LucideIcons.target,
    defaultZone: DashboardZone.primary,
    selfChromed: true,
    builder: _buildCockpitNowImaging,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.cockpitFrames,
    title: 'Frames',
    subtitle: 'Current sub-exposure with recent-capture strip',
    icon: LucideIcons.image,
    defaultZone: DashboardZone.primary,
    selfChromed: true,
    builder: _buildCockpitFrames,
  ),

  // Cockpit panels (transplanted Run dashboard). All are self-chromed: each
  // wraps itself in a SkotiqCard / banner, so the tile frame draws no
  // resting border. They read their own providers and degrade gracefully idle.
  DashboardWidgetDefinition(
    id: DashboardWidgetId.cockpitTargetHeader,
    title: 'Target',
    subtitle: 'Active target, progress, and night-at-a-glance banner',
    icon: LucideIcons.target,
    defaultZone: DashboardZone.primary,
    selfChromed: true,
    builder: _buildCockpitTargetHeader,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.cockpitLiveFrame,
    title: 'Live frame',
    subtitle: 'Most recent sub-exposure with quality readout',
    icon: LucideIcons.image,
    defaultZone: DashboardZone.primary,
    selfChromed: true,
    builder: _buildCockpitLiveFrame,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.cockpitExposureProgress,
    title: 'Exposure progress',
    subtitle: 'Current exposure, dither, and download timing',
    icon: LucideIcons.timer,
    defaultZone: DashboardZone.primary,
    selfChromed: true,
    builder: _buildCockpitExposureProgress,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.cockpitRecentFrames,
    title: 'Recent frames',
    subtitle: 'Newest captures with filter, exposure, and time',
    icon: LucideIcons.galleryThumbnails,
    defaultZone: DashboardZone.primary,
    selfChromed: true,
    builder: _buildCockpitRecentFrames,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.cockpitFilterIntegration,
    title: 'Filter integration',
    subtitle: 'Accumulated integration time per filter',
    icon: LucideIcons.layers,
    defaultZone: DashboardZone.secondary,
    selfChromed: true,
    builder: _buildCockpitFilterIntegration,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.cockpitEquipmentTelemetry,
    title: 'Equipment telemetry',
    subtitle: 'Live device readouts (temp, position, status)',
    icon: LucideIcons.plug,
    defaultZone: DashboardZone.secondary,
    selfChromed: true,
    builder: _buildCockpitEquipmentTelemetry,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.cockpitGuiding,
    // Disambiguated from Tonight's own Guiding panel: the widget picker refuses
    // two tiles with one name, and a user choosing between them has to be able
    // to tell which is which.
    title: 'Guiding (run panel)',
    subtitle: 'RMS error and guiding graph',
    icon: LucideIcons.crosshair,
    defaultZone: DashboardZone.secondary,
    selfChromed: true,
    builder: _buildCockpitGuiding,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.cockpitWeatherSafety,
    title: 'Weather & Safety',
    subtitle: 'Sky conditions and safety monitor status',
    icon: LucideIcons.cloud,
    defaultZone: DashboardZone.secondary,
    selfChromed: true,
    builder: _buildCockpitWeatherSafety,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.cockpitSessionWarnings,
    title: 'Session warnings',
    subtitle: 'Active warnings and degraded-condition notices',
    icon: LucideIcons.alertTriangle,
    defaultZone: DashboardZone.secondary,
    selfChromed: true,
    builder: _buildCockpitSessionWarnings,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.cockpitTriggerFeed,
    title: 'Trigger feed',
    subtitle: 'Recent automation trigger activity',
    icon: LucideIcons.zap,
    defaultZone: DashboardZone.secondary,
    selfChromed: true,
    builder: _buildCockpitTriggerFeed,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.cockpitScheduler,
    title: 'Unattended autopilot',
    subtitle: 'Runs unattended and re-picks targets all night — distinct from '
        'Plan tonight',
    icon: LucideIcons.calendarClock,
    defaultZone: DashboardZone.secondary,
    selfChromed: true,
    builder: _buildCockpitScheduler,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.cockpitCloudMotion,
    title: 'Cloud motion',
    subtitle: 'Radar-derived cloud movement and trend',
    icon: LucideIcons.wind,
    defaultZone: DashboardZone.secondary,
    selfChromed: true,
    builder: _buildCockpitCloudMotion,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.cockpitAdaptiveConditions,
    title: 'Adaptive conditions',
    subtitle: 'Adaptive exposure/condition responses',
    icon: LucideIcons.slidersHorizontal,
    defaultZone: DashboardZone.secondary,
    selfChromed: true,
    builder: _buildCockpitAdaptiveConditions,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.cockpitLightCurve,
    title: 'Light curve',
    subtitle: 'Photometric light curve for the active target',
    icon: LucideIcons.activity,
    defaultZone: DashboardZone.secondary,
    selfChromed: true,
    builder: _buildCockpitLightCurve,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.cockpitObservatory,
    title: 'Observatory',
    subtitle: 'Dome shutter/azimuth, flat cover, and power switches',
    icon: LucideIcons.warehouse,
    defaultZone: DashboardZone.secondary,
    selfChromed: true,
    builder: _buildCockpitObservatory,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.cockpitSecondaryRig,
    title: 'Secondary rig',
    subtitle: 'Piggyback camera loop with dither-coordinated capture',
    icon: LucideIcons.camera,
    defaultZone: DashboardZone.secondary,
    selfChromed: true,
    builder: _buildCockpitSecondaryRig,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.cockpitQuality,
    title: 'Quality',
    subtitle: 'Frame accept/reject rate, HFR trend, and adaptive exposure',
    icon: LucideIcons.gauge,
    defaultZone: DashboardZone.secondary,
    selfChromed: true,
    builder: _buildCockpitQuality,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.cockpitSessionVitals,
    title: 'Session vitals',
    subtitle: 'Integration efficiency and live run counters',
    icon: LucideIcons.activity,
    defaultZone: DashboardZone.secondary,
    selfChromed: true,
    builder: _buildCockpitSessionVitals,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.cockpitSkyContext,
    title: 'Sky context',
    subtitle: 'Altitude, airmass, moon, and darkness window',
    icon: LucideIcons.orbit,
    defaultZone: DashboardZone.secondary,
    selfChromed: true,
    builder: _buildCockpitSkyContext,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.cockpitForensics,
    title: 'Frame forensics',
    subtitle: 'Recent rejections grouped by likely cause',
    icon: LucideIcons.search,
    defaultZone: DashboardZone.secondary,
    selfChromed: true,
    builder: _buildCockpitForensics,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.cockpitNarrator,
    title: 'Night narrator',
    subtitle: "Live interpretation of your session's science data",
    icon: LucideIcons.sparkles,
    defaultZone: DashboardZone.secondary,
    selfChromed: true,
    builder: _buildCockpitNarrator,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.cockpitMorningReport,
    title: 'Morning report',
    subtitle: "Last night's accepted/rejected counts — tap to review",
    icon: LucideIcons.sunrise,
    defaultZone: DashboardZone.secondary,
    selfChromed: true,
    builder: _buildCockpitMorningReport,
  ),

  // Legacy control/info cards (disabled by default; retained for power users).
  // Primary zone widgets (hero content)
  DashboardWidgetDefinition(
    id: DashboardWidgetId.livePreview,
    // "(classic)" the way Guiding, Equipment and Weather already distinguish
    // their legacy cards. Before the sentence-case sweep this tile and the
    // Observatory "Live preview" differed ONLY by capital P, which told two
    // rows apart by a letterform nobody reads — the sweep turned a weak
    // distinction into no distinction, so it gets a real one.
    title: 'Live preview (classic)',
    subtitle: 'Current image, capture status, and image stats',
    icon: LucideIcons.image,
    defaultZone: DashboardZone.primary,
    group: DashboardWidgetGroup.classic,
    builder: _buildLivePreview,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.captureSettings,
    title: 'Capture settings',
    subtitle: 'Exposure, gain, filter, and capture controls',
    icon: LucideIcons.camera,
    defaultZone: DashboardZone.primary,
    group: DashboardWidgetGroup.classic,
    builder: _buildCaptureSettings,
  ),

  // Secondary zone widgets (supporting info and controls)
  DashboardWidgetDefinition(
    id: DashboardWidgetId.sequenceStatus,
    title: 'Sequence status',
    subtitle: 'Active sequence progress and timing',
    icon: LucideIcons.listOrdered,
    defaultZone: DashboardZone.secondary,
    group: DashboardWidgetGroup.classic,
    builder: _buildSequenceStatus,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.guiding,
    // Named apart from the cockpit 'Guiding' panel on purpose: the picker used
    // to list two rows both called "Guiding" with near-identical subtitles.
    title: 'Guiding (classic)',
    subtitle: 'Compact RMS readout and guide graph — the pre-cockpit card',
    icon: LucideIcons.crosshair,
    defaultZone: DashboardZone.secondary,
    group: DashboardWidgetGroup.classic,
    builder: _buildGuiding,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.equipmentStatus,
    title: 'Equipment (classic)',
    subtitle: 'Connect/disconnect list — not the live telemetry panel',
    icon: LucideIcons.plug,
    defaultZone: DashboardZone.secondary,
    group: DashboardWidgetGroup.classic,
    builder: _buildEquipmentStatus,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.quickActions,
    title: 'Quick actions',
    subtitle: 'Snapshot, autofocus, centering, and parking',
    icon: LucideIcons.zap,
    defaultZone: DashboardZone.secondary,
    group: DashboardWidgetGroup.classic,
    builder: _buildQuickActions,
  ),

  // Tertiary zone widgets (compact status cards)
  DashboardWidgetDefinition(
    id: DashboardWidgetId.mountControl,
    title: 'Mount control',
    subtitle: 'Mount connection and control actions',
    icon: LucideIcons.move3d,
    defaultZone: DashboardZone.tertiary,
    group: DashboardWidgetGroup.classic,
    builder: _buildMountControl,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.focus,
    title: 'Focus',
    subtitle: 'Focuser stats and autofocus controls',
    icon: LucideIcons.focus,
    defaultZone: DashboardZone.tertiary,
    group: DashboardWidgetGroup.classic,
    builder: _buildFocus,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.weather,
    title: 'Weather (classic)',
    subtitle: 'Cloud status card — not the run Weather & Safety panel',
    icon: LucideIcons.cloud,
    defaultZone: DashboardZone.tertiary,
    group: DashboardWidgetGroup.classic,
    builder: _buildWeather,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.tonight,
    title: 'Tonight',
    subtitle: 'Twilight, moon, and imaging window',
    icon: LucideIcons.moon,
    defaultZone: DashboardZone.tertiary,
    group: DashboardWidgetGroup.classic,
    builder: _buildTonight,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.alerts,
    title: 'Alerts',
    subtitle: 'Active operations and recent notifications',
    icon: LucideIcons.bell,
    defaultZone: DashboardZone.tertiary,
    group: DashboardWidgetGroup.classic,
    builder: _buildAlerts,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.quickStats,
    title: 'Quick stats',
    subtitle: 'Sensor temp, focus, HFR, and RMS',
    icon: LucideIcons.activity,
    defaultZone: DashboardZone.tertiary,
    group: DashboardWidgetGroup.classic,
    builder: _buildQuickStats,
  ),
  DashboardWidgetDefinition(
    id: DashboardWidgetId.storage,
    title: 'Storage',
    subtitle: 'Free space and projected sequence size',
    icon: LucideIcons.hardDrive,
    defaultZone: DashboardZone.tertiary,
    group: DashboardWidgetGroup.classic,
    builder: _buildStorage,
  ),
];

// Cockpit panel builders. These panels read their own Riverpod providers, so
// the colors/pulseController arguments are intentionally unused.
Widget _buildTonightPreview(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const TonightPreviewPanel();
}

Widget _buildTonightEquipment(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const TonightEquipmentPanel();
}

Widget _buildTonightGuiding(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const TonightGuidingPanel();
}

Widget _buildTonightProgress(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const TonightProgressPanel();
}

Widget _buildTonightSafety(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const TonightSafetyPanel();
}

Widget _buildCockpitNowImaging(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const CockpitNowImaging();
}

Widget _buildCockpitFrames(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const CockpitFrames();
}

Widget _buildCockpitTargetHeader(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const RunDashboardTargetHeader();
}

Widget _buildCockpitLiveFrame(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const RunDashboardLiveFrame();
}

Widget _buildCockpitExposureProgress(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const RunDashboardExposureProgress();
}

Widget _buildCockpitRecentFrames(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const CockpitRecentFrames();
}

Widget _buildCockpitFilterIntegration(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const RunDashboardFilterIntegration();
}

Widget _buildCockpitEquipmentTelemetry(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const RunDashboardEquipmentPanel();
}

Widget _buildCockpitGuiding(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const RunDashboardGuidingCard();
}

Widget _buildCockpitWeatherSafety(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const RunDashboardWeatherSafetyCard();
}

Widget _buildCockpitSessionWarnings(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const RunDashboardSessionWarningsPanel();
}

Widget _buildCockpitTriggerFeed(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const RunDashboardTriggerFeed();
}

Widget _buildCockpitScheduler(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const RunDashboardSchedulerPanel();
}

Widget _buildCockpitCloudMotion(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const RunDashboardCloudMotionPanel();
}

Widget _buildCockpitAdaptiveConditions(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const RunDashboardAdaptiveConditionsPanel();
}

Widget _buildCockpitLightCurve(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const LightCurvePanel();
}

Widget _buildCockpitObservatory(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const RunDashboardObservatoryPanel();
}

Widget _buildCockpitSecondaryRig(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const SecondaryRigCard();
}

Widget _buildCockpitQuality(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const RunDashboardQualityPanel();
}

Widget _buildCockpitSessionVitals(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const CockpitSessionVitals();
}

Widget _buildCockpitSkyContext(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const CockpitSkyContext();
}

// The forensics panel takes a session id (String) so it can backfill and
// filter live rejections for the active run. Resolve it from the live session
// state — `dbSessionId` is an int, so stringify it; the panel treats a null id
// as "live events only" and hides itself (empty state) when no rejections
// exist, so an idle dashboard stays clean.
Widget _buildCockpitForensics(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return Consumer(
    builder: (context, ref, _) {
      final dbSessionId = ref.watch(
        sessionStateProvider.select((s) => s.dbSessionId),
      );
      return RunDashboardForensicsPanel(
        sessionId: dbSessionId?.toString(),
      );
    },
  );
}

Widget _buildCockpitNarrator(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const CockpitNarrator();
}

Widget _buildCockpitMorningReport(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return const CockpitMorningReport();
}

Widget _buildLivePreview(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return LivePreviewCard(
    key: DashboardTutorialKeys.livePreview,
    colors: colors,
    pulseController: pulseController,
  );
}

Widget _buildCaptureSettings(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return CaptureSettingsCard(
      key: DashboardTutorialKeys.captureControls, colors: colors);
}

Widget _buildSequenceStatus(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return SessionProgressCard(
      key: DashboardTutorialKeys.sessionWidget, colors: colors);
}

Widget _buildGuiding(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return GuidingCard(key: DashboardTutorialKeys.guidingWidget, colors: colors);
}

Widget _buildMountControl(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return MountControlCard(
      key: DashboardTutorialKeys.mountWidget, colors: colors);
}

Widget _buildEquipmentStatus(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return EquipmentStatusCard(
      key: DashboardTutorialKeys.equipmentStatus, colors: colors);
}

Widget _buildWeather(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return DashboardWeatherWidget(key: DashboardTutorialKeys.weatherWidget);
}

Widget _buildFocus(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return FocusCard(key: DashboardTutorialKeys.focuserWidget, colors: colors);
}

Widget _buildAlerts(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return AlertsCard(colors: colors);
}

Widget _buildQuickActions(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return QuickActionsCard(colors: colors);
}

Widget _buildQuickStats(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return QuickStatsCard(colors: colors);
}

Widget _buildTonight(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return TonightCard(colors: colors);
}

Widget _buildStorage(
  BuildContext context,
  SkotiqColors colors,
  AnimationController pulseController,
) {
  return StorageCard(colors: colors);
}
