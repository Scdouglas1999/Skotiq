part of '../predictive_af_service.dart';

/// A single (temperature, focus_position) training sample. Mirrors the Rust
/// `FocusTrainingSample` JSON layout exactly so the same blob can be read
/// from either side.
class FocusTrainingSample {
  /// Unix seconds the sample was captured.
  final int timestampSecs;
  final double temperatureCelsius;
  final int focusPosition;
  final double hfr;

  const FocusTrainingSample({
    required this.timestampSecs,
    required this.temperatureCelsius,
    required this.focusPosition,
    required this.hfr,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'ts': timestampSecs,
    'temp': temperatureCelsius,
    'position': focusPosition,
    'hfr': hfr,
  };

  factory FocusTrainingSample.fromJson(Map<String, dynamic> json) =>
      FocusTrainingSample(
        timestampSecs: (json['ts'] as num).toInt(),
        temperatureCelsius: (json['temp'] as num).toDouble(),
        focusPosition: (json['position'] as num).toInt(),
        hfr: (json['hfr'] as num).toDouble(),
      );
}

/// User-tunable thresholds for the predictive-AF gates. Defaults match the
/// Rust [`PredictiveAfConfig`]. Mutating [PredictiveAfService.config] writes
/// them to `app_settings`, and [PredictiveAfService.hydrateFromSettings]
/// reloads them on startup so user-tuned gates survive a restart.
class PredictiveAfConfig {
  /// Toggle for the whole feature. When `false`, the service does not
  /// gate AF runs at all — it still records samples on success so the
  /// model can warm up.
  final bool enabled;

  /// Minimum number of *unique-temperature* samples required before the
  /// model is allowed to make a "trust" decision.
  final int minSamplesForTrust;

  /// R² ≥ this → apply prediction directly.
  final double highConfidenceThreshold;

  /// R² < this → force a real autofocus sweep.
  final double lowConfidenceThreshold;

  /// Dampened-band floor for the correction factor.
  final double minCorrectionFactor;

  /// Focus-position delta (steps) that counts as a "bad" prediction for
  /// drift tracking.
  final int driftThresholdSteps;

  /// Consecutive bad predictions required before the service surfaces a
  /// re-train recommendation.
  final int driftRunsBeforeWarn;

  const PredictiveAfConfig({
    this.enabled = true,
    this.minSamplesForTrust = 8,
    this.highConfidenceThreshold = 0.8,
    this.lowConfidenceThreshold = 0.5,
    this.minCorrectionFactor = 0.4,
    this.driftThresholdSteps = 200,
    this.driftRunsBeforeWarn = 5,
  });

  PredictiveAfConfig copyWith({
    bool? enabled,
    int? minSamplesForTrust,
    double? highConfidenceThreshold,
    double? lowConfidenceThreshold,
    double? minCorrectionFactor,
    int? driftThresholdSteps,
    int? driftRunsBeforeWarn,
  }) {
    return PredictiveAfConfig(
      enabled: enabled ?? this.enabled,
      minSamplesForTrust: minSamplesForTrust ?? this.minSamplesForTrust,
      highConfidenceThreshold:
          highConfidenceThreshold ?? this.highConfidenceThreshold,
      lowConfidenceThreshold:
          lowConfidenceThreshold ?? this.lowConfidenceThreshold,
      minCorrectionFactor: minCorrectionFactor ?? this.minCorrectionFactor,
      driftThresholdSteps: driftThresholdSteps ?? this.driftThresholdSteps,
      driftRunsBeforeWarn: driftRunsBeforeWarn ?? this.driftRunsBeforeWarn,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'minSamplesForTrust': minSamplesForTrust,
    'highConfidenceThreshold': highConfidenceThreshold,
    'lowConfidenceThreshold': lowConfidenceThreshold,
    'minCorrectionFactor': minCorrectionFactor,
    'driftThresholdSteps': driftThresholdSteps,
    'driftRunsBeforeWarn': driftRunsBeforeWarn,
  };

  factory PredictiveAfConfig.fromJson(Map<String, dynamic> json) {
    const defaults = PredictiveAfConfig();
    T value<T>(String key, T fallback) {
      final raw = json[key];
      return raw is T ? raw : fallback;
    }

    double number(String key, double fallback) {
      final raw = json[key];
      return raw is num && raw.isFinite ? raw.toDouble() : fallback;
    }

    return PredictiveAfConfig(
      enabled: value('enabled', defaults.enabled),
      minSamplesForTrust: value(
        'minSamplesForTrust',
        defaults.minSamplesForTrust,
      ),
      highConfidenceThreshold: number(
        'highConfidenceThreshold',
        defaults.highConfidenceThreshold,
      ),
      lowConfidenceThreshold: number(
        'lowConfidenceThreshold',
        defaults.lowConfidenceThreshold,
      ),
      minCorrectionFactor: number(
        'minCorrectionFactor',
        defaults.minCorrectionFactor,
      ),
      driftThresholdSteps: value(
        'driftThresholdSteps',
        defaults.driftThresholdSteps,
      ),
      driftRunsBeforeWarn: value(
        'driftRunsBeforeWarn',
        defaults.driftRunsBeforeWarn,
      ),
    );
  }
}

/// Compact projection of a [db.FocusModelEntry] for UI consumption.
class FilterFocusModel {
  final String uuid;
  final int? equipmentProfileId;
  final String filterName;
  final int? filterIndex;
  final double slopeStepsPerC;
  final int focusOffsetRelativeToLum;
  final int interceptAtReferenceTemp;
  final double referenceTempCelsius;
  final DateTime lastTrainedAt;
  final int trainingRunCount;
  final double confidenceScore;
  final DateTime? lastUsedAt;
  final List<FocusTrainingSample> samples;
  final int maxTrainingSamples;
  final int consecutiveBadPredictions;
  final int accumulatedDriftSteps;

  const FilterFocusModel({
    required this.uuid,
    required this.equipmentProfileId,
    required this.filterName,
    required this.filterIndex,
    required this.slopeStepsPerC,
    required this.focusOffsetRelativeToLum,
    required this.interceptAtReferenceTemp,
    required this.referenceTempCelsius,
    required this.lastTrainedAt,
    required this.trainingRunCount,
    required this.confidenceScore,
    required this.lastUsedAt,
    required this.samples,
    required this.maxTrainingSamples,
    required this.consecutiveBadPredictions,
    required this.accumulatedDriftSteps,
  });

  /// Predict focus position at a given temperature using the persisted
  /// slope + intercept (relative to the stored reference temperature).
  int predictPosition(double temperatureCelsius) {
    final delta = temperatureCelsius - referenceTempCelsius;
    return (interceptAtReferenceTemp + slopeStepsPerC * delta).round();
  }

  /// Export the full model + samples as a JSON blob (used by "Save my
  /// focus model for filter Ha as JSON" UI action).
  Map<String, dynamic> toExportJson() => <String, dynamic>{
    'schema': 'skotiq.focus_model.v1',
    'uuid': uuid,
    'filter_name': filterName,
    'filter_index': filterIndex,
    'slope_steps_per_c': slopeStepsPerC,
    'focus_offset_relative_to_lum': focusOffsetRelativeToLum,
    'intercept_at_reference_temp': interceptAtReferenceTemp,
    'reference_temp_celsius': referenceTempCelsius,
    'last_trained_at': lastTrainedAt.toIso8601String(),
    'training_run_count': trainingRunCount,
    'confidence_score': confidenceScore,
    'last_used_at': lastUsedAt?.toIso8601String(),
    'samples': samples.map((s) => s.toJson()).toList(),
    'max_training_samples': maxTrainingSamples,
  };

  Map<String, dynamic> toWireJson() => <String, dynamic>{
    ...toExportJson(),
    'equipment_profile_id': equipmentProfileId,
    'consecutive_bad_predictions': consecutiveBadPredictions,
    'accumulated_drift_steps': accumulatedDriftSteps,
  };

  factory FilterFocusModel.fromWireJson(Map<String, dynamic> json) {
    final samplesRaw = json['samples'];
    if (samplesRaw is! List) {
      throw const FormatException('Focus model samples must be an array');
    }
    return FilterFocusModel(
      uuid: json['uuid'] as String,
      equipmentProfileId: (json['equipment_profile_id'] as num?)?.toInt(),
      filterName: json['filter_name'] as String,
      filterIndex: (json['filter_index'] as num?)?.toInt(),
      slopeStepsPerC: (json['slope_steps_per_c'] as num).toDouble(),
      focusOffsetRelativeToLum: (json['focus_offset_relative_to_lum'] as num)
          .toInt(),
      interceptAtReferenceTemp: (json['intercept_at_reference_temp'] as num)
          .toInt(),
      referenceTempCelsius: (json['reference_temp_celsius'] as num).toDouble(),
      lastTrainedAt: DateTime.parse(json['last_trained_at'] as String),
      trainingRunCount: (json['training_run_count'] as num).toInt(),
      confidenceScore: (json['confidence_score'] as num).toDouble(),
      lastUsedAt: json['last_used_at'] is String
          ? DateTime.parse(json['last_used_at'] as String)
          : null,
      samples: samplesRaw
          .map(
            (sample) => FocusTrainingSample.fromJson(
              Map<String, dynamic>.from(sample as Map),
            ),
          )
          .toList(),
      maxTrainingSamples: (json['max_training_samples'] as num).toInt(),
      consecutiveBadPredictions:
          (json['consecutive_bad_predictions'] as num?)?.toInt() ?? 0,
      accumulatedDriftSteps:
          (json['accumulated_drift_steps'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Confidence-gated decision returned by
/// [PredictiveAfService.evaluateForFilter]. Mirrors the Rust
/// [`PredictiveAfDecision`] enum.
sealed class PredictiveAfDecision {
  const PredictiveAfDecision();

  /// The focus position the caller should send to the focuser, or `null`
  /// when the model says "you must run a real sweep from current position".
  int? get targetPosition;

  /// Confidence (R²) backing the decision. `null` for [InsufficientData].
  double? get confidence;
}

class InsufficientData extends PredictiveAfDecision {
  final String reason;
  const InsufficientData(this.reason);
  @override
  int? get targetPosition => null;
  @override
  double? get confidence => null;
}

class ForceAutofocus extends PredictiveAfDecision {
  final int suggestedPosition;
  @override
  final double confidence;
  const ForceAutofocus({
    required this.suggestedPosition,
    required this.confidence,
  });
  @override
  int? get targetPosition => suggestedPosition;
}

class ApplyDampened extends PredictiveAfDecision {
  final int predictedPosition;
  final double correctionFactor;
  @override
  final double confidence;
  const ApplyDampened({
    required this.predictedPosition,
    required this.correctionFactor,
    required this.confidence,
  });
  @override
  int? get targetPosition => predictedPosition;
}

class ApplyDirect extends PredictiveAfDecision {
  final int predictedPosition;
  @override
  final double confidence;
  const ApplyDirect({
    required this.predictedPosition,
    required this.confidence,
  });
  @override
  int? get targetPosition => predictedPosition;
}

/// Result of feeding an actual autofocus outcome back into the model. The
/// service surfaces [DriftStatus] objects via [PredictiveAfService.driftEvents]
/// so a notification listener can pick them up.
sealed class DriftStatus {
  final int? equipmentProfileId;
  final String filterName;
  const DriftStatus({
    required this.equipmentProfileId,
    required this.filterName,
  });
}

class WithinTolerance extends DriftStatus {
  final int deltaSteps;
  const WithinTolerance({
    required super.equipmentProfileId,
    required super.filterName,
    required this.deltaSteps,
  });
}

class Drifting extends DriftStatus {
  final int deltaSteps;
  final int consecutiveBadRuns;
  final int accumulatedDriftSteps;
  const Drifting({
    required super.equipmentProfileId,
    required super.filterName,
    required this.deltaSteps,
    required this.consecutiveBadRuns,
    required this.accumulatedDriftSteps,
  });
}

class ShouldWarn extends DriftStatus {
  final int consecutiveBadRuns;
  final int accumulatedDriftSteps;
  final String message;
  const ShouldWarn({
    required super.equipmentProfileId,
    required super.filterName,
    required this.consecutiveBadRuns,
    required this.accumulatedDriftSteps,
    required this.message,
  });
}

/// Last predictive-AF consultation, surfaced for the UI (focus model card).
///
/// Written by the device-service AF path before (the decision) and after (the
/// actual outcome) each sweep, so the operator can see whether the model trusts
/// itself for a filter, what it predicted, and how the real sweep compared.
class PredictiveAfStatus {
  final DateTime at;
  final String filterName;
  final PredictiveAfDecision decision;

  /// Best-focus position the real sweep converged to. Null until the sweep
  /// completes; stays null when the sweep failed.
  final int? actualPosition;

  const PredictiveAfStatus({
    required this.at,
    required this.filterName,
    required this.decision,
    this.actualPosition,
  });

  PredictiveAfStatus withActual(int actualPosition) => PredictiveAfStatus(
    at: at,
    filterName: filterName,
    decision: decision,
    actualPosition: actualPosition,
  );

  /// Short human label for the decision band.
  String get decisionLabel => switch (decision) {
    InsufficientData() => 'training',
    ForceAutofocus() => 'low confidence',
    ApplyDampened() => 'medium confidence',
    ApplyDirect() => 'high confidence',
  };

  /// Prediction error in steps once the sweep completed, when the model
  /// made a prediction at all.
  int? get predictionErrorSteps {
    final predicted = decision.targetPosition;
    final actual = actualPosition;
    if (predicted == null || actual == null) return null;
    return actual - predicted;
  }
}
