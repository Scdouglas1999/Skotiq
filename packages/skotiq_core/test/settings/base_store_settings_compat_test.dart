// Settings that features keep in the `app_settings` key/value store must read
// and write the same rows as the build these declarations were moved from
// (ed612800d), and stay on the same machine when a client is linked.
//
// `test/fixtures/settings/base_store_settings.json` was produced by that build
// with `SKOTIQ_STORE_PINS_UPDATE=1`: for each feature, what it read from a set
// of stored rows (well-formed, missing, and malformed), the rows each of its
// writes left behind, and for every key whether a linked client keeps it on
// its own computer.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart' hide Sequence;
import 'package:skotiq_core/src/models/annotation_settings.dart';
import 'package:skotiq_core/src/models/imaging/auto_stretch_settings.dart';
import 'package:skotiq_core/src/models/scheduler/scheduler_status.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart'
    show BinningMode, LiveStackingMethod, LiveStackingThumbnailSize;
import 'package:skotiq_core/src/providers/annotation_settings_provider.dart';
import 'package:skotiq_core/src/services/constellation/hub_credentials.dart'
    show resolveConstellationAccountId, resolveConstellationCredentials;
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/frame_watch_settings_provider.dart';
import 'package:skotiq_core/src/models/site/learned_obstruction.dart';
import 'package:skotiq_core/src/providers/glance_mode_provider.dart';
import 'package:skotiq_core/src/providers/home_assistant_provider.dart';
import 'package:skotiq_core/src/providers/host_settings/host_settings_providers.dart'
    show isDeviceLocalSettingKey;
import 'package:skotiq_core/src/providers/imaging_provider.dart'
    show autoStretchSettingsProvider;
import 'package:skotiq_core/src/providers/notes_provider.dart';
import 'package:skotiq_core/src/providers/plugin_enablement_provider.dart'
    show settingsPluginEnablementStoreProvider;
import 'package:skotiq_core/src/providers/polar_alignment_provider.dart';
import 'package:skotiq_core/src/providers/push_notification_provider.dart';
import 'package:skotiq_core/src/providers/scheduler_provider.dart';
import 'package:skotiq_core/src/providers/sequence/sequencer_defaults.dart';
import 'package:skotiq_core/src/providers/session_optimizer_provider.dart'
    show dismissedSessionInsightsProvider;
import 'package:skotiq_core/src/providers/tutorial_provider.dart';
import 'package:skotiq_core/src/services/home_assistant/home_assistant_discovery_config.dart';
import 'package:skotiq_core/src/services/push_notification_service.dart'
    show PushNotificationConfig;

const _fixturePath = 'test/fixtures/settings/base_store_settings.json';

/// A feature that keeps its settings in the key/value store.
class _Probe {
  const _Probe({
    required this.name,
    required this.keys,
    required this.read,
    this.rowSets = const {},
    this.writes = const {},
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
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 30));

Future<Object?> _capture(Future<Object?> Function() read) async {
  try {
    return await read();
  } catch (error) {
    return {'error': error.runtimeType.toString()};
  }
}

Map<String, Object?> _sequencerDefaults(SequencerDefaults d) => {
  'autofocusStepSize': d.autofocusStepSize,
  'autofocusStepsOut': d.autofocusStepsOut,
  'autofocusExposureDuration': d.autofocusExposureDuration,
  'autofocusIntervalFrames': d.autofocusIntervalFrames,
  'ditherPixels': d.ditherPixels,
  'ditherSettleTime': d.ditherSettleTime,
  'ditherSettlePixels': d.ditherSettlePixels,
  'ditherSettleTimeout': d.ditherSettleTimeout,
  'ditherRaOnly': d.ditherRaOnly,
  'exposureDuration': d.exposureDuration,
  'isExposureDurationConfigured': d.isExposureDurationConfigured,
  'exposureCount': d.exposureCount,
  'exposureFilter': d.exposureFilter,
  'exposureGain': d.exposureGain,
  'exposureOffset': d.exposureOffset,
  'exposureBinning': d.exposureBinning.name,
  'exposureDitherEvery': d.exposureDitherEvery,
  'frameDownloadOverheadSecs': d.frameDownloadOverheadSecs,
  'livestackingPublicByDefault': d.livestackingPublicByDefault,
  'livestackingDefaultStackMethod': d.livestackingDefaultStackMethod.name,
  'livestackingDefaultWatermark': d.livestackingDefaultWatermark,
  'livestackingDefaultThumbnailSize': d.livestackingDefaultThumbnailSize.name,
  'livestackingDisableEverywhere': d.livestackingDisableEverywhere,
};

const _sequencerKeys = [
  'sequencer_autofocus_step_size',
  'sequencer_autofocus_steps_out',
  'sequencer_autofocus_exposure_duration',
  'sequencer_autofocus_interval_frames',
  'sequencer_dither_pixels',
  'sequencer_dither_settle_time',
  'sequencer_dither_settle_pixels',
  'sequencer_dither_settle_timeout',
  'sequencer_dither_ra_only',
  'sequencer_exposure_duration',
  'sequencer_exposure_count',
  'sequencer_exposure_filter',
  'sequencer_exposure_gain',
  'sequencer_exposure_offset',
  'sequencer_exposure_binning',
  'sequencer_exposure_dither_every',
  'livestacking_public_by_default',
  'livestacking_default_stack_method',
  'livestacking_default_watermark',
  'livestacking_default_thumbnail_size',
  'livestacking_disable_everywhere',
];

final _probes = <_Probe>[
  _Probe(
    name: 'glance mode',
    keys: const ['glance_mode_enabled'],
    read: (c) async {
      c.read(glanceModeProvider);
      await _settle();
      return c.read(glanceModeProvider);
    },
    rowSets: const {
      'on': {'glance_mode_enabled': 'true'},
      'off': {'glance_mode_enabled': 'false'},
      'upper case': {'glance_mode_enabled': 'TRUE'},
      'other text': {'glance_mode_enabled': 'yes'},
    },
    writes: {
      'turn on': (c) => c.read(glanceModeProvider.notifier).setEnabled(true),
      'turn off': (c) => c.read(glanceModeProvider.notifier).setEnabled(false),
    },
  ),
  _Probe(
    name: 'tutorials enabled',
    keys: const ['tutorials_enabled'],
    read: (c) async {
      c.read(tutorialProvider);
      await _settle();
      return c.read(tutorialProvider).tutorialsEnabled;
    },
    rowSets: const {
      'off': {'tutorials_enabled': 'false'},
      'on': {'tutorials_enabled': 'true'},
      'upper case off': {'tutorials_enabled': 'FALSE'},
      'empty': {'tutorials_enabled': ''},
    },
    writes: {
      'turn off': (c) async {
        c.read(tutorialProvider);
        await _settle();
        await c.read(tutorialProvider.notifier).setTutorialsEnabled(false);
      },
      'turn on': (c) async {
        c.read(tutorialProvider);
        await _settle();
        await c.read(tutorialProvider.notifier).setTutorialsEnabled(true);
      },
    },
  ),
  _Probe(
    name: 'dismissed session insights',
    keys: const ['session_insights.dismissed'],
    read: (c) async {
      final ids = await c.read(dismissedSessionInsightsProvider.future);
      return ids.toList()..sort();
    },
    rowSets: const {
      'two': {'session_insights.dismissed': 'moon_glare,late_start'},
      'spaces and gaps': {'session_insights.dismissed': ' a , ,b '},
      'empty': {'session_insights.dismissed': ''},
    },
    writes: {
      'dismiss two, restore one': (c) async {
        await c.read(dismissedSessionInsightsProvider.future);
        final notifier = c.read(dismissedSessionInsightsProvider.notifier);
        await notifier.dismiss('moon_glare');
        await notifier.dismiss('late_start');
        await notifier.undismiss('moon_glare');
      },
      'clear': (c) async {
        await c.read(dismissedSessionInsightsProvider.future);
        await c.read(dismissedSessionInsightsProvider.notifier).clear();
      },
    },
  ),
  _Probe(
    name: 'prompt for notes after a run',
    keys: const ['notes.prompt_after_run'],
    read: (c) => c.read(promptForNotesAfterRunProvider.future),
    rowSets: const {
      'off': {'notes.prompt_after_run': 'false'},
      'upper case on': {'notes.prompt_after_run': 'TRUE'},
      'other text': {'notes.prompt_after_run': 'yes'},
    },
    writes: {
      "don't ask again": (c) async {
        await c.read(promptForNotesAfterRunProvider.future);
        await c.read(notesPromptToggleProvider)(false);
      },
      'ask again': (c) async {
        await c.read(promptForNotesAfterRunProvider.future);
        await c.read(notesPromptToggleProvider)(true);
      },
    },
  ),
  _Probe(
    name: 'sequencer defaults',
    keys: _sequencerKeys,
    read: (c) async {
      c.read(sequencerDefaultsProvider);
      await c.read(sequencerDefaultsProvider.notifier).ensureLoaded();
      return _sequencerDefaults(c.read(sequencerDefaultsProvider));
    },
    rowSets: const {
      'every value set': {
        'sequencer_autofocus_step_size': '80',
        'sequencer_autofocus_steps_out': '9',
        'sequencer_autofocus_exposure_duration': '4.5',
        'sequencer_autofocus_interval_frames': '40',
        'sequencer_dither_pixels': '3.5',
        'sequencer_dither_settle_time': '12.0',
        'sequencer_dither_settle_pixels': '0.8',
        'sequencer_dither_settle_timeout': '90.0',
        'sequencer_dither_ra_only': 'true',
        'sequencer_exposure_duration': '180.0',
        'sequencer_exposure_count': '25',
        'sequencer_exposure_filter': 'Ha',
        'sequencer_exposure_gain': '139',
        'sequencer_exposure_offset': '21',
        'sequencer_exposure_binning': 'two',
        'sequencer_exposure_dither_every': '5',
        'livestacking_public_by_default': 'true',
        'livestacking_default_stack_method': 'median_rej',
        'livestacking_default_watermark': r'$TARGET by me',
        'livestacking_default_thumbnail_size': 'large',
        'livestacking_disable_everywhere': 'true',
      },
      'unreadable values': {
        'sequencer_autofocus_step_size': 'x',
        'sequencer_autofocus_steps_out': '7.5',
        'sequencer_autofocus_exposure_duration': 'abc',
        'sequencer_autofocus_interval_frames': '',
        'sequencer_dither_pixels': 'NaNx',
        'sequencer_dither_settle_time': '',
        'sequencer_dither_settle_pixels': 'one',
        'sequencer_dither_settle_timeout': 'null',
        'sequencer_dither_ra_only': 'TRUE',
        'sequencer_exposure_duration': 'abc',
        'sequencer_exposure_count': '1e3',
        'sequencer_exposure_filter': '',
        'sequencer_exposure_gain': 'high',
        'sequencer_exposure_offset': '',
        'sequencer_exposure_binning': 'three',
        'sequencer_exposure_dither_every': 'z',
        'livestacking_public_by_default': 'yes',
        'livestacking_default_stack_method': 'medianRej',
        'livestacking_default_watermark': '',
        'livestacking_default_thumbnail_size': 'huge',
        'livestacking_disable_everywhere': '1',
      },
      'zero and negative': {
        'sequencer_exposure_duration': '0',
        'sequencer_autofocus_interval_frames': '0',
        'sequencer_exposure_gain': '-5',
        'sequencer_dither_settle_time': '-1.0',
      },
      'negative duration': {'sequencer_exposure_duration': '-30'},
      'null text': {
        'sequencer_exposure_filter': 'null',
        'sequencer_exposure_gain': 'null',
        'livestacking_default_watermark': 'null',
      },
    },
    writes: {
      'autofocus': (c) async {
        c.read(sequencerDefaultsProvider);
        final n = c.read(sequencerDefaultsProvider.notifier);
        await n.ensureLoaded();
        await n.updateAutofocusDefaults(
          stepSize: 75,
          stepsOut: 6,
          exposureDuration: 2.5,
          intervalFrames: 0,
        );
      },
      'dither': (c) async {
        c.read(sequencerDefaultsProvider);
        final n = c.read(sequencerDefaultsProvider.notifier);
        await n.ensureLoaded();
        await n.updateDitherDefaults(
          pixels: 4,
          settleTime: 3,
          settlePixels: 0.5,
          settleTimeout: 45,
          raOnly: true,
        );
      },
      'exposure': (c) async {
        c.read(sequencerDefaultsProvider);
        final n = c.read(sequencerDefaultsProvider.notifier);
        await n.ensureLoaded();
        await n.updateExposureDefaults(
          duration: 300,
          count: 12,
          filter: 'OIII',
          gain: 0,
          offset: 10,
          binning: BinningMode.two,
          ditherEvery: 2,
        );
      },
      'exposure empty filter': (c) async {
        c.read(sequencerDefaultsProvider);
        final n = c.read(sequencerDefaultsProvider.notifier);
        await n.ensureLoaded();
        await n.updateExposureDefaults(filter: '');
      },
      'live stacking': (c) async {
        c.read(sequencerDefaultsProvider);
        final n = c.read(sequencerDefaultsProvider.notifier);
        await n.ensureLoaded();
        await n.updateLiveStackingDefaults(
          publicByDefault: true,
          defaultStackMethod: LiveStackingMethod.medianRej,
          defaultWatermark: 'Skotiq',
          defaultThumbnailSize: LiveStackingThumbnailSize.small,
          disableEverywhere: true,
        );
      },
      'live stacking cleared watermark': (c) async {
        c.read(sequencerDefaultsProvider);
        final n = c.read(sequencerDefaultsProvider.notifier);
        await n.ensureLoaded();
        await n.updateLiveStackingDefaults(defaultWatermark: null);
      },
    },
  ),
  _Probe(
    name: 'frame watch',
    keys: const [
      'frame_watch_recenter_enabled',
      'frame_watch_drift_limit_arcsec',
      'frame_watch_obstruction_detection',
      'learned_horizon_points_json',
    ],
    read: (c) async {
      final s = await c.read(frameWatchSettingsProvider.future);
      return {
        'recenterEnabled': s.recenterEnabled,
        'driftLimitArcsec': s.driftLimitArcsec,
        'obstructionDetection': s.obstructionDetection,
        'learnedPoints': encodeLearnedObstructionPoints(s.learnedPoints),
      };
    },
    rowSets: {
      'every value set': {
        'frame_watch_recenter_enabled': 'false',
        'frame_watch_drift_limit_arcsec': '45.5',
        'frame_watch_obstruction_detection': 'false',
        'learned_horizon_points_json': encodeLearnedObstructionPoints([
          LearnedObstructionPoint(
            azimuthDeg: 120,
            altitudeDeg: 22,
            recordedAt: DateTime.utc(2026, 10, 1, 3),
            latitude: 40,
            longitude: -74,
            targetName: 'M31',
          ),
        ]),
      },
      'unreadable values': const {
        'frame_watch_recenter_enabled': 'no',
        'frame_watch_drift_limit_arcsec': 'abc',
        'frame_watch_obstruction_detection': 'FALSE',
        'learned_horizon_points_json': '[bad',
      },
      'drift below the floor': const {'frame_watch_drift_limit_arcsec': '5'},
      'drift above the ceiling': const {
        'frame_watch_drift_limit_arcsec': '9999',
      },
      'empty': const {
        'frame_watch_recenter_enabled': '',
        'frame_watch_drift_limit_arcsec': '',
        'frame_watch_obstruction_detection': '',
        'learned_horizon_points_json': '',
      },
    },
    writes: {
      'setters': (c) async {
        final n = c.read(frameWatchSettingsProvider.notifier);
        await c.read(frameWatchSettingsProvider.future);
        await n.setRecenterEnabled(false);
        await n.setDriftLimitArcsec(2000);
        await n.setObstructionDetection(false);
        await n.addLearnedPoint(
          LearnedObstructionPoint(
            azimuthDeg: 200,
            altitudeDeg: 15,
            recordedAt: DateTime.utc(2026, 9, 1),
            latitude: 51.5,
            longitude: -0.1,
          ),
        );
      },
    },
  ),
  _Probe(
    name: 'annotation settings',
    keys: const ['annotation_settings'],
    read: (c) => _capture(() async {
      return (await c.read(annotationSettingsProvider.future)).toJson();
    }),
    rowSets: {
      'stored': {
        'annotation_settings': jsonEncode(
          const AnnotationSettings(
            enabled: false,
            magnitudeCutoff: 11,
          ).toJson(),
        ),
      },
      'empty': const {'annotation_settings': ''},
      'corrupt': const {'annotation_settings': '{'},
    },
    writes: {
      'turn off': (c) async {
        await c.read(annotationSettingsProvider.future);
        await c.read(annotationSettingsProvider.notifier).setEnabled(false);
      },
    },
  ),
  _Probe(
    name: 'annotation marker style',
    keys: const ['annotation_marker_style'],
    read: (c) => _capture(() async {
      return (await c.read(annotationMarkerStyleProvider.future)).toJson();
    }),
    rowSets: {
      'stored': {
        'annotation_marker_style': jsonEncode(
          const AnnotationMarkerStyle(strokeWidth: 3).toJson(),
        ),
      },
      'empty': const {'annotation_marker_style': ''},
      'corrupt': const {'annotation_marker_style': '[1]'},
    },
    writes: {
      'stroke width': (c) async {
        await c.read(annotationMarkerStyleProvider.future);
        await c
            .read(annotationMarkerStyleProvider.notifier)
            .setStrokeWidth(2.5);
      },
    },
  ),
  _Probe(
    name: 'annotation presets',
    keys: const ['annotation_presets'],
    read: (c) => _capture(() async {
      final presets = await c.read(annotationPresetsProvider.future);
      return [for (final p in presets) p.toJson()];
    }),
    rowSets: const {
      'stored': {
        'annotation_presets':
            '[{"name":"Deep","visibleTypes":["galaxy"],"minMagnitude":-30.0,'
            '"magnitudeCutoff":14.0,"showLabels":true,"showMagnitudes":false}]',
      },
      'empty': {'annotation_presets': ''},
      'corrupt': {'annotation_presets': '{}'},
    },
  ),
  _Probe(
    name: 'polar alignment screen',
    keys: const ['polar_alignment_ui'],
    read: (c) async {
      c.read(polarAlignmentUiStateProvider);
      await _settle();
      return c.read(polarAlignmentUiStateProvider).toJson();
    },
    rowSets: const {
      'stored': {
        'polar_alignment_ui':
            '{"mode":"tppa","showCommonSettings":false,'
            '"showAdvancedSettings":true,"showHistoryPanel":true,'
            '"compactTabIndex":2}',
      },
      'empty': {'polar_alignment_ui': ''},
      'corrupt': {'polar_alignment_ui': 'not json'},
    },
    writes: {
      'history panel': (c) async {
        c.read(polarAlignmentUiStateProvider);
        await _settle();
        await c
            .read(polarAlignmentUiStateProvider.notifier)
            .toggleHistoryPanel();
      },
    },
  ),
  _Probe(
    name: 'auto stretch',
    keys: const ['auto_stretch_settings'],
    read: (c) async {
      c.read(autoStretchSettingsProvider);
      await _settle();
      return c.read(autoStretchSettingsProvider).toJson();
    },
    rowSets: {
      'stored': {
        'auto_stretch_settings': jsonEncode(
          AutoStretchSettings.defaults().copyWith(enabled: false).toJson(),
        ),
      },
      'empty': const {'auto_stretch_settings': ''},
      'corrupt': const {'auto_stretch_settings': '{'},
    },
    writes: {
      'turn off': (c) async {
        c.read(autoStretchSettingsProvider);
        await _settle();
        await c
            .read(autoStretchSettingsProvider.notifier)
            .update(
              c.read(autoStretchSettingsProvider).copyWith(enabled: false),
            );
      },
    },
  ),
  _Probe(
    name: 'home assistant discovery',
    keys: const ['home_assistant_discovery'],
    read: (c) async =>
        (await c.read(homeAssistantConfigProvider.future)).toJson(),
    rowSets: {
      'stored': {
        'home_assistant_discovery': jsonEncode(
          const HomeAssistantDiscoveryConfig(
            enabled: true,
            deviceName: 'Roof',
          ).toJson(),
        ),
      },
      'empty': const {'home_assistant_discovery': ''},
      'corrupt': const {'home_assistant_discovery': '{'},
    },
    writes: {
      'save': (c) async {
        await c.read(homeAssistantConfigProvider.future);
        await c
            .read(homeAssistantConfigProvider.notifier)
            .save(
              const HomeAssistantDiscoveryConfig(
                enabled: true,
                deviceName: 'Dome',
              ),
            );
      },
    },
  ),
  _Probe(
    name: 'push notifications',
    keys: const ['push_notification_config'],
    read: (c) => _capture(() async {
      final p = await c.read(pushNotificationConfigProvider.future);
      return _push(p);
    }),
    rowSets: const {
      'stored': {
        'push_notification_config':
            '{"enabled":false,"notifyGuidingLost":false,'
            '"notifyEquipmentDisconnected":true}',
      },
      'empty': {'push_notification_config': ''},
      'corrupt': {'push_notification_config': '{'},
    },
    writes: {
      'turn off': (c) async {
        await c.read(pushNotificationConfigProvider.future);
        await c.read(pushNotificationConfigProvider.notifier).setEnabled(false);
      },
    },
  ),
  _Probe(
    name: 'scheduler config',
    keys: const ['scheduler_config'],
    read: (c) => _capture(() async {
      final config = await c.read(schedulerConfigStoreProvider).load();
      return config.toStorageJson();
    }),
    rowSets: {
      'stored': {
        'scheduler_config': jsonEncode({
          ...SchedulerConfig.defaults.toStorageJson(),
          'minAltitudeDegrees': 25.0,
        }),
      },
      'empty': const {'scheduler_config': ''},
      'corrupt': const {'scheduler_config': '{'},
    },
    writes: {
      'save defaults': (c) =>
          c.read(schedulerConfigStoreProvider).save(SchedulerConfig.defaults),
    },
  ),
  _Probe(
    name: 'plugin enablement',
    keys: const ['plugin_enablement'],
    read: (c) => _capture(() async {
      final store = c.read(settingsPluginEnablementStoreProvider);
      return {
        'a': await store.isEnabled('a'),
        'b': await store.isEnabled('b'),
        'unknown': await store.isEnabled('unknown'),
      };
    }),
    rowSets: const {
      'stored': {'plugin_enablement': '{"a":false,"b":true}'},
      'bad entry': {'plugin_enablement': '{"a":"no","b":false}'},
      'empty': {'plugin_enablement': ''},
      'not an object': {'plugin_enablement': '[1]'},
    },
  ),
  _Probe(
    name: 'constellation account',
    keys: const [
      'constellation.hub_url',
      'constellation.hub_token',
      'constellation.account_id',
    ],
    read: (c) async {
      final dao = c.read(settingsDaoProvider);
      final credentials = await resolveConstellationCredentials(dao);
      return {
        'account': await resolveConstellationAccountId(dao),
        'hub': credentials?.hubBaseUrl.toString(),
        'token': credentials?.bearerToken,
      };
    },
    rowSets: const {
      'signed in': {
        'constellation.hub_url': 'http://hub.local:8800',
        'constellation.hub_token': 'tok',
        'constellation.account_id': 'acct-1',
      },
      'empty': {
        'constellation.hub_url': '',
        'constellation.hub_token': '',
        'constellation.account_id': '',
      },
      'no scheme': {
        'constellation.hub_url': 'hub.local',
        'constellation.hub_token': 'tok',
      },
    },
  ),
];

Map<String, Object?> _push(PushNotificationConfig p) => {
  'enabled': p.enabled,
  'notifySequenceCompleted': p.notifySequenceCompleted,
  'notifySequenceFailed': p.notifySequenceFailed,
  'notifyMeridianFlip': p.notifyMeridianFlip,
  'notifyWeatherUnsafe': p.notifyWeatherUnsafe,
  'notifyGuidingLost': p.notifyGuidingLost,
  'notifyExposureFailed': p.notifyExposureFailed,
  'notifyAutofocusFailed': p.notifyAutofocusFailed,
  'notifyEquipmentDisconnected': p.notifyEquipmentDisconnected,
};

/// Keys whose machine (host or this computer) is pinned, beyond the probes'.
const _scopeKeys = [
  'glance_mode_enabled',
  'sequencer_density_v1',
  'sequence_overview_visible_v1',
  'thumbnail_strip_prefs_v1',
  'auto_stretch_settings',
  'framing.lastTarget',
  'polar_alignment_ui',
  'annotation_settings',
  'annotation_marker_style',
  'annotation_presets',
  'tutorials_enabled',
  'imaging.depthlock_hint_dismissed',
  'session_insights.dismissed',
  'equipment_onboarding_draft',
  'location_google_geolocation_key',
  'notification_secrets_migrated_v2',
  'constellation.hub_url',
  'constellation.hub_token',
  'constellation.account_id',
  'constellation.display_name',
  'constellation.public_key',
  'constellation.privacy',
  'mosaic.upload.consented',
  'mosaic.upload.license',
  'mosaic.upload.attribution',
  'mosaic.upload.auto',
  'ai.openai_compatible.api_key',
  'ai.anthropic.api_key',
  'ai.ollama.api_key',
  'planning.active_project_id',
  'planning.active_project_id.host-1',
  'camera_presets',
  'camera_sensor_specs',
  'focuser_backlash_calibrations.v1',
  'hardware_presets.telescopes.v1',
  'hardware_presets.cameras.v1',
  'smart_night.hardware.camera_overrides.v1',
  'plugin_enablement',
  'notification_routing_matrix',
  'replay_debug.enabled',
  'replay_debug.retention_days',
  'science.feature.sky_atlas',
  'science.sky_atlas.limit_gb',
  'science.sky_atlas.off_notice',
  'imaging_capture_settings_profile_1',
  'theme',
  'sidebar_collapsed',
  'start_minimized',
  'observer_latitude',
  'smart_night.prompt_dismissed_day_key',
];

Future<Map<String, Object?>> _runProbe(_Probe probe) async {
  Future<T> withStore<T>(
    Map<String, String> rows,
    Future<T> Function(ProviderContainer c, SkotiqDatabase db) body,
  ) async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
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
            _withChanges(
              fixture['probes'][probe.name],
              _changedOnPurpose[probe.name],
            ),
          );
        }
      },
    );
  }

  test('every key stays on the machine it was kept on', () {
    final keys = {
      ..._scopeKeys,
      for (final probe in _probes) ...probe.keys,
    }.toList()..sort();
    final scope = {for (final key in keys) key: isDeviceLocalSettingKey(key)};
    if (update) {
      recorded['deviceLocal'] = scope;
    } else {
      expect(scope, fixture['deviceLocal']);
    }
  });

  if (update) {
    tearDownAll(() {
      File(_fixturePath).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'probes': _probesOf(recorded),
          'deviceLocal': recorded['deviceLocal'],
        }),
      );
    });
  }
}

/// What these settings now read from text no build writes, where that
/// differs from the base build. A declared setting reads it by its kind's one
/// rule instead of each feature's own idiom:
///   * a bool is on for `true` and off for `false` in any case (the base read
///     `TRUE` as off where it tested `== 'true'`, and `FALSE` as on where it
///     tested `!= 'false'`). Any other text reads as off, except for the
///     switches whose base reader took anything but `false` as on (tutorials,
///     frame watch): those read it as on, as before;
///   * an empty row of a JSON document or an optional text means nothing is
///     saved (the base kept an empty filter name, and failed on an empty push
///     notification document).
const Map<String, Object?> _changedOnPurpose = {
  'glance mode': {
    'reads': {'upper case': true},
  },
  'tutorials enabled': {
    'reads': {'upper case off': false},
  },
  'sequencer defaults': {
    'reads': {
      'unreadable values': {'ditherRaOnly': true, 'exposureFilter': null},
    },
  },
  'frame watch': {
    'reads': {
      'unreadable values': {'obstructionDetection': false},
    },
  },
  'push notifications': {
    'reads': {
      'empty': _Replace({
        'enabled': true,
        'notifySequenceCompleted': true,
        'notifySequenceFailed': true,
        'notifyMeridianFlip': true,
        'notifyWeatherUnsafe': true,
        'notifyGuidingLost': true,
        'notifyExposureFailed': true,
        'notifyAutofocusFailed': true,
        'notifyEquipmentDisconnected': false,
      }),
    },
  },
};

/// A change that replaces the base value whole instead of being laid over it.
class _Replace {
  const _Replace(this.value);

  final Object? value;
}

/// [base] with the entries of [changes] laid over it, map by map. A change
/// that is not a map replaces the base value whole.
Object? _withChanges(Object? base, Object? changes) {
  if (changes is _Replace) return changes.value;
  if (changes is! Map || base is! Map) return changes ?? base;
  return {
    ...base,
    for (final entry in changes.entries)
      entry.key: entry.value == null
          ? null
          : _withChanges(base[entry.key], entry.value),
  };
}

Map<String, Object?> _probesOf(Map<String, Object?> recorded) => {
  for (final entry in recorded.entries)
    if (entry.key != 'deviceLocal') entry.key: entry.value,
};
