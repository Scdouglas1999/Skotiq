import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/imaging/imaging_models.dart' show AutofocusSettings;
import '../../models/settings/app_settings.dart' show SafetyFailMode;
import '../../services/frame_identity.dart';
import '../../services/logging_service.dart';
import '../../settings/app_settings_table.dart';
import '../backend_provider.dart';
import '../focuser_backlash_provider.dart' show savedFocuserBacklashProvider;
import '../meridian_flip_provider.dart';
import '../profiles_provider.dart';
import '../replay_debug_provider.dart';
import '../settings_provider.dart';
import '../weather_providers.dart'
    show
        weatherDecisionPolicyProvider,
        weatherSettingsDataProvider,
        weatherSettingsProvider;
import 'sequence_executor/sequence_serializer.dart';
import 'sequencer_defaults.dart';
import '../../settings/app_settings_state.g.dart';

/// Keeps the host's executor on the run configuration the operator's settings
/// make: the native `RunConfig`, built whole from the settings catalog
/// (`kAppSettingsTable`, each entry with a `runConfig` path copied as it is)
/// and the settings stores the catalog does not hold, and sent in one call.
///
/// From host start-up on, every change to those settings is sent, so a manual
/// capture saves as the Imaging settings say and a running sequence takes the
/// change from its next step (the executor reads its settings as each step
/// starts; safety limits apply at once). A linked client has no executor to
/// configure: its settings reach the host, whose own copy of this service
/// sends them.
final runConfigSyncProvider = Provider<RunConfigSync>((ref) {
  final sync = RunConfigSync(ref, runsHere: !ref.watch(isRemoteClientProvider));
  ref.onDispose(sync._dispose);
  return sync;
});

class RunConfigSync {
  RunConfigSync(this._ref, {required bool runsHere}) : _runsHere = runsHere {
    if (!_runsHere) return;
    _listenToSources();
    _ready = _loadSources().then((_) {
      _loaded = true;
      _scheduleSend();
    });
    // A failed load is reported by the start that needs it.
    unawaited(_ready.catchError((Object _) {}));
  }

  final Ref _ref;
  final bool _runsHere;
  late final Future<void> _ready;
  bool _loaded = false;
  bool _disposed = false;

  late final SequenceSerializer _serializer = SequenceSerializer(
    ref: _ref,
    warn: (message) =>
        _ref.read(loggingServiceProvider).warning(message, source: 'RunConfig'),
  );

  /// Where a failed send during a run is reported.
  void Function(String message)? _onRunSendFailure;

  String? _lastSent;
  bool _sendScheduled = false;
  Future<void> _sending = Future<void>.value();

  /// Send the settings for a run about to start or resume. Throws when a
  /// setting cannot be read or the executor refuses the config, so the run
  /// does not start on values the operator did not choose. A later send that
  /// fails during the run goes to [onSendFailure] until [endRun]; the run
  /// keeps the previous values.
  Future<void> beginRun({
    required void Function(String message) onSendFailure,
  }) async {
    if (!_runsHere) {
      throw StateError('A linked client has no executor to configure.');
    }
    await _ready;
    final config = build();
    _onRunSendFailure = onSendFailure;
    // Sent even when equal to the last send: a resume has just loaded its
    // checkpoint's site, fail mode and offsets into the executor.
    try {
      await _enqueue(config);
    } catch (_) {
      endRun();
      rethrow;
    }
  }

  /// The run is over: a failed send is logged, not put on a run.
  void endRun() {
    _onRunSendFailure = null;
  }

  /// The run config the settings make now, as the native `RunConfig` reads
  /// it.
  Map<String, Object?> build() {
    final settings = _ref.read(appSettingsProvider).requireValue;
    final defaults = _ref.read(sequencerDefaultsProvider);
    final weather = _ref.read(weatherSettingsProvider);
    final identity = FrameIdentity.read(_ref);
    final (cameraMake, cameraModel) = identity.cameraMakeAndModel;
    final resumeAfterSafe = _ref
        .read(weatherDecisionPolicyProvider)
        .valueOrNull
        ?.requiredSafeDurationSeconds;

    final config = <String, Object?>{
      'dither': <String, Object?>{
        'pixels': defaults.ditherPixels,
        'settle_pixels': defaults.ditherSettlePixels,
        'settle_time': defaults.ditherSettleTime,
        'settle_timeout': defaults.ditherSettleTimeout,
        'ra_only': defaults.ditherRaOnly,
      },
      // The floor for trigger-fired refocus; an Autofocus node still wins.
      'autofocus': _serializer.autofocusRuntimeConfig(
        _ref.read(autofocusSettingsProvider),
        maxDurationSecs: 600,
      ),
      'autofocus_interval_frames': defaults.autofocusIntervalFrames,
      // No site is sent when none is configured: (0, 0) is a real place, and
      // the executor keeps the site it has (a resumed run's).
      'latitude': settings.hasObserverLocation ? settings.latitude : null,
      'longitude': settings.hasObserverLocation ? settings.longitude : null,
      'filter_focus_offsets': _filterFocusOffsets(settings),
      // With weather safety off, the native poll would fail closed on a rig
      // with no safety monitor and park the mount within moments of launch.
      'safety_fail_mode': _safetyFailModeWire(
        weather.weatherSafetyEnabled
            ? settings.safetyFailMode
            : SafetyFailMode.failOpen,
      ),
      'weather_resume_after_safe_secs': resumeAfterSafe,
      'default_quality_check': settings.enableImageGrading
          ? <String, Object?>{
              'hfr_threshold': settings.imageGradingHfrThresholdPx,
              'hfr_baseline_percent': settings.imageGradingHfrBaselinePercent,
              'eccentricity_threshold':
                  settings.imageGradingEccentricityThreshold,
              'star_count_min': settings.imageGradingStarCountMin,
              'max_consecutive_rejects':
                  settings.imageGradingMaxConsecutiveRejects,
            }
          : null,
      'observer_profile': <String, Object?>{
        'observer_name': identity.observerName,
        'site_elevation_m': identity.siteElevationM,
        'camera_make': cameraMake,
        'camera_model': cameraModel,
        'telescope_name': identity.telescopeName,
        'telescope_focal_length_mm': identity.focalLengthMm,
        'telescope_aperture_mm': identity.apertureMm,
      },
      'recovery': <String, Object?>{
        'retry_interval_secs': settings.recoveryDefaultRetryIntervalMins * 60,
        'max_duration_secs': settings.recoveryDefaultMaxDurationMins * 60,
      },
      'default_adaptive_exposure': settings.adaptiveExposureEnabled
          ? <String, Object?>{
              'enabled': true,
              'target_snr': settings.adaptiveExposureTargetSnr,
              'reference_sky_brightness_mag':
                  settings.adaptiveExposureReferenceMag,
              'min_exposure_secs': settings.adaptiveExposureMinSecs,
              'max_exposure_secs': settings.adaptiveExposureMaxSecs,
              'per_filter_enabled': settings.adaptiveExposurePerFilterEnabled,
              'per_filter_min_secs': settings.adaptiveExposurePerFilterMinSecs,
              'per_filter_max_secs': settings.adaptiveExposurePerFilterMaxSecs,
            }
          : null,
      // "Park on unsafe weather" and Weather Safety's "Auto-park mount" are
      // two pages showing one setting: either off stops the executor parking.
      'park_policy': <String, Object?>{
        'park_on_unsafe_weather':
            settings.parkOnUnsafeWeather && weather.autoParkEnabled,
      },
      'meridian_flip': _serializer.buildGlobalMeridianFlipConfigJson(),
      'decision_logging_enabled':
          _ref.read(replayDebugEnabledProvider).valueOrNull ?? true,
    };
    for (final setting in kAppSettingsTable) {
      final path = setting.runConfig;
      if (path != null) _setPath(config, path, settings.valueOf(setting));
    }
    return config;
  }

  /// The focus offset per filter: the active profile's, overridden by any set
  /// in the per-filter autofocus settings. None when offsets are turned off.
  Map<String, int> _filterFocusOffsets(AppSettingsState settings) {
    if (!settings.useFilterFocusOffsets) return const {};
    final offsets = <String, int>{
      ...?_ref.read(activeEquipmentProfileProvider)?.filterFocusOffsets,
    };
    final autofocusFilters = AutofocusSettings.parseFilterSettingsJson(
      settings.afFilterSettingsJson,
    );
    for (final entry in autofocusFilters.entries) {
      if (entry.value.focusOffset != 0) {
        offsets[entry.key] = entry.value.focusOffset;
      }
    }
    return offsets;
  }

  static String _safetyFailModeWire(SafetyFailMode mode) => switch (mode) {
    SafetyFailMode.failClosed => 'FailClosed',
    SafetyFailMode.failOpen => 'FailOpen',
    SafetyFailMode.warnOnly => 'WarnOnly',
  };

  static void _setPath(
    Map<String, Object?> config,
    String path,
    Object? value,
  ) {
    final keys = path.split('.');
    var node = config;
    for (final key in keys.take(keys.length - 1)) {
      node = (node[key] ??= <String, Object?>{}) as Map<String, Object?>;
    }
    node[keys.last] = value;
  }

  /// Every value [build] reads holds a default until its load completes;
  /// nothing is sent before they have loaded.
  Future<void> _loadSources() async {
    await _ref.read(appSettingsProvider.future);
    await _ref.read(weatherSettingsDataProvider.future);
    await _ref.read(savedFocuserBacklashProvider.future);
    await _ref.read(replayDebugEnabledProvider.future);
    await _ref.read(globalMeridianFlipSettingsProvider.notifier).ensureLoaded();
    await _ref.read(sequencerDefaultsProvider.notifier).ensureLoaded();
  }

  void _listenToSources() {
    void changed(Object? _, Object? __) => _scheduleSend();
    for (final source in <ProviderListenable<Object?>>[
      appSettingsProvider,
      sequencerDefaultsProvider,
      weatherSettingsProvider,
      weatherDecisionPolicyProvider,
      activeEquipmentProfileProvider,
      savedFocuserBacklashProvider,
      replayDebugEnabledProvider,
      globalMeridianFlipSettingsProvider,
    ]) {
      _ref.listen<Object?>(source, changed);
    }
  }

  /// One send for a burst of changes, after the burst.
  void _scheduleSend() {
    if (!_loaded || _disposed || _sendScheduled) return;
    _sendScheduled = true;
    scheduleMicrotask(() {
      _sendScheduled = false;
      if (_disposed) return;
      final Map<String, Object?> config;
      try {
        config = build();
      } catch (e) {
        _reportSendFailure('The sequencer settings could not be read: $e');
        return;
      }
      if (jsonEncode(config) == _lastSent) return;
      unawaited(
        _enqueue(config).catchError((Object e) {
          _reportSendFailure(
            'A settings change could not be sent to the sequencer, which keeps '
            'the previous values: $e',
          );
        }),
      );
    });
  }

  /// Sends run one after another, so the last change is the one that stays.
  Future<void> _enqueue(Map<String, Object?> config) {
    final json = jsonEncode(config);
    final send = _sending.catchError((Object _) {}).then((_) async {
      try {
        await _ref.read(sequencerBackendProvider).sequencerApplyRunConfig(json);
        _lastSent = json;
      } catch (_) {
        _lastSent = null;
        rethrow;
      }
    });
    _sending = send;
    return send;
  }

  void _reportSendFailure(String message) {
    if (_disposed) return;
    final onRunFailure = _onRunSendFailure;
    if (onRunFailure != null) {
      onRunFailure(message);
    } else {
      _ref.read(loggingServiceProvider).warning(message, source: 'RunConfig');
    }
  }

  void _dispose() => _disposed = true;
}
