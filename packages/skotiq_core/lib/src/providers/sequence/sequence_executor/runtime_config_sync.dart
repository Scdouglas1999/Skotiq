import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../backend/skotiq_backend.dart';
import '../../../models/equipment/equipment_models.dart';
import '../../../models/sequence/sequence_models.dart';
import '../../../models/settings/app_settings.dart' show ObserverLocation;
import '../../../services/logging_service.dart';
import '../../../services/session_handoff_service.dart'
    show SessionCarryOver, SessionHandoffDecision;
import '../../defect_map_provider.dart' show seedDefectMapRuntimeForSequence;
import '../../equipment_provider.dart';
import '../../flat_wizard_provider.dart' show skyBrightnessTrackerProvider;
import '../../session_handoff_provider.dart'
    show
        sessionCarryOverProvider,
        sessionHandoffDecisionProvider,
        sessionHandoffIgnoreUnavailableOnceProvider;
import '../../settings_provider.dart';
import '../run_config_sync.dart';

/// What a native launch sends besides the run configuration: the launch
/// wiring (site, simulation mode, save path, device ids, defect map), the
/// session-handoff carry-over, and the sky-brightness feed while a run lasts.
/// The operator's settings themselves reach the executor through
/// [RunConfigSync], which [seedFromSettings] asks for the run's values.
///
/// A failed push before launch is thrown, so the run refuses to start; a
/// failed push during the run cannot abort an imaging run, so it is put on
/// the run's warnings instead ([_pushMidRun]).
class RuntimeConfigSync {
  RuntimeConfigSync({
    required Ref ref,
    required SkotiqBackend backend,
    required LoggingService Function() logger,
    required void Function(String message, {bool persist}) warn,
    required bool Function() isDisposed,
  }) : _ref = ref,
       _backend = backend,
       _logger = logger,
       _warn = warn,
       _isDisposed = isDisposed;

  final Ref _ref;
  final SkotiqBackend _backend;
  final LoggingService Function() _logger;
  final void Function(String message, {bool persist}) _warn;
  final bool Function() _isDisposed;

  Timer? _skyBrightnessPollTimer;

  /// The last sky brightness pushed, so a steady sky is not re-sent.
  double? _lastPushedSkyMag;

  /// Push the launch-authoritative wiring: the site, simulation mode, save
  /// path, device ids and the defect-map runtime.
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

  /// Send the operator's settings as the run's configuration, and keep the
  /// sections a run keeps until the run ends ([stopWatchers]).
  ///
  /// Shared by every native launch (editor start, checkpoint resume, headless
  /// `load -> start`), so no path runs on the Rust defaults. Throws when the
  /// settings cannot be read or the executor refuses them, so the caller
  /// refuses to start.
  Future<void> seedFromSettings() => _ref
      .read(runConfigSyncProvider)
      .beginRun(onSendFailure: (message) => _warn(message));

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

  /// Start the sky-brightness feed for the run.
  void startWatchers() {
    _startSkyBrightnessPoll();
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

  /// The run is over: stop the sky-brightness feed, and let the sections a
  /// run keeps follow the settings again.
  void stopWatchers() {
    // A run that never sent its settings has none to end.
    if (_ref.exists(runConfigSyncProvider)) {
      _ref.read(runConfigSyncProvider).endRun();
    }
    _skyBrightnessPollTimer?.cancel();
    _skyBrightnessPollTimer = null;
    _lastPushedSkyMag = null;
  }

  /// Stop the sky-brightness poll.
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
