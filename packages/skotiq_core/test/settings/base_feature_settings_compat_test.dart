// The settings these features keep in the `app_settings` key/value store must
// read and write the same rows as the build their declarations were moved
// from (c4386947c): calibration (dark library, defect map), meridian flip,
// polar alignment, the active planning project, the decision log, Science,
// transient alerts, notification routing, flats and the capture settings.
//
// `test/fixtures/settings/base_feature_settings.json` was produced by that
// build with `SKOTIQ_STORE_PINS_UPDATE=1`: for each feature, what it read from
// a set of stored rows (well-formed, missing, and text no build writes), and
// the rows each of its writes left behind.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart' hide Sequence;
import 'package:skotiq_core/src/models/alerts/transient_alert.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/models/defect_map.dart';
import 'package:skotiq_core/src/models/meridian_flip_settings.dart';
import 'package:skotiq_core/src/models/polar_alignment_config.dart';
import 'package:skotiq_core/src/models/notification/notification_categories.dart';
import 'package:skotiq_core/src/models/science/science_models.dart';
import 'package:skotiq_core/src/providers/dark_library_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/defect_map_provider.dart';
import 'package:skotiq_core/src/providers/flat_wizard_provider.dart';
import 'package:skotiq_core/src/providers/imaging_provider.dart';
import 'package:skotiq_core/src/providers/meridian_flip_provider.dart';
import 'package:skotiq_core/src/providers/notification_router_provider.dart';
import 'package:skotiq_core/src/providers/planning_provider.dart';
import 'package:skotiq_core/src/providers/polar_alignment_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';
import 'package:skotiq_core/src/providers/replay_debug_provider.dart';
import 'package:skotiq_core/src/providers/science_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart'
    show autoConnectSettingsProvider;
import 'package:skotiq_core/src/providers/transient_alert_provider.dart';

const _fixturePath = 'test/fixtures/settings/base_feature_settings.json';

class _Probe {
  const _Probe({
    required this.name,
    required this.keys,
    required this.read,
    this.rowSets = const {},
    this.writes = const {},
    this.overrides = const [],
  });

  final String name;

  /// Every row the feature reads or writes.
  final List<String> keys;

  /// What the feature holds, as JSON, once it has loaded.
  final Future<Object?> Function(ProviderContainer container) read;

  /// Stored rows to read from, by label. Every probe is also read with none
  /// of its rows stored.
  final Map<String, Map<String, String>> rowSets;

  /// Writes through the feature's own API, by label. Each runs on a store
  /// holding none of the feature's rows, after the ones before it.
  final Map<String, Future<void> Function(ProviderContainer container)> writes;

  final List<Override> overrides;
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 40));

Future<Object?> _capture(Future<Object?> Function() read) async {
  try {
    return await read();
  } catch (error) {
    return {'error': error.runtimeType.toString()};
  }
}

Map<String, Object?> _science(ScienceSettings s) => {
  'advancedModeEnabled': s.advancedModeEnabled,
  'overlayEnabled': s.overlayEnabled,
  'photometryEnabled': s.photometryEnabled,
  'photometricCalibrationEnabled': s.photometricCalibrationEnabled,
  'transparencyEnabled': s.transparencyEnabled,
  'psfMapEnabled': s.psfMapEnabled,
  'astrometricResidualsEnabled': s.astrometricResidualsEnabled,
  'movingObjectsEnabled': s.movingObjectsEnabled,
  'skyAtlasEnabled': s.skyAtlasEnabled,
  'skyAtlasLimitGb': s.skyAtlasLimitGb,
  'narrowbandRatiosEnabled': s.narrowbandRatiosEnabled,
  'frameQualityMapsEnabled': s.frameQualityMapsEnabled,
  'surface3dEnabled': s.surface3dEnabled,
  'manualPurgeOnly': s.manualPurgeOnly,
  'fitsHeaderWritebackEnabled': s.fitsHeaderWritebackEnabled,
  'mpcObservatoryCode': s.mpcObservatoryCode,
  'aavsoObserverCode': s.aavsoObserverCode,
  'observerName': s.observerName,
  'mpcAstrometricCatalog': s.mpcAstrometricCatalog,
  'tnsBotId': s.tnsBotId,
  'tnsBotName': s.tnsBotName,
  'tnsReportingGroupId': s.tnsReportingGroupId,
  'tnsDataSourceId': s.tnsDataSourceId,
  'tnsReporterName': s.tnsReporterName,
  'tnsUseSandbox': s.tnsUseSandbox,
  'autoFrameGradingEnabled': s.autoFrameGradingEnabled,
  'frameGradeRulesJson': s.frameGradeRulesJson,
  'scienceGuideCollapsed': s.scienceGuideCollapsed,
};

const _scienceKeys = [
  'science.advanced_mode.enabled',
  'science.overlay.enabled',
  'science.feature.photometry',
  'science.feature.photometric_calibration',
  'science.feature.transparency',
  'science.feature.psf_map',
  'science.feature.astrometric_residuals',
  'science.feature.moving_objects',
  'science.feature.narrowband_ratios',
  'science.feature.frame_quality_maps',
  'science.feature.surface3d',
  'science.feature.sky_atlas',
  'science.sky_atlas.limit_gb',
  'science.retention.manual_purge_only',
  'science.writeback.fits_header_enabled',
  'science.mpc.observatory_code',
  'science.aavso.observer_code',
  'science.observer.name',
  'science.mpc.ast_cat',
  'science.tns.bot_id',
  'science.tns.bot_name',
  'science.tns.group_id',
  'science.tns.source_id',
  'science.tns.reporter',
  'science.tns.use_sandbox',
  'science.grading.auto_enabled',
  'science.grading.rules_json',
  'science.guide.collapsed',
  'image_grading_enabled',
];

const _scienceBoolKeys = [
  'science.advanced_mode.enabled',
  'science.overlay.enabled',
  'science.feature.photometry',
  'science.feature.photometric_calibration',
  'science.feature.transparency',
  'science.feature.psf_map',
  'science.feature.astrometric_residuals',
  'science.feature.moving_objects',
  'science.feature.narrowband_ratios',
  'science.feature.frame_quality_maps',
  'science.feature.surface3d',
  'science.feature.sky_atlas',
  'science.retention.manual_purge_only',
  'science.writeback.fits_header_enabled',
  'science.tns.use_sandbox',
  'science.grading.auto_enabled',
  'science.guide.collapsed',
];

Map<String, String> _allScienceBools(String text) => {
  for (final key in _scienceBoolKeys) key: text,
};

const _vizKeys = [
  'science.overlay.opacity',
  'science.overlay.live_grid_rows',
  'science.overlay.live_grid_cols',
  'science.overlay.analysis_grid_rows',
  'science.overlay.analysis_grid_cols',
];

Map<String, Object?> _viz(ScienceVisualizationPrefs p) => {
  'overlayOpacity': p.overlayOpacity,
  'liveGridRows': p.liveGridRows,
  'liveGridCols': p.liveGridCols,
  'analysisGridRows': p.analysisGridRows,
  'analysisGridCols': p.analysisGridCols,
};

const _photometryKeys = [
  'science.photometry.differential_active',
  'science.photometry.target_anchor',
  'science.photometry.comparison_anchors',
];

const _anchorA = PhotometryAnchor(
  objectId: 'a',
  label: 'A',
  raDegrees: 10.5,
  decDegrees: -3.25,
);
const _anchorB = PhotometryAnchor(
  objectId: 'b',
  label: 'B',
  raDegrees: 11,
  decDegrees: 4,
);

Map<String, Object?> _photometry(SciencePhotometrySelection s) => {
  'differentialEnabled': s.differentialEnabled,
  'target': s.target?.toJson(),
  'comparisons': [for (final c in s.comparisons) c.toJson()],
};

const _transientKeys = [
  'transient_alert_enabled_sources',
  'transient_alert_types_to_monitor',
  'transient_alert_magnitude_threshold',
  'transient_alert_notify_on_new',
  'transient_alert_auto_queue_bright',
  'transient_alert_auto_queue_magnitude',
];

Map<String, Object?> _transient(TransientAlertSettings s) => {
  'enabledSources': [for (final v in s.enabledSources) v.name]..sort(),
  'typesToMonitor': [for (final v in s.typesToMonitor) v.name]..sort(),
  'magnitudeThreshold': s.magnitudeThreshold,
  'notifyOnNew': s.notifyOnNew,
  'autoQueueBright': s.autoQueueBright,
  'autoQueueMagnitude': s.autoQueueMagnitude,
};

Future<TransientAlertSettings> _transientSettings(ProviderContainer c) async {
  await c.read(transientAlertSettingsProvider.notifier).loaded;
  return c.read(transientAlertSettingsProvider);
}

const _transientStateKeys = [
  'transient_alert_state_at2026abc',
  'transient_alert_state_sn2026xy',
];

Map<String, Object?> _defectMap(DefectMapSettings s) => {
  'autoApply': s.autoApply,
  'method': s.method.wireValue,
  'kernel': s.kernel.diameter,
  'saveOriginal': s.saveOriginal,
  'loadError': s.loadError?.runtimeType.toString(),
};

Future<DefectMapSettings> _defectMapSettings(ProviderContainer c) async {
  await c.read(defectMapSettingsProvider.notifier).loaded;
  await _settle();
  return c.read(defectMapSettingsProvider);
}

const _defectMapKeys = [
  'defectMap.autoApply',
  'defectMap.method',
  'defectMap.kernelDiameter',
  'defectMap.saveOriginal',
];

const _profile = EquipmentProfileModel(id: 1, name: 'Rig');
const _captureKey = 'imaging_capture_settings_profile_1';

Map<String, Object?> _exposure(ExposureSettings s) => {
  'exposureTime': s.exposureTime,
  'gain': s.gain,
  'offset': s.offset,
  'binningX': s.binningX,
  'binningY': s.binningY,
  'filter': s.filter,
  'frameType': s.frameType.name,
};

Future<ExposureSettings> _exposureSettings(ProviderContainer c) async {
  c.listen(syncExposureFromProfileProvider, (_, __) {});
  await _settle();
  return c.read(exposureSettingsProvider);
}

final _probes = <_Probe>[
  _Probe(
    name: 'dark library tolerances',
    keys: const [
      'dark_library.exposure_tolerance',
      'dark_library.temp_tolerance',
    ],
    read: (c) async {
      await c.read(allSettingsProvider.future);
      final t = c.read(darkLibraryMatchTolerancesProvider);
      return {'exposureSecs': t.exposureSecs, 'temperatureC': t.temperatureC};
    },
    rowSets: const {
      'stored': {
        'dark_library.exposure_tolerance': '0.25',
        'dark_library.temp_tolerance': '2.0',
      },
      'whole numbers': {
        'dark_library.exposure_tolerance': '1',
        'dark_library.temp_tolerance': '3',
      },
      'unreadable': {'dark_library.temp_tolerance': 'warm'},
      'empty': {'dark_library.exposure_tolerance': ''},
      'negative': {'dark_library.temp_tolerance': '-1'},
    },
  ),
  _Probe(
    name: 'dark library settings',
    keys: const ['dark_library.temp_tolerance', 'calibration.auto_calibrate'],
    read: (c) async {
      final s = await c.read(darkLibrarySettingsProvider.future);
      return {
        'autoCalibrate': s.autoCalibrate,
        'temperatureTolerance': s.temperatureTolerance,
      };
    },
    rowSets: const {
      'stored': {
        'dark_library.temp_tolerance': '2.0',
        'calibration.auto_calibrate': 'true',
      },
      'unreadable': {
        'dark_library.temp_tolerance': 'warm',
        'calibration.auto_calibrate': 'TRUE',
      },
      'empty': {'dark_library.temp_tolerance': ''},
    },
    writes: {
      'tolerance 3.5': (c) => c
          .read(darkLibrarySettingsActionsProvider)
          .setTemperatureTolerance(3.5),
      'tolerance 4': (c) =>
          c.read(darkLibrarySettingsActionsProvider).setTemperatureTolerance(4),
    },
  ),
  _Probe(
    name: 'defect map',
    keys: _defectMapKeys,
    read: (c) async => _defectMap(await _defectMapSettings(c)),
    rowSets: const {
      'stored': {
        'defectMap.autoApply': 'true',
        'defectMap.method': 'mean',
        'defectMap.kernelDiameter': '5',
        'defectMap.saveOriginal': 'true',
      },
      'off': {
        'defectMap.autoApply': 'false',
        'defectMap.saveOriginal': 'false',
      },
      'unreadable': {
        'defectMap.autoApply': '1',
        'defectMap.method': 'gaussian',
        'defectMap.kernelDiameter': 'big',
        'defectMap.saveOriginal': 'TRUE',
      },
      'empty': {
        'defectMap.autoApply': '',
        'defectMap.method': '',
        'defectMap.kernelDiameter': '',
        'defectMap.saveOriginal': '',
      },
      'unknown kernel': {'defectMap.kernelDiameter': '4'},
    },
    writes: {
      'auto apply on': (c) async {
        await _defectMapSettings(c);
        await c.read(defectMapSettingsProvider.notifier).setAutoApply(true);
      },
      'method and kernel': (c) async {
        final notifier = c.read(defectMapSettingsProvider.notifier);
        await notifier.setMethod(DefectMapMethod.values.last);
        await notifier.setKernel(DefectMapKernelSize.values.last);
      },
      'keep the original': (c) =>
          c.read(defectMapSettingsProvider.notifier).setSaveOriginal(true),
      'auto apply off': (c) =>
          c.read(defectMapSettingsProvider.notifier).setAutoApply(false),
    },
  ),
  _Probe(
    name: 'meridian flip',
    keys: const ['meridian_flip_settings'],
    read: (c) async {
      final notifier = c.read(globalMeridianFlipSettingsProvider.notifier);
      await notifier.ensureLoaded();
      return c.read(globalMeridianFlipSettingsProvider).toJson();
    },
    rowSets: {
      'stored': {
        'meridian_flip_settings': jsonEncode(
          const MeridianFlipSettings().copyWith(minutesPastMeridian: 12),
        ),
      },
      'one field': const {
        'meridian_flip_settings': '{"minutesPastMeridian":7.5}',
      },
      'empty': const {'meridian_flip_settings': ''},
      'not json': const {'meridian_flip_settings': 'flip'},
      'not an object': const {'meridian_flip_settings': '[1]'},
    },
    writes: {
      'minutes after 9': (c) async {
        final notifier = c.read(globalMeridianFlipSettingsProvider.notifier);
        await notifier.ensureLoaded();
        await notifier.updateSettings(
          c
              .read(globalMeridianFlipSettingsProvider)
              .copyWith(minutesPastMeridian: 9),
        );
      },
      'back to the default': (c) => c
          .read(globalMeridianFlipSettingsProvider.notifier)
          .updateSettings(const MeridianFlipSettings()),
    },
  ),
  _Probe(
    name: 'polar alignment config',
    keys: const ['polar_alignment_config'],
    read: (c) async {
      c.read(polarAlignmentConfigProvider);
      await _settle();
      return c.read(polarAlignmentConfigProvider).toJson();
    },
    rowSets: {
      'stored': {
        'polar_alignment_config': jsonEncode(
          const PolarAlignmentConfig().copyWith(exposureTime: 7.5).toJson(),
        ),
      },
      'empty': const {'polar_alignment_config': ''},
      'not json': const {'polar_alignment_config': 'polar'},
    },
    writes: {
      'exposure 4': (c) async {
        c.read(polarAlignmentConfigProvider);
        await _settle();
        await c
            .read(polarAlignmentConfigProvider.notifier)
            .updateConfig(const PolarAlignmentConfig().copyWith(exposureTime: 4));
      },
    },
  ),
  _Probe(
    name: 'active planning project',
    keys: const ['planning.active_project_id'],
    read: (c) async {
      await c.read(activeProjectIdProvider.notifier).loaded;
      return c.read(activeProjectIdProvider);
    },
    rowSets: const {
      'stored': {'planning.active_project_id': '12'},
      'spaces': {'planning.active_project_id': ' 12 '},
      'empty': {'planning.active_project_id': ''},
      'zero': {'planning.active_project_id': '0'},
      'not a number': {'planning.active_project_id': 'm31'},
    },
    writes: {
      'choose 7': (c) async {
        await c.read(activeProjectIdProvider.notifier).loaded;
        await c.read(activeProjectIdProvider.notifier).setActiveProject(7);
      },
      'choose none': (c) =>
          c.read(activeProjectIdProvider.notifier).setActiveProject(null),
    },
  ),
  _Probe(
    name: 'decision log',
    keys: const ['replay_debug.enabled', 'replay_debug.retention_days'],
    read: (c) async => {
      'enabled': await _capture(
        () => c.read(replayDebugEnabledProvider.future),
      ),
      'retentionDays': await _capture(
        () => c.read(replayDebugRetentionDaysProvider.future),
      ),
    },
    rowSets: const {
      'stored': {
        'replay_debug.enabled': 'false',
        'replay_debug.retention_days': '30',
      },
      'on': {'replay_debug.enabled': 'true'},
      'upper case and spaces': {
        'replay_debug.enabled': ' FALSE ',
        'replay_debug.retention_days': ' 45 ',
      },
      'unreadable': {
        'replay_debug.enabled': 'yes',
        'replay_debug.retention_days': 'month',
      },
      'empty': {
        'replay_debug.enabled': '',
        'replay_debug.retention_days': '',
      },
      'out of range': {'replay_debug.retention_days': '0'},
      'too long': {'replay_debug.retention_days': '4000'},
    },
  ),
  _Probe(
    name: 'science settings',
    keys: _scienceKeys,
    read: (c) async => _science(await c.read(scienceSettingsProvider.future)),
    rowSets: {
      'all on': _allScienceBools('true'),
      'all off': _allScienceBools('false'),
      'upper case': _allScienceBools('TRUE'),
      'empty': {
        ..._allScienceBools(''),
        'science.sky_atlas.limit_gb': '',
        'science.tns.bot_id': '',
        'science.grading.rules_json': '',
      },
      'unreadable switch': const {'science.feature.photometry': 'yes'},
      'unreadable number': const {'science.tns.bot_id': 'bot'},
      'identity': const {
        'science.mpc.observatory_code': 'G40',
        'science.aavso.observer_code': 'XYZ',
        'science.observer.name': ' A. Observer ',
        'science.mpc.ast_cat': 'Gaia3',
        'science.tns.bot_id': '1234',
        'science.tns.bot_name': 'bot',
        'science.tns.group_id': '5',
        'science.tns.source_id': '6',
        'science.tns.reporter': 'A. Observer',
        'science.sky_atlas.limit_gb': '50',
        'science.grading.rules_json': '{"maxHfr":4.0}',
      },
      'atlas limit': const {'science.sky_atlas.limit_gb': '-3'},
      'atlas limit text': const {'science.sky_atlas.limit_gb': 'lots'},
      'grading by the older switch': const {'image_grading_enabled': 'true'},
    },
    writes: {
      'advanced on': (c) async {
        await c.read(scienceSettingsProvider.future);
        await c
            .read(scienceSettingsProvider.notifier)
            .setAdvancedModeEnabled(true);
      },
      'photometry off': (c) => c
          .read(scienceSettingsProvider.notifier)
          .setFeatureEnabled(ScienceFeature.photometry, false),
      'sky atlas on, 80 GB': (c) async {
        final notifier = c.read(scienceSettingsProvider.notifier);
        await notifier.setFeatureEnabled(ScienceFeature.skyAtlas, true);
        await notifier.setSkyAtlasLimitGb(80);
      },
      'negative atlas limit': (c) =>
          c.read(scienceSettingsProvider.notifier).setSkyAtlasLimitGb(-5),
      'identity': (c) async {
        final notifier = c.read(scienceSettingsProvider.notifier);
        await notifier.setMpcObservatoryCode('G40');
        await notifier.setAavsoObserverCode('XYZ');
        await notifier.setObserverName('A. Observer');
        await notifier.setMpcAstrometricCatalog('Gaia3');
        await notifier.setTnsBotId(1234);
        await notifier.setTnsBotName('bot');
        await notifier.setTnsReportingGroupId(5);
        await notifier.setTnsDataSourceId(6);
        await notifier.setTnsReporterName('A. Observer');
        await notifier.setTnsUseSandbox(true);
      },
      'the rest': (c) async {
        final notifier = c.read(scienceSettingsProvider.notifier);
        await notifier.setOverlayEnabled(false);
        await notifier.setFitsHeaderWritebackEnabled(false);
        await notifier.setScienceGuideCollapsed(true);
        for (final feature in ScienceFeature.values) {
          await notifier.setFeatureEnabled(feature, true);
        }
      },
    },
  ),
  _Probe(
    name: 'science overlay grid',
    keys: _vizKeys,
    read: (c) async =>
        _viz(await c.read(scienceVisualizationPrefsProvider.future)),
    rowSets: const {
      'stored': {
        'science.overlay.opacity': '0.5',
        'science.overlay.live_grid_rows': '8',
        'science.overlay.live_grid_cols': '10',
        'science.overlay.analysis_grid_rows': '48',
        'science.overlay.analysis_grid_cols': '64',
      },
      'out of range': {
        'science.overlay.opacity': '2',
        'science.overlay.live_grid_rows': '1',
        'science.overlay.live_grid_cols': '500',
        'science.overlay.analysis_grid_rows': '0',
        'science.overlay.analysis_grid_cols': '97',
      },
      'empty': {
        'science.overlay.opacity': '',
        'science.overlay.live_grid_rows': '',
      },
      'unreadable opacity': {'science.overlay.opacity': 'half'},
      'unreadable rows': {'science.overlay.live_grid_rows': '8.5'},
    },
    writes: {
      'save': (c) async {
        await c.read(scienceVisualizationPrefsProvider.future);
        await c
            .read(scienceVisualizationPrefsProvider.notifier)
            .savePrefs(
              const ScienceVisualizationPrefs(
                overlayOpacity: 0.6,
                liveGridRows: 6,
                liveGridCols: 8,
                analysisGridRows: 30,
                analysisGridCols: 40,
              ),
            );
      },
    },
  ),
  _Probe(
    name: 'differential photometry selection',
    keys: _photometryKeys,
    read: (c) async =>
        _photometry(await c.read(sciencePhotometrySelectionProvider.future)),
    rowSets: {
      'stored': {
        'science.photometry.differential_active': 'true',
        'science.photometry.target_anchor': jsonEncode(_anchorA.toJson()),
        'science.photometry.comparison_anchors': jsonEncode([
          _anchorB.toJson(),
        ]),
      },
      'install rows': const {
        'science.photometry.differential_active': 'false',
        'science.photometry.target_anchor': '',
        'science.photometry.comparison_anchors': '[]',
      },
      'unreadable switch': const {
        'science.photometry.differential_active': 'on',
      },
      'unreadable anchors': const {
        'science.photometry.target_anchor': 'vega',
        'science.photometry.comparison_anchors': '{}',
      },
    },
    writes: {
      'turn on': (c) async {
        await c.read(sciencePhotometrySelectionProvider.future);
        await c
            .read(sciencePhotometrySelectionProvider.notifier)
            .setDifferentialEnabled(true);
      },
      'target and comparison': (c) async {
        final notifier = c.read(sciencePhotometrySelectionProvider.notifier);
        await notifier.setTarget(_anchorA);
        await notifier.toggleComparison(_anchorB);
      },
      'clear comparisons': (c) => c
          .read(sciencePhotometrySelectionProvider.notifier)
          .clearComparisons(),
      'clear target': (c) =>
          c.read(sciencePhotometrySelectionProvider.notifier).setTarget(null),
      'clear all': (c) =>
          c.read(sciencePhotometrySelectionProvider.notifier).clearAll(),
    },
  ),
  _Probe(
    name: 'transient alert settings',
    keys: _transientKeys,
    read: (c) async => _transient(await _transientSettings(c)),
    rowSets: const {
      'stored': {
        'transient_alert_enabled_sources': '["tns"]',
        'transient_alert_types_to_monitor': '["supernova","nova"]',
        'transient_alert_magnitude_threshold': '13.5',
        'transient_alert_notify_on_new': 'false',
        'transient_alert_auto_queue_bright': 'true',
        'transient_alert_auto_queue_magnitude': '11.0',
      },
      'upper case and spaces': {
        'transient_alert_notify_on_new': ' FALSE ',
        'transient_alert_auto_queue_bright': 'TRUE',
      },
      'unreadable': {
        'transient_alert_enabled_sources': 'tns',
        'transient_alert_types_to_monitor': '{"a":1}',
        'transient_alert_magnitude_threshold': 'bright',
        'transient_alert_notify_on_new': '1',
        'transient_alert_auto_queue_bright': 'yes',
        'transient_alert_auto_queue_magnitude': 'NaN',
      },
      'empty': {
        'transient_alert_enabled_sources': '',
        'transient_alert_types_to_monitor': '',
        'transient_alert_magnitude_threshold': '',
        'transient_alert_notify_on_new': '',
        'transient_alert_auto_queue_bright': '',
        'transient_alert_auto_queue_magnitude': '',
      },
      'no sources': {
        'transient_alert_enabled_sources': '[]',
        'transient_alert_types_to_monitor': '["unknownKind","nova"]',
      },
    },
    writes: {
      'magnitude 14': (c) async {
        await _transientSettings(c);
        await c
            .read(transientAlertSettingsProvider.notifier)
            .setMagnitudeThreshold(14);
      },
      'switches': (c) async {
        final notifier = c.read(transientAlertSettingsProvider.notifier);
        await notifier.setNotifyOnNew(false);
        await notifier.setAutoQueueBright(true);
        await notifier.setAutoQueueMagnitude(10.5);
      },
      'toggle a source': (c) => c
          .read(transientAlertSettingsProvider.notifier)
          .toggleSource(TransientSource.manual),
    },
  ),
  _Probe(
    name: 'transient alert states',
    keys: _transientStateKeys,
    read: (c) async {
      await c.read(transientAlertStatesProvider.notifier).loaded;
      final states = c.read(transientAlertStatesProvider);
      return {
        for (final key in states.keys.toList()..sort()) key: states[key]!.name,
      };
    },
    rowSets: const {
      'stored': {
        'transient_alert_state_at2026abc': 'acknowledged',
        'transient_alert_state_sn2026xy': 'dismissed',
      },
      'unknown state': {'transient_alert_state_at2026abc': 'snoozed'},
    },
    writes: {
      'acknowledge': (c) async {
        await c.read(transientAlertStatesProvider.notifier).loaded;
        await c
            .read(transientAlertStatesProvider.notifier)
            .acknowledge('at2026abc');
      },
      'dismiss another': (c) =>
          c.read(transientAlertStatesProvider.notifier).dismiss('sn2026xy'),
      'clear all': (c) =>
          c.read(transientAlertStatesProvider.notifier).clearAll(),
    },
  ),
  _Probe(
    name: 'notification routing',
    keys: const [
      'notification_routing_matrix',
      'notification_legacy_credentials_carried_v1',
    ],
    read: (c) async =>
        (await c.read(notificationRoutingMatrixProvider.future)).toJson(),
    rowSets: {
      'stored': {
        'notification_routing_matrix': jsonEncode(
          NotificationRoutingMatrix.defaults()
              .withRule(
                NotificationCategory.custom,
                const NotificationRoutingRule(
                  transports: [NotificationTransportKind.discord],
                ),
              )
              .toJson(),
        ),
        'notification_legacy_credentials_carried_v1': 'true',
      },
      'empty': const {'notification_routing_matrix': ''},
      'not json': const {'notification_routing_matrix': 'everything'},
    },
    writes: {
      'save': (c) async {
        final matrix = await c.read(notificationRoutingMatrixProvider.future);
        await c
            .read(notificationRoutingMatrixProvider.notifier)
            .save(
              matrix.withRule(
                NotificationCategory.custom,
                const NotificationRoutingRule(
                  transports: [NotificationTransportKind.email],
                ),
              ),
            );
      },
    },
  ),
  _Probe(
    name: 'flat settings',
    keys: const ['flat_wizard_global_settings'],
    read: (c) async {
      c.read(flatWizardProvider);
      await _settle();
      return c.read(flatWizardProvider).globalSettings.toJson();
    },
    rowSets: const {
      'stored': {
        'flat_wizard_global_settings':
            '{"savePath":"/data/flats","histogramTarget":40.0,'
            '"tolerancePercent":5.0,"frameCount":30,'
            '"createDateSubfolder":false,"createFilterSubfolders":false}',
      },
      'some fields': {
        'flat_wizard_global_settings': '{"frameCount":12,"histogramTarget":35}',
      },
      'empty': {'flat_wizard_global_settings': ''},
      'not json': {'flat_wizard_global_settings': 'flats'},
      'not an object': {'flat_wizard_global_settings': '[1]'},
    },
    writes: {
      'frame count 25': (c) async {
        c.read(flatWizardProvider);
        await _settle();
        c.read(flatWizardProvider.notifier).setFrameCount(25);
      },
      'folder': (c) async =>
          c.read(flatWizardProvider.notifier).setSavePath('/data/flats'),
    },
  ),
  _Probe(
    name: 'capture settings',
    keys: const [_captureKey],
    overrides: [activeEquipmentProfileProvider.overrideWithValue(_profile)],
    read: (c) async => _exposure(await _exposureSettings(c)),
    rowSets: const {
      'stored': {_captureKey: '{"exposureTime":12.0,"gain":100,"offset":50}'},
      'empty': {_captureKey: ''},
      'not json': {_captureKey: 'long'},
    },
    writes: {
      'exposure 20': (c) async {
        final current = await _exposureSettings(c);
        c
            .read(manualExposureSettingsUpdaterProvider)
            .update(current.copyWith(exposureTime: 20));
      },
    },
  ),
  _Probe(
    name: 'connect the equipment at start',
    keys: const ['auto_connect_equipment'],
    read: (c) => c.read(autoConnectSettingsProvider.future),
    rowSets: const {
      'on': {'auto_connect_equipment': 'true'},
      'off': {'auto_connect_equipment': 'false'},
      'upper case': {'auto_connect_equipment': 'True'},
      'one': {'auto_connect_equipment': '1'},
      'empty': {'auto_connect_equipment': ''},
    },
  ),
];

Future<Map<String, Object?>> _runProbe(_Probe probe) async {
  Future<T> withStore<T>(
    Map<String, String> rows,
    Future<T> Function(ProviderContainer c, SkotiqDatabase db) body,
  ) async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db), ...probe.overrides],
    );
    try {
      for (final key in probe.keys) {
        await db.settingsDao.deleteSetting(key);
      }
      if (rows.isNotEmpty) await db.settingsDao.setSettings(rows);
      return await body(container, db);
    } finally {
      container.dispose();
      await _settle();
      await db.close();
    }
  }

  final reads = <String, Object?>{};
  for (final entry in {
    'missing': <String, String>{},
    ...probe.rowSets,
  }.entries) {
    reads[entry.key] = await withStore(
      entry.value,
      (c, _) => _capture(() => probe.read(c)),
    );
  }

  final writes = <String, Object?>{};
  if (probe.writes.isNotEmpty) {
    await withStore(const {}, (c, db) async {
      for (final entry in probe.writes.entries) {
        await entry.value(c);
        await _settle();
        final all = await db.settingsDao.getAllSettings();
        writes[entry.key] = {
          for (final key in probe.keys)
            if (all.containsKey(key)) key: all[key],
        };
      }
    });
  }
  return {'reads': reads, 'writes': writes};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final update = Platform.environment['SKOTIQ_STORE_PINS_UPDATE'] == '1';
  final fixture = update
      ? <String, dynamic>{}
      : jsonDecode(File(_fixturePath).readAsStringSync())
            as Map<String, dynamic>;
  final recorded = <String, Object?>{};

  for (final probe in _probes) {
    test(
      '${probe.name} reads and writes the rows the base build did',
      () async {
        final result = jsonDecode(jsonEncode(await _runProbe(probe)));
        if (update) {
          recorded[probe.name] = result;
        } else {
          expect(
            result,
            _withChanges(fixture[probe.name], _changedOnPurpose[probe.name]),
          );
        }
      },
    );
  }

  if (update) {
    tearDownAll(() {
      File(
        _fixturePath,
      ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(recorded));
    });
  }
}

/// What these settings now read from text no build writes, where that
/// differs from the base build.
const Map<String, Object?> _changedOnPurpose = {};

/// [base] with the entries of [changes] laid over it, map by map. A change
/// that is not a map replaces the base value whole.
Object? _withChanges(Object? base, Object? changes) {
  if (changes is! Map || base is! Map) return changes ?? base;
  return {
    ...base,
    for (final entry in changes.entries)
      entry.key: entry.value == null
          ? null
          : _withChanges(base[entry.key], entry.value),
  };
}
