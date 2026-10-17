part of '../device_handlers.dart';

extension FocuserDeviceHandlers on DeviceHandlers {
  /// Reject a focuser target that lies outside the driver's advertised travel.
  ///
  /// A target above `maxPosition` must be refused, not forwarded: on an ASCOM
  /// focuser advertising `maxPosition: 50000`, `move-relative delta: 900000`
  /// ran the focuser blind for roughly 40 seconds before the driver clamped it
  /// at 50000, so a mistyped extra zero reported success and ended somewhere
  /// the operator never asked for. Drivers are not required to clamp; one that
  /// does not would be commanded into its end stop.
  ///
  /// `maxPosition <= 0` means the driver advertised no travel range (its
  /// `MaxStep` threw `PropertyNotImplementedException`), so there is nothing to
  /// validate against and the request passes through untouched. A null
  /// [status] means the read itself failed — same outcome, see
  /// [_tryFocuserStatus].
  ///
  /// Takes the already-read [status] rather than fetching its own: a relative
  /// move needs the current position anyway, and ASCOM focusers are polled over
  /// COM, so reading the same status twice per request would double the driver
  /// traffic and the chance of hitting a transient property fault.
  void _requireWithinTravel({
    required String deviceId,
    required FocuserStatus? status,
    required int target,
    required String field,
    String? origin,
  }) {
    if (status == null) return;
    final maxPosition = status.maxPosition;
    if (maxPosition <= 0) return;
    if (target >= 0 && target <= maxPosition) return;

    throw BadRequestError(
      field: field,
      expected: '0 to $maxPosition',
      message: origin == null
          ? 'Focuser target $target is outside the travel range 0 to '
                '$maxPosition reported by $deviceId'
          : 'Focuser target $target ($origin) is outside the travel range 0 '
                'to $maxPosition reported by $deviceId',
    );
  }

  /// Read focuser status for the range check, tolerating a failed read.
  ///
  /// A failed read must not propagate: on a USB-contended rig a focuser status
  /// poll can transiently fault while the move itself would have succeeded, so
  /// turning that into a failed move would refuse a move the driver would have
  /// accepted. Returning null skips the guard and lets the driver arbitrate.
  Future<FocuserStatus?> _tryFocuserStatus(String deviceId) async {
    try {
      return await container
          .read(deviceBackendProvider)
          .getFocuserStatus(deviceId);
    } catch (error) {
      _logInfo(
        'focuser travel-range check skipped for $deviceId: '
        'status read failed ($error)',
      );
      return null;
    }
  }

  Future<Response> handleFocuserMoveTo(Request request) async {
    _logInfo('[API] POST /api/focuser/move-to');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final position = requireInt(payload, 'position', min: 0);

    final backend = container.read(deviceBackendProvider);
    _requireWithinTravel(
      deviceId: deviceId,
      status: await _tryFocuserStatus(deviceId),
      target: position,
      field: 'position',
    );

    final commandId = commandCorrelator?.beginCommand(
      operation: 'focuser.move-to',
      deviceId: deviceId,
    );
    try {
      await backend.focuserMoveTo(deviceId, position);
    } catch (error) {
      if (_isFocuserBusy(error)) {
        return jsonError(
          code: 'device_busy',
          message: 'The focuser is already moving.',
          statusCode: HttpStatus.conflict,
          details: {'deviceId': deviceId},
        );
      }
      rethrow;
    }

    return jsonOk({
      if (commandId != null) 'commandId': commandId,
      'status': 'moving',
    });
  }

  Future<Response> handleFocuserMoveRelative(Request request) async {
    _logInfo('[API] POST /api/focuser/move-relative');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final delta = requireInt(payload, 'delta');

    final backend = container.read(deviceBackendProvider);
    // A relative move is only meaningful against the current position, so the
    // range check is applied to the resolved target rather than to the delta.
    // Without a readable position there is no target to check, so the guard is
    // skipped rather than failing a move the driver would accept.
    final status = await _tryFocuserStatus(deviceId);
    if (status != null) {
      final current = status.position;
      _requireWithinTravel(
        deviceId: deviceId,
        status: status,
        target: current + delta,
        field: 'delta',
        origin: 'position $current + delta $delta',
      );
    }

    final commandId = commandCorrelator?.beginCommand(
      operation: 'focuser.move-relative',
      deviceId: deviceId,
    );
    try {
      await backend.focuserMoveRelative(deviceId, delta);
    } catch (error) {
      if (_isFocuserBusy(error)) {
        return jsonError(
          code: 'device_busy',
          message: 'The focuser is already moving.',
          statusCode: HttpStatus.conflict,
          details: {'deviceId': deviceId},
        );
      }
      rethrow;
    }

    return jsonOk({
      if (commandId != null) 'commandId': commandId,
      'status': 'moving',
    });
  }

  Future<Response> handleFocuserHalt(Request request) async {
    _logInfo('[API] POST /api/focuser/halt');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');

    final backend = container.read(deviceBackendProvider);
    await backend.focuserHalt(deviceId);

    return jsonOk({'status': 'halted'});
  }

  bool _isFocuserBusy(Object error) {
    final message = error is bridge_error.SkotiqError
        ? error.maybeMap(
            operationFailed: (failure) => failure.field0,
            orElse: () => error.toString(),
          )
        : error.toString();
    final normalized = message.toLowerCase();
    return normalized.contains('move failure') ||
        normalized.contains('already moving') ||
        normalized.contains('device busy') ||
        normalized.contains('focuser is busy');
  }

  Future<Response> handleAutofocusStart(Request request) async {
    _logInfo('[API] POST /api/focuser/autofocus/start');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final cameraId = requireString(payload, 'cameraId');
    final exposureTime = requireDouble(
      payload,
      'exposureTime',
      min: 0.1,
      max: 300,
    );
    final stepSize = requireInt(payload, 'stepSize', min: 1, max: 10000);
    final stepsOut = requireInt(payload, 'stepsOut', min: 1, max: 50);
    final method = optionalString(payload, 'method') ?? 'VCurve';
    final binning = optionalInt(payload, 'binning', min: 1, max: 4) ?? 1;
    final gain = optionalInt(payload, 'gain', min: 0);
    final offset = optionalInt(payload, 'offset', min: 0);
    final curveFitting =
        optionalString(payload, 'curveFitting') ?? 'Hyperbolic';
    final numberOfAttempts =
        optionalInt(payload, 'numberOfAttempts', min: 1, max: 10) ?? 1;
    final exposuresPerPoint =
        optionalInt(payload, 'exposuresPerPoint', min: 1, max: 20) ?? 1;
    final rSquaredThreshold =
        optionalDouble(payload, 'rSquaredThreshold', min: 0, max: 1) ?? 0.7;
    final outerCropRatio =
        optionalDouble(payload, 'outerCropRatio', min: 0, max: 1) ?? 1.0;
    final innerCropRatio =
        optionalDouble(payload, 'innerCropRatio', min: 0, max: 1) ?? 0.0;
    if (outerCropRatio == 0 || innerCropRatio >= outerCropRatio) {
      throw BadRequestError(
        field: 'innerCropRatio/outerCropRatio',
        expected: '0 <= inner < outer <= 1',
        message: 'Crop ratios must satisfy 0 <= inner < outer <= 1',
      );
    }
    final useBrightestNStars =
        optionalInt(payload, 'useBrightestNStars', min: 0, max: 500) ?? 10;
    final focuserSettleTimeMs =
        optionalInt(payload, 'focuserSettleTimeMs', min: 0, max: 10000) ?? 500;
    final backlashCompMethod =
        optionalString(payload, 'backlashCompMethod') ?? 'Overshoot';
    // Zero, like every other backlash default: an API caller who omits it
    // gets no compensation rather than 350 steps of someone else's focuser.
    final backlashIn =
        optionalInt(payload, 'backlashIn', min: 0, max: 10000) ?? 0;
    final backlashOut =
        optionalInt(payload, 'backlashOut', min: 0, max: 10000) ?? 0;
    // A figure this app measured on the focuser, from a stored calibration.
    // Never overrides `backlashIn`: native applies it only when the operator
    // has left theirs at 0.
    final measuredBacklashIn = optionalInt(
      payload,
      'measuredBacklashIn',
      min: 0,
      max: 10000,
    );

    // register the command so any later event with a matching
    // operation kind picks up `correlatingCommandId`. We still register
    // even in the job-model path because the event correlator's matching is
    // independent of the job's own jobId — the two evolve in parallel.
    final commandId = commandCorrelator?.beginCommand(
      operation: 'focuser.autofocus.start',
      deviceId: deviceId,
    );

    // when a JobManager is wired up and the client has
    // NOT opted into the legacy synchronous shape, return `{jobId,
    // status: queued, commandId}` immediately and run the autofocus
    // work in the background. Progress + completion arrive via WS
    // events (category=job).
    final mgr = jobManager;
    final preferLegacy = requestPrefersLegacyBlocking(request);
    if (mgr != null && !preferLegacy) {
      final job = mgr.start(
        operation: 'focuser.autofocus',
        deviceId: deviceId,
        commandId: commandId,
        work: (sink, cancellation) async {
          sink.update(null, 'Starting autofocus');
          final backend = container.read(deviceBackendProvider);
          // Race the long-running call against the job token. If the client
          // cancels, propagate that request through the backend before marking
          // the job cancelled; otherwise the REST job would disappear while
          // the camera and focuser continued a physical autofocus sweep.
          final workFuture = backend.autofocusStart(
            deviceId: deviceId,
            cameraId: cameraId,
            exposureTime: exposureTime,
            stepSize: stepSize,
            stepsOut: stepsOut,
            method: method,
            binning: binning,
            gain: gain,
            offset: offset,
            curveFitting: curveFitting,
            numberOfAttempts: numberOfAttempts,
            exposuresPerPoint: exposuresPerPoint,
            rSquaredThreshold: rSquaredThreshold,
            outerCropRatio: outerCropRatio,
            innerCropRatio: innerCropRatio,
            useBrightestNStars: useBrightestNStars,
            focuserSettleTimeMs: focuserSettleTimeMs,
            backlashCompMethod: backlashCompMethod,
            backlashIn: backlashIn,
            backlashOut: backlashOut,
            measuredBacklashIn: measuredBacklashIn,
          );
          final result = await Future.any<dynamic>([
            workFuture,
            cancellation.whenCancelled.then((_) => _CancelledMarker.instance),
          ]);
          if (result is _CancelledMarker) {
            await backend.autofocusCancel();
            // `autofocusCancel` only requests cancellation. The native sweep
            // still has to halt the motor and command its return position, so
            // keep the job running until the original work future actually
            // settles. A terminal JobCancelled event before that point would
            // let clients start another sweep on moving hardware.
            try {
              await workFuture;
            } catch (error) {
              // Cancellation normally makes the work future fail with the
              // backend's typed cancelled error. The user's cancellation is
              // authoritative once the cancel command itself succeeded.
              _logger.debug(
                'Autofocus work settled with an error after client cancellation: '
                '$error',
                source: 'DeviceHandlers',
              );
            }
            throw const JobCancelledException(
              'Autofocus cancellation requested by client',
            );
          }
          final typed = result as AutofocusResult;
          return typed.toJson();
        },
      );
      return jsonOk({
        'jobId': job.jobId,
        'status': job.state.wireName,
        if (commandId != null) 'commandId': commandId,
        'operation': job.operation,
      });
    }

    // Legacy fallback (no JobManager wired or client opted into
    // synchronous shape). Existing behaviour preserved.
    final backend = container.read(deviceBackendProvider);
    final result = await backend.autofocusStart(
      deviceId: deviceId,
      cameraId: cameraId,
      exposureTime: exposureTime,
      stepSize: stepSize,
      stepsOut: stepsOut,
      method: method,
      binning: binning,
      gain: gain,
      offset: offset,
      curveFitting: curveFitting,
      numberOfAttempts: numberOfAttempts,
      exposuresPerPoint: exposuresPerPoint,
      rSquaredThreshold: rSquaredThreshold,
      outerCropRatio: outerCropRatio,
      innerCropRatio: innerCropRatio,
      useBrightestNStars: useBrightestNStars,
      focuserSettleTimeMs: focuserSettleTimeMs,
      backlashCompMethod: backlashCompMethod,
      backlashIn: backlashIn,
      backlashOut: backlashOut,
      measuredBacklashIn: measuredBacklashIn,
    );

    return jsonOk({
      if (commandId != null) 'commandId': commandId,
      ...result.toJson(),
    });
  }

  /// Measure the connected focuser's backlash.
  ///
  /// The response relays the outcome object native produced verbatim —
  /// including a refusal with the message and remedy already worded for the
  /// operator — because a remote client reads the same evidence a local one
  /// does, and re-describing a refusal on this hop would give the product two
  /// accounts of one result.
  Future<Response> handleFocuserBacklashCalibrationStart(
    Request request,
  ) async {
    _logInfo('[API] POST /api/focuser/backlash-calibration/start');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final cameraId = requireString(payload, 'cameraId');
    final configJson = _requireCalibrationConfig(payload);

    final commandId = commandCorrelator?.beginCommand(
      operation: 'focuser.backlash-calibration.start',
      deviceId: deviceId,
    );

    final mgr = jobManager;
    final preferLegacy = requestPrefersLegacyBlocking(request);
    if (mgr != null && !preferLegacy) {
      final job = mgr.start(
        operation: 'focuser.backlash-calibration',
        deviceId: deviceId,
        commandId: commandId,
        work: (sink, cancellation) async {
          sink.update(null, 'Starting the from-below scan');
          final backend = container.read(deviceBackendProvider);
          final workFuture = backend.focuserBacklashCalibrationStart(
            deviceId: deviceId,
            cameraId: cameraId,
            configJson: configJson,
          );
          final result = await Future.any<dynamic>([
            workFuture,
            cancellation.whenCancelled.then((_) => _CancelledMarker.instance),
          ]);
          if (result is _CancelledMarker) {
            await backend.focuserBacklashCalibrationCancel();
            // Cancelling only asks. The routine still has to halt the motor
            // and drive the focuser back to where the operator left it, so the
            // job stays live until the real future settles — otherwise a
            // client could start another run on moving hardware.
            try {
              await workFuture;
            } catch (error) {
              _logger.debug(
                'Backlash calibration settled with an error after client '
                'cancellation: $error',
                source: 'DeviceHandlers',
              );
            }
            throw const JobCancelledException(
              'Backlash calibration cancellation requested by client',
            );
          }
          return {'outcome': _decodeNativeJson(result as String, 'outcome')};
        },
      );
      return jsonOk({
        'jobId': job.jobId,
        'status': job.state.wireName,
        if (commandId != null) 'commandId': commandId,
        'operation': job.operation,
      });
    }

    final backend = container.read(deviceBackendProvider);
    final outcomeJson = await backend.focuserBacklashCalibrationStart(
      deviceId: deviceId,
      cameraId: cameraId,
      configJson: configJson,
    );
    return jsonOk({
      if (commandId != null) 'commandId': commandId,
      'outcome': _decodeNativeJson(outcomeJson, 'outcome'),
    });
  }

  Future<Response> handleFocuserBacklashCalibrationCancel(
    Request request,
  ) async {
    _logInfo('[API] POST /api/focuser/backlash-calibration/cancel');
    final commandId = commandCorrelator?.beginCommand(
      operation: 'focuser.backlash-calibration.cancel',
    );
    final manager = jobManager;
    final activeJobs = manager
        ?.list(operation: 'focuser.backlash-calibration')
        .where((job) => !job.state.isTerminal)
        .toList(growable: false);
    if (activeJobs != null && activeJobs.isNotEmpty) {
      for (final job in activeJobs) {
        manager!.cancel(job.jobId);
      }
      return jsonOk({
        if (commandId != null) 'commandId': commandId,
        'status': 'cancellation_requested',
        'jobIds': activeJobs.map((job) => job.jobId).toList(growable: false),
      });
    }

    final backend = container.read(deviceBackendProvider);
    await backend.focuserBacklashCalibrationCancel();
    return jsonOk({
      if (commandId != null) 'commandId': commandId,
      'status': 'cancellation_requested',
    });
  }

  /// What a calibration run would cost, without running it, so a remote client
  /// can state the travel and the time before the operator agrees to it.
  Future<Response> handleFocuserBacklashCalibrationPlan(Request request) async {
    _logInfo('[API] POST /api/focuser/backlash-calibration/plan');
    final payload = await readJsonObject(request);
    final centerPosition = requireInt(payload, 'centerPosition', min: 0);
    final configJson = _requireCalibrationConfig(payload);
    final backend = container.read(deviceBackendProvider);
    final planJson = await backend.focuserBacklashCalibrationPlan(
      configJson: configJson,
      centerPosition: centerPosition,
    );
    return jsonOk({'plan': _decodeNativeJson(planJson, 'plan')});
  }

  /// The calibration config, as the JSON object native validates.
  ///
  /// Passed through rather than re-validated field by field: every default and
  /// every bound lives in the native routine, and a second copy of them here
  /// would be the copy that goes stale. A caller that omits it gets those
  /// defaults, which is what the desktop sends.
  String _requireCalibrationConfig(Map<String, dynamic> payload) {
    final config = payload['config'];
    if (config == null) return '{}';
    if (config is String) return config;
    if (config is Map) return jsonEncode(config);
    throw BadRequestError(
      field: 'config',
      expected: 'a JSON object or a JSON string',
      message: 'Calibration config must be a JSON object or a JSON string',
    );
  }

  /// Decode JSON produced by the native routine for embedding in a response.
  Object _decodeNativeJson(String raw, String field) {
    try {
      return jsonDecode(raw) as Object;
    } on FormatException catch (error) {
      throw StateError(
        'The backlash calibration returned a $field that could not be read: '
        '$error',
      );
    }
  }

  Future<Response> handleAutofocusCancel(Request request) async {
    _logInfo('[API] POST /api/focuser/autofocus/cancel');
    final commandId = commandCorrelator?.beginCommand(
      operation: 'focuser.autofocus.cancel',
    );
    final manager = jobManager;
    final activeJobs = manager
        ?.list(operation: 'focuser.autofocus')
        .where((job) => !job.state.isTerminal)
        .toList(growable: false);
    if (activeJobs != null && activeJobs.isNotEmpty) {
      // Drive the same cooperative token owned by the job. Its work callback
      // propagates the request to the backend and does not become terminal
      // until the physical sweep future settles.
      for (final job in activeJobs) {
        manager!.cancel(job.jobId);
      }
      return jsonOk({
        if (commandId != null) 'commandId': commandId,
        'status': 'cancellation_requested',
        'jobIds': activeJobs.map((job) => job.jobId).toList(growable: false),
      });
    }

    // Legacy/no-job run (or a sweep started by another in-process surface).
    final backend = container.read(deviceBackendProvider);
    await backend.autofocusCancel();

    return jsonOk({
      if (commandId != null) 'commandId': commandId,
      'status': 'cancellation_requested',
    });
  }
}
