import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../backend/skotiq_backend.dart';
import '../../../models/equipment/equipment_models.dart';
import '../../../models/imaging/imaging_models.dart';
import '../../../models/sequence/sequence_models.dart';
import '../../../models/settings/app_settings.dart'
    show ObserverLocation, SafetyFailMode;
import '../../../models/weather/weather_settings.dart' show WeatherSettings;
import '../../../services/logging_service.dart';
import '../../../services/session_handoff_service.dart'
    show SessionCarryOver, SessionHandoffDecision;
import '../../defect_map_provider.dart' show seedDefectMapRuntimeForSequence;
import '../../equipment_provider.dart';
import '../../flat_wizard_provider.dart' show skyBrightnessTrackerProvider;
import '../../focuser_backlash_provider.dart' show savedFocuserBacklashProvider;
import '../../meridian_flip_provider.dart';
import '../../profiles_provider.dart';
import '../../replay_debug_provider.dart';
import '../../session_handoff_provider.dart'
    show
        sessionCarryOverProvider,
        sessionHandoffDecisionProvider,
        sessionHandoffIgnoreUnavailableOnceProvider;
import '../../settings_provider.dart';
import '../../weather_providers.dart' show weatherSettingsProvider;
import '../sequencer_defaults.dart';
import 'sequence_serializer.dart';

/// Keeps the native executor's runtime configuration in step with the
/// operator's settings: the launch-authoritative push, the full seed every
/// native launch shares, the session-handoff carry-over, and the mid-run
/// watchers that forward a settings change to the running sequence.
///
/// A failed push before launch is thrown, so the run refuses to start on the
/// Rust defaults; a failed mid-run push cannot abort an imaging run, so it is
/// put on the run's warnings instead ([_pushMidRun]).
class RuntimeConfigSync {
  RuntimeConfigSync({
    required Ref ref,
    required SkotiqBackend backend,
    required SequenceSerializer serializer,
    required LoggingService Function() logger,
    required void Function(String message, {bool persist}) warn,
    required bool Function() isDisposed,
  }) : _ref = ref,
       _backend = backend,
       _serializer = serializer,
       _logger = logger,
       _warn = warn,
       _isDisposed = isDisposed;

  final Ref _ref;
  final SkotiqBackend _backend;
  final SequenceSerializer _serializer;
  final LoggingService Function() _logger;
  final void Function(String message, {bool persist}) _warn;
  final bool Function() _isDisposed;

  final List<ProviderSubscription<Object?>> _settingsSubscriptions = [];
  Timer? _skyBrightnessPollTimer;

  /// The last sky brightness pushed, so a steady sky is not re-sent.
  double? _lastPushedSkyMag;

  /// Push the launch-authoritative configuration: location, simulation mode,
  /// safety fail mode, save path, device ids and the defect-map runtime.
  ///
  /// One ordered push for a start and a checkpoint resume. On a resume
  /// ([isResume]) the checkpoint knows better than an empty setting: an empty
  /// save path is not pushed (null would clobber the restored one), and device
  /// ids are pushed only when a camera is connected (the restored mapping is
  /// the best information during crash recovery).
  Future<void> pushLaunchConfig(
    AppSettingsState settings, {
    required bool isResume,
  }) async {
    final backend = _backend;
    _logger().debug(
      'Pushing launch config (resume=$isResume): lat=${settings.latitude}, '
      'lon=${settings.longitude}, elev=${settings.elevation}',
      source: 'SequenceExecutor',
    );

    // (0, 0) means "not configured"; forwarding it would arm the altitude
    // trigger against Null Island instead of leaving it disarmed.
    if (settings.latitude != 0.0 || settings.longitude != 0.0) {
      await backend.setLocation(
        ObserverLocation(
          latitude: settings.latitude,
          longitude: settings.longitude,
          elevation: settings.elevation,
        ),
      );
      _logger().debug('Location sync complete', source: 'SequenceExecutor');
    } else {
      _logger().debug(
        'Skipping location sync: location is 0,0',
        source: 'SequenceExecutor',
      );
    }

    // Never read from a setting: the bundled native library is a release
    // build and refuses simulation mode.
    await backend.sequencerSetSimulationMode(false);

    await _pushEffectiveSafetyFailMode(settings.safetyFailMode);

    final savePath = settings.imageOutputPath;
    if (savePath.isNotEmpty) {
      await backend.sequencerSetSavePath(savePath);
      _logger().debug(
        'Save path set to: $savePath',
        source: 'SequenceExecutor',
      );
    } else if (!isResume) {
      // A fresh run must not inherit a previous run's path.
      await backend.sequencerSetSavePath(null);
      _logger().warning(
        'No save path configured - images will NOT be saved to disk!',
        source: 'SequenceExecutor',
      );
    }

    final cameraState = _ref.read(cameraStateProvider);
    final cameraConnected =
        cameraState.connectionState == DeviceConnectionState.connected;
    if (!isResume || cameraConnected) {
      final mountState = _ref.read(mountStateProvider);
      final focuserState = _ref.read(focuserStateProvider);
      final filterwheelState = _ref.read(filterWheelStateProvider);
      final rotatorState = _ref.read(rotatorStateProvider);

      final focuserId =
          focuserState.connectionState == DeviceConnectionState.connected
          ? focuserState.deviceId
          : null;

      await backend.sequencerSetDevices(
        cameraId: cameraConnected ? cameraState.deviceId : null,
        mountId: mountState.connectionState == DeviceConnectionState.connected
            ? mountState.deviceId
            : null,
        focuserId: focuserId,
        filterwheelId:
            filterwheelState.connectionState == DeviceConnectionState.connected
            ? filterwheelState.deviceId
            : null,
        rotatorId:
            rotatorState.connectionState == DeviceConnectionState.connected
            ? rotatorState.deviceId
            : null,
      );

      // With no focuser the native executor disarms every refocus trigger,
      // which silently removes a protection the editor still advertises, so
      // the run record says so. Start only: a resume may run on the
      // checkpoint's device mapping. A start-up fact, carried by the final
      // stats write rather than an extra incremental one.
      if (!isResume && focuserId == null) {
        _warn(
          'No focuser is connected, so automatic refocus is disabled for this '
          'run (HFR-degradation, temperature-shift, focus-drift and '
          'interval refocus triggers are all inert). Focus will not be '
          'corrected automatically.',
          persist: false,
        );
      }
    }

    // The native defect-map slot is not restored from app settings; seed it
    // for every run so auto-apply survives restarts and headless starts.
    await seedDefectMapRuntimeForSequence(_ref);
  }

  /// The safety fail mode the native executor must run with. With weather
  /// safety disabled it is forced to `failOpen`: the native poll fail-closes
  /// on a rig with no safety monitor, and a raw `failClosed` would arm the
  /// `WeatherUnsafe` trigger and park the mount within moments of launch.
  /// Every push of the fail mode (start, resume, mid-run) goes through here.
  SafetyFailMode _effectiveSafetyFailMode(SafetyFailMode configured) {
    final weatherSafetyEnabled = _ref
        .read(weatherSettingsProvider)
        .weatherSafetyEnabled;
    return weatherSafetyEnabled ? configured : SafetyFailMode.failOpen;
  }

  Future<void> _pushEffectiveSafetyFailMode(SafetyFailMode configured) async {
    final effective = _effectiveSafetyFailMode(configured);
    final wire = _serializer.safetyFailModeToBackendString(effective);
    await _backend.sequencerSetSafetyFailMode(wire);
    _logger().debug(
      'Safety fail mode set to: $wire (configured=${configured.name})',
      source: 'SequenceExecutor',
    );
  }

  /// Weather parking is "Park on unsafe weather" AND Weather Safety's
  /// "Auto-park mount": two pages showing one setting, and turning either off
  /// must stop the executor parking.
  Future<void> _pushParkPolicy(AppSettingsState settings) async {
    final autoParkEnabled = _ref.read(weatherSettingsProvider).autoParkEnabled;
    final parkOnUnsafeWeather = settings.parkOnUnsafeWeather && autoParkEnabled;
    await _backend.sequencerSetParkPolicy(
      parkOnUnsafeWeather: parkOnUnsafeWeather,
      parkBeforeDawn: settings.parkBeforeDawn,
    );
    _logger().debug(
      'Park settings: on unsafe weather=$parkOnUnsafeWeather, '
      'before dawn=${settings.parkBeforeDawn}',
      source: 'SequenceExecutor',
    );
  }

  Future<void> _pushDeviceRetries(AppSettingsState settings) async {
    await _backend.sequencerSetDeviceRetries(
      cameraRetries: settings.cameraRetries,
      filterWheelRetries: settings.filterWheelRetries,
    );
    _logger().debug(
      'Device retries: camera=${settings.cameraRetries}, '
      'filter wheel=${settings.filterWheelRetries}',
      source: 'SequenceExecutor',
    );
  }

  /// "Stop the run for quality problems": off (the default) notifies and keeps
  /// imaging; on, each quality failure stops the run.
  Future<void> _pushQualityPolicy(AppSettingsState settings) async {
    await _backend.sequencerSetStopOnQualityProblems(
      settings.stopRunOnQualityProblems,
    );
    _logger().debug(
      'Stop the run for quality problems: '
      '${settings.stopRunOnQualityProblems}',
      source: 'SequenceExecutor',
    );
  }

  /// Push every user-controlled RuntimeConfig field into the loaded executor.
  ///
  /// Shared by every native launch (editor start, checkpoint resume, headless
  /// `load -> start`), so no path runs on the Rust defaults. Each push is
  /// independent; the first failure is rethrown after the batch so the caller
  /// refuses to start.
  Future<void> seedFromSettings() async {
    final backend = _backend;
    Object? firstError;
    StackTrace? firstStack;
    void fail(String what, Object e, StackTrace st) {
      firstError ??= e;
      firstStack ??= st;
      _logger().error('Failed to seed $what: $e', source: 'SequenceExecutor');
    }

    // Every value below is read synchronously from a provider that holds
    // library defaults until its load completes; wait for the loads so a
    // start racing a cold load cannot seed defaults. A failed load propagates:
    // with the operator's settings unknown there is nothing honest to seed.
    await _ref.read(appSettingsProvider.future);
    await _ref.read(savedFocuserBacklashProvider.future);
    await _ref.read(globalMeridianFlipSettingsProvider.notifier).ensureLoaded();
    await _ref.read(sequencerDefaultsProvider.notifier).ensureLoaded();

    // Autofocus cadence and tuning. Zero means off and is passed through as
    // zero (the engine never fires on 0); negative also means off. The tuning
    // is the floor for trigger-fired refocus; an Autofocus node still wins.
    try {
      final defaults = _ref.read(sequencerDefaultsProvider);
      final frames = defaults.autofocusIntervalFrames < 1
          ? 0
          : defaults.autofocusIntervalFrames;
      await backend.sequencerUpdateAutofocusInterval(frames);
      _logger().debug(
        frames == 0
            ? 'Seeded autofocus interval: disabled'
            : 'Seeded autofocus interval: every $frames frames',
        source: 'SequenceExecutor',
      );

      final afSettings = _ref.read(autofocusSettingsProvider);
      await backend.sequencerUpdateAutofocusConfig(
        jsonEncode(
          _serializer.autofocusRuntimeConfig(afSettings, maxDurationSecs: 600),
        ),
      );
      _logger().debug(
        'Seeded trigger-autofocus config: '
        'attempts=${afSettings.numberOfAttempts}, '
        'failure tolerance=${afSettings.failureHfrToleranceRatio}x',
        source: 'SequenceExecutor',
      );
    } catch (e, st) {
      fail('autofocus interval', e, st);
    }

    try {
      await _pushParkPolicy(await _ref.read(appSettingsProvider.future));
    } catch (e, st) {
      fail('the park settings', e, st);
    }

    try {
      await _pushDeviceRetries(await _ref.read(appSettingsProvider.future));
    } catch (e, st) {
      fail('the device retries', e, st);
    }

    try {
      await _pushQualityPolicy(await _ref.read(appSettingsProvider.future));
    } catch (e, st) {
      fail('the quality policy', e, st);
    }

    try {
      final defaults = _ref.read(sequencerDefaultsProvider);
      // The guider settle settings (the Settle values the dither settings
      // show) are the run's one settle bar: the native run holds every
      // restart of guiding to them, after a dither, autofocus or a flip.
      final settings = await _ref.read(appSettingsProvider.future);
      await backend.sequencerUpdateDitherConfig(
        pixels: defaults.ditherPixels,
        settlePixels: settings.settleThreshold,
        settleTime: settings.settleTime.toDouble(),
        settleTimeout: settings.settleTimeout.toDouble(),
        raOnly: defaults.ditherRaOnly,
      );
      _logger().debug(
        'Seeded dither config: pixels=${defaults.ditherPixels} '
        'settle=${defaults.ditherSettleTime}s',
        source: 'SequenceExecutor',
      );
    } catch (e, st) {
      fail('dither config', e, st);
    }

    // The native meridian-flip trigger starts from the Rust defaults; without
    // this push every trigger-driven flip ignores the Meridian Flip settings.
    try {
      await backend.sequencerUpdateMeridianFlipConfig(
        jsonEncode(_serializer.buildGlobalMeridianFlipConfigJson()),
      );
      _logger().debug(
        'Seeded meridian-flip trigger config from user settings',
        source: 'SequenceExecutor',
      );
    } catch (e, st) {
      fail('meridian-flip config', e, st);
    }

    // The sequencer's own lat/lon, used by meridian-flip and altitude math.
    // Only a configured site is pushed: (0, 0) arrives natively as a real
    // place, and the altitude trigger would vote targets away from a site the
    // telescope is not at. Withheld, the native side keeps altitude triggers
    // inactive and says so.
    try {
      final settings = _ref.read(appSettingsProvider).valueOrNull;
      final hasLocation =
          settings != null &&
          (settings.latitude != 0.0 || settings.longitude != 0.0);
      if (hasLocation) {
        await backend.sequencerUpdateLocation(
          latitude: settings.latitude,
          longitude: settings.longitude,
        );
        _logger().debug(
          'Seeded sequencer location: lat=${settings.latitude} '
          'lon=${settings.longitude}',
          source: 'SequenceExecutor',
        );
      } else if (settings != null) {
        _logger().warning(
          'No observing location is set, so the sequencer was not given one. '
          'Altitude-based triggers and meridian-flip timing stay inactive '
          'until a site is configured in Settings → Location.',
          source: 'SequenceExecutor',
        );
      }
    } catch (e, st) {
      fail('sequencer location', e, st);
    }

    // Filter focus offsets: the profile table merged with non-zero per-filter
    // autofocus overrides (DeviceService's precedence); an empty map when the
    // master toggle is off.
    try {
      final profile = _ref.read(activeEquipmentProfileProvider);
      final settings = _ref.read(appSettingsProvider).valueOrNull;
      if (settings == null) {
        throw StateError(
          'AppSettings is not loaded; filter focus-offset behavior is unknown.',
        );
      }
      final offsets = <String, int>{};
      if (settings.useFilterFocusOffsets) {
        offsets.addAll(profile?.filterFocusOffsets ?? const <String, int>{});
        final autofocusFilters = AutofocusSettings.parseFilterSettingsJson(
          settings.afFilterSettingsJson,
        );
        for (final entry in autofocusFilters.entries) {
          if (entry.value.focusOffset != 0) {
            offsets[entry.key] = entry.value.focusOffset;
          }
        }
      }
      await backend.sequencerUpdateFilterOffsets(offsets);
      _logger().debug(
        'Seeded filter focus offsets: ${offsets.length} entries',
        source: 'SequenceExecutor',
      );
    } catch (e, st) {
      fail('filter focus offsets', e, st);
    }

    try {
      final settings = _ref.read(appSettingsProvider).valueOrNull;
      if (settings != null) {
        await backend.sequencerUpdateDefaultQualityCheck(
          hfrThreshold: settings.imageGradingHfrThresholdPx,
          hfrBaselinePercent: settings.imageGradingHfrBaselinePercent,
          eccentricityThreshold: settings.imageGradingEccentricityThreshold,
          starCountMin: settings.imageGradingStarCountMin,
          maxConsecutiveRejects: settings.imageGradingMaxConsecutiveRejects,
          enabled: settings.enableImageGrading,
        );
        _logger().debug(
          'Seeded default_quality_check: '
          'enabled=${settings.enableImageGrading}, '
          'hfr=${settings.imageGradingHfrThresholdPx}px, '
          'baseline=${settings.imageGradingHfrBaselinePercent}%',
          source: 'SequenceExecutor',
        );
      }
    } catch (e, st) {
      fail('default_quality_check', e, st);
    }

    try {
      final settings = _ref.read(appSettingsProvider).valueOrNull;
      if (settings != null) {
        await backend.sequencerUpdateRejectFolderPath(
          settings.imageGradingRejectFolderPath,
        );
        _logger().debug(
          'Seeded reject_folder_path: '
          '${settings.imageGradingRejectFolderPath ?? "<default>"}',
          source: 'SequenceExecutor',
        );
      }
    } catch (e, st) {
      fail('reject_folder_path', e, st);
    }

    // Observer and equipment identity for the FITS header.
    try {
      await _pushObserverProfile();
    } catch (e, st) {
      fail('observer_profile', e, st);
    }

    // The global adaptive-exposure default; cleared when switched off so a
    // previous run's value cannot linger.
    try {
      final settings = _ref.read(appSettingsProvider).valueOrNull;
      if (settings != null) {
        if (settings.adaptiveExposureEnabled) {
          await _pushAdaptiveExposure(settings);
          _logger().debug(
            'Seeded default_adaptive_exposure: '
            'enabled=${settings.adaptiveExposureEnabled}, '
            'ref=${settings.adaptiveExposureReferenceMag} mag/arcsec², '
            'min=${settings.adaptiveExposureMinSecs}s, '
            'max=${settings.adaptiveExposureMaxSecs}s',
            source: 'SequenceExecutor',
          );
        } else {
          await backend.sequencerClearDefaultAdaptiveExposure();
          _logger().debug(
            'Cleared default_adaptive_exposure (disabled in settings)',
            source: 'SequenceExecutor',
          );
        }
      }
    } catch (e, st) {
      fail('default_adaptive_exposure', e, st);
    }

    // Decision logging follows the active authority's setting (local on the
    // host, the host's value on a remote client). An unreadable setting
    // aborts the start rather than run under the wrong logging policy.
    try {
      final enabled = await _ref.read(replayDebugEnabledProvider.future);
      await backend.sequencerSetDecisionLoggingEnabled(enabled);
      _logger().debug(
        'Seeded replay decision logging: enabled=$enabled',
        source: 'SequenceExecutor',
      );
    } catch (e, st) {
      fail('replay decision logging', e, st);
    }

    final error = firstError;
    if (error != null) {
      Error.throwWithStackTrace(error, firstStack ?? StackTrace.current);
    }
  }

  Future<void> _pushAdaptiveExposure(AppSettingsState settings) =>
      _backend.sequencerUpdateDefaultAdaptiveExposure(
        enabled: settings.adaptiveExposureEnabled,
        targetSnr: settings.adaptiveExposureTargetSnr,
        referenceSkyBrightnessMag: settings.adaptiveExposureReferenceMag,
        minExposureSecs: settings.adaptiveExposureMinSecs,
        maxExposureSecs: settings.adaptiveExposureMaxSecs,
        perFilterEnabled: settings.adaptiveExposurePerFilterEnabled,
        perFilterMinSecs: settings.adaptiveExposurePerFilterMinSecs,
        perFilterMaxSecs: settings.adaptiveExposurePerFilterMaxSecs,
      );

  /// Stage the session-handoff carry-over for each target that has one.
  ///
  /// Per target, the operator's pre-flight decision decides the seed:
  /// `resume` credits the previous session's per-filter integration, `restart`
  /// sends an empty map (zeroing a stale checkpoint entry), `continueNew` and
  /// a missing decision send nothing. Carry-overs join targets by
  /// case-insensitive name, the join `SessionHandoffService` made.
  ///
  /// A history read that fails is not "no history": it is rethrown, so a
  /// direct or API launch cannot silently reset a multi-night budget, unless
  /// the operator explicitly chose to start without it.
  Future<void> seedIntegrationCarryOver(Sequence sequence) async {
    final headers = sequence.targetHeaders;
    if (headers.isEmpty) return;

    final List<SessionCarryOver> carryOvers;
    try {
      carryOvers = await _ref.read(sessionCarryOverProvider.future);
      // The one-shot override is consumed even when the read recovered.
      if (_ref.read(sessionHandoffIgnoreUnavailableOnceProvider)) {
        _ref.read(sessionHandoffIgnoreUnavailableOnceProvider.notifier).state =
            false;
      }
    } catch (e, st) {
      if (_ref.read(sessionHandoffIgnoreUnavailableOnceProvider)) {
        _ref.read(sessionHandoffIgnoreUnavailableOnceProvider.notifier).state =
            false;
        _logger().warning(
          'Starting without session carry-over after explicit operator '
          'confirmation: $e',
          source: 'SequenceExecutor',
        );
        return;
      }
      _logger().error(
        'Failed to read session carry-over snapshot: $e',
        source: 'SequenceExecutor',
      );
      Error.throwWithStackTrace(e, st);
    }
    if (carryOvers.isEmpty) return;

    final headersByName = <String, TargetHeaderNode>{
      for (final h in headers) h.targetName.toLowerCase(): h,
    };

    final carryOverPayload = <String, Map<String, double>>{};
    for (final entry in carryOvers) {
      final header = headersByName[entry.targetName.toLowerCase()];
      if (header == null) continue;
      final key = (sequenceId: sequence.databaseId, targetId: entry.targetId);
      final decision = _ref.read(sessionHandoffDecisionProvider(key));
      switch (decision) {
        case null:
          continue;
        case SessionHandoffDecision.resume:
          carryOverPayload[header.id] = Map<String, double>.from(
            entry.perFilterIntegrationSecs,
          );
        case SessionHandoffDecision.restart:
          carryOverPayload[header.id] = const <String, double>{};
        case SessionHandoffDecision.continueNew:
          break;
      }
    }

    if (carryOverPayload.isEmpty) return;
    try {
      await _backend.sequencerUpdatePendingIntegrationCarryOver(
        carryOverPayload,
      );
      _logger().info(
        'Staged integration carry-over for ${carryOverPayload.length} '
        'target${carryOverPayload.length == 1 ? '' : 's'} '
        '(handoff decisions applied)',
        source: 'SequenceExecutor',
      );
    } catch (e, st) {
      _logger().error(
        'Failed to stage integration carry-over: $e',
        source: 'SequenceExecutor',
      );
      Error.throwWithStackTrace(e, st);
    }
  }

  /// Watch the settings a running sequence must follow and forward each change
  /// to the executor, and start the sky-brightness poll.
  ///
  /// Every `listen` is typed explicitly: an untyped listener's callback
  /// parameters are `dynamic`, and the extension getter `valueOrNull` then
  /// throws inside the listener on every change.
  void startWatchers() {
    stopWatchers();
    _startSkyBrightnessPoll();
    final backend = _backend;

    _settingsSubscriptions.add(
      _ref.listen<SequencerDefaults>(sequencerDefaultsProvider, (
        previous,
        next,
      ) {
        if (previous == null) return;
        if (previous.ditherPixels != next.ditherPixels ||
            previous.ditherSettlePixels != next.ditherSettlePixels ||
            previous.ditherSettleTime != next.ditherSettleTime ||
            previous.ditherSettleTimeout != next.ditherSettleTimeout ||
            previous.ditherRaOnly != next.ditherRaOnly) {
          _logger().debug(
            'Dither settings changed during execution, propagating to backend',
            source: 'SequenceExecutor',
          );
          _pushMidRun(
            'the dither settings',
            () => backend.sequencerUpdateDitherConfig(
              pixels: next.ditherPixels,
              settlePixels: next.ditherSettlePixels,
              settleTime: next.ditherSettleTime,
              settleTimeout: next.ditherSettleTimeout,
              raOnly: next.ditherRaOnly,
            ),
          );
        }
      }),
    );

    // Weather Safety's "Auto-park mount" is half of the weather park setting.
    _settingsSubscriptions.add(
      _ref.listen<WeatherSettings>(weatherSettingsProvider, (previous, next) {
        if (previous == null ||
            previous.autoParkEnabled == next.autoParkEnabled) {
          return;
        }
        final settings = _ref.read(appSettingsProvider).valueOrNull;
        if (settings == null) return;
        _pushMidRun('the park settings', () => _pushParkPolicy(settings));
      }),
    );

    _settingsSubscriptions.add(
      _ref.listen<AsyncValue<AppSettingsState>>(appSettingsProvider, (
        previous,
        next,
      ) {
        final prev = previous?.valueOrNull;
        final nextSettings = next.valueOrNull;
        if (prev == null || nextSettings == null) return;
        _forwardAppSettingsChange(prev, nextSettings);
      }),
    );

    _settingsSubscriptions.add(
      _ref.listen<EquipmentProfileModel?>(activeEquipmentProfileProvider, (
        previous,
        next,
      ) {
        if (previous == null || next == null) return;
        final nextOffsets = next.filterFocusOffsets;
        if (!mapEquals(previous.filterFocusOffsets, nextOffsets)) {
          _logger().debug(
            'Filter focus offsets changed during execution, propagating to '
            'backend',
            source: 'SequenceExecutor',
          );
          _pushMidRun(
            'the filter focus offsets',
            () => backend.sequencerUpdateFilterOffsets(nextOffsets),
          );
        }
        // Telescope / camera identity feeds the FITS header.
        if (previous.cameraName != next.cameraName ||
            previous.telescopeName != next.telescopeName ||
            previous.telescopeFocalLength != next.telescopeFocalLength ||
            previous.telescopeAperture != next.telescopeAperture ||
            previous.focalLength != next.focalLength) {
          _logger().debug(
            'Equipment profile identity changed during execution, '
            'propagating to backend',
            source: 'SequenceExecutor',
          );
          _pushMidRun('the observer profile', _pushObserverProfile);
        }
      }),
    );
  }

  void _forwardAppSettingsChange(AppSettingsState prev, AppSettingsState next) {
    final backend = _backend;
    if (prev.latitude != next.latitude || prev.longitude != next.longitude) {
      // A change that CLEARS the location is not forwarded as (0, 0).
      if (next.latitude != 0.0 || next.longitude != 0.0) {
        _logger().debug(
          'Location changed during execution, propagating to backend',
          source: 'SequenceExecutor',
        );
        _pushMidRun(
          'the observing location',
          () => backend.sequencerUpdateLocation(
            latitude: next.latitude,
            longitude: next.longitude,
          ),
        );
      }
    }

    if (prev.parkOnUnsafeWeather != next.parkOnUnsafeWeather ||
        prev.parkBeforeDawn != next.parkBeforeDawn) {
      _pushMidRun('the park settings', () => _pushParkPolicy(next));
    }

    if (prev.cameraRetries != next.cameraRetries ||
        prev.filterWheelRetries != next.filterWheelRetries) {
      _pushMidRun('the device retries', () => _pushDeviceRetries(next));
    }

    if (prev.stopRunOnQualityProblems != next.stopRunOnQualityProblems) {
      _pushMidRun('the quality policy', () => _pushQualityPolicy(next));
    }

    if (prev.safetyFailMode != next.safetyFailMode) {
      _logger().debug(
        'Safety fail mode changed during execution, propagating to backend',
        source: 'SequenceExecutor',
      );
      _pushMidRun(
        'the safety fail mode',
        () => _pushEffectiveSafetyFailMode(next.safetyFailMode),
      );
    }

    final gradingChanged =
        prev.enableImageGrading != next.enableImageGrading ||
        prev.imageGradingHfrThresholdPx != next.imageGradingHfrThresholdPx ||
        prev.imageGradingHfrBaselinePercent !=
            next.imageGradingHfrBaselinePercent ||
        prev.imageGradingEccentricityThreshold !=
            next.imageGradingEccentricityThreshold ||
        prev.imageGradingStarCountMin != next.imageGradingStarCountMin ||
        prev.imageGradingMaxConsecutiveRejects !=
            next.imageGradingMaxConsecutiveRejects;
    if (gradingChanged) {
      _logger().debug(
        'Image-grading settings changed during execution, propagating to '
        'backend',
        source: 'SequenceExecutor',
      );
      _pushMidRun(
        'the image-grading thresholds',
        () => backend.sequencerUpdateDefaultQualityCheck(
          hfrThreshold: next.imageGradingHfrThresholdPx,
          hfrBaselinePercent: next.imageGradingHfrBaselinePercent,
          eccentricityThreshold: next.imageGradingEccentricityThreshold,
          starCountMin: next.imageGradingStarCountMin,
          maxConsecutiveRejects: next.imageGradingMaxConsecutiveRejects,
          enabled: next.enableImageGrading,
        ),
      );
    }
    if (prev.imageGradingRejectFolderPath !=
        next.imageGradingRejectFolderPath) {
      _logger().debug(
        'Reject folder path changed during execution, propagating to backend',
        source: 'SequenceExecutor',
      );
      _pushMidRun(
        'the reject folder',
        () => backend.sequencerUpdateRejectFolderPath(
          next.imageGradingRejectFolderPath,
        ),
      );
    }

    if (prev.observerName != next.observerName ||
        prev.elevation != next.elevation) {
      _logger().debug(
        'Observer name / elevation changed during execution, propagating to '
        'backend',
        source: 'SequenceExecutor',
      );
      _pushMidRun('the observer profile', _pushObserverProfile);
    }

    // The executor takes the whole adaptive-exposure config on every push.
    final adaptiveChanged =
        prev.adaptiveExposureEnabled != next.adaptiveExposureEnabled ||
        prev.adaptiveExposureTargetSnr != next.adaptiveExposureTargetSnr ||
        prev.adaptiveExposureReferenceMag !=
            next.adaptiveExposureReferenceMag ||
        prev.adaptiveExposureMinSecs != next.adaptiveExposureMinSecs ||
        prev.adaptiveExposureMaxSecs != next.adaptiveExposureMaxSecs ||
        !mapEquals(
          prev.adaptiveExposurePerFilterEnabled,
          next.adaptiveExposurePerFilterEnabled,
        ) ||
        !mapEquals(
          prev.adaptiveExposurePerFilterMinSecs,
          next.adaptiveExposurePerFilterMinSecs,
        ) ||
        !mapEquals(
          prev.adaptiveExposurePerFilterMaxSecs,
          next.adaptiveExposurePerFilterMaxSecs,
        );
    if (adaptiveChanged) {
      _logger().debug(
        'Adaptive-exposure settings changed during execution, propagating to '
        'backend',
        source: 'SequenceExecutor',
      );
      _pushMidRun(
        'the adaptive-exposure settings',
        () => next.adaptiveExposureEnabled
            ? _pushAdaptiveExposure(next)
            : backend.sequencerClearDefaultAdaptiveExposure(),
      );
    }
  }

  /// Push the FITS observer profile: the observer name and site elevation
  /// from app settings, the rest from the active equipment profile. Missing
  /// values are omitted, never sent as sentinels. Throws on a failed push.
  Future<void> _pushObserverProfile() async {
    final settings = _ref.read(appSettingsProvider).valueOrNull;
    final profile = _ref.read(activeEquipmentProfileProvider);

    // The profile's camera name is a display label ("ZWO ASI2600MM Pro"):
    // make is the first word, model the rest; one word is a model alone.
    String? cameraMake;
    String? cameraModel;
    final rawCameraName = profile?.cameraName?.trim();
    if (rawCameraName != null && rawCameraName.isNotEmpty) {
      final spaceIdx = rawCameraName.indexOf(' ');
      if (spaceIdx > 0) {
        cameraMake = rawCameraName.substring(0, spaceIdx).trim();
        cameraModel = rawCameraName.substring(spaceIdx + 1).trim();
      } else {
        cameraModel = rawCameraName;
      }
    }

    // The dedicated telescope fields first, then the generic optics fields a
    // profile built through them carries; 0 means not configured.
    double? focalLength;
    double? aperture;
    if (profile != null) {
      final tfl = profile.telescopeFocalLength;
      final fl = profile.focalLength;
      if (tfl != null && tfl > 0) {
        focalLength = tfl;
      } else if (fl > 0) {
        focalLength = fl;
      }
      final ta = profile.telescopeAperture;
      final ap = profile.aperture;
      if (ta != null && ta > 0) {
        aperture = ta;
      } else if (ap > 0) {
        aperture = ap;
      }
    }

    await _backend.sequencerUpdateObserverProfile(
      observerName: (settings == null || settings.observerName.isEmpty)
          ? null
          : settings.observerName,
      siteElevationM: (settings != null && settings.elevation > 0)
          ? settings.elevation
          : null,
      cameraMake: cameraMake,
      cameraModel: cameraModel,
      telescopeName: profile?.telescopeName,
      telescopeFocalLengthMm: focalLength,
      telescopeApertureMm: aperture,
    );
    _logger().debug(
      'Pushed observer_profile: observer=${settings?.observerName}, '
      'telescope=${profile?.telescopeName}, camera=$cameraMake $cameraModel, '
      'focal=${focalLength}mm, aperture=${aperture}mm',
      source: 'SequenceExecutor',
    );
  }

  /// Send a mid-run change to the executor from a synchronous listener or
  /// timer. A failure is logged and put on the run's warnings (the run keeps
  /// the previous value); an un-awaited push would otherwise fail silently as
  /// an unhandled zone error. The logger is captured before the await because
  /// this work can outlive the provider container.
  void _pushMidRun(String what, Future<void> Function() push) {
    final logger = _logger();
    unawaited(() async {
      try {
        await push();
      } catch (e, st) {
        logger.error(
          'Failed to propagate $what to the running sequence: $e\n$st',
          source: 'SequenceExecutor',
        );
        if (!_isDisposed()) {
          _warn(
            'A change to $what could not be sent to the running sequence, '
            'which is still using the previous value: $e',
          );
        }
      }
    }());
  }

  /// Close the settings watchers and stop the sky-brightness poll.
  void stopWatchers() {
    for (final sub in _settingsSubscriptions) {
      sub.close();
    }
    _settingsSubscriptions.clear();
    _skyBrightnessPollTimer?.cancel();
    _skyBrightnessPollTimer = null;
    _lastPushedSkyMag = null;
  }

  /// Stop the sky-brightness poll; the watchers die with the container.
  void dispose() {
    _skyBrightnessPollTimer?.cancel();
    _skyBrightnessPollTimer = null;
  }

  /// Every 10 s, push the tracker's sky brightness when it moved by more than
  /// 0.05 mag/arcsec² (smaller wobble is noise). A failed read is logged at
  /// debug level and the poll continues; the tick stops itself once the
  /// executor is disposed.
  void _startSkyBrightnessPoll() {
    _skyBrightnessPollTimer?.cancel();
    // Captured once: the tick can outlive the container, and a catch that
    // reads a provider can itself throw.
    final logger = _logger();
    _skyBrightnessPollTimer = Timer.periodic(const Duration(seconds: 10), (
      timer,
    ) {
      if (_isDisposed()) {
        timer.cancel();
        return;
      }
      try {
        final mag = _ref
            .read(skyBrightnessTrackerProvider)
            .currentMagPerArcsec2();
        if (mag == _lastPushedSkyMag) return;
        final last = _lastPushedSkyMag;
        final changed =
            last == null || mag == null || (mag - last).abs() > 0.05;
        if (!changed) return;
        _lastPushedSkyMag = mag;
        _pushMidRun(
          'the sky brightness',
          () => _backend.sequencerUpdateSkyBrightness(mag: mag),
        );
        logger.debug(
          'Pushed sky brightness to executor: '
          '${mag?.toStringAsFixed(2) ?? "<none>"} mag/arcsec²',
          source: 'SequenceExecutor',
        );
      } catch (e) {
        logger.debug(
          'Sky brightness poll failed: $e',
          source: 'SequenceExecutor',
        );
      }
    });
  }
}
