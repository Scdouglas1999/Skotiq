/// Which machine owns a row of the `app_settings` key/value store.
///
/// A linked client mirrors the imaging host: every setting that changes what
/// the rig does, what it captures, where frames go or how the night is run is
/// read from and written to the host. Only the preferences that describe how
/// THIS screen presents the app stay on the device that renders it. A key that
/// is not listed here is host-owned, so a new rig setting is mirrored by default
/// and a new presentation preference has to be added on purpose.
library;

/// Exact `app_settings` keys that belong to the device rendering the UI.
const Set<String> deviceLocalSettingKeys = {
  // Look and window chrome.
  'theme',
  'accent_color',
  'font_size',
  'ui_scale',
  'sidebar_collapsed',
  'start_minimized',
  'confirm_before_closing',
  'glance_mode_enabled',
  // Where this machine keeps its own database and logs.
  'database_path',
  'logs_path',
  // Panel layout and per-screen view state.
  'sequencer.toolbox_collapsed',
  'sequencer.properties_collapsed',
  'sequencer.snippet_palette_visible',
  'sequencer.toolbox_tab',
  'sequencer.active_tab',
  'sequencer.left_panel_width',
  'sequencer.right_panel_width',
  'sequencer_density_v1',
  'sequence_overview_visible_v1',
  'thumbnail_strip_prefs_v1',
  'auto_stretch_settings',
  'framing.lastTarget',
  'polar_alignment_ui',
  // Image annotation overlay: what this screen draws on top of a frame.
  'annotation_settings',
  'annotation_marker_style',
  'annotation_presets',
  // Hints, tours and prompts this operator has dismissed on this screen.
  'tutorials_enabled',
  'imaging.depthlock_hint_dismissed',
  'session_insights.dismissed',
  'smart_night.prompt_dismissed_day_key',
  'equipment_onboarding_draft',
  // Per-device credentials and migrations of this device's own keyring.
  'location_google_geolocation_key',
  'notification_secrets_migrated_v2',
};

/// Key prefixes that belong to the device rendering the UI: the operator's
/// own Constellation account and contribution consent, the assistant's model
/// configuration, and the active planning project, which is already keyed per
/// host on a linked client.
const List<String> deviceLocalSettingKeyPrefixes = [
  'constellation.',
  'mosaic.upload.',
  'ai.',
  'planning.active_project_id',
];

/// True when [key] is a presentation preference of the device rendering the
/// UI and must never be read from or written to the imaging host.
bool isDeviceLocalSettingKey(String key) {
  if (deviceLocalSettingKeys.contains(key)) return true;
  for (final prefix in deviceLocalSettingKeyPrefixes) {
    if (key.startsWith(prefix)) return true;
  }
  return false;
}
