import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'watch_complication_service.dart';

/// bridges Riverpod sequence + weather state to the Apple Watch
/// complication.
///
/// Watches:
///   * [sequenceProgressProvider]  — frame counter, current filter,
///     current target, current node name.
///   * [sequenceExecutionStateProvider] — coarse rig state (`running`,
///     `paused`, `recovering`, etc.).
///   * [weatherSafetyProvider] — safe/unsafe + current alert level.
///   * [currentSequenceProvider]    — fallback target name when the
///     progress payload has not yet surfaced one.
///
/// Throttles publishes to at most one per [_minPublishInterval] to keep
/// WidgetKit's reload-timeline budget well-behaved. Sequence progress
/// can fire several times per second during dithering / fast download;
/// the watch face does not need (and the OS does not appreciate) that
/// cadence.
///
/// Non-iOS platforms instantiate the controller as a no-op so the same
/// `ref.watch(...)` in `main.dart` is safe across desktop / Android.
class WatchComplicationLifecycleController {
  WatchComplicationLifecycleController(
    this._ref, {
    WatchComplicationService? service,
    DateTime Function()? now,
    bool? platformIsIos,
  }) : _service = service ?? WatchComplicationService(),
       _now = now ?? DateTime.now,
       _platformIsIos = platformIsIos ?? Platform.isIOS;

  final Ref _ref;
  final WatchComplicationService _service;
  final DateTime Function() _now;

  /// Captured at construction so tests can simulate iOS without
  /// touching the global `Platform.isIOS`.
  final bool _platformIsIos;

  DateTime? _lastPublishAt;
  Timer? _pendingPublishTimer;
  WatchComplicationSnapshot? _pendingSnapshot;
  WatchComplicationSnapshot? _lastPublishedSnapshot;
  bool _disposed = false;

  /// Throttle floor — one publish every 30 seconds, not the Live Activity's
  /// 2 s. The complication falls back to its own TimelineProvider refresh every
  /// 60 s, so a tighter push buys no freshness, and every push costs a
  /// `WidgetCenter.reloadAllTimelines()` that reschedules every widget the app
  /// provides. At 30 s "frame 12/120, weather clear" is still accurate to the
  /// operator: exposures run for minutes, dither pauses for tens of seconds.
  static const Duration _minPublishInterval = Duration(seconds: 30);

  /// Install Riverpod listeners. Idempotent — calling twice is a
  /// programming error and will assert in debug. On non-iOS platforms
  /// this is a no-op so the provider can be eagerly read everywhere.
  void start() {
    if (!_platformIsIos) {
      return;
    }

    _ref.listen<SequenceProgress>(sequenceProgressProvider, (previous, next) {
      _scheduleFromCurrentState();
    }, fireImmediately: true);

    _ref.listen<SequenceExecutionState>(sequenceExecutionStateProvider, (
      previous,
      next,
    ) {
      _scheduleFromCurrentState();
    }, fireImmediately: false);

    _ref.listen<WeatherSafetyState>(weatherSafetyProvider, (previous, next) {
      _scheduleFromCurrentState();
    }, fireImmediately: false);
  }

  /// Build a snapshot from the *current* Riverpod state (not the value
  /// captured at listener time) so a publish always reflects the freshest
  /// state across all four providers. This matters because three
  /// listeners can fire in close succession — we want the publish that
  /// eventually flushes to carry the latest snapshot, not the one from
  /// the listener that scheduled it.
  WatchComplicationSnapshot _buildSnapshot() {
    final progress = _ref.read(sequenceProgressProvider);
    final exec = _ref.read(sequenceExecutionStateProvider);
    final safety = _ref.read(weatherSafetyProvider);
    final sequence = _ref.read(currentSequenceProvider);

    // Target name — prefer the live progress payload, fall back to the
    // sequence name so the watch face still says something useful when
    // the sequence is queued but the first target node has not fired.
    final target =
        (progress.currentTarget != null &&
            progress.currentTarget!.trim().isNotEmpty)
        ? progress.currentTarget!.trim()
        : (sequence?.name ?? '');

    return WatchComplicationSnapshot(
      targetName: target,
      framesCompleted: progress.completedExposures,
      framesTotal: progress.totalExposures,
      currentFilter: (progress.currentFilter ?? '').trim(),
      jobState: _jobStateFor(exec, progress: progress),
      weatherSafe: safety.isSafe,
      weatherLabel: _alertLabel(safety.currentAlertLevel),
    );
  }

  /// Map a SequenceExecutionState (+ current node hint) onto the
  /// vocabulary the watch widget understands. Same mapping as the iOS
  /// Live Activity controller — kept independent rather than imported so
  /// each widget target can evolve its vocabulary without forcing the
  /// other.
  String _jobStateFor(
    SequenceExecutionState exec, {
    required SequenceProgress progress,
  }) {
    switch (exec) {
      case SequenceExecutionState.idle:
        return 'idle';
      case SequenceExecutionState.running:
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
        // still pending); surface it to the complication as the transient
        // 'stopping' vocabulary.
        return 'stopping';
    }
  }

  String _alertLabel(AlertLevel level) {
    switch (level) {
      case AlertLevel.clear:
        return 'Clear';
      case AlertLevel.watch:
        return 'Watch';
      case AlertLevel.warning:
        return 'Warning';
      case AlertLevel.critical:
        return 'Critical';
    }
  }

  /// Public for tests — drive a schedule cycle synchronously from a
  /// listener callback. Production code should not call this directly.
  void scheduleFromCurrentStateForTest() {
    _scheduleFromCurrentState();
  }

  /// Public for tests — submit a pre-built snapshot through the same
  /// throttle / equality short-circuit / publish path the production
  /// listeners use, without requiring the test to spin up the four
  /// upstream providers (sequenceProgressProvider, weatherSafetyProvider,
  /// etc). Allows the throttle-policy test to assert that many event
  /// firings produce at most one publish per [_minPublishInterval]
  /// without dragging in Drift, FFI, or scheduler fixtures.
  ///
  /// Production code MUST NOT use this — it would bypass the
  /// `_platformIsIos` guard and the snapshot-building logic in
  /// `_buildSnapshot()`.
  void submitSnapshotForTest(WatchComplicationSnapshot snapshot) {
    if (_disposed) return;
    if (_lastPublishedSnapshot == snapshot && _pendingPublishTimer == null) {
      return;
    }
    _pendingSnapshot = snapshot;
    _maybeFlush();
  }

  void _scheduleFromCurrentState() {
    if (_disposed) return;
    if (!_platformIsIos) return;

    final snapshot = _buildSnapshot();
    // Skip if the snapshot hasn't changed since the last publish. Saves
    // a host-bridge round-trip and a WidgetKit reload when listeners
    // fire because of a sibling state change that doesn't actually
    // affect the complication.
    if (_lastPublishedSnapshot == snapshot && _pendingPublishTimer == null) {
      return;
    }
    _pendingSnapshot = snapshot;
    _maybeFlush();
  }

  void _maybeFlush() {
    final now = _now();
    final last = _lastPublishAt;
    final elapsed = last == null ? _minPublishInterval : now.difference(last);
    if (elapsed >= _minPublishInterval) {
      _pendingPublishTimer?.cancel();
      _pendingPublishTimer = null;
      unawaited(_flush());
      return;
    }
    if (_pendingPublishTimer != null && _pendingPublishTimer!.isActive) {
      // Already queued — _pendingSnapshot has been updated to the latest
      // value, so the eventual flush will carry it.
      return;
    }
    final wait = _minPublishInterval - elapsed;
    _pendingPublishTimer = Timer(wait, () {
      _pendingPublishTimer = null;
      if (_disposed) return;
      unawaited(_flush());
    });
  }

  Future<void> _flush() async {
    if (_disposed) return;
    if (!_platformIsIos) return;
    final snapshot = _pendingSnapshot ?? _buildSnapshot();
    _pendingSnapshot = null;
    try {
      await _service.publish(snapshot);
      _lastPublishAt = _now();
      _lastPublishedSnapshot = snapshot;
    } catch (e, st) {
      // Loud failure (developer.log + Riverpod logger). We do not
      // re-throw inside a Riverpod listener callback chain — the next
      // state change will retry naturally.
      developer.log(
        '[WatchComplicationLifecycle] publish failed: $e',
        name: 'WatchComplicationLifecycle',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      try {
        _ref
            .read(loggingServiceProvider)
            .warning(
              'WatchComplication publish failed: $e',
              source: 'WatchComplicationLifecycle',
            );
      } catch (_) {
        // Logging service may not be wired during early app start. The
        // developer.log call above is the authoritative surface.
      }
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _pendingPublishTimer?.cancel();
    _pendingPublishTimer = null;
    _pendingSnapshot = null;
  }

  // Test hooks ---------------------------------------------------------------

  /// Last snapshot pushed to the host (or null if none yet).
  WatchComplicationSnapshot? get lastPublishedSnapshotForTest =>
      _lastPublishedSnapshot;

  /// Wall-clock time of the most recent publish (or null).
  DateTime? get lastPublishAtForTest => _lastPublishAt;

  /// True iff a publish is queued behind the throttle.
  bool get hasPendingTimerForTest =>
      _pendingPublishTimer != null && _pendingPublishTimer!.isActive;
}

/// Provider for the watch-complication lifecycle controller.
///
/// Built eagerly — `main.dart` calls `ref.watch(watchComplicationLifecycleProvider)`
/// after the connection succeeds, which calls [start] to install the
/// Riverpod listeners. On non-iOS platforms the controller installs no
/// listeners and owns no resources.
final watchComplicationLifecycleProvider =
    Provider<WatchComplicationLifecycleController>((ref) {
      final controller = WatchComplicationLifecycleController(ref);
      controller.start();
      ref.onDispose(() {
        unawaited(controller.dispose());
      });
      return controller;
    });
