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

import '../models/sequence/sequence_models.dart'
    show BinningMode, LiveStackingThumbnailSize;
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

  /// TCP port a new Live Stacking node broadcasts on, clear of the headless
  /// API server's default (8080).
  static const liveStackingPort = IntSetting(
    'livestackingDefaultPort',
    'livestacking_default_port',
    8081,
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
    liveStackingPort,
    liveStackingPublicByDefault,
    liveStackingStackMethod,
    liveStackingWatermark,
    liveStackingThumbnailSize,
    liveStackingDisableEverywhere,
  ];

  static const List<SettingFamily> families = [
    constellation,
    mosaicUpload,
    assistant,
    activePlanningProject,
  ];
}

String _trimmed(String value) => value.trim();
