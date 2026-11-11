/// The sidebar groups of the Settings screen, in display order.
enum SettingsGroupId {
  general('General', 'settingsGroupGeneral'),
  equipment('Equipment', 'settingsGroupEquipment'),
  imaging('Imaging', 'settingsGroupImaging'),
  automationSafety('Automation & Safety', 'settingsGroupAutomationSafety'),
  science('Science', 'settingsGroupScience'),
  notificationsRemote(
    'Notifications & Remote',
    'settingsGroupNotificationsRemote',
  ),
  advanced('Advanced', 'settingsGroupAdvanced');

  const SettingsGroupId(this.title, this.titleKey);

  /// English name; an identifier, never shown translated.
  final String title;

  /// Localization key of the name the operator reads.
  final String titleKey;

  /// This group's sections, in sidebar order.
  List<SettingsSectionId> get sections => [
        for (final section in SettingsSectionId.values)
          if (section.group == this) section,
      ];
}

/// Every Settings section. The declaration order within a group is the
/// sidebar order; this enum is the only place a section's key, group and
/// position are written down.
///
/// [key] is the string that appears in `/settings?section=<key>` URLs, in
/// tour steps, and in routes carried by core models, so it never changes.
/// A section that is renamed or merged keeps resolving through [aliases].
enum SettingsSectionId {
  general('general', SettingsGroupId.general),
  appearance('appearance', SettingsGroupId.general, onThisDevice: true),
  location('location', SettingsGroupId.general),
  filesStorage('files-storage', SettingsGroupId.general),
  help('help', SettingsGroupId.general, onThisDevice: true),
  about('about', SettingsGroupId.general, onThisDevice: true),

  connection('connection', SettingsGroupId.equipment, onThisDevice: true),
  equipmentProfiles('equipment-profiles', SettingsGroupId.equipment),
  phd2Guiding('phd2-guiding', SettingsGroupId.equipment),
  plateSolving('plate-solving', SettingsGroupId.equipment),
  autofocus('autofocus', SettingsGroupId.equipment),
  calibration('calibration', SettingsGroupId.equipment),

  imaging('imaging', SettingsGroupId.imaging),
  adaptiveExposure('adaptive-exposure', SettingsGroupId.imaging),
  imageGrading('image-grading', SettingsGroupId.imaging),
  annotations('annotations', SettingsGroupId.imaging, onThisDevice: true),
  catalogs('catalogs', SettingsGroupId.imaging),

  sequencer('sequencer', SettingsGroupId.automationSafety),
  preflight('preflight', SettingsGroupId.automationSafety),
  weatherSafety('weather-safety', SettingsGroupId.automationSafety),
  adaptiveConditions('adaptive-conditions', SettingsGroupId.automationSafety),
  // The darks and bias the night's lights need; before the Darkroom entry
  // because its masters feed that pass.
  endOfNightCalibration(
    'end-of-night-calibration',
    SettingsGroupId.automationSafety,
  ),
  // Points at the Darkroom's Activity tab, where night-end automation lives.
  darkroom('darkroom', SettingsGroupId.automationSafety),
  // The tail of the unattended night, so it sits with the rest of it rather
  // than under Advanced.
  delivery('delivery', SettingsGroupId.automationSafety),

  science('science', SettingsGroupId.science),
  observationLog('observation-log', SettingsGroupId.science),
  observingLists('observing-lists', SettingsGroupId.science),

  notifications('notifications', SettingsGroupId.notificationsRemote),
  integrations('integrations', SettingsGroupId.notificationsRemote),
  remoteAccess('remote-access', SettingsGroupId.notificationsRemote),

  logs('logs', SettingsGroupId.advanced),
  backup('backup', SettingsGroupId.advanced),
  updates('updates', SettingsGroupId.advanced),
  rigCatalogs('rig-catalogs', SettingsGroupId.advanced),
  capturedImages('captured-images', SettingsGroupId.advanced),
  replayDebug('replay-debug', SettingsGroupId.advanced);

  const SettingsSectionId(this.key, this.group, {this.onThisDevice = false});

  final String key;
  final SettingsGroupId group;

  /// On a linked client, whether the section's values belong to the device
  /// showing them (its look, its own link to the host, its help and app
  /// version) rather than to the imaging host.
  final bool onThisDevice;

  /// The section a fresh Settings screen shows.
  static const SettingsSectionId first = SettingsSectionId.general;

  /// Old or alternative keys that must keep landing somewhere sensible: a
  /// section that was merged into another, a page that moved, and the keys
  /// older builds and docs wrote into links.
  static const Map<String, SettingsSectionId> aliases = {
    // Files & storage = file paths + auto-save.
    'file-paths': SettingsSectionId.filesStorage,
    'auto-save': SettingsSectionId.filesStorage,
    'storage': SettingsSectionId.filesStorage,
    // Autofocus = autofocus + predictive autofocus + focus model.
    'predictive-af': SettingsSectionId.autofocus,
    'focus-model': SettingsSectionId.autofocus,
    // Notifications = notifications + routing.
    'notification-routing': SettingsSectionId.notifications,
    // The calibration pages moved to the Darkroom; the Calibration entry
    // points there.
    'dark-library': SettingsSectionId.calibration,
    'calibration-library': SettingsSectionId.calibration,
  };

  /// The section [key] names, directly or through [aliases]; null for null or
  /// an unknown key.
  static SettingsSectionId? resolve(String? key) {
    if (key == null) return null;
    for (final section in values) {
      if (section.key == key) return section;
    }
    return aliases[key];
  }
}
