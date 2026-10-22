part of '../sequencer_handlers.dart';

/// Sky-conditions telemetry: cloud motion, weather verdict, conditions score
/// and the adaptive-swap snapshot.
extension _SequencerConditions on SequencerHandlers {
  /// POST /api/sequencer/update-cloud-motion.
  ///
  /// Mirrors `NetworkBackend.sequencerUpdateCloudMotion`. Forwards the
  /// payload into the local executor; remote controllers running the
  /// app as a thin client push their analyzer output here so the
  /// remote rig's cloud-aware triggers see fresh data.
  Future<Response> _handleSequencerUpdateCloudMotion(Request request) async {
    _logInfo('[API] POST /api/sequencer/update-cloud-motion');
    final payload = await readJsonObject(request);
    final backend = container.read(sequencerBackendProvider);
    await backend.sequencerUpdateCloudMotion(
      currentCoverPercent: optionalDouble(payload, 'currentCoverPercent'),
      predictedArrivalMinutes: optionalDouble(
        payload,
        'predictedArrivalMinutes',
      ),
      predictedOpeningMinutes: optionalDouble(
        payload,
        'predictedOpeningMinutes',
      ),
      predictedOpeningDurationSecs: optionalDouble(
        payload,
        'predictedOpeningDurationSecs',
      ),
      predictedClearSkyAlt: optionalDouble(payload, 'predictedClearSkyAlt'),
      predictedClearSkyAz: optionalDouble(payload, 'predictedClearSkyAz'),
    );
    return jsonOk({'status': 'ok'});
  }

  /// Full-night audit 2026-06-04 (defense-in-depth) — POST
  /// /api/sequencer/update-weather-verdict.
  ///
  /// Mirrors `NetworkBackend.sequencerUpdateWeatherVerdict`. Forwards the
  /// Dart-side weather-safety verdict into the local executor so a remote
  /// controller running as a thin client drives the remote rig's in-sequencer
  /// `WeatherUnsafe` trigger the same way the local controller does.
  Future<Response> _handleSequencerUpdateWeatherVerdict(Request request) async {
    _logInfo('[API] POST /api/sequencer/update-weather-verdict');
    final payload = await readJsonObject(request);
    final backend = container.read(sequencerBackendProvider);
    await backend.sequencerUpdateWeatherVerdict(
      unsafeOverride: optionalBool(payload, 'unsafeOverride'),
      advisory: optionalBool(payload, 'advisory') ?? false,
    );
    return jsonOk({'status': 'ok'});
  }

  /// POST /api/sequencer/weather-operator-clear — the operator says the sky
  /// is clear. Body: `{"durationSecs": 1800, "reason": "..."}`; `0` ends it.
  /// Goes through the host's weather safety so its snooze, its verdict push
  /// and the executor all agree.
  Future<Response> _handleSequencerWeatherOperatorClear(Request request) async {
    _logInfo('[API] POST /api/sequencer/weather-operator-clear');
    final payload = await readJsonObject(request);
    final seconds = optionalInt(
      payload,
      'durationSecs',
      min: 0,
      max: 24 * 3600,
    );
    if (seconds == null) {
      throw BadRequestError(
        field: 'durationSecs',
        expected: 'integer',
        message: 'durationSecs is required',
      );
    }
    final reason =
        optionalString(payload, 'reason') ?? 'Operator says the sky is clear';
    final safety = container.read(weatherSafetyProvider.notifier);
    if (seconds == 0) {
      safety.cancelSnooze();
    } else {
      safety.snooze(Duration(seconds: seconds), reason: reason);
    }
    return jsonOk({'status': 'ok'});
  }

  /// POST /api/sequencer/weather-resume-after — `{"seconds": 300}`.
  Future<Response> _handleSequencerWeatherResumeAfter(Request request) async {
    _logInfo('[API] POST /api/sequencer/weather-resume-after');
    final payload = await readJsonObject(request);
    final seconds = optionalInt(payload, 'seconds', min: 0, max: 24 * 3600);
    if (seconds == null) {
      throw BadRequestError(
        field: 'seconds',
        expected: 'integer',
        message: 'seconds is required',
      );
    }
    await container
        .read(safetyConfigStoreProvider)
        .setRequiredSafeDurationSeconds(seconds);
    await container
        .read(sequencerBackendProvider)
        .sequencerSetWeatherResumeAfterSafeSecs(seconds);
    container.invalidate(weatherDecisionPolicyProvider);
    return jsonOk({'status': 'ok'});
  }

  /// GET /api/sequencer/cloud-motion.
  ///
  /// Returns `{"cloud_motion": "<json>"}` (or `null`) so the remote run
  /// dashboard can render the same panel as the local one.
  Future<Response> _handleSequencerGetCloudMotion(Request request) async {
    final backend = container.read(sequencerBackendProvider);
    final json = await backend.sequencerGetCloudMotionJson();
    return jsonOk({'cloud_motion': json});
  }

  /// POST /api/sequencer/update-conditions-score.
  ///
  /// Remote controllers push the same composite sky-conditions score the
  /// local adaptive-swap driver would send through FFI. `score: null`
  /// deliberately clears telemetry in the executor.
  Future<Response> _handleSequencerUpdateConditionsScore(
    Request request,
  ) async {
    _logInfo('[API] POST /api/sequencer/update-conditions-score');
    final payload = await readJsonObject(request);
    final rawScore = payload['score'];
    final ConditionsScore? score;
    if (rawScore == null) {
      score = null;
    } else if (rawScore is Map) {
      // ConditionsScore requires `score` AND the snake_case
      // `generated_unix_secs`; both are hard `as num` casts. Its own comment
      // justifies that by "the Rust producer always emits this field", which is
      // true of the FFI path and false of this HTTP handler — a caller sending
      // the obvious {"score": {"score": 75.0}} got a 500. Report it as the
      // client error it is.
      try {
        score = ConditionsScore.fromJson(
          rawScore is Map<String, dynamic>
              ? rawScore
              : Map<String, dynamic>.from(rawScore),
        );
      } on Object {
        throw BadRequestError(
          field: 'score',
          expected: 'object with numeric score and generated_unix_secs',
          message: 'Malformed conditions-score payload',
        );
      }
    } else {
      throw BadRequestError(field: 'score', expected: 'object or null');
    }

    final backend = container.read(sequencerBackendProvider);
    await backend.sequencerUpdateConditionsScore(score);
    return jsonOk({'status': 'ok'});
  }

  /// GET /api/sequencer/adaptive-swap.
  ///
  /// Returns a structured snapshot so remote dashboards do not have to parse
  /// the native JSON string format.
  Future<Response> _handleSequencerGetAdaptiveSwap(Request request) async {
    final backend = container.read(sequencerBackendProvider);
    final snapshot = await backend.sequencerGetAdaptiveSwapSnapshot();
    return jsonOk({'adaptive_swap': snapshot?.toJson()});
  }
}
