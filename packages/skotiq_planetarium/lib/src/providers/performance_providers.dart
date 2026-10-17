import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Tracks frame timing for performance monitoring.
///
/// This class collects frame time measurements and calculates
/// rolling averages to help identify performance issues and
/// potentially enable auto-quality adjustment.
class PerformanceMonitor extends ChangeNotifier {
  final List<double> _frameTimings = [];
  final List<double> _buildTimings = [];
  final List<double> _rasterTimings = [];
  static const int _maxSamples = 30;
  bool _dirty = false;
  Timer? _notifyTimer;

  PerformanceMonitor({
    Duration notifyInterval = const Duration(milliseconds: 250),
  }) {
    _notifyTimer = Timer.periodic(notifyInterval, (_) {
      if (!_dirty) return;
      _dirty = false;
      notifyListeners();
    });
  }

  /// Record a frame time measurement in milliseconds.
  void recordFrameTime(double milliseconds) {
    _record(_frameTimings, milliseconds);
    _dirty = true;
  }

  /// Record build and raster timings in milliseconds.
  void recordFrameTimings({
    required double buildMs,
    required double rasterMs,
    required double totalMs,
  }) {
    _record(_buildTimings, buildMs);
    _record(_rasterTimings, rasterMs);
    _record(_frameTimings, totalMs);
    _dirty = true;
  }

  /// Get the average frame time over recent frames.
  double get averageFrameTime {
    if (_frameTimings.isEmpty) return 0;
    return _frameTimings.reduce((a, b) => a + b) / _frameTimings.length;
  }

  /// Get the average build (UI thread) time.
  double get averageBuildTime {
    if (_buildTimings.isEmpty) return 0;
    return _buildTimings.reduce((a, b) => a + b) / _buildTimings.length;
  }

  /// Get the average raster (GPU) time.
  double get averageRasterTime {
    if (_rasterTimings.isEmpty) return 0;
    return _rasterTimings.reduce((a, b) => a + b) / _rasterTimings.length;
  }

  /// Frames per second implied by [averageFrameTime], or null until the first
  /// frame timing has been recorded.
  ///
  /// Null rather than a nominal 60: the HUD renders this as a live reading, so
  /// a number here before any frame has been measured is a measurement the
  /// monitor has not taken.
  double? get estimatedFps {
    final avg = averageFrameTime;
    return avg > 0 ? 1000 / avg : null;
  }

  /// Get the minimum frame time (best performance).
  double get minFrameTime {
    if (_frameTimings.isEmpty) return 0;
    return _frameTimings.reduce((a, b) => a < b ? a : b);
  }

  /// Get the maximum frame time (worst performance).
  double get maxFrameTime {
    if (_frameTimings.isEmpty) return 0;
    return _frameTimings.reduce((a, b) => a > b ? a : b);
  }

  /// Get the number of samples currently collected.
  int get sampleCount => _frameTimings.length;

  /// True when the measured frame rate is below 30 FPS. False while no frame
  /// has been sampled — there is no verdict to give yet.
  bool get isPerformanceLow {
    final fps = estimatedFps;
    return fps != null && fps < 30;
  }

  /// True when the measured frame rate is at least 55 FPS. False while no frame
  /// has been sampled.
  bool get isPerformanceGood {
    final fps = estimatedFps;
    return fps != null && fps >= 55;
  }

  /// Clear all collected frame timings.
  void reset() {
    _frameTimings.clear();
    _buildTimings.clear();
    _rasterTimings.clear();
    _dirty = false;
    notifyListeners();
  }

  void _record(List<double> samples, double milliseconds) {
    samples.add(milliseconds);
    if (samples.length > _maxSamples) {
      samples.removeAt(0);
    }
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    _notifyTimer = null;
    super.dispose();
  }
}

/// Provider for the performance monitor singleton.
final performanceMonitorProvider = ChangeNotifierProvider<PerformanceMonitor>((
  ref,
) {
  return PerformanceMonitor();
});

/// Toggles the on-screen performance HUD (UI-thread ms / GPU-raster ms / FPS).
///
/// Available in release builds so performance can be diagnosed on real target
/// hardware (the timing data from [PerformanceMonitor] is collected in release;
/// this only controls whether the readout is painted).
final showPerfHudProvider = StateProvider<bool>((ref) => false);
