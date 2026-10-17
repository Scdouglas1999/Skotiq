// ignore_for_file: unused_local_variable

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../utils/skotiq_data_directory.dart';

/// Provider for the focus model service
final focusModelServiceProvider = Provider<FocusModelService>((ref) {
  // Plumb user-configurable thresholds
  // through so the autofocus settings panel can override the rejection /
  // reliability / filter-offset gates without a recompile.
  final config = ref.watch(focusModelConfigProvider);
  final service = FocusModelService(config: config);
  unawaited(service.initialize());
  return service;
});

/// User-configurable thresholds that gate the focus regression model.
///
/// Grouped into one config object so the autofocus settings panel can mutate
/// them.
class FocusModelConfig {
  /// Reject regressions whose absolute slope exceeds this many steps/°C.
  /// Was hardcoded `|slope| > 500`.
  final double maxAcceptableSlopeStepsPerC;

  /// Minimum R² before [FocusModel.isReliable] returns true. Was 0.7.
  final double minRSquared;

  /// Minimum sample count before [FocusModel.isReliable] returns true. Was 5.
  final int minDataPointCount;

  /// Minimum filter-offset confidence required to apply the offset during a
  /// prediction. Was 0.5.
  final double minFilterOffsetConfidence;

  const FocusModelConfig({
    this.maxAcceptableSlopeStepsPerC = 500.0,
    this.minRSquared = 0.7,
    this.minDataPointCount = 5,
    this.minFilterOffsetConfidence = 0.5,
  });

  FocusModelConfig copyWith({
    double? maxAcceptableSlopeStepsPerC,
    double? minRSquared,
    int? minDataPointCount,
    double? minFilterOffsetConfidence,
  }) {
    return FocusModelConfig(
      maxAcceptableSlopeStepsPerC:
          maxAcceptableSlopeStepsPerC ?? this.maxAcceptableSlopeStepsPerC,
      minRSquared: minRSquared ?? this.minRSquared,
      minDataPointCount: minDataPointCount ?? this.minDataPointCount,
      minFilterOffsetConfidence:
          minFilterOffsetConfidence ?? this.minFilterOffsetConfidence,
    );
  }
}

/// Provider for the focus-model thresholds. Defaults reproduce the prior
/// hardcoded behaviour exactly. Override this provider from the autofocus
/// settings panel (or in tests) to change behaviour.
///
final focusModelConfigProvider = StateProvider<FocusModelConfig>(
  (_) => const FocusModelConfig(),
);

/// A single temperature-compensation history sample collected after each
/// successful autofocus run. Persisted across sessions to feed the linear
/// regression model that predicts focus position from temperature.
///
/// Distinct from `FocusDataPoint` (in `models/backend/autofocus_result.dart`),
/// which represents a single sample on an in-progress autofocus V-curve.
class FocusHistoryPoint {
  final DateTime timestamp;
  final double temperatureCelsius;
  final int focusPosition;
  final double hfr;
  final String? filterName;

  FocusHistoryPoint({
    required this.timestamp,
    required this.temperatureCelsius,
    required this.focusPosition,
    required this.hfr,
    this.filterName,
  });

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'temperature': temperatureCelsius,
    'position': focusPosition,
    'hfr': hfr,
    'filter': filterName,
  };

  factory FocusHistoryPoint.fromJson(Map<String, dynamic> json) =>
      FocusHistoryPoint(
        timestamp: DateTime.parse(json['timestamp'] as String),
        temperatureCelsius: (json['temperature'] as num).toDouble(),
        focusPosition: json['position'] as int,
        hfr: (json['hfr'] as num).toDouble(),
        filterName: json['filter'] as String?,
      );
}

/// Linear regression result for temperature-focus correlation
class FocusModel {
  final double slope; // Steps per degree C
  final double intercept; // Base focus position at 0°C
  final double rSquared; // Correlation coefficient
  final int dataPointCount; // Number of points used
  final DateTime lastUpdated;

  FocusModel({
    required this.slope,
    required this.intercept,
    required this.rSquared,
    required this.dataPointCount,
    required this.lastUpdated,
  });

  /// Predict focus position for a given temperature
  int predictPosition(double temperatureCelsius) {
    return (intercept + slope * temperatureCelsius).round();
  }

  /// Check if model is reliable enough to use against the default thresholds.
  ///
  /// Defaults are `rSquared >= 0.7 && dataPointCount >= 5`. The regression
  /// service routes through [isReliableWith] so the operator's
  /// [FocusModelConfig] thresholds apply instead.
  bool get isReliable => isReliableWith(const FocusModelConfig());

  /// User-configurable reliability gate.
  bool isReliableWith(FocusModelConfig config) =>
      rSquared >= config.minRSquared &&
      dataPointCount >= config.minDataPointCount;

  Map<String, dynamic> toJson() => {
    'slope': slope,
    'intercept': intercept,
    'rSquared': rSquared,
    'dataPointCount': dataPointCount,
    'lastUpdated': lastUpdated.toIso8601String(),
  };

  factory FocusModel.fromJson(Map<String, dynamic> json) => FocusModel(
    slope: (json['slope'] as num).toDouble(),
    intercept: (json['intercept'] as num).toDouble(),
    rSquared: (json['rSquared'] as num).toDouble(),
    dataPointCount: json['dataPointCount'] as int,
    lastUpdated: DateTime.parse(json['lastUpdated'] as String),
  );
}

/// Coarse confidence ladder for filter-offset estimation.
///
/// Filters sampled at different temperatures carry temperature drift into
/// their offsets, so the temperature-model prediction is subtracted before
/// averaging — but only when that model is reliable. This enum surfaces the
/// reliability ladder to the UI:
///
/// - [high]: model R² ≥ threshold AND sample temperatures span ≥ 5°C.
///   Offsets are temperature-corrected and trustworthy.
/// - [medium]: model R² ≥ threshold but sample temperature spread < 5°C.
///   Offsets are temperature-corrected, but with little leverage on the
///   slope estimate, so the correction could be wrong.
/// - [low]: model R² < threshold or no model at all. Falls back to raw
///   averaging — offsets may be temperature drift in disguise.
enum FilterOffsetConfidence { high, medium, low }

/// Filter focus offset relative to a reference filter
class FilterOffset {
  final String filterName;
  final String referenceFilter;
  final int offsetSteps;
  final int measurementCount;
  final double confidence; // 0.0 to 1.0

  /// Coarse confidence band — see [FilterOffsetConfidence].
  ///
  /// Defaults to [FilterOffsetConfidence.low] for persisted offsets that carry
  /// no band; those come from raw averaging and must not be advertised as
  /// "high".
  final FilterOffsetConfidence confidenceBand;

  /// Human-readable explanation of the confidence band, suitable for UI
  /// display. Empty string for legacy/manually-set offsets.
  final String confidenceReason;

  /// True when the offset was computed after subtracting the temperature
  /// model's prediction. False for raw-average fallbacks and for persisted
  /// offsets that carry no such correction.
  final bool temperatureCorrected;

  FilterOffset({
    required this.filterName,
    required this.referenceFilter,
    required this.offsetSteps,
    required this.measurementCount,
    required this.confidence,
    this.confidenceBand = FilterOffsetConfidence.low,
    this.confidenceReason = '',
    this.temperatureCorrected = false,
  });

  Map<String, dynamic> toJson() => {
    'filterName': filterName,
    'referenceFilter': referenceFilter,
    'offsetSteps': offsetSteps,
    'measurementCount': measurementCount,
    'confidence': confidence,
    'confidenceBand': confidenceBand.name,
    'confidenceReason': confidenceReason,
    'temperatureCorrected': temperatureCorrected,
  };

  factory FilterOffset.fromJson(Map<String, dynamic> json) => FilterOffset(
    filterName: json['filterName'] as String,
    referenceFilter: json['referenceFilter'] as String,
    offsetSteps: json['offsetSteps'] as int,
    measurementCount: json['measurementCount'] as int,
    confidence: (json['confidence'] as num).toDouble(),
    confidenceBand: _confidenceBandFromJson(json['confidenceBand']),
    confidenceReason: json['confidenceReason'] as String? ?? '',
    temperatureCorrected: json['temperatureCorrected'] as bool? ?? false,
  );

  static FilterOffsetConfidence _confidenceBandFromJson(dynamic raw) {
    if (raw is String) {
      for (final value in FilterOffsetConfidence.values) {
        if (value.name == raw) return value;
      }
    }
    return FilterOffsetConfidence.low;
  }
}

/// Complete focus data for an equipment profile
class ProfileFocusData {
  final String profileId;
  final List<FocusHistoryPoint> dataPoints;
  final FocusModel? temperatureModel;
  final Map<String, FilterOffset> filterOffsets;
  final String? referenceFilter;

  ProfileFocusData({
    required this.profileId,
    this.dataPoints = const [],
    this.temperatureModel,
    this.filterOffsets = const {},
    this.referenceFilter,
  });

  ProfileFocusData copyWith({
    String? profileId,
    List<FocusHistoryPoint>? dataPoints,
    FocusModel? temperatureModel,
    bool clearTemperatureModel = false,
    Map<String, FilterOffset>? filterOffsets,
    String? referenceFilter,
    bool clearReferenceFilter = false,
  }) {
    return ProfileFocusData(
      profileId: profileId ?? this.profileId,
      dataPoints: dataPoints ?? this.dataPoints,
      temperatureModel: clearTemperatureModel
          ? null
          : (temperatureModel ?? this.temperatureModel),
      filterOffsets: filterOffsets ?? this.filterOffsets,
      referenceFilter: clearReferenceFilter
          ? null
          : (referenceFilter ?? this.referenceFilter),
    );
  }

  Map<String, dynamic> toJson() => {
    'profileId': profileId,
    'dataPoints': dataPoints.map((p) => p.toJson()).toList(),
    'temperatureModel': temperatureModel?.toJson(),
    'filterOffsets': filterOffsets.map((k, v) => MapEntry(k, v.toJson())),
    'referenceFilter': referenceFilter,
  };

  factory ProfileFocusData.fromJson(
    Map<String, dynamic> json,
  ) => ProfileFocusData(
    profileId: json['profileId'] as String,
    dataPoints:
        (json['dataPoints'] as List<dynamic>?)
            ?.map((p) => FocusHistoryPoint.fromJson(p as Map<String, dynamic>))
            .toList() ??
        [],
    temperatureModel: json['temperatureModel'] != null
        ? FocusModel.fromJson(json['temperatureModel'] as Map<String, dynamic>)
        : null,
    filterOffsets:
        (json['filterOffsets'] as Map<String, dynamic>?)?.map(
          (k, v) =>
              MapEntry(k, FilterOffset.fromJson(v as Map<String, dynamic>)),
        ) ??
        {},
    referenceFilter: json['referenceFilter'] as String?,
  );
}

/// Service for managing focus models and predictions
class FocusModelService {
  final Map<String, ProfileFocusData> _profileData = {};
  String? _storageDir;
  Future<void>? _initializeFuture;
  bool _isInitialized = false;

  /// Thresholds that gate regression rejection, reliability, and filter-offset
  /// application.
  final FocusModelConfig config;

  FocusModelService({this.config = const FocusModelConfig()});

  /// Initialize storage directory
  Future<void> initialize() async {
    if (_isInitialized) return;
    _initializeFuture ??= _initializeInternal();
    await _initializeFuture;
  }

  Future<void> _initializeInternal() async {
    final appDir = await resolveSkotiqDocumentsDirectory();
    _storageDir = '${appDir.path}/Skotiq/focus_models';
    await Directory(_storageDir!).create(recursive: true);
    await _loadAllProfiles();
    _isInitialized = true;
  }

  /// Get focus data for a profile
  ProfileFocusData? getProfileData(String profileId) {
    return _profileData[profileId];
  }

  /// Add a focus data point from an autofocus run
  Future<void> addDataPoint({
    required String profileId,
    required double temperatureCelsius,
    required int focusPosition,
    required double hfr,
    String? filterName,
  }) async {
    await initialize();
    final point = FocusHistoryPoint(
      timestamp: DateTime.now(),
      temperatureCelsius: temperatureCelsius,
      focusPosition: focusPosition,
      hfr: hfr,
      filterName: filterName,
    );

    var data =
        _profileData[profileId] ?? ProfileFocusData(profileId: profileId);
    final newPoints = [...data.dataPoints, point];

    // Keep only last 100 points to avoid unbounded growth
    if (newPoints.length > 100) {
      newPoints.removeRange(0, newPoints.length - 100);
    }

    data = data.copyWith(dataPoints: newPoints);

    // Recalculate temperature model
    final model = _calculateTemperatureModel(newPoints);
    if (model != null) {
      data = data.copyWith(temperatureModel: model);
    } else {
      data = data.copyWith(clearTemperatureModel: true);
    }

    // Update filter offsets if we have a reference filter.
    // Pass the freshly recomputed temperature model so the offset
    // estimation can subtract temperature drift before averaging.
    if (filterName != null && data.referenceFilter != null) {
      final offsets = _updateFilterOffsets(
        newPoints,
        data.referenceFilter!,
        data.temperatureModel,
      );
      data = data.copyWith(filterOffsets: offsets);
    }

    _profileData[profileId] = data;
    await _saveProfile(profileId);
  }

  /// Calculate linear regression model for temperature vs focus position
  FocusModel? _calculateTemperatureModel(List<FocusHistoryPoint> points) {
    if (points.length < 3) return null;

    // Use only the best HFR point per temperature range
    // Group by temperature buckets (1°C)
    final buckets = <int, List<FocusHistoryPoint>>{};
    for (final point in points) {
      final bucket = point.temperatureCelsius.round();
      buckets.putIfAbsent(bucket, () => []).add(point);
    }

    // Take best (lowest HFR) from each bucket
    final bestPoints = <FocusHistoryPoint>[];
    for (final bucket in buckets.values) {
      bucket.sort((a, b) => a.hfr.compareTo(b.hfr));
      bestPoints.add(bucket.first);
    }

    if (bestPoints.length < 3) return null;

    // Linear regression: y = mx + b
    // where y = focus position, x = temperature
    final n = bestPoints.length;
    double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0, sumY2 = 0;

    for (final point in bestPoints) {
      final x = point.temperatureCelsius;
      final y = point.focusPosition.toDouble();
      sumX += x;
      sumY += y;
      sumXY += x * y;
      sumX2 += x * x;
      sumY2 += y * y;
    }

    final denominator = n * sumX2 - sumX * sumX;
    if (denominator.abs() < 1e-9) {
      return null;
    }

    final slope = (n * sumXY - sumX * sumY) / denominator;
    if (slope.abs() > config.maxAcceptableSlopeStepsPerC) {
      developer.log(
        'Rejecting focus model with unrealistic slope ${slope.toStringAsFixed(2)} steps/°C '
        '(threshold ${config.maxAcceptableSlopeStepsPerC.toStringAsFixed(0)})',
        name: 'FocusModelService',
        level: 900,
      );
      return null;
    }
    final intercept = (sumY - slope * sumX) / n;

    // Calculate R-squared
    final meanY = sumY / n;
    double ssTot = 0, ssRes = 0;
    for (final point in bestPoints) {
      final predicted = intercept + slope * point.temperatureCelsius;
      ssTot += math.pow(point.focusPosition - meanY, 2);
      ssRes += math.pow(point.focusPosition - predicted, 2);
    }

    final rSquared = ssTot > 0 ? 1.0 - (ssRes / ssTot) : 0.0;

    return FocusModel(
      slope: slope,
      intercept: intercept,
      rSquared: rSquared,
      dataPointCount: bestPoints.length,
      lastUpdated: DateTime.now(),
    );
  }

  /// Minimum temperature spread (°C) required between the coldest and
  /// hottest sample before the temperature-corrected offset is reported as
  /// "high" confidence. Below this, the slope correction has little leverage,
  /// so we down-grade to "medium"..
  static const double _highConfidenceTemperatureSpreadC = 5.0;

  /// Update filter offsets based on collected data.
  ///
  /// The temperature model's prediction is subtracted at each sample's
  /// temperature before averaging, so the reported offset is the *additional*
  /// per-filter shift on top of the shared temperature relationship: for a
  /// sample at temperature `T_x` with position `P_x`,
  /// `corrected = P_x - slope * (T_x - T_ref)`, where `T_ref` is the median
  /// sample temperature (robust to outliers and independent of which filter is
  /// the reference). Without it, a filter sampled in winter shows a large
  /// offset that is really seasonal drift.
  ///
  /// When the temperature model is missing or unreliable (R² below the
  /// configured threshold), the raw average is used and flagged
  /// [FilterOffsetConfidence.low] so the UI can warn rather than present
  /// contaminated offsets as high confidence.
  Map<String, FilterOffset> _updateFilterOffsets(
    List<FocusHistoryPoint> points,
    String referenceFilter,
    FocusModel? temperatureModel,
  ) {
    final offsets = <String, FilterOffset>{};

    // Group by filter
    final byFilter = <String, List<FocusHistoryPoint>>{};
    for (final point in points) {
      if (point.filterName != null) {
        byFilter.putIfAbsent(point.filterName!, () => []).add(point);
      }
    }

    // Get reference filter data
    final refPoints = byFilter[referenceFilter];
    if (refPoints == null || refPoints.isEmpty) return offsets;

    // Decide whether the temperature model is trustworthy enough
    // to correct with. We deliberately reuse the same R²/sample-count gate
    // that gates `predictFocusPosition` so behaviour is consistent.
    //
    // We also re-estimate the slope using a *within-filter* regression
    // (positions de-meaned per filter) instead of the global model.slope.
    // Why: when filters are sampled at disjoint temperature ranges, the
    // global slope absorbs the inter-filter offset and becomes biased — e.g.
    // L at 0–8°C and R at 12–20°C with a true 50 steps/°C slope and 200-step
    // offset yields a global slope of ~64 steps/°C, which then under-corrects
    // the offset. The within-filter slope ignores between-filter level
    // differences and recovers the true 50 steps/°C.
    final hasGlobalModel =
        temperatureModel != null && temperatureModel.isReliableWith(config);
    final withinFilterSlope = _withinFilterSlope(byFilter);
    final hasReliableModel = hasGlobalModel && withinFilterSlope != null;
    final slope = hasReliableModel ? withinFilterSlope : 0.0;

    // Reference temperature for the correction. We use the median of every
    // sample's temperature (across all filters) rather than the reference
    // filter's mean: it is robust to outliers and does not bias the
    // correction toward whichever filter was nominated as the reference.
    final allTemps =
        points
            .where((p) => p.filterName != null)
            .map((p) => p.temperatureCelsius)
            .toList()
          ..sort();
    final refTemperature = allTemps.isEmpty ? 0.0 : _median(allTemps);

    // Sample temperature spread across all filtered points — used for the
    // confidence ladder (insufficient spread => medium, not high).
    final tempSpread = allTemps.isEmpty
        ? 0.0
        : (allTemps.last - allTemps.first);

    double correctedPosition(FocusHistoryPoint p) {
      return p.focusPosition - slope * (p.temperatureCelsius - refTemperature);
    }

    // Mean corrected position of the reference filter, used as the zero.
    final refCorrected = refPoints.map(correctedPosition).toList();
    final refAvg = refCorrected.reduce((a, b) => a + b) / refCorrected.length;

    // Pre-compute the confidence band for the *batch*. All offsets in a
    // single recompute share this band because they all share the same
    // temperature model and sample temperature distribution.
    final FilterOffsetConfidence batchBand;
    final String batchReason;
    if (!hasReliableModel) {
      batchBand = FilterOffsetConfidence.low;
      if (temperatureModel == null) {
        batchReason =
            'No temperature model yet — offsets are raw averages and may be '
            'contaminated by temperature drift. Collect autofocus samples '
            'across a wider temperature range.';
      } else {
        batchReason =
            'Temperature model R²=${temperatureModel.rSquared.toStringAsFixed(2)} '
            'is below the reliability threshold of '
            '${config.minRSquared.toStringAsFixed(2)} — offsets are raw '
            'averages and may include temperature drift.';
      }
      developer.log(
        'Filter offsets computed without temperature correction '
        '(${batchReason.replaceAll('\n', ' ')}); reporting low confidence.',
        name: 'FocusModelService',
        level: 900,
      );
    } else if (tempSpread < _highConfidenceTemperatureSpreadC) {
      batchBand = FilterOffsetConfidence.medium;
      batchReason =
          'Samples span only ${tempSpread.toStringAsFixed(1)}°C '
          '(< ${_highConfidenceTemperatureSpreadC.toStringAsFixed(0)}°C); '
          'temperature correction applied but the slope estimate has '
          'limited leverage.';
    } else {
      batchBand = FilterOffsetConfidence.high;
      batchReason =
          'Temperature correction applied (within-filter slope='
          '${slope.toStringAsFixed(2)} steps/°C, global model R²='
          '${temperatureModel.rSquared.toStringAsFixed(2)}, '
          'span=${tempSpread.toStringAsFixed(1)}°C).';
    }

    // Calculate offsets for each non-reference filter
    for (final entry in byFilter.entries) {
      if (entry.key == referenceFilter) continue;

      final filterPoints = entry.value;
      if (filterPoints.isEmpty) continue;

      final corrected = filterPoints.map(correctedPosition).toList();
      final filterAvg = corrected.reduce((a, b) => a + b) / corrected.length;

      final offsetSteps = (filterAvg - refAvg).round();

      // Per-filter scalar confidence: count + consistency, measured on the
      // temperature-corrected positions so a filter sampled across a
      // temperature range does not look inconsistent purely from drift.
      final variance =
          corrected
              .map((p) => math.pow(p - filterAvg, 2))
              .reduce((a, b) => a + b) /
          corrected.length;
      final stdDev = math.sqrt(variance);
      final consistency = stdDev < 50 ? 1.0 : 50 / stdDev;
      final countFactor = math.min(filterPoints.length / 5.0, 1.0);
      var confidence = (consistency * countFactor).clamp(0.0, 1.0);

      // Surface the band in the scalar too so any legacy consumer that just
      // reads `.confidence` does not get a misleading "1.0" when the batch
      // is actually low/medium.
      switch (batchBand) {
        case FilterOffsetConfidence.high:
          break;
        case FilterOffsetConfidence.medium:
          confidence = math.min(confidence, 0.6);
          break;
        case FilterOffsetConfidence.low:
          confidence = math.min(confidence, 0.3);
          break;
      }

      offsets[entry.key] = FilterOffset(
        filterName: entry.key,
        referenceFilter: referenceFilter,
        offsetSteps: offsetSteps,
        measurementCount: filterPoints.length,
        confidence: confidence,
        confidenceBand: batchBand,
        confidenceReason: batchReason,
        temperatureCorrected: hasReliableModel,
      );
    }

    return offsets;
  }

  /// Median of an already-sorted, non-empty list of doubles.
  static double _median(List<double> sorted) {
    final n = sorted.length;
    final mid = n ~/ 2;
    if (n.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2.0;
  }

  /// Estimate the temperature-vs-position slope using a *within-filter*
  /// regression — i.e., subtract each filter's mean temperature and mean
  /// position before pooling, so that between-filter level differences do
  /// not bias the slope estimate.
  ///
  /// The global `FocusModel.slope` mixes temperature drift with
  /// per-filter offset when filters are sampled at disjoint temperature
  /// ranges. The within-filter slope (also known as a fixed-effects
  /// estimator) is immune to that confound; it asks only "as T moves, how
  /// does P move within the same filter?".
  ///
  /// Returns null if there is not enough leverage to estimate a slope —
  /// e.g. every filter has fewer than 2 samples, or no filter has any
  /// temperature variation in its samples.
  static double? _withinFilterSlope(
    Map<String, List<FocusHistoryPoint>> byFilter,
  ) {
    double numerator = 0.0;
    double denominator = 0.0;

    for (final filterPoints in byFilter.values) {
      if (filterPoints.length < 2) continue;
      double meanT = 0.0;
      double meanP = 0.0;
      for (final p in filterPoints) {
        meanT += p.temperatureCelsius;
        meanP += p.focusPosition.toDouble();
      }
      meanT /= filterPoints.length;
      meanP /= filterPoints.length;

      for (final p in filterPoints) {
        final dt = p.temperatureCelsius - meanT;
        final dp = p.focusPosition - meanP;
        numerator += dt * dp;
        denominator += dt * dt;
      }
    }

    if (denominator < 1e-9) return null;
    return numerator / denominator;
  }

  /// Predict optimal focus position based on current conditions
  FocusPrediction? predictFocusPosition({
    required String profileId,
    required double currentTemperature,
    String? currentFilter,
  }) {
    final data = _profileData[profileId];
    if (data == null || data.temperatureModel == null) return null;

    final model = data.temperatureModel!;
    if (!model.isReliableWith(config)) return null;

    int predictedPosition = model.predictPosition(currentTemperature);
    double confidence = model.rSquared;

    // Apply filter offset if applicable
    int filterOffset = 0;
    if (currentFilter != null &&
        data.filterOffsets.containsKey(currentFilter)) {
      final offset = data.filterOffsets[currentFilter]!;
      if (offset.confidence >= config.minFilterOffsetConfidence) {
        filterOffset = offset.offsetSteps;
        predictedPosition += filterOffset;
        confidence *= offset.confidence;
      }
    }

    return FocusPrediction(
      position: predictedPosition,
      confidence: confidence,
      basedOnTemperature: currentTemperature,
      filterOffset: filterOffset,
      model: model,
    );
  }

  /// Check if autofocus should be triggered based on temperature drift
  bool shouldRefocus({
    required String profileId,
    required double currentTemperature,
    required double lastFocusTemperature,
    double maxDriftSteps = 50.0,
  }) {
    final data = _profileData[profileId];
    if (data == null || data.temperatureModel == null) return false;

    final model = data.temperatureModel!;
    if (!model.isReliableWith(config)) return false;

    // Calculate expected focus drift
    final tempDelta = (currentTemperature - lastFocusTemperature).abs();
    final expectedDrift = tempDelta * model.slope.abs();

    return expectedDrift >= maxDriftSteps;
  }

  /// Set the reference filter for offset calculations
  Future<void> setReferenceFilter(String profileId, String filterName) async {
    await initialize();
    var data = _profileData[profileId];
    if (data == null) return;

    data = data.copyWith(referenceFilter: filterName);

    // Recalculate offsets with new reference.
    // Include the existing temperature model so the recomputed
    // offsets are temperature-corrected when the model is reliable.
    final offsets = _updateFilterOffsets(
      data.dataPoints,
      filterName,
      data.temperatureModel,
    );
    data = data.copyWith(filterOffsets: offsets);

    _profileData[profileId] = data;
    await _saveProfile(profileId);
  }

  /// Directly update filter offsets for a profile and persist to disk.
  ///
  /// This is used by the FilterOffsetNotifier when the user manually
  /// adjusts filter offsets in the UI.
  Future<void> updateFilterOffsets(
    String profileId,
    Map<String, FilterOffset> offsets, {
    String? referenceFilter,
  }) async {
    await initialize();
    var data =
        _profileData[profileId] ?? ProfileFocusData(profileId: profileId);

    data = data.copyWith(
      filterOffsets: offsets,
      referenceFilter: referenceFilter ?? data.referenceFilter,
    );

    _profileData[profileId] = data;
    await _saveProfile(profileId);
  }

  /// Clear focus data for a profile
  Future<void> clearProfileData(String profileId) async {
    await initialize();
    _profileData.remove(profileId);
    if (_storageDir != null) {
      final file = File('$_storageDir/$profileId.json');
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  /// Export focus data
  String exportData(String profileId) {
    final data = _profileData[profileId];
    if (data == null) return '{}';
    return jsonEncode(data.toJson());
  }

  /// Import focus data
  Future<void> importData(String profileId, String jsonData) async {
    await initialize();
    final json = jsonDecode(jsonData) as Map<String, dynamic>;
    // An export identifies its source profile, but Import means "apply this
    // model to the profile the operator selected." Persisting the source id
    // caused the data to migrate back to that source key on the next launch.
    final data = ProfileFocusData.fromJson(json).copyWith(profileId: profileId);
    _profileData[profileId] = data;
    await _saveProfile(profileId);
  }

  Future<void> _saveProfile(String profileId) async {
    if (_storageDir == null) return;

    final data = _profileData[profileId];
    if (data == null) return;

    final file = File('$_storageDir/$profileId.json');
    await file.writeAsString(jsonEncode(data.toJson()));
  }

  Future<void> _loadAllProfiles() async {
    if (_storageDir == null) return;

    final dir = Directory(_storageDir!);
    if (!await dir.exists()) return;

    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        try {
          final content = await entity.readAsString();
          final json = jsonDecode(content) as Map<String, dynamic>;
          final data = ProfileFocusData.fromJson(json);
          _profileData[data.profileId] = data;
        } catch (e) {
          // Log corrupted files but continue loading others
          developer.log(
            'FocusModelService: Skipping corrupted focus data file ${entity.path}: $e',
            name: 'FocusModelService',
            level: 900,
            error: e,
          );
        }
      }
    }
  }
}

/// Result of focus position prediction
class FocusPrediction {
  final int position;
  final double confidence;
  final double basedOnTemperature;
  final int filterOffset;
  final FocusModel model;

  FocusPrediction({
    required this.position,
    required this.confidence,
    required this.basedOnTemperature,
    required this.filterOffset,
    required this.model,
  });

  /// Get a human-readable confidence description
  String get confidenceDescription {
    if (confidence >= 0.9) return 'High';
    if (confidence >= 0.7) return 'Good';
    if (confidence >= 0.5) return 'Moderate';
    return 'Low';
  }
}
