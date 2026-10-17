import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/science/science_models.dart';
import '../services/science/period_analysis_service.dart';

/// Provider for the period analysis service singleton.
final periodAnalysisServiceProvider = Provider<PeriodAnalysisService>((ref) {
  return const PeriodAnalysisService();
});

/// Configuration for a period analysis run.
class PeriodAnalysisConfig {
  final double minPeriodDays;
  final double maxPeriodDays;
  final int frequencyOversampling;
  final int blsNbins;

  const PeriodAnalysisConfig({
    this.minPeriodDays = 0.01,
    this.maxPeriodDays = 100.0,
    this.frequencyOversampling = 5,
    this.blsNbins = 200,
  });
}

/// State for the period analysis — holds the result or loading/error state.
class PeriodAnalysisState {
  final bool isRunning;
  final PeriodAnalysisResult? result;
  final String? error;
  final double? customPeriodDays;
  final List<PhaseFoldedPoint>? customPhaseFold;

  const PeriodAnalysisState({
    this.isRunning = false,
    this.result,
    this.error,
    this.customPeriodDays,
    this.customPhaseFold,
  });

  PeriodAnalysisState copyWith({
    bool? isRunning,
    PeriodAnalysisResult? result,
    bool clearResult = false,
    String? error,
    bool clearError = false,
    double? customPeriodDays,
    bool clearCustomPeriod = false,
    List<PhaseFoldedPoint>? customPhaseFold,
    bool clearCustomPhaseFold = false,
  }) {
    return PeriodAnalysisState(
      isRunning: isRunning ?? this.isRunning,
      result: clearResult ? null : (result ?? this.result),
      error: clearError ? null : (error ?? this.error),
      customPeriodDays: clearCustomPeriod
          ? null
          : (customPeriodDays ?? this.customPeriodDays),
      customPhaseFold: clearCustomPhaseFold
          ? null
          : (customPhaseFold ?? this.customPhaseFold),
    );
  }
}

/// Notifier that manages period analysis state and computation.
class PeriodAnalysisNotifier extends Notifier<PeriodAnalysisState> {
  @override
  PeriodAnalysisState build() {
    return const PeriodAnalysisState();
  }

  /// Run period analysis on the given light curve data.
  ///
  /// Computation happens on an isolate to avoid blocking the UI.
  Future<void> runAnalysis({
    required List<LightCurvePoint> lightCurve,
    PeriodAnalysisConfig config = const PeriodAnalysisConfig(),
  }) async {
    if (lightCurve.length < 10) {
      state = state.copyWith(
        isRunning: false,
        error:
            'Need at least 10 light curve points for period analysis. '
            'Currently have ${lightCurve.length}.',
        clearResult: true,
      );
      return;
    }

    state = state.copyWith(isRunning: true, clearError: true);

    try {
      final result = await compute(
        _runAnalysisIsolate,
        _AnalysisParams(
          points: lightCurve,
          minPeriodDays: config.minPeriodDays,
          maxPeriodDays: config.maxPeriodDays,
          frequencyOversampling: config.frequencyOversampling,
          blsNbins: config.blsNbins,
        ),
      );

      state = state.copyWith(
        isRunning: false,
        result: result,
        clearError: true,
        clearCustomPeriod: true,
        clearCustomPhaseFold: true,
      );
    } catch (error, stack) {
      developer.log(
        'Period analysis failed: $error',
        name: 'PeriodAnalysis',
        level: 1000,
        error: error,
        stackTrace: stack,
      );
      state = state.copyWith(
        isRunning: false,
        error: error.toString(),
        clearResult: true,
      );
    }
  }

  /// Phase-fold the light curve at a user-specified custom period.
  void setCustomPeriod({
    required double periodDays,
    required List<LightCurvePoint> lightCurve,
  }) {
    if (periodDays <= 0 || lightCurve.isEmpty) {
      state = state.copyWith(
        clearCustomPeriod: true,
        clearCustomPhaseFold: true,
      );
      return;
    }

    final service = ref.read(periodAnalysisServiceProvider);
    final folded = service.phaseFold(
      points: lightCurve,
      periodDays: periodDays,
    );

    state = state.copyWith(
      customPeriodDays: periodDays,
      customPhaseFold: folded,
    );
  }

  /// Clear all analysis state.
  void clear() {
    state = const PeriodAnalysisState();
  }
}

/// Parameters sent to the isolate for period analysis computation.
class _AnalysisParams {
  final List<LightCurvePoint> points;
  final double minPeriodDays;
  final double maxPeriodDays;
  final int frequencyOversampling;
  final int blsNbins;

  const _AnalysisParams({
    required this.points,
    required this.minPeriodDays,
    required this.maxPeriodDays,
    required this.frequencyOversampling,
    required this.blsNbins,
  });
}

/// Top-level function that runs on an isolate (required by [compute]).
PeriodAnalysisResult _runAnalysisIsolate(_AnalysisParams params) {
  const service = PeriodAnalysisService();
  return service.analyze(
    points: params.points,
    minPeriodDays: params.minPeriodDays,
    maxPeriodDays: params.maxPeriodDays,
    frequencyOversampling: params.frequencyOversampling,
    blsNbins: params.blsNbins,
  );
}

/// The main provider for period analysis state.
final periodAnalysisProvider =
    NotifierProvider<PeriodAnalysisNotifier, PeriodAnalysisState>(
      PeriodAnalysisNotifier.new,
    );
