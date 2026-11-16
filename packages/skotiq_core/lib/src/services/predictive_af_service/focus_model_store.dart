part of '../predictive_af_service.dart';

extension _PredictiveAfFocusModelStore on PredictiveAfService {
  void _validateConfig(PredictiveAfConfig value) {
    if (value.minSamplesForTrust < 3 || value.minSamplesForTrust > 50) {
      throw ArgumentError.value(
        value.minSamplesForTrust,
        'minSamplesForTrust',
        'must be between 3 and 50',
      );
    }
    if (!value.highConfidenceThreshold.isFinite ||
        value.highConfidenceThreshold < 0.5 ||
        value.highConfidenceThreshold > 1) {
      throw ArgumentError.value(
        value.highConfidenceThreshold,
        'highConfidenceThreshold',
        'must be between 0.5 and 1.0',
      );
    }
    if (!value.lowConfidenceThreshold.isFinite ||
        value.lowConfidenceThreshold < 0 ||
        value.lowConfidenceThreshold > 0.9 ||
        value.lowConfidenceThreshold > value.highConfidenceThreshold) {
      throw ArgumentError.value(
        value.lowConfidenceThreshold,
        'lowConfidenceThreshold',
        'must be between 0 and the high-confidence threshold',
      );
    }
    if (!value.minCorrectionFactor.isFinite ||
        value.minCorrectionFactor < 0 ||
        value.minCorrectionFactor > 1) {
      throw ArgumentError.value(
        value.minCorrectionFactor,
        'minCorrectionFactor',
        'must be between 0 and 1',
      );
    }
    if (value.driftThresholdSteps < 20 || value.driftThresholdSteps > 2000) {
      throw ArgumentError.value(
        value.driftThresholdSteps,
        'driftThresholdSteps',
        'must be between 20 and 2000',
      );
    }
    if (value.driftRunsBeforeWarn < 1 || value.driftRunsBeforeWarn > 20) {
      throw ArgumentError.value(
        value.driftRunsBeforeWarn,
        'driftRunsBeforeWarn',
        'must be between 1 and 20',
      );
    }
  }

  Future<void> _persistConfig(SettingsDao dao, PredictiveAfConfig c) async {
    await dao.setSettings({
      PredictiveAfService._enabledKey: c.enabled.toString(),
      PredictiveAfService._minSamplesKey: c.minSamplesForTrust.toString(),
      PredictiveAfService._highConfidenceKey: c.highConfidenceThreshold
          .toString(),
      PredictiveAfService._lowConfidenceKey: c.lowConfidenceThreshold
          .toString(),
      PredictiveAfService._driftThresholdKey: c.driftThresholdSteps.toString(),
      PredictiveAfService._driftRunsKey: c.driftRunsBeforeWarn.toString(),
    });
  }

  Future<void> _hydrateFromSettings() async {
    final dao = _settingsDao;
    if (dao == null) return;
    final String? enabled;
    final String? minSamples;
    final String? highConfidence;
    final String? lowConfidence;
    final String? driftThreshold;
    final String? driftRuns;
    try {
      enabled = await dao.getSetting(PredictiveAfService._enabledKey);
      minSamples = await dao.getSetting(PredictiveAfService._minSamplesKey);
      highConfidence = await dao.getSetting(
        PredictiveAfService._highConfidenceKey,
      );
      lowConfidence = await dao.getSetting(
        PredictiveAfService._lowConfidenceKey,
      );
      driftThreshold = await dao.getSetting(
        PredictiveAfService._driftThresholdKey,
      );
      driftRuns = await dao.getSetting(PredictiveAfService._driftRunsKey);
    } on StateError {
      // Hydration is fired unawaited at provider construction; if the owner
      // is disposed (and the database closed) before it lands, keep the
      // defaults rather than surfacing a shutdown-order error.
      if (_disposed) return;
      rethrow;
    }
    if (_disposed) return;
    final loaded = _config.copyWith(
      enabled: enabled == null ? null : enabled == 'true',
      minSamplesForTrust: minSamples == null ? null : int.tryParse(minSamples),
      highConfidenceThreshold: highConfidence == null
          ? null
          : double.tryParse(highConfidence),
      lowConfidenceThreshold: lowConfidence == null
          ? null
          : double.tryParse(lowConfidence),
      driftThresholdSteps: driftThreshold == null
          ? null
          : int.tryParse(driftThreshold),
      driftRunsBeforeWarn: driftRuns == null ? null : int.tryParse(driftRuns),
    );
    try {
      _validateConfig(loaded);
      _config = loaded;
    } on ArgumentError catch (error) {
      Log.warning(
        'Ignoring invalid persisted predictive-AF config: $error',
        source: 'PredictiveAfService',
      );
    }
  }

  Future<void> _touchLastUsed(
    int? equipmentProfileId,
    String filterName,
  ) async {
    await _db.customStatement(
      'UPDATE focus_models SET last_used_at = ?, updated_at = ? '
      'WHERE equipment_profile_id IS ? AND filter_name = ?',
      <Object?>[
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
        equipmentProfileId,
        filterName,
      ],
    );
  }

  Future<Map<String, dynamic>?> _loadByKey(
    int? equipmentProfileId,
    String filterName,
  ) async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM focus_models WHERE equipment_profile_id IS ? AND filter_name = ?',
          variables: <Variable<Object>>[
            if (equipmentProfileId != null)
              Variable.withInt(equipmentProfileId)
            else
              const Variable<Object>(null),
            Variable.withString(filterName),
          ],
        )
        .get();
    if (rows.isEmpty) return null;
    return _rowToMap(rows.first);
  }

  Map<String, dynamic> _rowToMap(dynamic row) {
    // QueryRow has a `.data` Map<String, Object?>.
    final data = (row.data as Map).cast<String, Object?>();
    final samplesJson = data['training_samples_json'] as String? ?? '[]';
    final samples = (jsonDecode(samplesJson) as List<dynamic>)
        .map((s) => FocusTrainingSample.fromJson(s as Map<String, dynamic>))
        .toList();
    return <String, dynamic>{...data, 'samples': samples};
  }

  FilterFocusModel? _rawToModel(Map<String, dynamic>? raw) {
    if (raw == null) return null;
    return FilterFocusModel(
      uuid: raw['uuid'] as String,
      equipmentProfileId: raw['equipment_profile_id'] as int?,
      filterName: raw['filter_name'] as String,
      filterIndex: raw['filter_index'] as int?,
      slopeStepsPerC: (raw['temperature_compensation_slope'] as num).toDouble(),
      focusOffsetRelativeToLum: (raw['focus_offset_relative_to_lum'] as num)
          .toInt(),
      interceptAtReferenceTemp: (raw['intercept_at_reference_temp'] as num)
          .toInt(),
      referenceTempCelsius: (raw['reference_temp_celsius'] as num).toDouble(),
      lastTrainedAt: DateTime.fromMillisecondsSinceEpoch(
        (raw['last_trained_at'] as num).toInt() * 1000,
        isUtc: true,
      ),
      trainingRunCount: (raw['training_run_count'] as num).toInt(),
      confidenceScore: (raw['confidence_score'] as num).toDouble(),
      lastUsedAt: raw['last_used_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (raw['last_used_at'] as num).toInt() * 1000,
              isUtc: true,
            ),
      samples: raw['samples'] as List<FocusTrainingSample>,
      maxTrainingSamples: (raw['max_training_samples'] as num).toInt(),
      consecutiveBadPredictions: (raw['consecutive_bad_predictions'] as num)
          .toInt(),
      accumulatedDriftSteps: (raw['accumulated_drift_steps'] as num).toInt(),
    );
  }

  _RegressionFit? _fitRegression(List<FocusTrainingSample> samples) {
    final line = fitFocusTemperatureLine([
      for (final s in samples)
        (
          temperatureCelsius: s.temperatureCelsius,
          focusPosition: s.focusPosition,
          hfr: s.hfr,
        ),
    ]);
    if (line == null) return null;
    // Stored at the mean temperature, where the line passes through the mean
    // position: predictions near the data carry no intercept error.
    return _RegressionFit(
      slope: line.slope,
      intercept: line.meanPosition,
      referenceTemp: line.meanTemperatureCelsius,
      rSquared: line.rSquared,
    );
  }

  String _generateUuid() {
    // Tiny RFC4122-ish v4: 16 random bytes hex-encoded with the standard
    // version + variant nibbles. We don't pull in `package:uuid` to keep
    // the service self-contained.
    final rnd = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx
    String hex(int b) => b.toRadixString(16).padLeft(2, '0');
    final s = bytes.map(hex).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-'
        '${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
  }
}
