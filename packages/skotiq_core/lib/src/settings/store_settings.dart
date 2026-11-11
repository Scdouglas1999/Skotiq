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
  ];

  static const List<SettingFamily> families = [
    constellation,
    mosaicUpload,
    assistant,
    activePlanningProject,
  ];
}

String _trimmed(String value) => value.trim();
