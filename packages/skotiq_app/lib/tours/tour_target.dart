import 'package:flutter/widgets.dart';

import '../router/app_routes.dart';
import '../screens/analytics/analytics_route.dart';
import '../screens/equipment/equipment_route.dart';
import '../screens/planner/planner_route.dart';
import '../screens/sequencer/sequencer_route.dart';
import '../screens/settings/settings_sections.dart';

/// Every control a guided tour can spotlight, named once.
///
/// A tour step points at a value here. The widget attaches [key]; [location]
/// says which screen shows it. A step can only name a target that exists, and
/// a target can only name a route or tab that exists, so a renamed route or a
/// mistyped target fails to compile instead of leaving a coach mark pointing
/// at nothing.
enum TourTarget {
  // The rail destinations, the phone bar's More button and the shell's
  // Settings button.
  navTonight,
  navImaging,
  navSequencer,
  navGuiding,
  navPlanner,
  navEquipment,
  navFlatWizard,
  navWeather,
  navDarkroom,
  navAnalytics,
  navSettings,
  navMore,

  // Plan
  planTabPlanetarium,
  planTabFraming,

  // Equipment > Devices
  equipmentDevicesTab,
  equipmentScanButton,
  equipmentProfileMenu,
  equipmentCameraCard,
  equipmentMountCard,

  // Equipment > Profiles
  equipmentProfileSelector,
  equipmentCreateProfileButton,
  equipmentQuickConnectBar,

  // Imaging
  imagingTabBar,
  imagingPreviewArea,
  imagingZoomControls,
  imagingExposureSlider,
  imagingGainControl,
  imagingFilterSelector,
  imagingSnapshotButton,
  imagingLoopButton,
  imagingAbortButton,
  imagingStatsPanel,
  imagingMountTab,
  imagingFocusTab,
  imagingHistogram,

  // Guiding
  guidingConnectButton,
  guidingStatusBar,
  guidingStarView,
  guidingTargetDisplay,
  guidingGraph,
  guidingRmsDisplay,
  guidingControls,
  guidingBrainButton,

  // Sequencer
  sequencerTabBuilder,
  sequencerTabTemplates,
  sequencerNodePalette,
  sequencerCanvas,
  sequencerTargetNode,
  sequencerCaptureNode,
  sequencerPropertiesPanel,
  sequencerToolbar,
  sequencerTransport,
  sequencerProgressBar,

  // Plan > Planetarium
  planetariumSkyView,
  planetariumSearch,
  planetariumLayersButton,
  planetariumFovToggle,
  planetariumSlewButton,
  planetariumObjectPopup,
  planetariumSendToFraming,
  planetariumAddToSequence,

  // Plan > Framing
  framingTargetSearch,
  framingCanvas,
  framingFovRect,
  framingRotation,
  framingCoordinates,
  framingAltitudeChart,
  framingMosaicButton,
  framingSlewButton,

  // Analytics
  analyticsSessionTab,
  analyticsHistoryTab,
  analyticsEquipmentTab,
  analyticsHfrChart,
  analyticsGuidingChart,
  analyticsThumbnails,

  // Flat wizard
  flatModeTabs,
  flatFilterSelect,
  flatTargetAdu,
  flatFrameCount,
  flatPreview,
  flatStartButton,

  // Weather
  weatherRadarMap,
  weatherTimeline,
  weatherStatusCard,
  weatherAlertRadius,
  weatherCloudMotion,
  weatherRefreshButton,

  // Settings sidebar
  settingsCategories,
  settingsConnection,
  settingsLocation,
  settingsAppearance,
  settingsFilePaths,
  settingsPlateSolving,
  settingsNotifications,
  settingsHelp,

  // Polar alignment
  polarHemisphere,
  polarExposure,
  polarStepSize,
  polarStartButton,
  polarImageView,
  polarErrorDisplay,
  polarAdjustment,
  polarProgress;

  /// The key the widget this target names is built with.
  GlobalKey get key => _keys[index];

  static final List<GlobalKey> _keys = [
    for (final target in values) GlobalKey(debugLabel: 'tour.${target.name}'),
  ];

  /// The rail target for [destination], or null when it is not on the rail.
  static TourTarget? forDestination(AppRoute destination) =>
      switch (destination) {
        AppRoute.tonight => navTonight,
        AppRoute.imaging => navImaging,
        AppRoute.sequencer => navSequencer,
        AppRoute.guiding => navGuiding,
        AppRoute.planner => navPlanner,
        AppRoute.equipment => navEquipment,
        AppRoute.flatWizard => navFlatWizard,
        AppRoute.weather => navWeather,
        AppRoute.darkroom => navDarkroom,
        AppRoute.analytics => navAnalytics,
        _ => null,
      };

  /// Whether this is a rail destination, which a phone may keep behind
  /// [navMore].
  bool get isRailDestination => switch (this) {
        navTonight ||
        navImaging ||
        navSequencer ||
        navGuiding ||
        navPlanner ||
        navEquipment ||
        navFlatWizard ||
        navWeather ||
        navDarkroom ||
        navAnalytics =>
          true,
        _ => false,
      };

  /// Where the target is on show, or null for the shell's own controls, which
  /// every screen carries.
  String? get location => switch (this) {
        navTonight ||
        navImaging ||
        navSequencer ||
        navGuiding ||
        navPlanner ||
        navEquipment ||
        navFlatWizard ||
        navWeather ||
        navDarkroom ||
        navAnalytics ||
        navSettings ||
        navMore =>
          null,
        planTabPlanetarium || planTabFraming => AppRoute.planner.path,
        equipmentDevicesTab ||
        equipmentScanButton ||
        equipmentProfileMenu ||
        equipmentCameraCard ||
        equipmentMountCard =>
          AppRoutes.equipment(tab: EquipmentTab.devices),
        equipmentProfileSelector ||
        equipmentCreateProfileButton ||
        equipmentQuickConnectBar =>
          AppRoutes.equipment(tab: EquipmentTab.profiles),
        imagingTabBar ||
        imagingPreviewArea ||
        imagingZoomControls ||
        imagingExposureSlider ||
        imagingGainControl ||
        imagingFilterSelector ||
        imagingSnapshotButton ||
        imagingLoopButton ||
        imagingAbortButton ||
        imagingStatsPanel ||
        imagingMountTab ||
        imagingFocusTab ||
        imagingHistogram =>
          AppRoute.imaging.path,
        guidingConnectButton ||
        guidingStatusBar ||
        guidingStarView ||
        guidingTargetDisplay ||
        guidingGraph ||
        guidingRmsDisplay ||
        guidingControls ||
        guidingBrainButton =>
          AppRoute.guiding.path,
        sequencerTabBuilder || sequencerTabTemplates => AppRoute.sequencer.path,
        sequencerNodePalette ||
        sequencerCanvas ||
        sequencerTargetNode ||
        sequencerCaptureNode ||
        sequencerPropertiesPanel ||
        sequencerToolbar ||
        sequencerTransport ||
        sequencerProgressBar =>
          AppRoutes.sequencer(tab: SequencerTab.builder),
        planetariumSkyView ||
        planetariumSearch ||
        planetariumLayersButton ||
        planetariumFovToggle ||
        planetariumSlewButton ||
        planetariumObjectPopup ||
        planetariumSendToFraming ||
        planetariumAddToSequence =>
          AppRoutes.planner(tab: PlannerTab.planetarium),
        framingTargetSearch ||
        framingCanvas ||
        framingFovRect ||
        framingRotation ||
        framingCoordinates ||
        framingAltitudeChart ||
        framingMosaicButton ||
        framingSlewButton =>
          AppRoutes.planner(tab: PlannerTab.framing),
        analyticsSessionTab ||
        analyticsHistoryTab ||
        analyticsEquipmentTab =>
          AppRoute.analytics.path,
        analyticsHfrChart ||
        analyticsGuidingChart ||
        analyticsThumbnails =>
          AppRoutes.analytics(tab: AnalyticsTab.session),
        flatModeTabs ||
        flatFilterSelect ||
        flatTargetAdu ||
        flatFrameCount ||
        flatPreview ||
        flatStartButton =>
          AppRoute.flatWizard.path,
        weatherRadarMap ||
        weatherTimeline ||
        weatherStatusCard ||
        weatherAlertRadius ||
        weatherCloudMotion ||
        weatherRefreshButton =>
          AppRoute.weather.path,
        settingsCategories => AppRoute.settings.path,
        settingsConnection => AppRoutes.settings(SettingsSectionId.connection),
        settingsLocation => AppRoutes.settings(SettingsSectionId.location),
        settingsAppearance => AppRoutes.settings(SettingsSectionId.appearance),
        settingsFilePaths => AppRoutes.settings(SettingsSectionId.filesStorage),
        settingsPlateSolving =>
          AppRoutes.settings(SettingsSectionId.plateSolving),
        settingsNotifications =>
          AppRoutes.settings(SettingsSectionId.notifications),
        settingsHelp => AppRoutes.settings(SettingsSectionId.help),
        polarHemisphere ||
        polarExposure ||
        polarStepSize ||
        polarStartButton ||
        polarImageView ||
        polarErrorDisplay ||
        polarAdjustment ||
        polarProgress =>
          AppRoute.polarAlignment.path,
      };
}
