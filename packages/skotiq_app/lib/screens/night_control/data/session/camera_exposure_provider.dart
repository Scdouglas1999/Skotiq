// The main camera's exposure in flight, from the camera's own events.
//
// Every exposure the camera takes (a run's frames, a snapshot, a loop)
// goes through the native camera path, which publishes ExposureStarted with
// its length, ExposureProgress about five times a second, and
// ExposureComplete, ExposureCancelled or ExposureFailed when it ends. The
// sequencer's own "ExposureStarted" is not this: the executor synthesizes it
// after a frame has already finished, immediately followed by its
// ExposureCompleted, so it never describes an exposure still running.
// `cameraStateProvider.isExposing` and `exposureProgressProvider` follow the
// imaging service's captures and that synthesized pair, so neither says that
// a run's frame is being exposed.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// One exposure the camera is taking.
@immutable
class NightCameraExposure {
  const NightCameraExposure({
    required this.startedAt,
    required this.total,
    this.elapsed,
    this.reportedAt,
  });

  /// When the camera started, a true instant (UTC), as this app saw it.
  final DateTime startedAt;

  /// The exposure length in seconds.
  final double total;

  /// Seconds exposed at [reportedAt], from the camera's last progress report.
  final double? elapsed;

  /// When [elapsed] was reported (UTC).
  final DateTime? reportedAt;

  /// When the exposure should end: from the last progress report when there
  /// is one, else from the start.
  DateTime get endsAt {
    final reported = elapsed;
    final at = reportedAt;
    final remaining = reported == null || at == null
        ? null
        : (total - reported).clamp(0.0, total);
    final base = remaining == null ? startedAt : at!;
    final seconds = remaining ?? total;
    return base.add(Duration(milliseconds: (seconds * 1000).round()));
  }

  @override
  bool operator ==(Object other) =>
      other is NightCameraExposure &&
      other.startedAt == startedAt &&
      other.total == total &&
      other.elapsed == elapsed &&
      other.reportedAt == reportedAt;

  @override
  int get hashCode => Object.hash(startedAt, total, elapsed, reportedAt);
}

/// The camera's exposure in flight; null when it is not exposing.
final nightCameraExposureProvider =
    StateNotifierProvider<NightCameraExposureNotifier, NightCameraExposure?>(
  NightCameraExposureNotifier.new,
);

class NightCameraExposureNotifier extends StateNotifier<NightCameraExposure?> {
  NightCameraExposureNotifier(this._ref) : super(null) {
    _bind(_ref.read(backendProvider));
    _ref.listen<SkotiqBackend>(backendProvider, (_, next) {
      state = null;
      _bind(next);
    });
  }

  final Ref _ref;
  StreamSubscription<SkotiqEvent>? _sub;
  int _generation = 0;

  /// Progress reports closer together than this do not rebuild the stage;
  /// it counts down from the last one on its own one-second tick.
  static const Duration progressResync = Duration(seconds: 2);

  void _bind(SkotiqBackend backend) {
    final generation = ++_generation;
    final previous = _sub;
    _sub = backend.eventStream.listen((event) {
      if (generation != _generation || !mounted) return;
      _onEvent(event);
    });
    previous?.cancel();
  }

  DateTime _now() => _ref.read(clockProvider).nowUtc();

  void _onEvent(SkotiqEvent event) {
    if (event.category != EventCategory.imaging) return;
    final data = event.data;
    switch (event.eventType) {
      case 'ExposureStarted':
        final total = (data['duration_secs'] as num?)?.toDouble() ??
            (data['durationSecs'] as num?)?.toDouble();
        if (total == null || total <= 0) {
          state = null;
          return;
        }
        state = NightCameraExposure(startedAt: _now(), total: total);
      case 'ExposureProgress':
        final current = state;
        if (current == null) return;
        final remaining = (data['remainingSecs'] as num?)?.toDouble() ??
            (data['remaining_secs'] as num?)?.toDouble();
        if (remaining == null) return;
        final now = _now();
        final last = current.reportedAt ?? current.startedAt;
        if (now.difference(last) < progressResync) return;
        state = NightCameraExposure(
          startedAt: current.startedAt,
          total: current.total,
          elapsed: (current.total - remaining).clamp(0.0, current.total),
          reportedAt: now,
        );
      case 'ExposureComplete' ||
            'ExposureCompleted' ||
            'ExposureCancelled' ||
            'ExposureFailed' ||
            'DownloadStarted':
        state = null;
    }
  }

  @override
  void dispose() {
    _generation++;
    _sub?.cancel();
    super.dispose();
  }
}
