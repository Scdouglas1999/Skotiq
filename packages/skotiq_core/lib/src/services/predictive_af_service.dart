// Predictive autofocus that learns per-filter slope across sessions.
//
// This service is the Dart side of the persisted predictive-AF subsystem.
// It mirrors the Rust [`PersistedFocusModel`] schema/math (in
// `native/skotiq_native/sequencer/src/focus_prediction.rs`) so the model
// can be evaluated synchronously on the hot path without hopping over FRB,
// while still letting Rust drive in-process predictions inside the sequencer.
//
// Storage: a single `focus_models` row per (equipment_profile_id, filter_name).
// The `training_samples_json` blob holds the rolling N-sample regression
// window. Confidence (R²) gates whether a caller can skip a real AF sweep.
//
// File ownership: this service does not touch the existing
// [FocusModelService] (which keeps its JSON-file storage for backwards
// compat). The two coexist: [FocusModelService] is the *legacy*, profile-
// scoped, in-app working set used by the equipment screen scatter plot;
// [PredictiveAfService] is the *persisted, per-filter* model that drives
// cross-session learning, drift detection, and confidence gating.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:drift/drift.dart' show Variable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/settings_dao.dart';
import '../database/database.dart' as db;
import '../backend/network_backend.dart';
import '../backend/skotiq_backend.dart';
import '../providers/backend_provider.dart';
import '../providers/database_provider.dart';
part 'predictive_af_service/predictive_af_models.dart';
part 'predictive_af_service/settings_controller.dart';
part 'predictive_af_service/regression.dart';
part 'predictive_af_service/focus_model_store.dart';

/// The service.
///
/// Public surface:
///   * [recordAutofocusOutcome] — call after every successful AF run.
///   * [evaluateForFilter] — pre-AF gate: should the sequencer apply the
///     prediction, dampen it, or force a real sweep?
///   * [recordPredictionVsActual] — post-AF: feed the actual converged
///     position back so drift tracking can surface re-train prompts.
///   * [getModel] / [listModels] / [exportModel] / [importModel] — UI.
///   * [clearSamples] — the "Re-train" button (clears samples but keeps
///     the row + lifetime counter).
class PredictiveAfService {
  final db.SkotiqDatabase _db;
  final SettingsDao? _settingsDao;
  PredictiveAfConfig _config;
  bool _disposed = false;
  Future<void>? _hydration;
  Future<void> _configWriteTail = Future<void>.value();

  final _driftController = StreamController<DriftStatus>.broadcast();

  PredictiveAfService(
    this._db, {
    PredictiveAfConfig? config,
    SettingsDao? settingsDao,
  }) : _config = config ?? const PredictiveAfConfig(),
       _settingsDao = settingsDao;

  static const _enabledKey = 'predictive_af.enabled';
  static const _minSamplesKey = 'predictive_af.min_samples_for_trust';
  static const _highConfidenceKey = 'predictive_af.high_confidence_threshold';
  static const _lowConfidenceKey = 'predictive_af.low_confidence_threshold';
  static const _driftThresholdKey = 'predictive_af.drift_threshold_steps';
  static const _driftRunsKey = 'predictive_af.drift_runs_before_warn';

  PredictiveAfConfig get config => _config;

  /// Set new gate thresholds and persist them to `app_settings` so they
  /// survive a restart. Already-recorded samples / drift counters are
  /// unaffected — only future [evaluateForFilter] calls see the new config.
  set config(PredictiveAfConfig value) {
    final dao = _settingsDao;
    if (dao == null) {
      _validateConfig(value);
      _config = value;
      return;
    }
    unawaited(updateConfig(value));
  }

  Future<void> updateConfig(PredictiveAfConfig value) async {
    await hydrated;
    _validateConfig(value);
    final operation = _configWriteTail.then((_) async {
      final dao = _settingsDao;
      if (dao != null) await _persistConfig(dao, value);
      if (!_disposed) _config = value;
    });
    _configWriteTail = operation.then<void>((_) {}, onError: (_, __) {});
    await operation;
  }

  Future<void> get hydrated => _hydration ?? Future<void>.value();

  /// Load the persisted gate thresholds from `app_settings` into [config].
  /// Called once at provider construction; missing or unparseable keys keep
  /// the current default for that field.
  Future<void> hydrateFromSettings() {
    return _hydration ??= _hydrateFromSettings();
  }

  /// Stream of drift detection events. Listen here to surface
  /// notifications in the UI.
  Stream<DriftStatus> get driftEvents => _driftController.stream;

  Future<void> dispose() async {
    _disposed = true;
    await _driftController.close();
  }

  // ── Sample recording ──────────────────────────────────────────────────

  /// Append a sample from a freshly-completed autofocus run, capping the
  /// window to `maxTrainingSamples` (default 50). Re-fits the regression
  /// and updates the stored slope/intercept/confidence.
  ///
  /// Returns the updated [FilterFocusModel]. If the regression cannot be
  /// computed yet (fewer than 3 unique-temperature samples) the slope is
  /// 0 and confidence is 0 — the row still exists so the UI can show
  /// "Building..." status.
  Future<FilterFocusModel> recordAutofocusOutcome({
    required int? equipmentProfileId,
    required String filterName,
    int? filterIndex,
    required double temperatureCelsius,
    required int focusPosition,
    required double hfr,
    DateTime? timestamp,
  }) async {
    final now = timestamp ?? DateTime.now();
    final existing = await _loadByKey(equipmentProfileId, filterName);
    final samples = <FocusTrainingSample>[
      ...?existing?['samples'] as List<FocusTrainingSample>?,
      FocusTrainingSample(
        timestampSecs: now.millisecondsSinceEpoch ~/ 1000,
        temperatureCelsius: temperatureCelsius,
        focusPosition: focusPosition,
        hfr: hfr,
      ),
    ];
    final maxSamples = (existing?['max_training_samples'] as int?) ?? 50;
    if (samples.length > maxSamples) {
      final indexedSamples = <MapEntry<int, FocusTrainingSample>>[
        for (var i = 0; i < samples.length; i++) MapEntry(i, samples[i]),
      ];
      indexedSamples.sort((a, b) {
        final byTimestamp = a.value.timestampSecs.compareTo(
          b.value.timestampSecs,
        );
        return byTimestamp != 0 ? byTimestamp : a.key.compareTo(b.key);
      });
      samples
        ..clear()
        ..addAll(
          indexedSamples
              .skip(indexedSamples.length - maxSamples)
              .map((entry) => entry.value),
        );
    }

    final regression = _fitRegression(samples);
    final slope = regression?.slope ?? 0.0;
    final referenceTemp = regression?.referenceTemp ?? temperatureCelsius;
    final intercept = regression?.intercept.round() ?? focusPosition;
    final rSquared = regression?.rSquared ?? 0.0;

    if (existing == null) {
      await _db.customStatement(
        '''
        INSERT INTO focus_models (
          uuid, equipment_profile_id, filter_name, filter_index,
          temperature_compensation_slope, focus_offset_relative_to_lum,
          intercept_at_reference_temp, reference_temp_celsius,
          last_trained_at, training_run_count, confidence_score,
          last_used_at, training_samples_json, max_training_samples,
          consecutive_bad_predictions, accumulated_drift_steps,
          created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, 1, ?, NULL, ?, ?, 0, 0, ?, ?)
        ''',
        <Object?>[
          _generateUuid(),
          equipmentProfileId,
          filterName,
          filterIndex,
          slope,
          intercept,
          referenceTemp,
          now.millisecondsSinceEpoch ~/ 1000,
          rSquared,
          jsonEncode(samples.map((s) => s.toJson()).toList()),
          maxSamples,
          now.millisecondsSinceEpoch ~/ 1000,
          now.millisecondsSinceEpoch ~/ 1000,
        ],
      );
    } else {
      await _db.customStatement(
        '''
        UPDATE focus_models SET
          filter_index = COALESCE(?, filter_index),
          temperature_compensation_slope = ?,
          intercept_at_reference_temp = ?,
          reference_temp_celsius = ?,
          last_trained_at = ?,
          training_run_count = training_run_count + 1,
          confidence_score = ?,
          training_samples_json = ?,
          updated_at = ?
        WHERE equipment_profile_id IS ? AND filter_name = ?
        ''',
        <Object?>[
          filterIndex,
          slope,
          intercept,
          referenceTemp,
          now.millisecondsSinceEpoch ~/ 1000,
          rSquared,
          jsonEncode(samples.map((s) => s.toJson()).toList()),
          now.millisecondsSinceEpoch ~/ 1000,
          equipmentProfileId,
          filterName,
        ],
      );
    }

    // Re-load to get the canonical row (so callers see exactly what's in DB).
    final fetched = await getModel(
      equipmentProfileId: equipmentProfileId,
      filterName: filterName,
    );
    return fetched!;
  }

  // ── Prediction gate ───────────────────────────────────────────────────

  /// Should the caller skip the AF sweep and trust the learned model?
  /// Updates `last_used_at` as a side effect so the UI can show staleness.
  Future<PredictiveAfDecision> evaluateForFilter({
    required int? equipmentProfileId,
    required String filterName,
    required double temperatureCelsius,
  }) async {
    final model = await getModel(
      equipmentProfileId: equipmentProfileId,
      filterName: filterName,
    );
    if (model == null) {
      return const InsufficientData('No focus model stored for this filter');
    }
    // Update last_used_at to "now". We don't await — the predict path is
    // performance-sensitive and the timestamp is purely informational.
    unawaited(_touchLastUsed(equipmentProfileId, filterName));

    if (!_config.enabled) {
      // Feature toggled off — surface a deterministic ForceAutofocus so
      // callers still get the prediction for UI display, but always run
      // a real sweep.
      return ForceAutofocus(
        suggestedPosition: model.predictPosition(temperatureCelsius),
        confidence: model.confidenceScore,
      );
    }

    final samples = model.samples;
    if (samples.length < 3 || model.confidenceScore == 0.0) {
      return InsufficientData(
        'Need at least 3 unique-temperature samples (have ${samples.length})',
      );
    }

    final predicted = model.predictPosition(temperatureCelsius);

    if (samples.length < _config.minSamplesForTrust) {
      return ForceAutofocus(
        suggestedPosition: predicted,
        confidence: model.confidenceScore,
      );
    }

    if (model.confidenceScore < _config.lowConfidenceThreshold) {
      return ForceAutofocus(
        suggestedPosition: predicted,
        confidence: model.confidenceScore,
      );
    }

    if (model.confidenceScore >= _config.highConfidenceThreshold) {
      return ApplyDirect(
        predictedPosition: predicted,
        confidence: model.confidenceScore,
      );
    }

    // Dampened band: linearly interpolate the correction factor.
    final band = math.max(
      _config.highConfidenceThreshold - _config.lowConfidenceThreshold,
      1e-6,
    );
    final t = ((model.confidenceScore - _config.lowConfidenceThreshold) / band)
        .clamp(0.0, 1.0);
    final correction =
        _config.minCorrectionFactor + t * (1.0 - _config.minCorrectionFactor);
    return ApplyDampened(
      predictedPosition: predicted,
      correctionFactor: correction,
      confidence: model.confidenceScore,
    );
  }

  // ── Drift tracking ────────────────────────────────────────────────────

  /// After a real AF run completes, call this with what the model predicted
  /// (BEFORE the AF) and the actual converged position. Updates the drift
  /// counters and, when the threshold is crossed, emits a [ShouldWarn]
  /// event on [driftEvents] AND returns it from this method.
  Future<DriftStatus> recordPredictionVsActual({
    required int? equipmentProfileId,
    required String filterName,
    required int predictedPosition,
    required int actualPosition,
  }) async {
    final model = await getModel(
      equipmentProfileId: equipmentProfileId,
      filterName: filterName,
    );
    if (model == null) {
      // No model to drift-track — pretend it's a healthy run so the caller
      // doesn't need to special-case the null path.
      final status = WithinTolerance(
        equipmentProfileId: equipmentProfileId,
        filterName: filterName,
        deltaSteps: actualPosition - predictedPosition,
      );
      _driftController.add(status);
      return status;
    }

    final delta = actualPosition - predictedPosition;
    final absDelta = delta.abs();

    if (absDelta <= _config.driftThresholdSteps) {
      // Good run — reset drift counters.
      await _db.customStatement(
        'UPDATE focus_models SET consecutive_bad_predictions = 0, '
        'accumulated_drift_steps = 0, updated_at = ? '
        'WHERE equipment_profile_id IS ? AND filter_name = ?',
        <Object?>[
          DateTime.now().millisecondsSinceEpoch ~/ 1000,
          equipmentProfileId,
          filterName,
        ],
      );
      final status = WithinTolerance(
        equipmentProfileId: equipmentProfileId,
        filterName: filterName,
        deltaSteps: delta,
      );
      _driftController.add(status);
      return status;
    }

    final newConsecutive = model.consecutiveBadPredictions + 1;
    final newAccumulated = model.accumulatedDriftSteps + absDelta;
    await _db.customStatement(
      'UPDATE focus_models SET consecutive_bad_predictions = ?, '
      'accumulated_drift_steps = ?, updated_at = ? '
      'WHERE equipment_profile_id IS ? AND filter_name = ?',
      <Object?>[
        newConsecutive,
        newAccumulated,
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
        equipmentProfileId,
        filterName,
      ],
    );

    if (newConsecutive >= _config.driftRunsBeforeWarn) {
      final msg =
          'Your $filterName filter focus model has drifted by '
          '$newAccumulated steps over the last $newConsecutive runs. '
          'Consider re-training (clear samples and start fresh).';
      developer.log(
        'Predictive AF drift warning for $filterName: $msg',
        name: 'PredictiveAfService',
        level: 900,
      );
      final status = ShouldWarn(
        equipmentProfileId: equipmentProfileId,
        filterName: filterName,
        consecutiveBadRuns: newConsecutive,
        accumulatedDriftSteps: newAccumulated,
        message: msg,
      );
      _driftController.add(status);
      return status;
    }

    final status = Drifting(
      equipmentProfileId: equipmentProfileId,
      filterName: filterName,
      deltaSteps: delta,
      consecutiveBadRuns: newConsecutive,
      accumulatedDriftSteps: newAccumulated,
    );
    _driftController.add(status);
    return status;
  }

  // ── Queries ───────────────────────────────────────────────────────────

  Future<FilterFocusModel?> getModel({
    required int? equipmentProfileId,
    required String filterName,
  }) async {
    final raw = await _loadByKey(equipmentProfileId, filterName);
    if (raw == null) return null;
    return _rawToModel(raw);
  }

  /// List every model for a profile, ordered by most-recently-used.
  Future<List<FilterFocusModel>> listModels({int? equipmentProfileId}) async {
    final query = equipmentProfileId == null
        ? _db.customSelect(
            'SELECT * FROM focus_models WHERE equipment_profile_id IS NULL '
            'ORDER BY COALESCE(last_used_at, last_trained_at) DESC',
          )
        : _db.customSelect(
            'SELECT * FROM focus_models WHERE equipment_profile_id = ? '
            'ORDER BY COALESCE(last_used_at, last_trained_at) DESC',
            variables: [Variable.withInt(equipmentProfileId)],
          );
    final rows = await query.get();
    return rows.map((r) => _rawToModel(_rowToMap(r))!).toList();
  }

  /// Export a single model as a portable JSON string.
  Future<String?> exportModel({
    required int? equipmentProfileId,
    required String filterName,
  }) async {
    final model = await getModel(
      equipmentProfileId: equipmentProfileId,
      filterName: filterName,
    );
    if (model == null) return null;
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(model.toExportJson());
  }

  /// Wipe training samples for one (profile, filter) — the "Re-train"
  /// button in the model viewer. Keeps the lifetime counter intact so the
  /// UI can show "this model has been re-trained N times".
  Future<void> clearSamples({
    required int? equipmentProfileId,
    required String filterName,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await _db.customStatement(
      '''
      UPDATE focus_models SET
        training_samples_json = '[]',
        temperature_compensation_slope = 0.0,
        intercept_at_reference_temp = 0,
        confidence_score = 0.0,
        consecutive_bad_predictions = 0,
        accumulated_drift_steps = 0,
        last_trained_at = ?,
        updated_at = ?
      WHERE equipment_profile_id IS ? AND filter_name = ?
      ''',
      <Object?>[now, now, equipmentProfileId, filterName],
    );
  }
}

/// Riverpod provider for the predictive AF service. Lives at the DB layer
/// so it can be reached from anywhere in the app.
final predictiveAfServiceProvider = Provider<PredictiveAfService>((ref) {
  final database = ref.watch(databaseProvider);
  final settingsDao = ref.watch(settingsDaoProvider);
  final service = PredictiveAfService(database, settingsDao: settingsDao);
  unawaited(service.hydrateFromSettings());
  ref.onDispose(() async {
    await service.dispose();
  });
  return service;
});
