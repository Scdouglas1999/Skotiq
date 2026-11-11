import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../localization/skotiq_localizations.dart';
import 'catalog_settings_screen.dart';
import 'delivery_settings.dart';
import '../equipment/widgets/profiles_manager.dart';
import 'settings_search_index.g.dart';
import 'settings_sections.dart';
import 'integrations_settings.dart';
import 'backup_screen.dart';
import 'merged_sections.dart';
import 'widgets/adaptive_conditions_settings.dart';
import 'widgets/adaptive_exposure_settings.dart';
import 'widgets/about_settings.dart';
import 'widgets/captured_images_settings.dart';
import 'widgets/rig_catalog_settings.dart';
import 'widgets/settings_widgets.dart' show SettingsFormScope;
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

export 'settings_sections.dart';

/// One Settings section as the screen shows it: its identity plus the label
/// in the current language, its icon, its search synonyms and its page.
class SettingsSectionDef {
  final SettingsSectionId id;

  /// Display label in the current language.
  final String label;

  final IconData icon;

  /// Hand-written synonyms: terms a user might type that appear nowhere in the
  /// section's own text ('dark mode' for Appearance, 'ASCOM' for a page headed
  /// 'Drivers', 'capture folder' for a row titled 'Image output').
  ///
  /// The rendered row titles are not listed here; they come from
  /// [kSettingsSearchTerms], which is generated from the section widgets.
  /// Kept small and deliberate: a synonym that is too generous makes the
  /// search match everything.
  final List<String> keywords;

  /// Builds the detail pane. The form factor comes from the enclosing
  /// [SettingsFormScope].
  final WidgetBuilder build;

  const SettingsSectionDef({
    required this.id,
    required this.label,
    required this.icon,
    required this.build,
    this.keywords = const [],
  });

  /// The stable deep-link key, e.g. `'location'`.
  String get key => id.key;

  /// True if [query] (already lower-cased) matches this section's title, one
  /// of its synonyms, or the title of any row it renders.
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

/// A group of [SettingsSectionDef]s in the sidebar.
class SettingsGroupDef {
  final SettingsGroupId id;

  /// What the user reads, in the current language.
  final String displayTitle;

  final IconData icon;
  final List<SettingsSectionDef> sections;

  const SettingsGroupDef({
    required this.id,
    required this.displayTitle,
    required this.icon,
    required this.sections,
  });

  /// English name; an identifier, not for display.
  String get title => id.title;
}

/// The Settings catalog in the current language.
///
/// Structure (which sections exist, their groups and order) comes from
/// [SettingsSectionId] alone. This only attaches what the screen shows for
/// each one, and the `switch` in [_sectionDef] is exhaustive, so a section
/// cannot be declared without a page or shown without being declared.
List<SettingsGroupDef> buildSettingsGroups(BuildContext context) {
  final l10n = context.l10n;
  String t(String key) => l10n.text(key);

  return [
    for (final group in SettingsGroupId.values)
      SettingsGroupDef(
        id: group,
        displayTitle: t(group.titleKey),
        icon: _groupIcon(group),
        sections: [
          for (final id in group.sections) _sectionDef(id, t),
        ],
      ),
  ];
}

IconData _groupIcon(SettingsGroupId group) => switch (group) {
      SettingsGroupId.general => LucideIcons.settings,
      SettingsGroupId.equipment => LucideIcons.boxes,
      SettingsGroupId.imaging => LucideIcons.camera,
      SettingsGroupId.automationSafety => LucideIcons.listOrdered,
      SettingsGroupId.science => LucideIcons.flaskConical,
      SettingsGroupId.notificationsRemote => LucideIcons.bell,
      SettingsGroupId.advanced => LucideIcons.bug,
    };

SettingsSectionDef _sectionDef(
  SettingsSectionId id,
  String Function(String key) t,
) {
  return switch (id) {
    SettingsSectionId.general => SettingsSectionDef(
        id: id,
        label: t('settingsGeneral'),
        icon: LucideIcons.settings,
        keywords: const [
          'language',
          'units',
          'startup',
          'defaults',
          'time format',
        ],
        build: (context) =>
            GeneralSettings(isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.appearance => SettingsSectionDef(
        id: id,
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
        build: (context) =>
            AppearanceSettings(isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.location => SettingsSectionDef(
        id: id,
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
        build: (context) => LocationSettingsPage(
            isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.filesStorage => SettingsSectionDef(
        id: id,
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

          // The Dashboard says "capture directory" and the status bar "save
          // path" for the row this page titles "Image output".
          'capture folder',
          'capture directory',
          'save path',
          'image folder',
          'disk space',
          'free space',
          'storage location',
        ],
        build: (context) => FilesAndStorageSettings(
            isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.help => SettingsSectionDef(
        id: id,
        label: t('settingsHelpTutorials'),
        icon: LucideIcons.helpCircle,
        keywords: const [
          'tutorials',
          'tours',
          'guides',
          'walkthrough',
          'onboarding',
        ],
        build: (context) => HelpTutorialsSettings(
            isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.about => SettingsSectionDef(
        id: id,
        label: t('settingsAbout'),
        icon: LucideIcons.info,
        keywords: const [
          'version',
          'license',
          'credits',
          'updates',
          'build',
        ],
        build: (context) =>
            AboutSettings(isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.connection => SettingsSectionDef(
        id: id,
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
        build: (context) =>
            ConnectionSettings(isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.equipmentProfiles => SettingsSectionDef(
        id: id,
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
        build: (context) => const ProfilesManager(),
      ),
    SettingsSectionId.phd2Guiding => SettingsSectionDef(
        id: id,
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
        build: (context) => Phd2GuidingSettings(
            isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.plateSolving => SettingsSectionDef(
        id: id,
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
        build: (context) => PlateSolvingSettings(
            isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.autofocus => SettingsSectionDef(
        id: id,
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
        build: (context) => AutofocusMergedSettings(
            isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.calibration => SettingsSectionDef(
        id: id,
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
        build: (context) => CalibrationSettingsRedirect(
            isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.imaging => SettingsSectionDef(
        id: id,
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
        build: (context) =>
            ImagingSettings(isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.adaptiveExposure => SettingsSectionDef(
        id: id,
        label: t('settingsAdaptiveExposure'),
        icon: LucideIcons.sun,
        keywords: const [
          'auto exposure',
          'sky background',
          'sub length',
          'optimization',
          'sky brightness',
        ],
        build: (context) => AdaptiveExposureSettings(
            isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.imageGrading => SettingsSectionDef(
        id: id,
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
        build: (context) => ImageGradingSettings(
            isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.annotations => SettingsSectionDef(
        id: id,
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
        build: (context) => AnnotationSettingsPage(
            isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.catalogs => SettingsSectionDef(
        id: id,
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
        build: (context) => CatalogSettingsScreen(
            isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.sequencer => SettingsSectionDef(
        id: id,
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
        build: (context) =>
            SequencerSettings(isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.preflight => SettingsSectionDef(
        id: id,
        label: t('settingsPreflight'),
        icon: LucideIcons.clipboardCheck,
        keywords: const [
          'preflight',
          'checklist',
          'readiness',
          'startup checks',
          'safety',
        ],
        build: (context) =>
            PreflightSettings(isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.weatherSafety => SettingsSectionDef(
        id: id,
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
        build: (context) => WeatherSafetySettings(
            isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.adaptiveConditions => SettingsSectionDef(
        id: id,
        label: t('settingsAdaptiveConditions'),
        icon: LucideIcons.cloud,
        keywords: const [
          'seeing',
          'transparency',
          'conditions',
          'adaptive',
          'sky quality',
        ],
        build: (context) => AdaptiveConditionsSettings(
            isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.endOfNightCalibration => SettingsSectionDef(
        id: id,
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
        build: (context) => EndOfNightCalibrationSettings(
            isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.darkroom => SettingsSectionDef(
        id: id,
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
        build: (context) => DarkroomAutopilotSettings(
            isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.delivery => SettingsSectionDef(
        id: id,
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
        build: (context) =>
            DeliverySettings(isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.science => SettingsSectionDef(
        id: id,
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
        build: (context) => ScienceSettingsPage(
            isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.observationLog => SettingsSectionDef(
        id: id,
        label: t('settingsObservationLog'),
        icon: LucideIcons.bookOpen,
        keywords: const [
          'log',
          'journal',
          'session notes',
          'records',
          'history',
        ],
        build: (context) => const ObservationLogSettings(),
      ),
    SettingsSectionId.observingLists => SettingsSectionDef(
        id: id,
        label: t('settingsObservingLists'),
        icon: LucideIcons.list,
        keywords: const [
          'target list',
          'wishlist',
          'plan',
          'import',
          'export',
        ],
        build: (context) => const ObservingListsSettings(),
      ),
    SettingsSectionId.notifications => SettingsSectionDef(
        id: id,
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
        build: (context) => NotificationSettings(
            isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.integrations => SettingsSectionDef(
        id: id,
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
        build: (context) => IntegrationsSettings(
            isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.remoteAccess => SettingsSectionDef(
        id: id,
        label: t('settingsRemoteAccess'),
        icon: LucideIcons.globe,
        keywords: const [
          'remote control',
          'imaging computer',
          'link',
          'connect',
          'use this computer',
          'pairing',
          'discovery',
          'mobile',
          'web',
          'encryption',
          'companion',
        ],
        build: (context) => RemoteAccessSettings(
            isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.logs => SettingsSectionDef(
        id: id,
        label: t('settingsLogs'),
        icon: LucideIcons.fileText,
        keywords: const [
          'log viewer',
          'diagnostics',
          'debug log',
          'errors',
          'verbosity',
        ],
        build: (context) =>
            LogViewer(isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.backup => SettingsSectionDef(
        id: id,
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
        build: (context) => const BackupScreen(),
      ),
    SettingsSectionId.updates => SettingsSectionDef(
        id: id,
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
        build: (context) =>
            UpdateSettings(isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.rigCatalogs => SettingsSectionDef(
        id: id,
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
        build: (context) =>
            RigCatalogSettings(isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.capturedImages => SettingsSectionDef(
        id: id,
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
        build: (context) => CapturedImagesSettings(
            isMobile: SettingsFormScope.isMobileOf(context)),
      ),
    SettingsSectionId.replayDebug => SettingsSectionDef(
        id: id,
        label: t('settingsReplayDebug'),
        icon: LucideIcons.bug,
        keywords: const [
          'replay',
          'debug',
          'session replay',
          'recording',
          'developer',
        ],
        build: (context) => ReplayDebugSettings(
            isMobile: SettingsFormScope.isMobileOf(context)),
      ),
  };
}
