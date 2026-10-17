import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/network_backend.dart';
import '../backend/skotiq_backend.dart';
import '../database/database.dart';
import '../models/polar_alignment_config.dart';
import '../utils/resilient_poll_stream.dart';
import 'backend_provider.dart';
import 'capability_provider.dart';
import 'database_provider.dart';
import 'profiles_provider.dart';

part 'polar_alignment/polar_wire_decoding.dart';
part 'polar_alignment/polar_config_notifier.dart';
part 'polar_alignment/polar_ui_state.dart';
part 'polar_alignment/polar_history.dart';
part 'polar_alignment/polar_controller.dart';

/// Raised when [PolarAlignmentStateNotifier.startAlignment] is called with a
/// configuration that fails validation. It *fails the awaited command* so
/// callers cannot mistake a rejected start for a successful one.
class PolarAlignmentValidationException implements Exception {
  PolarAlignmentValidationException(this.errors);

  final List<String> errors;

  @override
  String toString() =>
      'PolarAlignmentValidationException: ${errors.join(', ')}';
}

/// Raised when a start is rejected because a run is already active / in flight,
/// or when stop/complete cannot admit the operation. Deterministic so rapid
/// double-starts and start-during-stop reject predictably instead of racing.
class PolarAlignmentBusyException implements Exception {
  PolarAlignmentBusyException(this.message);

  final String message;

  @override
  String toString() => 'PolarAlignmentBusyException: $message';
}

/// Raised when the active backend changes while a polar-alignment command is
/// in flight. A command admitted against one rig must never continue against a
/// newly connected rig.
class PolarAlignmentBackendChangedException implements Exception {
  PolarAlignmentBackendChangedException(this.message);

  final String message;

  @override
  String toString() => 'PolarAlignmentBackendChangedException: $message';
}

// Polar alignment state provider

/// Main provider for polar alignment runtime state
final polarAlignmentStateProvider =
    StateNotifierProvider<PolarAlignmentStateNotifier, PolarAlignmentState>((
      ref,
    ) {
      return PolarAlignmentStateNotifier(ref);
    });

/// Notifier that manages polar alignment state and subscribes to backend events
class PolarAlignmentStateNotifier extends StateNotifier<PolarAlignmentState> {
  final Ref ref;
  StreamSubscription? _eventSub;

  /// Stores the initial error when entering adjustment phase
  PolarAlignmentError? _capturedInitialError;

  /// Bumped on every [_bindToBackend]. Each subscription closure captures the
  /// generation it was created with; events whose generation is stale (from a
  /// backend that has since been swapped out, or a subscription mid-teardown)
  /// are ignored. This makes correctness independent of when the old
  /// subscription's `cancel()` future actually resolves.
  int _backendGeneration = 0;

  /// Backend that admitted the current standalone run. Stop and Complete must
  /// target this exact object; reading [backendProvider] again after a host
  /// switch could send a teardown command to an unrelated rig.
  SkotiqBackend? _runBackend;

  /// Backend whose event stream is currently bound.
  SkotiqBackend? _boundBackend;

  /// True while exactly one run owns the hardware — set once the backend
  /// confirms a start, cleared only once the run is confirmed terminated
  /// (successful stop, successful complete, or a terminal native event).
  /// While true, a new Start is rejected: at most one run may own hardware.
  bool _hardwareOwned = false;

  /// The admitted start operation. Published synchronously before its first
  /// await so Stop can join it rather than racing a backend stop against a
  /// backend start whose task handle is not ready yet.
  Future<void>? _startFuture;

  /// The in-flight stop, if any. Concurrent stops join this future rather than
  /// issuing a second backend stop; a start waits on it before proceeding.
  Future<void>? _stopFuture;

  /// True from the moment Stop is accepted until the teardown settles.
  ///
  /// Teardown is bounded but not instant — the host signals the run and waits
  /// for it to reach a checkpoint — and the run's last act on the way to that
  /// checkpoint is usually to fail whatever it was blocked on. That failure is
  /// the stop landing, not a run that broke, so while this is set the failure
  /// is recorded rather than published as the run's outcome.
  bool _stopRequested = false;

  /// Manual completion is terminal too. Stop joins it instead of issuing a
  /// second backend stop; repeated Complete presses share one exact outcome.
  Future<void>? _completeFuture;

  /// Set once the current run's result has been persisted to history, so a run
  /// produces exactly one durable record even if stop, manual complete, and a
  /// native auto-complete event all fire. Reset when a new run begins.
  bool _historySaved = false;

  /// Single-flight history write. A native auto-complete event and a manual
  /// Complete/Stop can arrive together; all join this write so they cannot
  /// double-insert or let a failed optimistic claim suppress a retry.
  Future<void>? _historySaveFuture;

  PolarAlignmentStateNotifier(this.ref) : super(const PolarAlignmentState()) {
    _init();
  }

  void _init() {
    _bindToBackend(ref.read(backendProvider));

    // The active backend can be swapped at runtime (local FFI <-> network).
    // Re-bind to the new backend's event stream on every swap so polar
    // alignment events keep flowing after a reconnect; the old subscription
    // is cancelled inside [_bindToBackend].
    ref.listen<SkotiqBackend>(backendProvider, (_, next) {
      _bindToBackend(next);
    });
  }

  void _bindToBackend(SkotiqBackend backend) {
    // Bump the generation first so the *old* subscription's closure — which
    // captured the previous value — short-circuits any event that is still
    // in flight from the backend being swapped away. Cancelling the old
    // subscription is best-effort cleanup; the generation check is what
    // actually guarantees a late event from the old backend cannot mutate the
    // new run's state.
    final previousBackend = _boundBackend;
    final backendChanged =
        previousBackend != null && !identical(previousBackend, backend);
    _boundBackend = backend;
    final generation = ++_backendGeneration;
    final previous = _eventSub;

    if (backendChanged &&
        (_startFuture != null ||
            _stopFuture != null ||
            _completeFuture != null ||
            _hardwareOwned ||
            state.isRunning)) {
      // BackendNotifier disposes the outgoing backend before publishing the
      // replacement. We can no longer issue a trustworthy Stop to that run,
      // and must never redirect it to the replacement backend. Release local
      // admission ownership, retain the last measurements for diagnosis, and
      // make the loss of control explicit to the operator.
      _hardwareOwned = false;
      _runBackend = null;
      state = state.copyWith(
        phase: PolarAlignPhase.error,
        statusMessage: 'Polar alignment control disconnected',
        errorMessage:
            'The connected imaging host changed during polar alignment. '
            'Skotiq will not send Stop or Complete to the new host. '
            'Verify the previous host before moving the mount or starting '
            'another alignment.',
      );
    }

    _eventSub = backend.eventStream.listen((event) {
      if (!mounted) return; // Guard against updates after disposal
      if (generation != _backendGeneration) return; // stale subscription

      if (event.category == EventCategory.polarAlignment) {
        _handlePolarAlignmentEvent(event.eventType, event.data);
      }
    });

    // Fire-and-forget: the generation guard above already neutralises any
    // events this subscription emits between now and full teardown.
    previous?.cancel();
  }

  void _handlePolarAlignmentEvent(String eventType, Map<String, dynamic> data) {
    if (!mounted) return;

    developer.log(
      '[PolarAlignmentStateNotifier] Received event: $eventType',
      name: 'PolarAlignmentStateNotifier',
      level: 500,
    );

    switch (eventType) {
      case 'PolarAlignment':
        _handleErrorUpdate(data);
        break;

      case 'PolarAlignmentStatus':
        _handleStatusUpdate(data);
        break;

      case 'PolarAlignmentImage':
        _handleImageUpdate(data);
        break;
    }
  }

  void _handleErrorUpdate(Map<String, dynamic> data) {
    final error = PolarAlignmentError.fromEventData(data);

    // Capture initial error when first entering adjustment phase
    if (state.phase == PolarAlignPhase.adjusting &&
        state.initialError == null) {
      _capturedInitialError = error;
      state = state.copyWith(currentError: error, initialError: error);
    } else {
      state = state.copyWith(currentError: error);
    }

    // Notify error history provider
    ref.read(polarAlignmentErrorHistoryProvider.notifier).addError(error);
  }

  void _handleStatusUpdate(Map<String, dynamic> data) {
    final statusStr = data['status'] as String? ?? '';
    final phaseStr = data['phase'] as String? ?? '';
    final point = _wireInt(data['point']) ?? 0;

    final phase = _parsePhase(phaseStr);

    switch (phase) {
      case PolarAlignPhase.complete:
        // Native auto-completion (threshold reached). Persist the durable
        // record and settle — the native task has already stopped itself.
        _handleNativeComplete(statusStr);
        return;

      case PolarAlignPhase.error:
        if (_stopRequested) {
          // This is the requested stop landing: the run failed the exposure or
          // solve it was blocked on because we told it to end. Blaming the
          // solver for a run the user stopped is the failure the operator did
          // not have. The reason goes to the log; `_doStop` publishes the
          // stopped outcome once the host confirms.
          developer.log(
            '[PolarAlignmentStateNotifier] Run ended during a requested stop: '
            '$statusStr',
            name: 'PolarAlignmentStateNotifier',
            level: 700,
          );
          return;
        }
        // The native run failed on its own. Release hardware ownership so a
        // fresh Start is admitted and surface the error truthfully.
        _hardwareOwned = false;
        _runBackend = null;
        state = state.copyWith(
          phase: PolarAlignPhase.error,
          statusMessage: statusStr.isNotEmpty
              ? statusStr
              : 'Polar alignment error',
          errorMessage: statusStr.isNotEmpty ? statusStr : state.errorMessage,
        );
        return;

      case PolarAlignPhase.idle:
        // Native reported the run stopped/cancelled. Release ownership. A
        // local stop already drives its own final idle, so only overwrite the
        // status here if we are not already idle.
        _hardwareOwned = false;
        _runBackend = null;
        if (state.phase != PolarAlignPhase.idle) {
          state = state.copyWith(
            phase: PolarAlignPhase.idle,
            statusMessage: statusStr.isNotEmpty
                ? statusStr
                : 'Polar alignment stopped',
          );
        }
        return;

      case PolarAlignPhase.measuring:
      case PolarAlignPhase.adjusting:
        break;
    }

    // Live progress (measuring / adjusting). When transitioning into the
    // adjustment phase, prepare to capture the initial error from the next
    // error event.
    if (phase == PolarAlignPhase.adjusting &&
        state.phase != PolarAlignPhase.adjusting) {
      _capturedInitialError = null;
    }

    state = state.copyWith(
      phase: phase,
      currentPoint: point,
      statusMessage: statusStr,
      // Preserve initial error if we already have it
      initialError: _capturedInitialError ?? state.initialError,
    );
  }

  /// Handle a native `complete` status: persist exactly one auto-completed
  /// history record and settle into the completed state. Guarded so repeated
  /// `complete` events — or a manual [completeAlignment] racing the native
  /// one — cannot double-save.
  void _handleNativeComplete(String statusStr) {
    _hardwareOwned = false;
    _runBackend = null;

    if (!_historySaved &&
        state.initialError != null &&
        state.currentError != null) {
      // Claim the single-save slot optimistically so a second `complete`
      // event cannot start a duplicate insert. If the insert fails we release
      // the slot again so a later event can retry.
      unawaited(
        _saveHistoryOnce(autoCompleted: true).catchError((Object e) {
          developer.log(
            '[PolarAlignmentStateNotifier] auto-complete save failed: $e',
            name: 'PolarAlignmentStateNotifier',
            level: 1000,
            error: e,
          );
        }),
      );
    }

    if (state.phase != PolarAlignPhase.complete) {
      state = state.copyWith(
        phase: PolarAlignPhase.complete,
        statusMessage: statusStr.isNotEmpty
            ? statusStr
            : 'Polar alignment complete',
      );
    }
  }

  void _handleImageUpdate(Map<String, dynamic> data) {
    // The image payload arrives as raw bytes over the local FFI path
    // (`Uint8List`) but as a JSON array of ints (`List<dynamic>`) — or, on some
    // transports, a base64 string — over the network. Decode all shapes and,
    // critically, reject a malformed payload *without* tearing down the event
    // subscription.
    final Uint8List bytes;
    try {
      bytes = _decodeImageBytes(data['image_data']);
    } catch (e) {
      developer.log(
        '[PolarAlignmentStateNotifier] Ignoring malformed polar image payload: $e',
        name: 'PolarAlignmentStateNotifier',
        level: 900,
      );
      return; // keep prior image/state; subscription stays alive
    }

    state = state.copyWith(
      imageData: bytes,
      imageWidth: _wireInt(data['width']) ?? state.imageWidth,
      imageHeight: _wireInt(data['height']) ?? state.imageHeight,
      // solved_ra / solved_dec are null on the pre-solve image emit and numeric
      // (int OR double over JSON) once solved. Preserve prior solve on absence.
      solvedRa: _wireDoubleOrNull(data['solved_ra']) ?? state.solvedRa,
      solvedDec: _wireDoubleOrNull(data['solved_dec']) ?? state.solvedDec,
    );
  }

  PolarAlignPhase _parsePhase(String phaseStr) {
    switch (phaseStr.toLowerCase()) {
      case 'measuring':
        return PolarAlignPhase.measuring;
      case 'adjusting':
        return PolarAlignPhase.adjusting;
      case 'complete':
        return PolarAlignPhase.complete;
      case 'error':
        return PolarAlignPhase.error;
      default:
        return PolarAlignPhase.idle;
    }
  }

  /// Start three-point (TPPA) polar alignment with the given configuration.
  ///
  /// Serialized and idempotent: rejects deterministically ([
  /// PolarAlignmentBusyException]) if a run already owns the hardware or a
  /// start is already in flight, and waits for any in-flight stop first so a
  /// start can never overlap a teardown. Validation failure *fails the awaited
  /// command* ([PolarAlignmentValidationException]) rather than returning an
  /// apparent success.
  Future<void> startAlignment(PolarAlignmentConfig config) =>
      _startSerialized(config, allSky: false);

  /// Start all-sky (Sharpcap-style) polar alignment.
  ///
  /// Unlike TPPA this streams drift-based error updates straight into the
  /// adjusting phase — there is no discrete measurement phase. Shares the same
  /// serialized/idempotent admission control as [startAlignment] so the two
  /// routines can never overlap on the hardware.
  Future<void> startAllSkyAlignment(PolarAlignmentConfig config) =>
      _startSerialized(config, allSky: true);

  Future<void> _startSerialized(
    PolarAlignmentConfig config, {
    required bool allSky,
  }) {
    if (_startFuture != null) {
      return Future<void>.error(
        PolarAlignmentBusyException(
          'A polar alignment start is already in progress',
        ),
      );
    }
    final admittedBackend = ref.read(backendProvider);
    final admittedGeneration = _backendGeneration;
    final start = _doStart(
      config,
      allSky: allSky,
      admittedBackend: admittedBackend,
      admittedGeneration: admittedGeneration,
    );
    late Future<void> tracked;
    tracked = start.whenComplete(() {
      if (identical(_startFuture, tracked)) _startFuture = null;
    });
    _startFuture = tracked;
    return tracked;
  }

  Future<void> _doStart(
    PolarAlignmentConfig config, {
    required bool allSky,
    required SkotiqBackend admittedBackend,
    required int admittedGeneration,
  }) async {
    // Serialize against an in-flight stop so a start can never overlap the
    // teardown of the previous run's hardware ownership.
    final pendingStop = _stopFuture;
    if (pendingStop != null) {
      try {
        await pendingStop;
      } catch (_) {
        // A failed stop leaves the run owning the hardware; the ownership
        // check below rejects the start truthfully.
      }
      if (!mounted) return;
    }

    // Do not reset the single-save bookkeeping while the previous terminal
    // record is still committing. A new run may proceed after a failed history
    // write, but never overlap it and inherit its late `_historySaved=true`.
    final pendingHistory = _historySaveFuture;
    if (pendingHistory != null) {
      try {
        await pendingHistory;
      } catch (_) {
        // The previous run is already terminal. Its persistence failure is
        // logged/surfaced by its owner and must not permanently block Start.
      }
      if (!mounted) return;
    }

    // Deterministic rejection while a run still owns the hardware (including
    // after a failed stop).
    if (_hardwareOwned || state.isRunning) {
      throw PolarAlignmentBusyException('Polar alignment is already running');
    }

    _throwIfBackendChanged(admittedBackend, admittedGeneration);

    try {
      // Both start modes are supported end-to-end: "Current" measures from the
      // mount's current pointing, "Pole" (startFromCurrent=false) slews to the
      // pole region first (native `slew_to_pole_region`, which requires the
      // site location — enforced host-side). Pass the user's choice through
      // verbatim.
      final effectiveConfig = config;

      // Validate against the real camera capabilities where resolvable (host
      // authority flows through cameraCapabilitiesProvider); otherwise the
      // conservative built-in ranges.
      final caps = await _resolveCameraCapabilities();
      if (!mounted) return;
      _throwIfBackendChanged(admittedBackend, admittedGeneration);
      final validationErrors = caps != null
          ? effectiveConfig.validateForCamera(caps)
          : effectiveConfig.validate();
      if (validationErrors.isNotEmpty) {
        // Surface for the UI AND fail the awaited command.
        state = state.copyWith(
          phase: PolarAlignPhase.error,
          errorMessage: validationErrors.join(', '),
          statusMessage: 'Invalid polar alignment configuration',
        );
        throw PolarAlignmentValidationException(validationErrors);
      }

      _historySaved = false;
      _capturedInitialError = null;
      state = PolarAlignmentState(
        phase: allSky ? PolarAlignPhase.adjusting : PolarAlignPhase.measuring,
        statusMessage: allSky
            ? 'Starting all-sky polar alignment...'
            : 'Starting polar alignment...',
        config: effectiveConfig,
        startedAt: DateTime.now(),
      );

      _runBackend = admittedBackend;
      if (allSky) {
        await admittedBackend.startAllSkyPolarAlignment(
          exposureTime: effectiveConfig.exposureTime,
          solveTimeout: effectiveConfig.solveTimeout,
          binning: effectiveConfig.binning,
          isNorth: effectiveConfig.isNorth,
          acceptanceThresholdArcsec: effectiveConfig.autoCompleteThreshold,
          iterationCadenceSecs: effectiveConfig.iterationCadenceSecs,
          gain: effectiveConfig.gain,
          offset: effectiveConfig.offset,
        );
      } else {
        await admittedBackend.startPolarAlignment(
          exposureTime: effectiveConfig.exposureTime,
          stepSize: effectiveConfig.stepSize,
          binning: effectiveConfig.binning,
          isNorth: effectiveConfig.isNorth,
          manualRotation: effectiveConfig.manualRotation,
          rotateEast: effectiveConfig.rotateEast,
          gain: effectiveConfig.gain,
          offset: effectiveConfig.offset,
          solveTimeout: effectiveConfig.solveTimeout,
          startFromCurrent: effectiveConfig.startFromCurrent,
          autoCompleteThreshold: effectiveConfig.autoCompleteThreshold,
        );
      }
      _throwIfBackendChanged(admittedBackend, admittedGeneration);
      // Backend confirmed the start. A very fast native terminal event may
      // already have settled the state while the start acknowledgement was in
      // flight; do not resurrect ownership in that case.
      _hardwareOwned = state.isRunning;
    } on PolarAlignmentValidationException {
      rethrow; // state already reflects the error
    } on PolarAlignmentBackendChangedException {
      if (identical(_runBackend, admittedBackend)) _runBackend = null;
      rethrow; // backend-swap listener already published the actionable error
    } catch (e) {
      if (identical(_runBackend, admittedBackend)) _runBackend = null;
      if (mounted) {
        state = state.copyWith(
          phase: PolarAlignPhase.error,
          errorMessage: e.toString(),
          statusMessage: allSky
              ? 'Failed to start all-sky polar alignment'
              : 'Failed to start polar alignment',
        );
      }
      rethrow;
    }
  }

  void _throwIfBackendChanged(
    SkotiqBackend admittedBackend,
    int admittedGeneration,
  ) {
    if (admittedGeneration == _backendGeneration &&
        identical(ref.read(backendProvider), admittedBackend)) {
      return;
    }
    throw PolarAlignmentBackendChangedException(
      'The imaging backend changed while polar alignment was starting.',
    );
  }

  /// Resolve the connected camera's capabilities so config limits and null
  /// gain/offset semantics reflect real hardware. Returns null when no camera
  /// is configured or capabilities can't be read (validation then falls back
  /// to the built-in ranges).
  Future<CameraCapabilities?> _resolveCameraCapabilities() async {
    try {
      final cameraId = ref.read(activeEquipmentProfileProvider)?.cameraId;
      if (cameraId == null || cameraId.isEmpty) return null;
      return await ref.read(cameraCapabilitiesProvider(cameraId).future);
    } catch (e) {
      developer.log(
        '[PolarAlignmentStateNotifier] Could not resolve camera capabilities: $e',
        name: 'PolarAlignmentStateNotifier',
        level: 700,
      );
      return null;
    }
  }

  /// Stop the polar alignment process.
  ///
  /// Concurrent stops join a single in-flight stop (the backend is asked to
  /// stop at most once). Returns only once the run is confirmed terminated;
  /// if the backend stop fails/times out this method throws, keeps the run
  /// blocked (hardware ownership retained), and never publishes idle.
  Future<void> stopAlignment({bool forceBackend = false}) async {
    final completing = _completeFuture;
    if (completing != null) return completing;

    final existing = _stopFuture;
    if (existing != null) return existing; // concurrent stops join

    // A stop requested during Start waits until backend admission has either
    // succeeded or failed. Issuing stop concurrently can otherwise land before
    // the native task handle exists and return while the new run continues.
    final starting = _startFuture;
    if (starting != null) {
      try {
        await starting;
      } catch (_) {
        return; // rejected start owns no hardware
      }
      if (!mounted) return;
      final completionAfterStart = _completeFuture;
      if (completionAfterStart != null) return completionAfterStart;
      final stopAfterStart = _stopFuture;
      if (stopAfterStart != null) return stopAfterStart;
    }

    // Idempotent: nothing to stop when no run owns the hardware.
    if (!_hardwareOwned && !state.isRunning && !forceBackend) return;

    _stopRequested = true;
    // Say so before asking the host. Stopping a three-point run means waiting
    // for an exposure or a plate solve to reach a checkpoint, which is seconds
    // of a screen that would otherwise look exactly like a dropped click. The
    // phase stays active because the run still owns the hardware.
    if (mounted && state.isRunning) {
      state = state.copyWith(statusMessage: 'Stopping polar alignment…');
    }

    final future = _doStop();
    _stopFuture = future;
    try {
      await future;
    } finally {
      _stopFuture = null;
      _stopRequested = false;
    }
  }

  Future<void> _doStop() async {
    final SkotiqBackend backend = _runBackend ?? ref.read(backendProvider);
    final generation = _backendGeneration;
    try {
      await backend.stopPolarAlignment();
    } catch (e) {
      // Stop failed / timed out. Do NOT publish idle and keep hardware
      // ownership and the active phase so the UI keeps Stop available. Moving
      // to the non-active error phase would enable Back and Restart while the
      // camera or mount may still be running on the host.
      if (mounted && generation == _backendGeneration) {
        state = state.copyWith(
          errorMessage: 'Failed to stop polar alignment: $e',
          statusMessage: 'Stop failed — retry to make the rig safe',
        );
      }
      rethrow;
    }

    // A backend swap already published an explicit loss-of-control error. Do
    // not overwrite it with idle or persist a result against the replacement
    // host after the outgoing command happens to settle late.
    if (generation != _backendGeneration) return;

    // Backend confirmed termination — the run no longer owns the hardware.
    _hardwareOwned = false;
    _runBackend = null;

    // Best-effort history persistence on a user stop: the run terminated
    // successfully, but a save failure must not resurrect the run or claim
    // success — log and still settle into idle.
    if (!_historySaved &&
        state.initialError != null &&
        state.currentError != null) {
      try {
        await _saveHistoryOnce();
      } catch (e) {
        developer.log(
          '[PolarAlignmentStateNotifier] Failed to save result on stop: $e',
          name: 'PolarAlignmentStateNotifier',
          level: 900,
          error: e,
        );
      }
    }

    if (!mounted) return;
    state = state.copyWith(
      phase: PolarAlignPhase.idle,
      statusMessage: 'Polar alignment stopped',
      errorMessage: null,
    );
  }

  /// Mark alignment as complete and save the result.
  ///
  /// Requires valid measurements and a successful stop/settle *before* any
  /// persistence: a missing measurement or a failed stop throws and leaves the
  /// run visibly in error — it never creates a false success record.
  Future<void> completeAlignment({bool autoCompleted = false}) async {
    final existing = _completeFuture;
    if (existing != null) return existing;
    if (_stopFuture != null) {
      throw PolarAlignmentBusyException('Polar alignment is already stopping');
    }
    final completion = _doComplete(autoCompleted: autoCompleted);
    late Future<void> tracked;
    tracked = completion.whenComplete(() {
      if (identical(_completeFuture, tracked)) _completeFuture = null;
    });
    _completeFuture = tracked;
    return tracked;
  }

  Future<void> _doComplete({required bool autoCompleted}) async {
    // Measurements may remain visible after a backend switch so the operator
    // can diagnose what happened. They do not grant authority to Complete:
    // without an active run, dispatching Stop would target the current (and
    // potentially unrelated) backend.
    if (!_hardwareOwned && !state.isRunning) {
      throw StateError('Cannot complete polar alignment: no active run');
    }

    // Complete requires valid measurements — otherwise there is no truthful
    // record to write. Fail the awaited command instead of silently no-oping.
    if (state.initialError == null || state.currentError == null) {
      if (mounted) {
        state = state.copyWith(
          errorMessage: 'Cannot complete polar alignment: no measurement yet',
          statusMessage: 'Waiting for the first alignment measurement',
        );
      }
      throw StateError('Cannot complete polar alignment without measurements');
    }

    final starting = _startFuture;
    if (starting != null) {
      await starting;
      if (!mounted) return;
    }

    // Stop/settle the hardware first. If the stop fails the run is NOT
    // complete: keep it visible and persist nothing.
    final SkotiqBackend backend = _runBackend ?? ref.read(backendProvider);
    final generation = _backendGeneration;
    try {
      await backend.stopPolarAlignment();
    } catch (e) {
      if (mounted) {
        state = state.copyWith(
          errorMessage: 'Failed to stop before completing: $e',
          statusMessage: 'Stop failed — retry before leaving alignment',
        );
      }
      rethrow; // no save, no complete
    }
    if (generation != _backendGeneration) {
      throw PolarAlignmentBackendChangedException(
        'The imaging backend changed while polar alignment was completing.',
      );
    }
    _hardwareOwned = false;
    _runBackend = null;

    // Persist exactly one record. A save failure surfaces (propagates) and
    // does not mark the run complete.
    if (!_historySaved) {
      try {
        await _saveHistoryOnce(autoCompleted: autoCompleted);
      } catch (e) {
        // Hardware is confirmed stopped, so this is terminal and it is safe to
        // expose Restart/Done. Do not leave the UI in an active phase that
        // invites another Stop against an already-settled backend.
        if (mounted) {
          state = state.copyWith(
            phase: PolarAlignPhase.error,
            errorMessage:
                'Polar alignment stopped, but its result could not be saved: $e',
            statusMessage: 'Alignment stopped — result was not saved',
          );
        }
        rethrow;
      }
    }

    if (!mounted) return;
    state = state.copyWith(
      phase: PolarAlignPhase.complete,
      statusMessage: autoCompleted
          ? 'Polar alignment complete - threshold reached!'
          : 'Polar alignment complete',
      errorMessage: null,
    );
  }

  /// Persist the current run's result. Throws on a database failure so callers
  /// can decide whether to surface it (manual complete) or log-and-continue
  /// (user stop / native auto-complete).
  Future<void> _saveResult({bool autoCompleted = false}) async {
    if (state.initialError == null ||
        state.currentError == null ||
        state.config == null ||
        state.startedAt == null) {
      return;
    }

    // Get current equipment profile ID
    final profileId = ref.read(activeEquipmentProfileProvider)?.id;

    final result = PolarAlignmentResult(
      initialError: state.initialError!,
      finalError: state.currentError!,
      startedAt: state.startedAt!,
      completedAt: DateTime.now(),
      config: state.config!,
      autoCompleted: autoCompleted,
      equipmentProfileId: profileId,
    );

    if (ref.read(backendProvider) is NetworkBackend) {
      // The equipment host runs the same state notifier for REST-started
      // alignments and owns the authoritative history write. A remote
      // controller must not create a second row from its slightly later WS
      // timestamps; just refresh the host-backed history views.
      ref.invalidate(polarAlignmentHistoryProvider(profileId));
      ref.invalidate(lastPolarAlignmentProvider(profileId));
      ref.invalidate(polarAlignmentHistoryStreamProvider(profileId));
    } else {
      final db = ref.read(databaseProvider);
      await db.polarAlignmentHistoryDao.insertResult(result);
    }
    developer.log(
      '[PolarAlignmentStateNotifier] Saved alignment result',
      name: 'PolarAlignmentStateNotifier',
      level: 800,
    );
  }

  Future<void> _saveHistoryOnce({bool autoCompleted = false}) {
    if (_historySaved) return Future<void>.value();
    final existing = _historySaveFuture;
    if (existing != null) return existing;

    final save = _saveResult(autoCompleted: autoCompleted).then((_) {
      _historySaved = true;
    });
    late Future<void> tracked;
    tracked = save.whenComplete(() {
      if (identical(_historySaveFuture, tracked)) _historySaveFuture = null;
    });
    _historySaveFuture = tracked;
    return tracked;
  }

  /// Reset state to initial. Clears run bookkeeping so a subsequent start is
  /// admitted cleanly.
  void reset() {
    if (_startFuture != null ||
        _stopFuture != null ||
        _completeFuture != null ||
        _historySaveFuture != null ||
        _hardwareOwned ||
        state.isRunning) {
      throw PolarAlignmentBusyException(
        'Cannot reset while polar alignment is starting, running, stopping, '
        'completing, or saving history',
      );
    }
    _capturedInitialError = null;
    _hardwareOwned = false;
    _runBackend = null;
    _historySaved = false;
    state = const PolarAlignmentState();
    ref.read(polarAlignmentErrorHistoryProvider.notifier).clear();
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }
}
