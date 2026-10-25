part of '../calibration_handlers.dart';

/// The end-of-night calibration step: its settings, its state, and the
/// operator's controls over it.
///
///   GET  /api/calibration/end-of-night                 — settings, status, last report
///   POST /api/calibration/end-of-night/settings        — change settings
///   POST /api/calibration/end-of-night/start           — run it now
///   POST /api/calibration/end-of-night/imaging-ended   — the night's imaging ended
///   POST /api/calibration/end-of-night/confirm-capped  — the telescope is capped
///   POST /api/calibration/end-of-night/cancel          — stop it
extension CalibrationEndOfNightHandlers on CalibrationHandlers {
  Future<Map<String, Object?>> _endOfNightJson() async {
    final dao = container.read(settingsDaoProvider);
    final settings = await EonSettings.load(dao);
    final lastRaw = await dao.getSetting(EonSettings.lastReportKey);
    Object? lastReport;
    if (lastRaw != null && lastRaw.isNotEmpty) {
      try {
        lastReport = jsonDecode(lastRaw);
      } on FormatException {
        lastReport = null;
      }
    }
    return {
      'settings': settings.toJson(),
      'status': container.read(endOfNightCalibrationProvider).toJson(),
      'lastReport': lastReport,
    };
  }

  Future<Response> handleGetEndOfNight(Request request) async {
    _logInfo('[API] GET /api/calibration/end-of-night');
    return jsonOk(await _endOfNightJson());
  }

  Future<Response> handleUpdateEndOfNightSettings(Request request) async {
    _logInfo('[API] POST /api/calibration/end-of-night/settings');
    final payload = await readJsonObject(request);
    final dao = container.read(settingsDaoProvider);
    final current = await EonSettings.load(dao);
    final mount = optionalString(payload, 'mountAction');
    if (mount != null && !const {'home', 'park', 'leave'}.contains(mount)) {
      throw BadRequestError(
        field: 'mountAction',
        expected: 'one_of:home,park,leave',
      );
    }
    final noDarkSlot = optionalString(payload, 'noDarkSlot');
    if (noDarkSlot != null && !const {'ask', 'skip'}.contains(noDarkSlot)) {
      throw BadRequestError(field: 'noDarkSlot', expected: 'one_of:ask,skip');
    }
    final updated = current.copyWith(
      enabled: optionalBool(payload, 'enabled'),
      mountAction: mount == null ? null : EonMountAction.parse(mount),
      darkCount: optionalInt(
        payload,
        'darkCount',
        min: EonSettings.minCount,
        max: EonSettings.maxCount,
      ),
      biasCount: optionalInt(
        payload,
        'biasCount',
        min: EonSettings.minCount,
        max: EonSettings.maxCount,
      ),
      noDarkSlot: noDarkSlot == null
          ? null
          : EonNoDarkSlotPolicy.parse(noDarkSlot),
      capWaitMinutes: optionalInt(payload, 'capWaitMinutes', min: 1, max: 240),
      warmUp: optionalBool(payload, 'warmUp'),
    );
    await dao.setSettings(updated.toStorage());
    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.settings,
      action: HostMutationAction.updated,
      extra: const {'namespace': EonSettings.keyPrefix},
    );
    return jsonOk(await _endOfNightJson());
  }

  Future<Response> handleStartEndOfNight(Request request) async {
    _logInfo('[API] POST /api/calibration/end-of-night/start');
    final service = container.read(endOfNightCalibrationProvider.notifier);
    if (service.isRunning) {
      return jsonConflict({
        'error': 'end_of_night_running',
        'message': 'End-of-night calibration is already running',
      });
    }
    if (!container.read(sequenceExecutionStateProvider).canStart) {
      return jsonConflict({
        'error': 'sequence_running',
        'message': 'A run is active; stop it before taking calibration frames',
      });
    }
    unawaited(
      container.read(endOfNightCalibrationCoordinatorProvider).runNow(),
    );
    return Response(
      HttpStatus.accepted,
      body: jsonEncode(await _endOfNightJson()),
      headers: const {'content-type': 'application/json'},
    );
  }

  Future<Response> handleEndOfNightImagingEnded(Request request) async {
    _logInfo('[API] POST /api/calibration/end-of-night/imaging-ended');
    final payload = await readJsonObjectOrEmpty(request);
    final raw = optionalString(payload, 'reason') ?? 'obstruction';
    final reason = EonEndReason.values.where((r) => r.name == raw).firstOrNull;
    if (reason == null) {
      throw BadRequestError(
        field: 'reason',
        expected: 'one_of:${EonEndReason.values.map((r) => r.name).join(',')}',
      );
    }
    final started = await container
        .read(endOfNightCalibrationCoordinatorProvider)
        .imagingEnded(reason);
    return jsonOk({'started': started, ...await _endOfNightJson()});
  }

  Future<Response> handleConfirmEndOfNightCapped(Request request) async {
    _logInfo('[API] POST /api/calibration/end-of-night/confirm-capped');
    final confirmed = container
        .read(endOfNightCalibrationProvider.notifier)
        .confirmCapped();
    if (!confirmed) {
      return jsonConflict({
        'error': 'not_waiting_for_cap',
        'message': 'End-of-night calibration is not waiting for a cap',
      });
    }
    return jsonOk(await _endOfNightJson());
  }

  Future<Response> handleCancelEndOfNight(Request request) async {
    _logInfo('[API] POST /api/calibration/end-of-night/cancel');
    await container.read(endOfNightCalibrationProvider.notifier).cancel();
    return jsonOk(await _endOfNightJson());
  }
}
