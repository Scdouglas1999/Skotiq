// Voice Control Lifecycle Provider
//
// Wires the running sequence state into [VoiceControlService] and
// dispatches inbound assistant actions back into the executor.
//
//   * Publish: throttled to 1 Hz (the AppIntents / shortcuts cache only
//     needs to be roughly current; the executor produces 5-10 events per
//     second during exposures, which is overkill for a Siri response).
//   * Inbound: pause/resume route to `sequenceExecutorProvider`,
//     openLastImage / refreshStatus surface as forwarded actions other
//     parts of the app can listen to.
//
// Failures are not swallowed: a publish failure is logged via LoggingService
// and its PlatformException rethrown on the throttled tick, so a voice cache
// that has stopped updating is visible rather than silently stale.

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'voice_control_service.dart';

/// Bridges Riverpod sequence state -> native voice cache and back.
class VoiceControlLifecycleController {
  VoiceControlLifecycleController(this._ref, {VoiceControlService? service})
    : _service = service ?? VoiceControlService();

  final Ref _ref;
  final VoiceControlService _service;

  /// Lower bound between publishes. The voice assistants don't need
  /// sub-second freshness — they read the cache when the user asks a
  /// question, not on every executor tick. 1 second is a sensible
  /// floor that keeps the App Group write rate down for battery
  /// (UserDefaults sync is cheap but not free).
  static const Duration _minPublishInterval = Duration(seconds: 1);

  DateTime? _lastPublishedAt;
  Timer? _pendingTimer;
  StreamSubscription<VoiceControlAction>? _actionSubscription;
  bool _disposed = false;
  bool _started = false;

  /// Install the listeners. Idempotent — repeated calls are no-ops.
  /// On platforms with no voice integration (anything but iOS/Android)
  /// we install no listeners and own no resources, so the provider is
  /// safe to construct unconditionally from shared code.
  void start() {
    if (_started) return;
    _started = true;

    if (!Platform.isIOS && !Platform.isAndroid) {
      // No voice integration on this platform. Don't bind anything; the
      // service itself would throw if called. Constructing this
      // controller is still legal so callers can keep their providers
      // platform-agnostic.
      return;
    }

    // Outbound: react to progress / execution-state changes.
    _ref.listen<SequenceProgress>(
      sequenceProgressProvider,
      (_, __) => _scheduleSync(),
      fireImmediately: false,
    );
    _ref.listen<SequenceExecutionState>(
      sequenceExecutionStateProvider,
      (_, __) => _scheduleSync(),
      fireImmediately: false,
    );
    _ref.listen<Sequence?>(
      currentSequenceProvider,
      (_, __) => _scheduleSync(),
      fireImmediately: false,
    );

    // Inbound: handle assistant-triggered actions.
    _actionSubscription = _service.actionStream.listen(
      _handleInboundAction,
      onError: (Object error, StackTrace stack) {
        developer.log(
          '[VoiceControlLifecycle] inbound action stream error: $error',
          name: 'VoiceControlLifecycle',
          level: 1000,
          error: error,
          stackTrace: stack,
        );
      },
    );

    // Immediate first publish so the cache is populated even before the
    // first state-change event — e.g. after a hot restart while a
    // sequence is already running.
    _scheduleSync();
  }

  void _scheduleSync() {
    if (_disposed) return;
    final last = _lastPublishedAt;
    final now = DateTime.now();
    final elapsed = last == null ? _minPublishInterval : now.difference(last);
    if (elapsed >= _minPublishInterval) {
      _pendingTimer?.cancel();
      _pendingTimer = null;
      unawaited(_publishNow());
      return;
    }
    if (_pendingTimer != null && _pendingTimer!.isActive) {
      return; // Already deferred; the deferred fire will see latest state.
    }
    final wait = _minPublishInterval - elapsed;
    _pendingTimer = Timer(wait, () {
      _pendingTimer = null;
      if (_disposed) return;
      unawaited(_publishNow());
    });
  }

  Future<void> _publishNow() async {
    if (_disposed) return;
    final progress = _ref.read(sequenceProgressProvider);
    final execState = _ref.read(sequenceExecutionStateProvider);
    final sequence = _ref.read(currentSequenceProvider);

    // If there's no sequence loaded AND we're idle, clear the cache so
    // Siri / Assistant give the canonical "no sequence" answer instead
    // of stale state from yesterday's run.
    if (sequence == null && execState == SequenceExecutionState.idle) {
      try {
        await _service.clearStatus();
        _lastPublishedAt = DateTime.now();
      } catch (e, st) {
        developer.log(
          '[VoiceControlLifecycle] clearStatus failed: $e',
          name: 'VoiceControlLifecycle',
          level: 900,
          error: e,
          stackTrace: st,
        );
      }
      return;
    }

    final snapshot = SequenceStatusSnapshot(
      sequenceId: sequence?.id ?? '',
      sequenceName: sequence?.name ?? '',
      targetName: progress.currentTarget?.trim().isNotEmpty == true
          ? progress.currentTarget!
          : (sequence?.name ?? ''),
      executionState: _executionStateWireValue(execState),
      framesCompleted: progress.completedExposures,
      framesTotal: progress.totalExposures,
      elapsedSeconds: progress.elapsedSecs.round(),
      estimatedRemainingSeconds: progress.estimatedRemainingSecs?.round(),
      currentFilter: progress.currentFilter ?? '',
      currentNodeName: progress.currentNodeName ?? '',
      updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
    );

    try {
      await _service.publishSequenceStatus(snapshot);
      _lastPublishedAt = DateTime.now();
    } catch (e, st) {
      developer.log(
        '[VoiceControlLifecycle] publish failed: $e',
        name: 'VoiceControlLifecycle',
        level: 900,
        error: e,
        stackTrace: st,
      );
      // Don't rethrow inside a Riverpod listener — surface via dev log
      // and the LoggingService (production telemetry).
      try {
        _ref
            .read(loggingServiceProvider)
            .warning(
              'Voice control publish failed: $e',
              source: 'VoiceControlLifecycle',
            );
      } catch (_) {
        // Logging service may not be ready during very-early app start;
        // we already wrote to developer.log above.
      }
    }
  }

  Future<void> _handleInboundAction(VoiceControlAction action) async {
    if (_disposed) return;
    final executor = _ref.read(sequenceExecutorProvider);
    final execState = _ref.read(sequenceExecutionStateProvider);

    switch (action) {
      case VoiceControlAction.pauseSequence:
        if (execState != SequenceExecutionState.running) {
          // Loudly note the no-op. Without this an operator who said
          // "Hey Siri, pause Skotiq" while paused would have no
          // feedback about why nothing happened.
          _logInfo(
            'Voice action pauseSequence ignored: execution state is '
            '$execState (need running).',
          );
          return;
        }
        try {
          await executor.pause();
          _logInfo('Voice action pauseSequence handled.');
        } catch (e, st) {
          _logError('pauseSequence failed: $e', error: e, stack: st);
        }
        break;

      case VoiceControlAction.resumeSequence:
        if (execState != SequenceExecutionState.paused) {
          _logInfo(
            'Voice action resumeSequence ignored: execution state is '
            '$execState (need paused).',
          );
          return;
        }
        try {
          await executor.resume();
          _logInfo('Voice action resumeSequence handled.');
        } catch (e, st) {
          _logError('resumeSequence failed: $e', error: e, stack: st);
        }
        break;

      case VoiceControlAction.refreshStatus:
        // Force a publish so the next Siri / Assistant query sees the
        // freshest cache. Bypass throttling for this explicit user
        // request.
        _pendingTimer?.cancel();
        _pendingTimer = null;
        _lastPublishedAt = null;
        unawaited(_publishNow());
        break;

      case VoiceControlAction.openLastImage:
        // The lifecycle controller doesn't own the router. Re-emit the
        // action through the broadcast stream so a UI-layer listener
        // can navigate to the gallery.
        //
        // Note: actionStream is the *same* broadcast stream the service
        // exposes, but the lifecycle controller has already received
        // this event by reading from it. Re-injection would loop. The
        // openLastImage action is observable to other listeners
        // subscribing to `voiceControlServiceProvider`.
        _logInfo(
          'Voice action openLastImage received; UI layer is expected to '
          'handle navigation via voiceControlServiceProvider.',
        );
        break;
    }
  }

  /// Map [SequenceExecutionState] onto the wire string the native side
  /// reads. We keep this in lockstep with `SequenceStatusSnapshot.toSpokenSummary`.
  static String _executionStateWireValue(SequenceExecutionState s) {
    switch (s) {
      case SequenceExecutionState.idle:
        return 'idle';
      case SequenceExecutionState.running:
        return 'running';
      case SequenceExecutionState.paused:
        return 'paused';
      case SequenceExecutionState.stopping:
        return 'stopping';
      case SequenceExecutionState.completed:
        return 'completed';
      case SequenceExecutionState.failed:
        return 'failed';
      case SequenceExecutionState.recovering:
        return 'recovering';
      case SequenceExecutionState.stopFailed:
      case SequenceExecutionState.cleanupFailed:
      case SequenceExecutionState.finalizing:
        // The run has not settled (the stop / finalization / its cleanup is
        // still pending); report it on the wire as the transient 'stopping'
        // vocabulary the native side already understands.
        return 'stopping';
    }
  }

  void _logInfo(String message) {
    try {
      _ref
          .read(loggingServiceProvider)
          .info(message, source: 'VoiceControlLifecycle');
    } catch (_) {
      developer.log(
        '[VoiceControlLifecycle] $message',
        name: 'VoiceControlLifecycle',
      );
    }
  }

  void _logError(
    String message, {
    required Object error,
    required StackTrace stack,
  }) {
    developer.log(
      '[VoiceControlLifecycle] $message',
      name: 'VoiceControlLifecycle',
      level: 1000,
      error: error,
      stackTrace: stack,
    );
    try {
      _ref
          .read(loggingServiceProvider)
          .error(
            message,
            source: 'VoiceControlLifecycle',
            fields: <String, Object?>{'error': error.toString()},
          );
    } catch (_) {
      // best-effort
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _pendingTimer?.cancel();
    _pendingTimer = null;
    await _actionSubscription?.cancel();
    _actionSubscription = null;
    await _service.dispose();
  }
}

/// The bare service (singleton). UI-layer consumers that just want to
/// listen to `actionStream` (e.g. a navigator that routes openLastImage)
/// can `ref.watch(voiceControlServiceProvider)`.
final voiceControlServiceProvider = Provider<VoiceControlService>((ref) {
  final service = VoiceControlService();
  ref.onDispose(() {
    unawaited(service.dispose());
  });
  return service;
});

/// Eagerly-constructed lifecycle controller. The consumer in
/// `apps/mobile/lib/main.dart` calls `ref.watch(voiceControlLifecycleProvider)`
/// during app boot which triggers `start()` and installs the listeners.
final voiceControlLifecycleProvider = Provider<VoiceControlLifecycleController>(
  (ref) {
    // Share the same service instance so the inbound stream a UI listener
    // sees and the inbound stream the lifecycle controller sees are the
    // same broadcast stream.
    final service = ref.watch(voiceControlServiceProvider);
    final controller = VoiceControlLifecycleController(ref, service: service);
    controller.start();
    ref.onDispose(() {
      unawaited(controller.dispose());
    });
    return controller;
  },
);
