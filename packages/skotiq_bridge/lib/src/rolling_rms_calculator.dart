/// Rolling RMS (Root Mean Square) Calculator
///
/// Calculates RMS using the proper formula: sqrt(mean(x²))
/// Maintains a rolling window of the last N samples.
///
/// This is used for PHD2 guiding statistics to provide accurate
/// error measurements over a recent time window.
library;

import 'dart:collection';
import 'dart:math';

/// Calculator for rolling RMS statistics
class RollingRmsCalculator {
  final Queue<double> _values = Queue();
  final int windowSize;

  /// Create a rolling RMS calculator with specified window size
  ///
  /// [windowSize] determines how many samples to keep (default: 100)
  RollingRmsCalculator({this.windowSize = 100});

  /// Add a new value to the rolling window
  ///
  /// If the window is full, the oldest value is removed.
  void add(double value) {
    _values.addLast(value);
    while (_values.length > windowSize) {
      _values.removeFirst();
    }
  }

  /// Calculate the RMS of all values in the window
  ///
  /// Returns 0 if no values are present.
  ///
  /// Formula: sqrt(sum(x²) / n)
  double get rms {
    if (_values.isEmpty) return 0;
    final sumSquares = _values.fold<double>(0, (sum, v) => sum + v * v);
    return sqrt(sumSquares / _values.length);
  }

  /// Get the number of values currently in the window
  int get count => _values.length;

  /// Check if the window is empty
  bool get isEmpty => _values.isEmpty;

  /// Check if the window is full
  bool get isFull => _values.length >= windowSize;

  /// Clear all values from the window
  void clear() {
    _values.clear();
  }

  /// Get the most recent value (or 0 if empty)
  double get latest => _values.isEmpty ? 0 : _values.last;

  /// Get the mean of all values in the window
  double get mean {
    if (_values.isEmpty) return 0;
    return _values.fold<double>(0, (sum, v) => sum + v) / _values.length;
  }

  /// Get the peak (maximum absolute) value in the window
  double get peak {
    if (_values.isEmpty) return 0;
    return _values.map((v) => v.abs()).reduce(max);
  }
}
