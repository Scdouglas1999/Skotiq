/// Settings a feature keeps in the `app_settings` key/value store for itself,
/// declared once: the row, the value when nothing is stored, and which machine
/// holds it when this app is linked to a host.
///
/// These are not fields of `AppSettingsState` and do not travel in the host's
/// typed settings. A linked client reaches a [SettingSync.hostStore] row
/// through the host's key/value store, and keeps a [SettingSync.thisComputer]
/// row in its own database. A row that is declared nowhere is the host's.
///
/// A setting held as a JSON document is declared as text: no row, or an empty
/// one, means "nothing saved", and the feature decodes the document itself.
library;

import '../models/notification/notification_categories.dart'
    show NotificationTransportKind;
import '../models/sequence/sequence_models.dart'
    show BinningMode, LiveStackingThumbnailSize;
import '../services/sync/sync_service.dart' show SyncSettingsKeys;
import 'setting.dart';

abstract final class StoreSettings {
  // How this screen presents the app. Each computer keeps its own.

  static const glanceMode = BoolSetting(
    'glanceMode',
    'glance_mode_enabled',
    false,
    sync: SettingSync.thisComputer,
  );

  /// The tours and hints are offered.
  static const tutorialsEnabled = BoolSetting(
    'tutorialsEnabled',
    'tutorials_enabled',
    true,
    unreadableIsFallback: true,
    sync: SettingSync.thisComputer,
  );

  /// Ids of the session insights the operator asked not to see again,
  /// comma-separated.
  static const dismissedSessionInsights = TextSetting(
    'dismissedSessionInsights',
    'session_insights.dismissed',
    '',
    sync: SettingSync.thisComputer,
  );

  /// The DepthLock introduction was dismissed, or a goal was created.
  static const depthLockHintDismissed = BoolSetting(
    'depthLockHintDismissed',
    'imaging.depthlock_hint_dismissed',
    false,
    sync: SettingSync.thisComputer,
  );

  /// The equipment set-up wizard's progress, kept until it is finished.
  static const equipmentOnboardingDraft = OptionalTextSetting(
    'equipmentOnboardingDraft',
    'equipment_onboarding_draft',
    unsetText: '',
    sync: SettingSync.thisComputer,
  );

  static const autoStretch = OptionalTextSetting(
    'autoStretch',
    'auto_stretch_settings',
    unsetText: '',
    sync: SettingSync.thisComputer,
  );

  static const annotationSettings = OptionalTextSetting(
    'annotationSettings',
    'annotation_settings',
    unsetText: '',
    sync: SettingSync.thisComputer,
  );

  static const annotationMarkerStyle = OptionalTextSetting(
    'annotationMarkerStyle',
    'annotation_marker_style',
    unsetText: '',
    sync: SettingSync.thisComputer,
  );

  static const annotationPresets = OptionalTextSetting(
    'annotationPresets',
    'annotation_presets',
    unsetText: '',
    sync: SettingSync.thisComputer,
  );

  static const polarAlignmentScreen = OptionalTextSetting(
    'polarAlignmentScreen',
    'polar_alignment_ui',
    unsetText: '',
    sync: SettingSync.thisComputer,
  );

  /// The target last open in Framing, restored at the next launch.
  static const lastFramedTarget = OptionalTextSetting(
    'lastFramedTarget',
    'framing.lastTarget',
    unsetText: '',
    sync: SettingSync.thisComputer,
  );

  /// Name of the sequencer tree's row density.
  static const sequencerDensity = OptionalTextSetting(
    'sequencerDensity',
    'sequencer_density_v1',
    unsetText: '',
    sync: SettingSync.thisComputer,
  );

  /// Which row densities show the sequence overview.
  static const sequenceOverview = OptionalTextSetting(
    'sequenceOverview',
    'sequence_overview_visible_v1',
    unsetText: '',
    sync: SettingSync.thisComputer,
  );

  static const thumbnailStrip = OptionalTextSetting(
    'thumbnailStrip',
    'thumbnail_strip_prefs_v1',
    unsetText: '',
    sync: SettingSync.thisComputer,
  );

  /// The operator's own Google Geolocation API key. Empty: the key-free
  /// lookup runs.
  static const googleGeolocationKey = TextSetting(
    'googleGeolocationKey',
    'location_google_geolocation_key',
    '',
    normalize: _trimmed,
    sync: SettingSync.thisComputer,
  );

  /// The notification credentials in this computer's database were moved to
  /// its keyring.
  static const notificationSecretsMigrated = BoolSetting(
    'notificationSecretsMigrated',
    'notification_secrets_migrated_v2',
    false,
    sync: SettingSync.thisComputer,
  );

  /// The operator's own Constellation account and contribution consent.
  static const constellation = SettingFamily(
    'constellation.',
    sync: SettingSync.thisComputer,
  );

  static const constellationHubUrl = TextSetting(
    'constellationHubUrl',
    'constellation.hub_url',
    '',
    sync: SettingSync.thisComputer,
  );

  /// The hub's bearer token for this account.
  static const constellationHubToken = TextSetting(
    'constellationHubToken',
    'constellation.hub_token',
    '',
    sync: SettingSync.thisComputer,
  );

  /// The id the hub records this account under.
  static const constellationAccountId = TextSetting(
    'constellationAccountId',
    'constellation.account_id',
    '',
    sync: SettingSync.thisComputer,
  );

  /// The name this imager is shown under on the hub.
  static const constellationDisplayName = TextSetting(
    'constellationDisplayName',
    'constellation.display_name',
    '',
    sync: SettingSync.thisComputer,
  );

  /// This install's stable opaque key on the hub, random hex minted at the
  /// first registration.
  static const constellationPublicKey = TextSetting(
    'constellationPublicKey',
    'constellation.public_key',
    '',
    sync: SettingSync.thisComputer,
  );

  /// What a contribution sends to the hub: `sums` (the co-add sums only) or
  /// `subs` (the raw subframes).
  static const constellationPrivacy = TextSetting(
    'constellationPrivacy',
    'constellation.privacy',
    'sums',
    allowed: ['sums', 'subs'],
    sync: SettingSync.thisComputer,
  );

  /// Consent to share mosaic panels, and how they are licensed.
  static const mosaicUpload = SettingFamily(
    'mosaic.upload.',
    sync: SettingSync.thisComputer,
  );

  /// The assistant's model configuration and keys.
  static const assistant = SettingFamily('ai.', sync: SettingSync.thisComputer);

  /// The active planning project: one row here, and on a linked client one
  /// per host.
  static const activePlanningProject = SettingFamily(
    'planning.active_project_id',
    sync: SettingSync.thisComputer,
  );

  // Rig settings kept by the feature that uses them. A linked client reads
  // and writes the host's rows.

  // What a new sequence node starts from.

  static const sequencerAutofocusStepSize = IntSetting(
    'autofocusStepSize',
    'sequencer_autofocus_step_size',
    100,
    sync: SettingSync.hostStore,
  );
  static const sequencerAutofocusStepsOut = IntSetting(
    'autofocusStepsOut',
    'sequencer_autofocus_steps_out',
    7,
    sync: SettingSync.hostStore,
  );

  /// Seconds.
  static const sequencerAutofocusExposure = DoubleSetting(
    'autofocusExposureDuration',
    'sequencer_autofocus_exposure_duration',
    3.0,
    sync: SettingSync.hostStore,
  );

  /// Frames between the runs of the standard autofocus-interval trigger. The
  /// executor refuses 0.
  static const sequencerAutofocusIntervalFrames = IntSetting(
    'autofocusIntervalFrames',
    'sequencer_autofocus_interval_frames',
    25,
    inputMin: 1,
    sync: SettingSync.hostStore,
  );

  /// Pixels.
  static const sequencerDitherPixels = DoubleSetting(
    'ditherPixels',
    'sequencer_dither_pixels',
    5.0,
    sync: SettingSync.hostStore,
  );

  /// Seconds.
  static const sequencerDitherSettleTime = DoubleSetting(
    'ditherSettleTime',
    'sequencer_dither_settle_time',
    30.0,
    sync: SettingSync.hostStore,
  );

  /// Pixels.
  static const sequencerDitherSettlePixels = DoubleSetting(
    'ditherSettlePixels',
    'sequencer_dither_settle_pixels',
    1.5,
    sync: SettingSync.hostStore,
  );

  /// Seconds.
  static const sequencerDitherSettleTimeout = DoubleSetting(
    'ditherSettleTimeout',
    'sequencer_dither_settle_timeout',
    120.0,
    sync: SettingSync.hostStore,
  );
  static const sequencerDitherRaOnly = BoolSetting(
    'ditherRaOnly',
    'sequencer_dither_ra_only',
    false,
    sync: SettingSync.hostStore,
  );

  /// Seconds. Not set, or not above zero, means no exposure length has been
  /// chosen yet.
  static const sequencerExposureDuration = OptionalDoubleSetting(
    'exposureDuration',
    'sequencer_exposure_duration',
    null,
    sync: SettingSync.hostStore,
  );
  static const sequencerExposureCount = IntSetting(
    'exposureCount',
    'sequencer_exposure_count',
    10,
    sync: SettingSync.hostStore,
  );
  static const sequencerExposureFilter = OptionalTextSetting(
    'exposureFilter',
    'sequencer_exposure_filter',
    unsetText: '',
    sync: SettingSync.hostStore,
  );
  static const sequencerExposureGain = OptionalIntSetting(
    'exposureGain',
    'sequencer_exposure_gain',
    null,
    sync: SettingSync.hostStore,
  );
  static const sequencerExposureOffset = OptionalIntSetting(
    'exposureOffset',
    'sequencer_exposure_offset',
    null,
    sync: SettingSync.hostStore,
  );
  static const sequencerExposureBinning = EnumSetting<BinningMode>(
    'exposureBinning',
    'sequencer_exposure_binning',
    BinningMode.one,
    BinningMode.values,
    sync: SettingSync.hostStore,
  );

  /// Frames between dithers.
  static const sequencerExposureDitherEvery = IntSetting(
    'exposureDitherEvery',
    'sequencer_exposure_dither_every',
    3,
    sync: SettingSync.hostStore,
  );

  /// A new Live Stacking node broadcasts without an access token.
  static const liveStackingPublicByDefault = BoolSetting(
    'livestackingPublicByDefault',
    'livestacking_public_by_default',
    false,
    sync: SettingSync.hostStore,
  );

  /// A `LiveStackingMethod.storageKey`.
  static const liveStackingStackMethod = TextSetting(
    'livestackingDefaultStackMethod',
    'livestacking_default_stack_method',
    'average',
    sync: SettingSync.hostStore,
  );

  /// Watermark template of a new Live Stacking node. Not set: no watermark.
  static const liveStackingWatermark = OptionalTextSetting(
    'livestackingDefaultWatermark',
    'livestacking_default_watermark',
    unsetText: '',
    sync: SettingSync.hostStore,
  );
  static const liveStackingThumbnailSize =
      EnumSetting<LiveStackingThumbnailSize>(
        'livestackingDefaultThumbnailSize',
        'livestacking_default_thumbnail_size',
        LiveStackingThumbnailSize.medium,
        LiveStackingThumbnailSize.values,
        sync: SettingSync.hostStore,
      );

  /// Every Live Stacking node runs with its broadcast off.
  static const liveStackingDisableEverywhere = BoolSetting(
    'livestackingDisableEverywhere',
    'livestacking_disable_everywhere',
    false,
    sync: SettingSync.hostStore,
  );

  // Frame watch: what a run does when the framing drifts or something blocks
  // the view.

  static const frameWatchRecenter = BoolSetting(
    'frameWatchRecenter',
    'frame_watch_recenter_enabled',
    true,
    unreadableIsFallback: true,
    sync: SettingSync.hostStore,
  );

  /// Arcseconds the solved center may drift before the run recenters.
  static const frameWatchDriftLimit = DoubleSetting(
    'frameWatchDriftLimit',
    'frame_watch_drift_limit_arcsec',
    30,
    sync: SettingSync.hostStore,
  );
  static const frameWatchObstructionDetection = BoolSetting(
    'frameWatchObstructionDetection',
    'frame_watch_obstruction_detection',
    true,
    unreadableIsFallback: true,
    sync: SettingSync.hostStore,
  );

  /// Obstructions learned from frames that went dark, by site.
  static const learnedHorizonPoints = OptionalTextSetting(
    'learnedHorizonPoints',
    'learned_horizon_points_json',
    unsetText: '',
    sync: SettingSync.hostStore,
  );

  /// What the host publishes to Home Assistant through its MQTT broker, whose
  /// password it keeps, and whether Home Assistant may command the rig.
  static const homeAssistantDiscovery = OptionalTextSetting(
    'homeAssistantDiscovery',
    'home_assistant_discovery',
    unsetText: '',
    sync: SettingSync.hostStore,
    adminOnly: AdminOnly.credentialTarget,
  );

  static const pushNotifications = OptionalTextSetting(
    'pushNotifications',
    'push_notification_config',
    unsetText: '',
    sync: SettingSync.hostStore,
  );

  /// The scheduler's scoring weights and limits.
  static const schedulerConfig = OptionalTextSetting(
    'schedulerConfig',
    'scheduler_config',
    unsetText: '',
    sync: SettingSync.hostStore,
  );

  /// Each plugin's on/off choice, by plugin id.
  static const pluginEnablement = OptionalTextSetting(
    'pluginEnablement',
    'plugin_enablement',
    unsetText: '',
    sync: SettingSync.hostStore,
    adminOnly: AdminOnly.hostProgram,
  );

  /// The camera's gain and offset presets.
  static const cameraPresets = OptionalTextSetting(
    'cameraPresets',
    'camera_presets',
    unsetText: '',
    sync: SettingSync.hostStore,
  );

  /// The operator's own telescope presets, and edited copies of built-in ones.
  static const telescopePresetOverrides = OptionalTextSetting(
    'telescopePresetOverrides',
    'hardware_presets.telescopes.v1',
    unsetText: '',
    sync: SettingSync.hostStore,
  );

  /// The operator's own camera presets, and edited copies of built-in ones.
  static const cameraPresetOverrides = OptionalTextSetting(
    'cameraPresetOverrides',
    'hardware_presets.cameras.v1',
    unsetText: '',
    sync: SettingSync.hostStore,
  );

  // Calibration.

  /// Lights are calibrated as they are captured.
  static const calibrationAutoCalibrate = BoolSetting(
    'calibrationAutoCalibrate',
    'calibration.auto_calibrate',
    false,
    sync: SettingSync.hostStore,
  );

  /// The dark for a light is picked from the dark library.
  static const calibrationAutoDarkFromLibrary = BoolSetting(
    'calibrationAutoDarkFromLibrary',
    'calibration.auto_dark_from_library',
    true,
    unreadableIsFallback: true,
    sync: SettingSync.hostStore,
  );
  static const calibrationMasterFlatPath = OptionalTextSetting(
    'calibrationMasterFlatPath',
    'calibration.master_flat_path',
    unsetText: '',
    sync: SettingSync.hostStore,
  );
  static const calibrationMasterBiasPath = OptionalTextSetting(
    'calibrationMasterBiasPath',
    'calibration.master_bias_path',
    unsetText: '',
    sync: SettingSync.hostStore,
  );
  static const calibrationManualDarkPath = OptionalTextSetting(
    'calibrationManualDarkPath',
    'calibration.manual_dark_path',
    unsetText: '',
    sync: SettingSync.hostStore,
  );

  /// Seconds a dark's exposure may differ from the light's and still match.
  static const darkExposureTolerance = DoubleSetting(
    'darkExposureTolerance',
    'dark_library.exposure_tolerance',
    0.5,
    sync: SettingSync.hostStore,
  );

  /// Degrees Celsius a dark's sensor temperature may differ from the light's
  /// and still match. An install starts at 2.
  static const darkTemperatureTolerance = DoubleSetting(
    'darkTemperatureTolerance',
    'dark_library.temp_tolerance',
    1.0,
    seed: '2.0',
    sync: SettingSync.hostStore,
  );

  /// Frames are corrected with the defect map as they are captured.
  static const defectMapAutoApply = BoolSetting(
    'defectMapAutoApply',
    'defectMap.autoApply',
    false,
    sync: SettingSync.hostStore,
  );

  /// A `DefectMapMethod.wireValue`.
  static const defectMapMethod = TextSetting(
    'defectMapMethod',
    'defectMap.method',
    'median',
    sync: SettingSync.hostStore,
  );

  /// Pixels across the neighborhood a defect is replaced from.
  static const defectMapKernelDiameter = IntSetting(
    'defectMapKernelDiameter',
    'defectMap.kernelDiameter',
    3,
    sync: SettingSync.hostStore,
  );

  /// The uncorrected frame is kept beside the corrected one.
  static const defectMapSaveOriginal = BoolSetting(
    'defectMapSaveOriginal',
    'defectMap.saveOriginal',
    false,
    sync: SettingSync.hostStore,
  );

  /// The flat folder, target, tolerance and frame count last used.
  static const flatWizard = OptionalTextSetting(
    'flatWizard',
    'flat_wizard_global_settings',
    unsetText: '',
    sync: SettingSync.hostStore,
  );

  /// The fields of the meridian flip settings that differ from their defaults.
  static const meridianFlip = OptionalTextSetting(
    'meridianFlip',
    'meridian_flip_settings',
    unsetText: '',
    sync: SettingSync.hostStore,
  );

  static const polarAlignment = OptionalTextSetting(
    'polarAlignment',
    'polar_alignment_config',
    unsetText: '',
    sync: SettingSync.hostStore,
  );

  // The decision log a run keeps for replay.

  static const replayDebugEnabled = BoolSetting(
    'replayDebugEnabled',
    'replay_debug.enabled',
    true,
    sync: SettingSync.hostStore,
  );

  /// Days a decision is kept. Never off, or the log grows without bound.
  static const replayDebugRetentionDays = IntSetting(
    'replayDebugRetentionDays',
    'replay_debug.retention_days',
    90,
    inputMin: 1,
    inputMax: 3650,
    sync: SettingSync.hostStore,
  );

  // Notifications.

  /// Which transports each kind of notification goes to.
  static const notificationRouting = OptionalTextSetting(
    'notificationRouting',
    'notification_routing_matrix',
    unsetText: '',
    sync: SettingSync.hostStore,
  );

  /// The Discord and Pushover settings from before notification routing
  /// were carried into it.
  static const legacyNotificationCredentialsCarried = BoolSetting(
    'legacyNotificationCredentialsCarried',
    'notification_legacy_credentials_carried_v1',
    false,
    sync: SettingSync.hostStore,
  );

  // Science.

  static const scienceAdvancedMode = BoolSetting(
    'scienceAdvancedMode',
    'science.advanced_mode.enabled',
    false,
    seeded: true,
    sync: SettingSync.hostStore,
  );
  static const scienceOverlay = BoolSetting(
    'scienceOverlay',
    'science.overlay.enabled',
    true,
    seeded: true,
    sync: SettingSync.hostStore,
  );
  static const sciencePhotometry = BoolSetting(
    'sciencePhotometry',
    'science.feature.photometry',
    true,
    seeded: true,
    sync: SettingSync.hostStore,
  );
  static const sciencePhotometricCalibration = BoolSetting(
    'sciencePhotometricCalibration',
    'science.feature.photometric_calibration',
    true,
    seeded: true,
    sync: SettingSync.hostStore,
  );
  static const scienceTransparency = BoolSetting(
    'scienceTransparency',
    'science.feature.transparency',
    true,
    seeded: true,
    sync: SettingSync.hostStore,
  );
  static const sciencePsfMap = BoolSetting(
    'sciencePsfMap',
    'science.feature.psf_map',
    true,
    seeded: true,
    sync: SettingSync.hostStore,
  );
  static const scienceAstrometricResiduals = BoolSetting(
    'scienceAstrometricResiduals',
    'science.feature.astrometric_residuals',
    true,
    seeded: true,
    sync: SettingSync.hostStore,
  );
  static const scienceMovingObjects = BoolSetting(
    'scienceMovingObjects',
    'science.feature.moving_objects',
    false,
    seeded: true,
    sync: SettingSync.hostStore,
  );
  static const scienceNarrowbandRatios = BoolSetting(
    'scienceNarrowbandRatios',
    'science.feature.narrowband_ratios',
    false,
    seeded: true,
    sync: SettingSync.hostStore,
  );
  static const scienceFrameQualityMaps = BoolSetting(
    'scienceFrameQualityMaps',
    'science.feature.frame_quality_maps',
    true,
    seeded: true,
    sync: SettingSync.hostStore,
  );
  static const scienceSurface3d = BoolSetting(
    'scienceSurface3d',
    'science.feature.surface3d',
    true,
    seeded: true,
    sync: SettingSync.hostStore,
  );

  /// Solved lights fold into the Your Sky atlas. Off until the operator turns
  /// it on: the atlas keeps gigabytes of tiles on disk.
  static const scienceSkyAtlas = BoolSetting(
    'scienceSkyAtlas',
    'science.feature.sky_atlas',
    false,
    seeded: true,
    sync: SettingSync.hostStore,
  );

  /// Largest size, in GB, the atlas may reach before new frames stop being
  /// added to it. 0 means no limit.
  static const scienceSkyAtlasLimitGb = IntSetting(
    'scienceSkyAtlasLimitGb',
    'science.sky_atlas.limit_gb',
    defaultSkyAtlasLimitGb,
    inputMin: 0,
    sync: SettingSync.hostStore,
  );

  /// This database has been through the rule that made Your Sky opt-in.
  static const scienceSkyAtlasOptInMigrated = BoolSetting(
    'scienceSkyAtlasOptInMigrated',
    'science.sky_atlas.opt_in_migrated',
    false,
    sync: SettingSync.hostStore,
  );

  /// `pending` while the one-time "Your Sky is now off" notice is owed,
  /// `shown` once it is answered.
  static const scienceSkyAtlasOffNotice = OptionalTextSetting(
    'scienceSkyAtlasOffNotice',
    'science.sky_atlas.off_notice',
    unsetText: '',
    sync: SettingSync.hostStore,
  );
  static const scienceManualPurgeOnly = BoolSetting(
    'scienceManualPurgeOnly',
    'science.retention.manual_purge_only',
    true,
    seeded: true,
    sync: SettingSync.hostStore,
  );

  /// The photometric and atmospheric measurements are written into the
  /// captured FITS header.
  static const scienceFitsHeaderWriteback = BoolSetting(
    'scienceFitsHeaderWriteback',
    'science.writeback.fits_header_enabled',
    true,
    sync: SettingSync.hostStore,
  );
  static const scienceMpcObservatoryCode = TextSetting(
    'scienceMpcObservatoryCode',
    'science.mpc.observatory_code',
    '',
    sync: SettingSync.hostStore,
  );
  static const scienceAavsoObserverCode = TextSetting(
    'scienceAavsoObserverCode',
    'science.aavso.observer_code',
    '',
    sync: SettingSync.hostStore,
  );
  static const scienceObserverName = TextSetting(
    'scienceObserverName',
    'science.observer.name',
    '',
    sync: SettingSync.hostStore,
  );
  static const scienceMpcAstrometricCatalog = TextSetting(
    'scienceMpcAstrometricCatalog',
    'science.mpc.ast_cat',
    '',
    sync: SettingSync.hostStore,
  );
  static const scienceTnsBotId = IntSetting(
    'scienceTnsBotId',
    'science.tns.bot_id',
    0,
    sync: SettingSync.hostStore,
  );
  static const scienceTnsBotName = TextSetting(
    'scienceTnsBotName',
    'science.tns.bot_name',
    '',
    sync: SettingSync.hostStore,
  );
  static const scienceTnsReportingGroupId = IntSetting(
    'scienceTnsReportingGroupId',
    'science.tns.group_id',
    0,
    sync: SettingSync.hostStore,
  );
  static const scienceTnsDataSourceId = IntSetting(
    'scienceTnsDataSourceId',
    'science.tns.source_id',
    0,
    sync: SettingSync.hostStore,
  );
  static const scienceTnsReporterName = TextSetting(
    'scienceTnsReporterName',
    'science.tns.reporter',
    '',
    sync: SettingSync.hostStore,
  );
  static const scienceTnsUseSandbox = BoolSetting(
    'scienceTnsUseSandbox',
    'science.tns.use_sandbox',
    false,
    sync: SettingSync.hostStore,
  );
  static const scienceAutoFrameGrading = BoolSetting(
    'scienceAutoFrameGrading',
    'science.grading.auto_enabled',
    false,
    sync: SettingSync.hostStore,
  );

  /// The frame grading rules. Not set: the conservative defaults.
  static const scienceFrameGradeRules = OptionalTextSetting(
    'scienceFrameGradeRules',
    'science.grading.rules_json',
    unsetText: '',
    sync: SettingSync.hostStore,
  );
  static const scienceGuideCollapsed = BoolSetting(
    'scienceGuideCollapsed',
    'science.guide.collapsed',
    false,
    sync: SettingSync.hostStore,
  );
  static const scienceOverlayOpacity = DoubleSetting(
    'scienceOverlayOpacity',
    'science.overlay.opacity',
    0.35,
    min: 0.05,
    max: 0.95,
    seeded: true,
    sync: SettingSync.hostStore,
  );
  static const scienceLiveGridRows = IntSetting(
    'scienceLiveGridRows',
    'science.overlay.live_grid_rows',
    12,
    min: 4,
    max: 64,
    seeded: true,
    sync: SettingSync.hostStore,
  );
  static const scienceLiveGridCols = IntSetting(
    'scienceLiveGridCols',
    'science.overlay.live_grid_cols',
    16,
    min: 4,
    max: 64,
    seeded: true,
    sync: SettingSync.hostStore,
  );
  static const scienceAnalysisGridRows = IntSetting(
    'scienceAnalysisGridRows',
    'science.overlay.analysis_grid_rows',
    24,
    min: 4,
    max: 96,
    seeded: true,
    sync: SettingSync.hostStore,
  );
  static const scienceAnalysisGridCols = IntSetting(
    'scienceAnalysisGridCols',
    'science.overlay.analysis_grid_cols',
    32,
    min: 4,
    max: 96,
    seeded: true,
    sync: SettingSync.hostStore,
  );
  static const scienceDifferentialPhotometry = BoolSetting(
    'scienceDifferentialPhotometry',
    'science.photometry.differential_active',
    false,
    seeded: true,
    sync: SettingSync.hostStore,
  );

  /// The differential photometry target, as a JSON object. Empty: none.
  static const sciencePhotometryTarget = TextSetting(
    'sciencePhotometryTarget',
    'science.photometry.target_anchor',
    '',
    seeded: true,
    sync: SettingSync.hostStore,
  );

  /// The comparison stars, as a JSON list.
  static const sciencePhotometryComparisons = TextSetting(
    'sciencePhotometryComparisons',
    'science.photometry.comparison_anchors',
    '[]',
    seeded: true,
    sync: SettingSync.hostStore,
  );

  // Transient alerts.

  /// Names of the alert sources that are watched, as a JSON list.
  static const transientAlertSources = OptionalTextSetting(
    'transientAlertSources',
    'transient_alert_enabled_sources',
    unsetText: '',
    sync: SettingSync.hostStore,
  );

  /// Names of the transient types that are watched, as a JSON list.
  static const transientAlertTypes = OptionalTextSetting(
    'transientAlertTypes',
    'transient_alert_types_to_monitor',
    unsetText: '',
    sync: SettingSync.hostStore,
  );

  /// Alerts fainter than this magnitude are not shown.
  static const transientAlertMagnitudeThreshold = DoubleSetting(
    'transientAlertMagnitudeThreshold',
    'transient_alert_magnitude_threshold',
    15.0,
    sync: SettingSync.hostStore,
  );
  static const transientAlertNotifyOnNew = BoolSetting(
    'transientAlertNotifyOnNew',
    'transient_alert_notify_on_new',
    true,
    unreadableIsFallback: true,
    sync: SettingSync.hostStore,
  );
  static const transientAlertAutoQueueBright = BoolSetting(
    'transientAlertAutoQueueBright',
    'transient_alert_auto_queue_bright',
    false,
    unreadableIsFallback: true,
    sync: SettingSync.hostStore,
  );
  static const transientAlertAutoQueueMagnitude = DoubleSetting(
    'transientAlertAutoQueueMagnitude',
    'transient_alert_auto_queue_magnitude',
    10.0,
    sync: SettingSync.hostStore,
  );

  /// What each alert was marked as (acknowledged, queued, dismissed), by
  /// alert id.
  static const transientAlertStates = SettingFamily(
    'transient_alert_state_',
    sync: SettingSync.hostStore,
  );

  /// The capture settings last used with each equipment profile.
  static const captureSettings = SettingFamily(
    'imaging_capture_settings_profile_',
    sync: SettingSync.hostStore,
  );

  /// The per-filter flat choices, by profile, camera and filter wheel.
  static const flatWizardFilters = SettingFamily(
    'flat_wizard_filters.v1.',
    sync: SettingSync.hostStore,
  );

  static const List<Setting<Object?>> all = [
    glanceMode,
    tutorialsEnabled,
    dismissedSessionInsights,
    depthLockHintDismissed,
    equipmentOnboardingDraft,
    autoStretch,
    annotationSettings,
    annotationMarkerStyle,
    annotationPresets,
    polarAlignmentScreen,
    lastFramedTarget,
    sequencerDensity,
    sequenceOverview,
    thumbnailStrip,
    googleGeolocationKey,
    notificationSecretsMigrated,
    constellationHubUrl,
    constellationHubToken,
    constellationAccountId,
    constellationDisplayName,
    constellationPublicKey,
    constellationPrivacy,
    sequencerAutofocusStepSize,
    sequencerAutofocusStepsOut,
    sequencerAutofocusExposure,
    sequencerAutofocusIntervalFrames,
    sequencerDitherPixels,
    sequencerDitherSettleTime,
    sequencerDitherSettlePixels,
    sequencerDitherSettleTimeout,
    sequencerDitherRaOnly,
    sequencerExposureDuration,
    sequencerExposureCount,
    sequencerExposureFilter,
    sequencerExposureGain,
    sequencerExposureOffset,
    sequencerExposureBinning,
    sequencerExposureDitherEvery,
    liveStackingPublicByDefault,
    liveStackingStackMethod,
    liveStackingWatermark,
    liveStackingThumbnailSize,
    liveStackingDisableEverywhere,
    frameWatchRecenter,
    frameWatchDriftLimit,
    frameWatchObstructionDetection,
    learnedHorizonPoints,
    calibrationAutoCalibrate,
    calibrationAutoDarkFromLibrary,
    calibrationMasterFlatPath,
    calibrationMasterBiasPath,
    calibrationManualDarkPath,
    darkExposureTolerance,
    darkTemperatureTolerance,
    defectMapAutoApply,
    defectMapMethod,
    defectMapKernelDiameter,
    defectMapSaveOriginal,
    flatWizard,
    meridianFlip,
    polarAlignment,
    replayDebugEnabled,
    replayDebugRetentionDays,
    notificationRouting,
    legacyNotificationCredentialsCarried,
    scienceAdvancedMode,
    scienceOverlay,
    sciencePhotometry,
    sciencePhotometricCalibration,
    scienceTransparency,
    sciencePsfMap,
    scienceAstrometricResiduals,
    scienceMovingObjects,
    scienceNarrowbandRatios,
    scienceFrameQualityMaps,
    scienceSurface3d,
    scienceSkyAtlas,
    scienceSkyAtlasLimitGb,
    scienceSkyAtlasOptInMigrated,
    scienceSkyAtlasOffNotice,
    scienceManualPurgeOnly,
    scienceFitsHeaderWriteback,
    scienceMpcObservatoryCode,
    scienceAavsoObserverCode,
    scienceObserverName,
    scienceMpcAstrometricCatalog,
    scienceTnsBotId,
    scienceTnsBotName,
    scienceTnsReportingGroupId,
    scienceTnsDataSourceId,
    scienceTnsReporterName,
    scienceTnsUseSandbox,
    scienceAutoFrameGrading,
    scienceFrameGradeRules,
    scienceGuideCollapsed,
    scienceOverlayOpacity,
    scienceLiveGridRows,
    scienceLiveGridCols,
    scienceAnalysisGridRows,
    scienceAnalysisGridCols,
    scienceDifferentialPhotometry,
    sciencePhotometryTarget,
    sciencePhotometryComparisons,
    transientAlertSources,
    transientAlertTypes,
    transientAlertMagnitudeThreshold,
    transientAlertNotifyOnNew,
    transientAlertAutoQueueBright,
    transientAlertAutoQueueMagnitude,
    homeAssistantDiscovery,
    pushNotifications,
    schedulerConfig,
    pluginEnablement,
    cameraPresets,
    telescopePresetOverrides,
    cameraPresetOverrides,
  ];

  /// Each notification transport's server and account. The passwords, tokens
  /// and webhook addresses are in the host's keyring.
  static const notificationTransports = SettingFamily(
    NotificationTransportKind.settingKeyPrefix,
    sync: SettingSync.hostStore,
    adminOnly: AdminOnly.credentialTarget,
  );

  /// Where the host's cloud backup goes. Its password or secret key is in the
  /// host's keyring.
  static const cloudBackup = SettingFamily(
    SyncSettingsKeys.prefix,
    sync: SettingSync.hostStore,
    adminOnly: AdminOnly.credentialTarget,
  );

  /// Where the host's backups are kept (`backup.directory`).
  static const backups = SettingFamily(
    'backup.',
    sync: SettingSync.hostStore,
    adminOnly: AdminOnly.administration,
  );

  /// Whether and how often the host backs itself up
  /// (`autosave.backup_enabled`, `autosave.backup_interval_hours`).
  static const automaticBackups = SettingFamily(
    'autosave.backup_',
    sync: SettingSync.hostStore,
    adminOnly: AdminOnly.administration,
  );

  /// How many automatic backups the host keeps; lowering it deletes the
  /// older ones.
  static const automaticBackupsKept = SettingFamily(
    'autosave.max_backups',
    sync: SettingSync.hostStore,
    adminOnly: AdminOnly.administration,
  );

  /// When the host last backed itself up.
  static const lastAutomaticBackup = SettingFamily(
    'autosave.last_backup_at',
    sync: SettingSync.hostStore,
    adminOnly: AdminOnly.administration,
  );

  static const List<SettingFamily> families = [
    backups,
    automaticBackups,
    automaticBackupsKept,
    lastAutomaticBackup,
    notificationTransports,
    cloudBackup,
    constellation,
    mosaicUpload,
    assistant,
    activePlanningProject,
    transientAlertStates,
    captureSettings,
    flatWizardFilters,
  ];
}

String _trimmed(String value) => value.trim();

/// The Your Sky atlas size limit, in GB, until the operator picks one. With
/// compressed tiles this is several hundred hours of a typical field mix;
/// reaching it only stops new folds, it never deletes tiles.
const int defaultSkyAtlasLimitGb = 25;
