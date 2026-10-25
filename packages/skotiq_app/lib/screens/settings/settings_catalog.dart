import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../localization/skotiq_localizations.dart';
import 'catalog_settings_screen.dart';
import 'delivery_settings.dart';
import 'equipment_profiles_screen.dart';
import 'settings_search_index.g.dart';
import 'integrations_settings.dart';
import 'backup_screen.dart';
import 'merged_sections.dart';
import 'widgets/adaptive_conditions_settings.dart';
import 'widgets/adaptive_exposure_settings.dart';
import 'widgets/about_settings.dart';
import 'widgets/captured_images_settings.dart';
import 'widgets/rig_catalog_settings.dart';
import 'widgets/update_settings.dart';
import 'widgets/annotation_settings.dart';
import 'widgets/appearance_settings.dart';
import 'widgets/calibration_redirect.dart';
import 'widgets/connection_settings.dart';
import 'widgets/darkroom_autopilot_settings.dart';
import 'widgets/end_of_night_calibration_settings.dart';
import 'widgets/general_settings.dart';
import 'widgets/help_tutorials_settings.dart';
import 'widgets/image_grading_settings.dart';
import 'widgets/imaging_settings.dart';
import 'widgets/location_settings.dart';
import 'widgets/log_viewer.dart';
import 'widgets/notification_settings.dart';
import 'widgets/observation_log_settings.dart';
import 'widgets/observing_lists_settings.dart';
import 'widgets/phd2_guiding_settings.dart';
import 'plate_solving_settings_screen.dart';
import 'widgets/preflight_settings.dart';
import 'widgets/remote_access_settings.dart';
import 'widgets/replay_debug_settings.dart';
import 'widgets/science_settings.dart';
import 'widgets/sequencer_settings.dart';
import 'widgets/weather_safety_settings.dart';

/// A single, navigable Settings section.
///
/// The [key] is the stable deep-link identifier used by
/// `context.go('/settings?section=<key>')` and is part of the app's navigation
/// contract — see [SettingsCatalog]. [build] returns the detail widget for this
/// section.
class SettingsSectionDef {
  /// Stable deep-link key, e.g. `'location'`.
  final String key;

  /// Display label. Pass a [labelKey] for sections with a localized string.
  final String label;

  final IconData icon;

  /// Hand-written synonyms — terms a user might type that appear NOWHERE in the
  /// section's own text ('dark mode' for Appearance, 'ASCOM' for a page headed
  /// 'Drivers').
  ///
  /// The rendered row titles are NOT listed here; they come from
  /// [kSettingsSearchTerms], which is GENERATED from the section widgets. A
  /// hand-written index rots silently — a row that cannot be found by typing
  /// its own visible title looks like a missing setting.
  final List<String> keywords;

  /// Builds the detail pane for this section. [isMobile] is threaded through to
  /// every settings widget.
  final Widget Function(bool isMobile) build;

  const SettingsSectionDef({
    required this.key,
    required this.label,
    required this.icon,
    required this.build,
    this.keywords = const [],
  });

  /// True if [query] (already lower-cased) matches this section's title, one of
  /// its hand-written synonyms, or the title of any row it renders.
  bool matches(String query) {
    if (label.toLowerCase().contains(query)) return true;
    for (final keyword in keywords) {
      if (keyword.toLowerCase().contains(query)) return true;
    }
    for (final term in kSettingsSearchTerms[key] ?? const <String>[]) {
      if (term.toLowerCase().contains(query)) return true;
    }
    return false;
  }
}

/// A collapsible group of related [SettingsSectionDef]s in the sidebar.
class SettingsGroupDef {
  /// Structural identity, always English. Matched against [kGroupTitles] by
  /// callers that resolve a section's owning group without a [BuildContext], so
  /// it must NOT follow the locale.
  final String title;

  /// What the user reads. Separate from [title] precisely because that one is an
  /// identifier: with only the English literal to render, the settings sidebar
  /// showed translated leaf items under untranslated group headers ("Apariencia"
  /// and "Ubicación" beneath a header reading "EQUIPMENT").
  final String displayTitle;

  final IconData icon;
  final List<SettingsSectionDef> sections;

  const SettingsGroupDef({
    required this.title,
    required this.icon,
    required this.sections,
    String? displayTitle,
  }) : displayTitle = displayTitle ?? title;
}

/// Resolves localized section labels at build time.
///
/// Most sections have a localized label key (`settingsXxx`); a few keep
/// literals. Building the catalog through a [BuildContext] lets labels follow
/// the active locale instead of being frozen at first build.
List<SettingsGroupDef> buildSettingsGroups(BuildContext context) {
  final l10n = context.l10n;
  String t(String key) => l10n.text(key);

  return [
    SettingsGroupDef(
      title: 'General',
      displayTitle: t('settingsGroupGeneral'),
      icon: LucideIcons.settings,
      sections: [
        SettingsSectionDef(
          key: 'general',
          label: t('settingsGeneral'),
          icon: LucideIcons.settings,
          keywords: const [
            'language',
            'units',
            'startup',
            'defaults',
            'time format',
          ],
          build: (isMobile) => GeneralSettings(isMobile: isMobile),
        ),
        SettingsSectionDef(
          key: 'appearance',
          label: t('settingsAppearance'),
          icon: LucideIcons.palette,
          keywords: const [
            'theme',
            'dark mode',
            'light mode',
            'colors',
            'sidebar',
            'font',
          ],
          build: (isMobile) => AppearanceSettings(isMobile: isMobile),
        ),
        SettingsSectionDef(
          key: 'location',
          label: t('settingsLocation'),
          icon: LucideIcons.mapPin,
          keywords: const [
            'latitude',
            'longitude',
            'elevation',
            'horizon',
            'timezone',
            'observing site',
            'coordinates',
          ],
          build: (isMobile) => LocationSettingsPage(isMobile: isMobile),
        ),
        SettingsSectionDef(
          key: 'files-storage',
          label: t('settingsFilesStorage'),
          icon: LucideIcons.folder,
          keywords: const [
            'file paths',
            'image output',
            'directory',
            'folder',
            'auto-save',
            'autosave',
            'backups',
            'storage',
            'save interval',
          ],
          build: (isMobile) => FilesAndStorageSettings(isMobile: isMobile),
        ),
        SettingsSectionDef(
          key: 'help',
          label: t('settingsHelpTutorials'),
          icon: LucideIcons.helpCircle,
          keywords: const [
            'tutorials',
            'tours',
            'guides',
            'walkthrough',
            'onboarding',
          ],
          build: (isMobile) => HelpTutorialsSettings(isMobile: isMobile),
        ),
        SettingsSectionDef(
          key: 'about',
          label: t('settingsAbout'),
          icon: LucideIcons.info,
          keywords: const [
            'version',
            'license',
            'credits',
            'updates',
            'build',
          ],
          build: (isMobile) => AboutSettings(isMobile: isMobile),
        ),
      ],
    ),
    SettingsGroupDef(
      title: 'Equipment',
      displayTitle: t('settingsGroupEquipment'),
      icon: LucideIcons.boxes,
      sections: [
        SettingsSectionDef(
          key: 'connection',
          label: t('settingsConnection'),
          icon: LucideIcons.wifi,
          keywords: const [
            'ascom',
            'alpaca',
            'indi',
            'devices',
            'driver',
            'network',
            'host',
            'port',
          ],
          build: (isMobile) => ConnectionSettings(isMobile: isMobile),
        ),
        SettingsSectionDef(
          key: 'equipment-profiles',
          label: t('settingsEquipmentProfiles'),
          icon: LucideIcons.boxes,
          keywords: const [
            'camera',
            'mount',
            'focuser',
            'filter wheel',
            'guider',
            'gear',
            'rig',
          ],
          build: (isMobile) => EquipmentProfilesScreen(isMobile: isMobile),
        ),
        SettingsSectionDef(
          key: 'phd2-guiding',
          label: t('settingsPhd2Guiding'),
          icon: LucideIcons.target,
          keywords: const [
            'phd2',
            'guiding',
            'dithering',
            'calibration',
            'rms',
            'star lost',
          ],
          build: (isMobile) => Phd2GuidingSettings(isMobile: isMobile),
        ),
        SettingsSectionDef(
          key: 'plate-solving',
          label: t('settingsPlateSolving'),
          icon: LucideIcons.crosshair,
          keywords: const [
            'astap',
            'astrometry',
            'blind solve',
            'catalog',
            'sync',
            'center',
            'wcs',
          ],
          build: (isMobile) => PlateSolvingSettings(isMobile: isMobile),
        ),
        SettingsSectionDef(
          key: 'autofocus',
          label: t('settingsAutofocus'),
          icon: LucideIcons.focus,
          keywords: const [
            'focus',
            'hfr',
            'curve',
            'v-curve',
            'temperature compensation',
            'predictive',
            'focus model',
            'slope',
            'per-filter',
            'backlash',
          ],
          build: (isMobile) => AutofocusMergedSettings(isMobile: isMobile),
        ),
        SettingsSectionDef(
          key: 'calibration',
          label: t('settingsCalibration'),
          icon: LucideIcons.sliders,
          keywords: const [
            'flats',
            'darks',
            'bias',
            'master frames',
            'calibration',
            'dark library',
            'calibration library',
            'auto-calibrate',
            'temperature tolerance',
            'defect map',
          ],
          build: (isMobile) => CalibrationSettingsRedirect(isMobile: isMobile),
        ),
      ],
    ),
    SettingsGroupDef(
      title: 'Imaging',
      displayTitle: t('settingsGroupImaging'),
      icon: LucideIcons.camera,
      sections: [
        SettingsSectionDef(
          key: 'imaging',
          label: t('settingsImaging'),
          icon: LucideIcons.camera,
          keywords: const [
            'exposure',
            'gain',
            'offset',
            'binning',
            'file format',
            'fits',
            'frame naming',
          ],
          build: (isMobile) => ImagingSettings(isMobile: isMobile),
        ),
        SettingsSectionDef(
          key: 'adaptive-exposure',
          label: t('settingsAdaptiveExposure'),
          icon: LucideIcons.sun,
          keywords: const [
            'auto exposure',
            'sky background',
            'sub length',
            'optimization',
            'sky brightness',
          ],
          build: (isMobile) => AdaptiveExposureSettings(isMobile: isMobile),
        ),
        SettingsSectionDef(
          key: 'image-grading',
          label: t('settingsImageGrading'),
          icon: LucideIcons.star,
          keywords: const [
            'hfr',
            'eccentricity',
            'star count',
            'reject',
            'quality',
            'grading thresholds',
          ],
          build: (isMobile) => ImageGradingSettings(isMobile: isMobile),
        ),
        SettingsSectionDef(
          key: 'annotations',
          label: t('settingsAnnotations'),
          icon: LucideIcons.tag,
          keywords: const [
            'labels',
            'overlay',
            'dso',
            'stars',
            'grid',
            'constellation',
          ],
          build: (isMobile) => AnnotationSettingsPage(isMobile: isMobile),
        ),
        SettingsSectionDef(
          key: 'catalogs',
          label: t('settingsCatalogs'),
          icon: LucideIcons.database,
          keywords: const [
            'messier',
            'ngc',
            'ic',
            'star catalog',
            'database',
            'download',
          ],
          build: (isMobile) => CatalogSettingsScreen(isMobile: isMobile),
        ),
      ],
    ),
    SettingsGroupDef(
      title: 'Automation & Safety',
      displayTitle: t('settingsGroupAutomationSafety'),
      icon: LucideIcons.listOrdered,
      sections: [
        SettingsSectionDef(
          key: 'sequencer',
          label: t('settingsSequencer'),
          icon: LucideIcons.listOrdered,
          keywords: const [
            'sequence',
            'automation',
            'triggers',
            'meridian flip',
            'recovery',
            'behavior tree',
          ],
          build: (isMobile) => SequencerSettings(isMobile: isMobile),
        ),
        SettingsSectionDef(
          key: 'preflight',
          label: t('settingsPreflight'),
          icon: LucideIcons.clipboardCheck,
          keywords: const [
            'preflight',
            'checklist',
            'readiness',
            'startup checks',
            'safety',
          ],
          build: (isMobile) => PreflightSettings(isMobile: isMobile),
        ),
        SettingsSectionDef(
          key: 'weather-safety',
          label: t('settingsWeatherSafety'),
          icon: LucideIcons.cloudSun,
          keywords: const [
            'clouds',
            'rain',
            'wind',
            'safety monitor',
            'humidity',
            'roof',
            'abort',
          ],
          build: (isMobile) => WeatherSafetySettings(isMobile: isMobile),
        ),
        SettingsSectionDef(
          key: 'adaptive-conditions',
          label: t('settingsAdaptiveConditions'),
          icon: LucideIcons.cloud,
          keywords: const [
            'seeing',
            'transparency',
            'conditions',
            'adaptive',
            'sky quality',
          ],
          build: (isMobile) => AdaptiveConditionsSettings(isMobile: isMobile),
        ),
        // The darks and bias the night's lights need, taken when imaging
        // ends. Before the Darkroom because its masters feed that pass.
        SettingsSectionDef(
          key: 'end-of-night-calibration',
          label: 'End-of-night calibration',
          icon: LucideIcons.moonStar,
          keywords: const [
            'darks',
            'bias',
            'calibration',
            'dark library',
            'master dark',
            'end of night',
            'dawn',
            'cap',
            'warm up',
            'unattended',
          ],
          build: (isMobile) =>
              EndOfNightCalibrationSettings(isMobile: isMobile),
        ),
        // The night-end automation lives in the Darkroom's Activity tab; this
        // entry, beside Delivery, takes the operator there.
        SettingsSectionDef(
          key: 'darkroom',
          label: 'Night-end automation',
          icon: LucideIcons.sparkles,
          keywords: const [
            'darkroom',
            'autopilot',
            'auto-integrate',
            'auto integrate',
            'post-session',
            'masters',
            'build masters',
            'dawn',
            'morning message',
            'delivery',
            'night end',
            'unattended',
          ],
          build: (isMobile) => DarkroomAutopilotSettings(isMobile: isMobile),
        ),
        // Where the night's masters, draft render and report leave the rig —
        // the tail of the unattended night, so it sits with the rest of it
        // rather than under Advanced between the Log Viewer and Replay Debug.
        SettingsSectionDef(
          key: 'delivery',
          label: 'Delivery',
          icon: LucideIcons.send,
          keywords: const [
            'delivery',
            'destination',
            'watched folder',
            'sftp',
            'nas',
            'copy',
            'artifacts',
            'masters',
            'peer',
            'pull',
          ],
          build: (isMobile) => DeliverySettings(isMobile: isMobile),
        ),
      ],
    ),
    SettingsGroupDef(
      title: 'Science',
      displayTitle: t('settingsGroupScience'),
      icon: LucideIcons.flaskConical,
      sections: [
        SettingsSectionDef(
          key: 'science',
          label: t('settingsScience'),
          icon: LucideIcons.flaskConical,
          keywords: const [
            'photometry',
            'astrometry',
            'measurements',
            'aavso',
            'variable stars',
            'science frames',
          ],
          build: (isMobile) => ScienceSettingsPage(isMobile: isMobile),
        ),
        SettingsSectionDef(
          key: 'observation-log',
          label: t('settingsObservationLog'),
          icon: LucideIcons.bookOpen,
          keywords: const [
            'log',
            'journal',
            'session notes',
            'records',
            'history',
          ],
          build: (isMobile) => const ObservationLogSettings(),
        ),
        SettingsSectionDef(
          key: 'observing-lists',
          label: t('settingsObservingLists'),
          icon: LucideIcons.list,
          keywords: const [
            'target list',
            'wishlist',
            'plan',
            'import',
            'export',
          ],
          build: (isMobile) => const ObservingListsSettings(),
        ),
      ],
    ),
    SettingsGroupDef(
      title: 'Notifications & Remote',
      displayTitle: t('settingsGroupNotificationsRemote'),
      icon: LucideIcons.bell,
      sections: [
        SettingsSectionDef(
          key: 'notifications',
          label: t('settingsNotifications'),
          icon: LucideIcons.bell,
          keywords: const [
            'alerts',
            'push',
            'pushover',
            'discord',
            'routing',
            'channels',
            'per-category',
            'email',
          ],
          // NotificationSettings already embeds the per-event routing matrix
          // (NotificationRoutingSettings), so the `notification-routing` alias
          // resolves here and the page surfaces both — no second stack needed.
          build: (isMobile) => NotificationSettings(isMobile: isMobile),
        ),
        SettingsSectionDef(
          key: 'integrations',
          label: t('settingsIntegrations'),
          icon: LucideIcons.puzzle,
          keywords: const [
            'plugins',
            'discord',
            'pushover',
            'home assistant',
            'webhook',
            'third-party',
          ],
          build: (isMobile) => IntegrationsSettings(isMobile: isMobile),
        ),
        SettingsSectionDef(
          key: 'remote-access',
          label: t('settingsRemoteAccess'),
          icon: LucideIcons.globe,
          keywords: const [
            'remote control',
            'pairing',
            'discovery',
            'mobile',
            'web',
            'encryption',
            'companion',
          ],
          build: (isMobile) => RemoteAccessSettings(isMobile: isMobile),
        ),
      ],
    ),
    SettingsGroupDef(
      title: 'Advanced',
      displayTitle: t('settingsGroupAdvanced'),
      icon: LucideIcons.bug,
      sections: [
        SettingsSectionDef(
          key: 'logs',
          label: t('settingsLogs'),
          icon: LucideIcons.fileText,
          keywords: const [
            'log viewer',
            'diagnostics',
            'debug log',
            'errors',
            'verbosity',
          ],
          build: (isMobile) => LogViewer(isMobile: isMobile),
        ),
        SettingsSectionDef(
          key: 'backup',
          label: 'Backup & restore',
          icon: LucideIcons.archive,
          keywords: const [
            'backup',
            'restore',
            'export',
            'import',
            'snapshot',
            'database',
            'migrate',
          ],
          build: (isMobile) => const BackupScreen(),
        ),
        SettingsSectionDef(
          key: 'updates',
          label: 'Appliance updates',
          icon: LucideIcons.downloadCloud,
          keywords: const [
            'update',
            'ota',
            'upgrade',
            'firmware',
            'version',
            'rollback',
            'appliance',
          ],
          build: (isMobile) => UpdateSettings(isMobile: isMobile),
        ),
        SettingsSectionDef(
          key: 'rig-catalogs',
          label: 'Appliance catalogs',
          icon: LucideIcons.library,
          keywords: const [
            'catalog',
            'plate solve',
            'star catalog',
            'astrometry',
            'download catalog',
            'appliance',
            'rig',
          ],
          build: (isMobile) => RigCatalogSettings(isMobile: isMobile),
        ),
        SettingsSectionDef(
          key: 'captured-images',
          label: 'Captured images',
          icon: LucideIcons.image,
          keywords: const [
            'gallery',
            'images',
            'frames',
            'captures',
            'thumbnails',
            'photos',
            'appliance',
          ],
          build: (isMobile) => CapturedImagesSettings(isMobile: isMobile),
        ),
        SettingsSectionDef(
          key: 'replay-debug',
          label: t('settingsReplayDebug'),
          icon: LucideIcons.bug,
          keywords: const [
            'replay',
            'debug',
            'session replay',
            'recording',
            'developer',
          ],
          build: (isMobile) => ReplayDebugSettings(isMobile: isMobile),
        ),
      ],
    ),
  ];
}

/// Stable deep-link keys that point at a different section than their own key
/// because the source section was merged away. Old `?section=<key>` URLs and
/// in-app buttons must still land somewhere sensible.
const Map<String, String> kMergedSectionAliases = {
  // Files & Storage = file-paths + auto-save
  'file-paths': 'files-storage',
  'auto-save': 'files-storage',
  // Autofocus = autofocus + predictive-af
  'predictive-af': 'autofocus',
  'focus-model': 'autofocus',
  // Notifications = notifications + notification-routing
  'notification-routing': 'notifications',
  // Calibration, Dark library and Calibration library moved to the
  // Darkroom's Calibration tab; the Calibration entry redirects there.
  'dark-library': 'calibration',
  'calibration-library': 'calibration',
};

/// Resolves a deep-link [key] (including merged-away aliases) to the section
/// that should open, or `null` if no section matches.
SettingsSectionDef? resolveSection(
  List<SettingsGroupDef> groups,
  String? key,
) {
  final resolvedKey = resolveSectionKey(key);
  if (resolvedKey == null) return null;
  for (final group in groups) {
    for (final section in group.sections) {
      if (section.key == resolvedKey) return section;
    }
  }
  return null;
}

/// Resolves a deep-link [key] (including merged-away aliases) to the stable
/// section key that should open, or `null` if [key] is null or unknown.
///
/// Locale-independent (no [BuildContext] / labels), so it is safe to call from
/// `initState` before the first build.
String? resolveSectionKey(String? key) {
  if (key == null) return null;
  final target = kMergedSectionAliases[key] ?? key;
  for (final group in _structuralGroups) {
    if (group.contains(target)) return target;
  }
  return null;
}

/// The stable key of the very first section (the default selection / fallback).
const String kFirstSectionKey = 'general';

/// Group titles in structural order. These are fixed English literals (not
/// localized), kept in lock-step with [buildSettingsGroups] and
/// [_structuralGroups]. Locale-independent so callers in `initState` can resolve
/// a section's owning group without a [BuildContext].
const List<String> kGroupTitles = [
  'General',
  'Equipment',
  'Imaging',
  'Automation & Safety',
  'Science',
  'Notifications & Remote',
  'Advanced',
];

/// The structural group title that contains [key], or the first group's title
/// if [key] is not found. Locale-independent.
String groupTitleForKey(String key) {
  for (var i = 0; i < _structuralGroups.length; i++) {
    if (_structuralGroups[i].contains(key)) return kGroupTitles[i];
  }
  return kGroupTitles.first;
}

/// Backward-compatible derived index map.
///
/// Selection is driven by KEY internally; this exists only so external code
/// (and the navigation-contract tests) that still reads an integer index keeps
/// compiling. The index is the section's flat position across all groups, which
/// is stable for a given catalog ordering. Merged-away aliases resolve to their
/// combined section's index.
final Map<String, int> kSettingsSectionIndex = _deriveSectionIndex();

Map<String, int> _deriveSectionIndex() {
  // The flat ordering is independent of locale, so a label-free traversal of
  // the catalog structure is sufficient and avoids needing a BuildContext.
  final flatKeys = <String>[];
  for (final group in _structuralGroups) {
    for (final key in group) {
      flatKeys.add(key);
    }
  }
  final map = <String, int>{};
  for (var i = 0; i < flatKeys.length; i++) {
    map[flatKeys[i]] = i;
  }
  // Merged-away aliases share their combined section's index.
  kMergedSectionAliases.forEach((alias, target) {
    final index = map[target];
    if (index != null) map[alias] = index;
  });
  return map;
}

/// The catalog's structural ordering (group -> section keys), kept in lock-step
/// with [buildSettingsGroups]. Used only to derive [kSettingsSectionIndex]
/// without a [BuildContext].
const List<List<String>> _structuralGroups = [
  ['general', 'appearance', 'location', 'files-storage', 'help', 'about'],
  [
    'connection',
    'equipment-profiles',
    'phd2-guiding',
    'plate-solving',
    'autofocus',
    'calibration',
  ],
  [
    'imaging',
    'adaptive-exposure',
    'image-grading',
    'annotations',
    'catalogs',
  ],
  [
    'sequencer',
    'preflight',
    'weather-safety',
    'adaptive-conditions',
    'end-of-night-calibration',
    'darkroom',
    'delivery',
  ],
  ['science', 'observation-log', 'observing-lists'],
  ['notifications', 'integrations', 'remote-access'],
  [
    'logs',
    'backup',
    'updates',
    'rig-catalogs',
    'captured-images',
    'focus-model',
    'replay-debug',
  ],
];
