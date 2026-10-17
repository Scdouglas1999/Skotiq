import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'live_activity_service.dart';

/// bridges the running sequence state to an iOS Live Activity.
///
/// Watches [sequenceExecutionStateProvider] + [sequenceProgressProvider] +
/// [currentSequenceProvider] and:
///
///   * calls [LiveActivityService.start] when execution enters `running`
///     from any non-active state (idle/null/completed/failed)
///   * calls [LiveActivityService.update] on progress changes, throttled
///     to at most one push every [_minUpdateInterval] (Apple's "frequent
///     updates" budget is generous but conservative is safer here)
///   * calls [LiveActivityService.end] when execution leaves the active
///     set (`running` / `paused` / `recovering` / `stopping`) — i.e. when
///     transitioning to `completed`, `failed`, or `idle`.
///
/// Non-iOS platforms instantiate the controller as a no-op (the service's
/// platform guard would throw, but we skip the calls earlier so we don't
/// fight with the desktop / Android flow).
class LiveActivityLifecycleController {
  LiveActivityLifecycleController(this._ref, {LiveActivityService? service})
    : _service = service ?? LiveActivityService();

  final Ref _ref;
  final LiveActivityService _service;

  String? _activityId;
  DateTime? _lastUpdateAt;
  DateTime? _activityStartedAt;
  String? _activeSequenceId;
  Timer? _pendingUpdateTimer;
  SequenceProgress? _pendingProgress;
  bool _disposed = false;

  /// Throttling floor. ActivityKit's frequent-updates budget is shared
  /// across all activities the app owns, so we keep this conservative at
  /// 1 update / 2 s. Sequence progress events fire at most every few
  /// hundred ms in normal operation, so this still gives near-realtime
  /// lock-screen behaviour while staying far below the daily budget.
  static const Duration _minUpdateInterval = Duration(seconds: 2);

  /// Coarse states where the user benefits from a visible Live Activity.
  /// `stopping` is included because a sequence in `stopping` may take many
  /// seconds to actually transition to `idle` (final exposure to flush,
  /// mount park, dome close); the operator needs the rig-state banner
  /// the entire time.
  static const Set<SequenceExecutionState> _activeStates = {
    SequenceExecutionState.running,
    SequenceExecutionState.paused,
    SequenceExecutionState.recovering,
    SequenceExecutionState.stopping,
  };

  /// Map [SequenceExecutionState] onto the `jobState` string the Swift
  /// widget reads. We deliberately don't expose every internal state to
  /// the widget — the widget only branches on the values listed in the
  /// Swift `ContentState.jobState` doc.
  String _jobStateForExecution(
    SequenceExecutionState exec, {
    required SequenceProgress progress,
  }) {
    switch (exec) {
      case SequenceExecutionState.idle:
        return 'idle';
      case SequenceExecutionState.running:
        // Inside `running` we further classify based on the current node
        // name so the Dynamic Island can show AF/CT/GD icons. If the
        // currentNodeName doesn't hint at a sub-state, default to
        // 'exposing' — the most common steady-state.
        final node = (progress.currentNodeName ?? '').toLowerCase();
        if (node.contains('autofocus') || node.contains('focus')) {
          return 'focusing';
        }
        if (node.contains('center')) return 'centering';
        if (node.contains('guid')) return 'guiding';
        return 'exposing';
      case SequenceExecutionState.paused:
        return 'paused';
      case SequenceExecutionState.recovering:
        return 'recovering';
      case SequenceExecutionState.stopping:
        return 'stopping';
      case SequenceExecutionState.completed:
        return 'completed';
      case SequenceExecutionState.failed:
        return 'failed';
      case SequenceExecutionState.stopFailed:
      case SequenceExecutionState.cleanupFailed:
      case SequenceExecutionState.finalizing:
        // The run has not settled (the stop / finalization / its cleanup is
        // still pending); surface it to the widget as the transient 'stopping'
        // vocabulary.
        return 'stopping';
    }
  }

  /// Install the Riverpod listeners. Idempotent — calling start() twice
  /// is a programming error and will assert in debug. The matching
  /// dispose hook runs on provider tear-down.
  void start() {
    if (!Platform.isIOS) {
      // Non-iOS platforms get a controller that observes nothing and
      // owns no resources. The provider always exists for symmetry but
      // does no work.
      return;
    }

    _ref.listen<SequenceExecutionState>(sequenceExecutionStateProvider, (
      previous,
      next,
    ) {
      _handleStateChange(previous, next);
    }, fireImmediately: false);

    _ref.listen<SequenceProgress>(sequenceProgressProvider, (previous, next) {
      _handleProgressChange(next);
    }, fireImmediately: false);
  }

  void _handleStateChange(
    SequenceExecutionState? previous,
    SequenceExecutionState next,
  ) {
    if (_disposed) return;
    final wasActive = previous != null && _activeStates.contains(previous);
    final nowActive = _activeStates.contains(next);

    if (!wasActive && nowActive && _activityId == null) {
      // Edge: starting fresh. Read the current sequence + progress and
      // request a new activity.
      unawaited(_startActivity());
      return;
    }

    if (wasActive && !nowActive) {
      // Leaving the active set — end the activity with a final terminal
      // state so the lock-screen banner shows the outcome.
      unawaited(_endActivity(next));
      return;
    }

    if (nowActive && _activityId != null) {
      // Still active, but the coarse state shifted (e.g. running → paused).
      // Trigger an update so the widget icon/colour reflects the new state.
      _scheduleUpdate();
    }
  }

  void _handleProgressChange(SequenceProgress next) {
    if (_disposed) return;
    if (_activityId == null) return; // No live activity to update.
    _pendingProgress = next;
    _scheduleUpdate();
  }

  /// Schedule an update, respecting [_minUpdateInterval]. If a previous
  /// update fired within the window, we defer this one rather than
  /// dropping it — the *latest* progress always wins because
  /// `_pendingProgress` is overwritten on every call.
  void _scheduleUpdate() {
    if (_disposed) return;
    final now = DateTime.now();
    final last = _lastUpdateAt;
    final elapsed = last == null ? _minUpdateInterval : now.difference(last);
    if (elapsed >= _minUpdateInterval) {
      _pendingUpdateTimer?.cancel();
      _pendingUpdateTimer = null;
      unawaited(_flushUpdate());
      return;
    }
    if (_pendingUpdateTimer != null && _pendingUpdateTimer!.isActive) {
      // Already queued; latest progress was captured above. Don't pile up.
      return;
    }
    final wait = _minUpdateInterval - elapsed;
    _pendingUpdateTimer = Timer(wait, () {
      _pendingUpdateTimer = null;
      if (_disposed) return;
      unawaited(_flushUpdate());
    });
  }

  Future<void> _startActivity() async {
    if (!Platform.isIOS) return;
    final sequence = _ref.read(currentSequenceProvider);
    final progress = _ref.read(sequenceProgressProvider);
    final execState = _ref.read(sequenceExecutionStateProvider);
    if (sequence == null) {
      _logger.warning(
        'LiveActivity: sequence transitioned to running but currentSequenceProvider is null; deferring activity start.',
        source: 'LiveActivityLifecycle',
      );
      return;
    }

    final jobState = _jobStateForExecution(execState, progress: progress);
    final elapsed = progress.elapsedSecs.round();
    final remaining = progress.estimatedRemainingSecs?.round();
    final targetName = progress.currentTarget?.trim().isNotEmpty == true
        ? progress.currentTarget!
        : sequence.name;

    try {
      final id = await _service.start(
        sequenceId: sequence.id,
        targetName: targetName,
        framesCompleted: progress.completedExposures,
        framesTotal: progress.totalExposures,
        elapsedSeconds: elapsed,
        estimatedRemainingSeconds: remaining,
        currentFilter: progress.currentFilter ?? '',
        currentHfr: null,
        currentNodeName: progress.currentNodeName ?? '',
        jobState: jobState,
      );
      _activityId = id;
      _activeSequenceId = sequence.id;
      _activityStartedAt = DateTime.now();
      _lastUpdateAt = _activityStartedAt;
      _logger.info(
        'LiveActivity started (id=$id, sequence=${sequence.id}, target=$targetName)',
        source: 'LiveActivityLifecycle',
      );
    } catch (e, st) {
      developer.log(
        '[LiveActivityLifecycle] start failed: $e',
        name: 'LiveActivityLifecycle',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      _logger.error(
        'LiveActivity start failed: $e',
        source: 'LiveActivityLifecycle',
        fields: <String, Object?>{
          'sequenceId': sequence.id,
          'error': e.toString(),
        },
      );
      // Deliberate: do not throw out of a Riverpod listen callback. We've
      // already surfaced via developer.log + LoggingService.
    }
  }

  Future<void> _flushUpdate() async {
    if (!Platform.isIOS) return;
    final id = _activityId;
    if (id == null) return;
    // _pendingProgress may be null between flushes; fall back to a fresh
    // read (which is non-nullable) so we always push a complete snapshot.
    final SequenceProgress? pending = _pendingProgress;
    final SequenceProgress progress =
        pending ?? _ref.read(sequenceProgressProvider);
    final execState = _ref.read(sequenceExecutionStateProvider);

    final elapsed = progress.elapsedSecs.round();
    final remaining = progress.estimatedRemainingSecs?.round();
    final jobState = _jobStateForExecution(execState, progress: progress);

    try {
      await _service.update(
        id,
        framesCompleted: progress.completedExposures,
        framesTotal: progress.totalExposures,
        elapsedSeconds: elapsed,
        estimatedRemainingSeconds: remaining,
        currentFilter: progress.currentFilter ?? '',
        currentHfr: null,
        currentNodeName: progress.currentNodeName ?? '',
        jobState: jobState,
      );
      _lastUpdateAt = DateTime.now();
      _pendingProgress = null;
    } catch (e, st) {
      developer.log(
        '[LiveActivityLifecycle] update failed: $e',
        name: 'LiveActivityLifecycle',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      _logger.warning(
        'LiveActivity update failed: $e',
        source: 'LiveActivityLifecycle',
      );
    }
  }

  Future<void> _endActivity(SequenceExecutionState terminalState) async {
    if (!Platform.isIOS) return;
    _pendingUpdateTimer?.cancel();
    _pendingUpdateTimer = null;
    final id = _activityId;
    if (id == null) return;
    _activityId = null;

    final progress = _ref.read(sequenceProgressProvider);
    final jobState = _jobStateForExecution(terminalState, progress: progress);
    final elapsed = progress.elapsedSecs.round();
    final remaining = progress.estimatedRemainingSecs?.round();

    try {
      await _service.end(
        id,
        // Immediate dismissal (DateTime.now()) — the host treats a missing
        // dismissDate as "now" too, but we set it explicitly so the
        // contract is obvious.
        dismissDate: DateTime.now(),
        framesCompleted: progress.completedExposures,
        framesTotal: progress.totalExposures,
        elapsedSeconds: elapsed,
        estimatedRemainingSeconds: remaining,
        currentFilter: progress.currentFilter ?? '',
        currentHfr: null,
        currentNodeName: progress.currentNodeName ?? '',
        jobState: jobState,
      );
      _logger.info(
        'LiveActivity ended (id=$id, terminalState=$terminalState)',
        source: 'LiveActivityLifecycle',
      );
    } catch (e, st) {
      developer.log(
        '[LiveActivityLifecycle] end failed: $e',
        name: 'LiveActivityLifecycle',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      _logger.error(
        'LiveActivity end failed: $e',
        source: 'LiveActivityLifecycle',
        fields: <String, Object?>{'activityId': id, 'error': e.toString()},
      );
    } finally {
      _activeSequenceId = null;
      _activityStartedAt = null;
      _lastUpdateAt = null;
      _pendingProgress = null;
    }
  }

  /// Best-effort lookup so consumers (tests, debug overlays) can confirm
  /// the controller currently owns an activity.
  String? get currentActivityId => _activityId;

  /// Sequence id of the activity currently displayed (if any).
  String? get currentActivitySequenceId => _activeSequenceId;

  LoggingService get _logger {
    // Read lazily — the provider container has to exist by the time any
    // listener fires, and the LoggingService is created during app start.
    return _ref.read(loggingServiceProvider);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _pendingUpdateTimer?.cancel();
    _pendingUpdateTimer = null;
    // Best-effort cleanup. If the controller is being torn down (provider
    // disposal, e.g. backend disconnect) we end the activity so the
    // lock-screen banner doesn't outlive the app.
    final id = _activityId;
    _activityId = null;
    if (id != null && Platform.isIOS) {
      try {
        await _service.end(id, dismissDate: DateTime.now());
      } catch (e, st) {
        developer.log(
          '[LiveActivityLifecycle] dispose end failed: $e',
          name: 'LiveActivityLifecycle',
          level: 900,
          error: e,
          stackTrace: st,
        );
      }
    }
  }
}

/// Provider for the Live Activity lifecycle controller.
///
/// Constructed eagerly (the consumer in `main.dart` does
/// `ref.watch(liveActivityLifecycleProvider)`), which calls [start] to
/// install the Riverpod listeners. The controller hangs around for the
/// app's lifetime; `ref.onDispose` only fires if the provider container
/// itself is torn down (test teardown, hot restart).
final liveActivityLifecycleProvider = Provider<LiveActivityLifecycleController>(
  (ref) {
    final controller = LiveActivityLifecycleController(ref);
    controller.start();
    ref.onDispose(() {
      unawaited(controller.dispose());
    });
    return controller;
  },
);
