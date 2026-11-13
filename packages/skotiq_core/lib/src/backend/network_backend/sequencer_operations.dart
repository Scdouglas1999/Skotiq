part of '../network_backend.dart';

mixin _NetworkBackendSequencerOperations on _NetworkBackendTransport {
  /// Remote-only: schedule the run loaded on the host to start at tonight's
  /// astronomical dark. The host starts it itself, so it does not depend on
  /// this client staying awake or connected. Returns when it will start.
  Future<DateTime?> armHostStartAtDark() async {
    final response = await _post(
      SequencerApi.armScheduledStart,
      body: const {},
      maxAttempts: 1,
    );
    return parseHostScheduledStart(response['at']);
  }

  /// Remote-only: cancel the host's scheduled start.
  Future<void> cancelHostScheduledStart() async {
    await _post(
      SequencerApi.cancelScheduledStart,
      body: const {},
      maxAttempts: 1,
    );
  }

  /// Remote-only: tell the host the telescope is capped for its darks.
  Future<EonStatus?> confirmHostEndOfNightCapped() async {
    final response = await _post(
      CalibrationApi.confirmEndOfNightCapped,
      body: const {},
      maxAttempts: 1,
    );
    return EonStatus.fromHostJson(response['status']);
  }

  /// Remote-only: stop the host's end-of-night calibration (skip the darks).
  Future<EonStatus?> cancelHostEndOfNight() async {
    final response = await _post(
      CalibrationApi.cancelEndOfNight,
      body: const {},
      maxAttempts: 1,
    );
    return EonStatus.fromHostJson(response['status']);
  }

  Future<Map<String, dynamic>> awaitJobResultOrLegacy(
    Map<String, dynamic> response, {
    required String operation,
    required Duration timeout,
  });

  /// Implemented by [_NetworkBackendRemoteOperations].
  Future<RemoteJob> awaitJobCompletion(
    String jobId, {
    Duration timeout,
    Duration pollInterval,
  });

  /// Implemented by [_NetworkBackendRemoteOperations].
  Map<String, dynamic> finishedJobResult(
    RemoteJob job, {
    required String operation,
  });

  @override
  Future<PlateSolveResult> plateSolve({
    required String imagePath,
    double? ra,
    double? dec,
    double? fovDegrees,
    int? timeoutSeconds,
  }) async {
    final start = await _post(
      ImagingApi.plateSolve,
      body: {
        'imagePath': imagePath,
        if (ra != null) 'ra': ra,
        if (dec != null) 'dec': dec,
        if (fovDegrees != null) 'fov': fovDegrees,
        if (timeoutSeconds != null) 'timeoutSeconds': timeoutSeconds,
      },
    );
    final jobId = start['jobId'] as String?;
    final Map<String, dynamic> response;
    if (jobId == null || jobId.isEmpty) {
      // A host that solved before answering sent the result itself.
      response = start;
    } else {
      final job = await awaitJobCompletion(
        jobId,
        timeout: Duration(seconds: (timeoutSeconds ?? 300) + 30),
      );
      // A solve that found nothing ends its job `failed`, with the result
      // the solver gave (and its reason) as the failure's details. That is
      // an answer for the caller, not a broken request.
      response =
          _unsolvedPlateSolve(job) ??
          finishedJobResult(job, operation: 'plate solve');
    }

    // CD matrix + SIP distortion terms are enriched by the master
    // (`ImagingHandlers._plateSolveJson`). Tolerate their absence so an older
    // master — or a solve that carried no distortion model — degrades to a
    // pure-WCS / linear result instead of crashing.
    double cd(String key) => (response[key] as num?)?.toDouble() ?? 0;
    int sipOrder(String key) => (response[key] as num?)?.toInt() ?? 0;
    Float64List sipCoeffs(String key) {
      final raw = response[key];
      if (raw is! List) return Float64List(0);
      return Float64List.fromList(
        raw.map((e) => (e as num).toDouble()).toList(),
      );
    }

    return PlateSolveResult(
      success: response['success'] as bool,
      ra: (response['ra'] as num).toDouble(),
      dec: (response['dec'] as num).toDouble(),
      pixelScale: (response['pixelScale'] as num).toDouble(),
      rotation: (response['rotation'] as num).toDouble(),
      fieldWidth: (response['fieldWidth'] as num).toDouble(),
      fieldHeight: (response['fieldHeight'] as num).toDouble(),
      solveTimeSecs: (response['solveTimeSecs'] as num).toDouble(),
      error: response['error'] as String?,
      cd11: cd('cd11'),
      cd12: cd('cd12'),
      cd21: cd('cd21'),
      cd22: cd('cd22'),
      sipAOrder: sipOrder('sipAOrder'),
      sipBOrder: sipOrder('sipBOrder'),
      sipACoeffs: sipCoeffs('sipACoeffs'),
      sipBCoeffs: sipCoeffs('sipBCoeffs'),
      sipApOrder: sipOrder('sipApOrder'),
      sipBpOrder: sipOrder('sipBpOrder'),
      sipApCoeffs: sipCoeffs('sipApCoeffs'),
      sipBpCoeffs: sipCoeffs('sipBpCoeffs'),
    );
  }

  /// The solver's own result for a plate-solve job that ended `failed`
  /// because no solution was found, or null for any other outcome.
  static Map<String, dynamic>? _unsolvedPlateSolve(RemoteJob job) {
    final error = job.error;
    if (job.state != 'failed' || error?['code'] != 'plate_solve_failed') {
      return null;
    }
    final details = error?['details'];
    return details is Map ? Map<String, dynamic>.from(details) : null;
  }

  // Plate solver setup
  //
  // These run against the HOST's filesystem (the machine wired to the rig).
  // On the phone the settings page must probe the host — never the phone —
  // so we forward to the host's `/api/plate-solver/*` endpoints which call
  // the host's `bridge_api.apiPlatesolve*`.

  @override
  Future<PlateSolverDetection> detectPlateSolvers() async {
    final response = await _get(ImagingApi.detectPlateSolvers);
    return PlateSolverDetection(
      astapPath: response['astapPath'] as String?,
      astrometryPath: response['astrometryPath'] as String?,
      catalogName: response['catalogName'] as String?,
      catalogMagnitudeLimit: (response['catalogMagnitudeLimit'] as num?)
          ?.toDouble(),
      catalogPath: response['catalogPath'] as String?,
    );
  }

  @override
  Future<PlateSolverInfo> verifyPlateSolver(String executablePath) async {
    final response = await _post(
      ImagingApi.verifyPlateSolver,
      body: {'executablePath': executablePath},
    );
    return PlateSolverInfo(
      path: response['path'] as String,
      flavour: response['flavour'] as String,
      versionLine: response['versionLine'] as String,
    );
  }

  @override
  Future<PlateSolverPreference> getPlateSolverConfig() async {
    final response = await _get(ImagingApi.getPlateSolverConfig);
    return PlateSolverPreference(
      astapPath: (response['astapPath'] as String?) ?? '',
      astrometryPath: (response['astrometryPath'] as String?) ?? '',
      catalogPath: (response['catalogPath'] as String?) ?? '',
      choice: PlateSolverChoice.fromSerialized(
        (response['solverChoice'] as String?) ?? 'auto',
      ),
    );
  }

  @override
  Future<void> setPlateSolverConfig(PlateSolverPreference pref) async {
    await _post(
      ImagingApi.setPlateSolverConfig,
      body: {
        'astapPath': pref.astapPath,
        'astrometryPath': pref.astrometryPath,
        'catalogPath': pref.catalogPath,
        'solverChoice': pref.choice.serialized,
      },
    );
  }

  @override
  Future<void> sequencerStart() async {
    await _post(SequencerApi.start);
  }

  @override
  Future<void> sequencerStop({String? origin}) async {
    // A remote client's stop is an operator action; the origin is not
    // forwarded because the host treats an unlabelled stop as operator.
    await _post(SequencerApi.stop);
  }

  /// Host-authoritative secondary-rig status. These operations deliberately
  /// live on [NetworkBackend] rather than the generic sequencer role because
  /// the local implementation is still an FRB-owned background capture loop.
  Future<Map<String, dynamic>> secondaryRigGetStatus() {
    return _get(SequencerApi.secondaryRigStatus);
  }

  Future<void> secondaryRigStart(Map<String, dynamic> config) async {
    await _post(SequencerApi.secondaryRigStart, body: config);
  }

  Future<void> secondaryRigStop() async {
    await _post(SequencerApi.secondaryRigStop);
  }

  @override
  Future<void> sequencerPause() async {
    await _post(SequencerApi.pause);
  }

  @override
  Future<void> sequencerResume() async {
    await _post(SequencerApi.resume);
  }

  @override
  Future<void> sequencerSkip() async {
    await _post(SequencerApi.skip);
  }

  @override
  Future<void> sequencerSkipToNode(String nodeId) async {
    // Forwarded to the remote host's sequencer.skip-to-node
    // endpoint. Server side maps to api_sequencer_skip_to_node.
    await _post(SequencerApi.skipToNode, body: {'nodeId': nodeId});
  }

  @override
  Future<void> sequencerPluginNodeFinished({
    required String nodeId,
    required bool success,
    String? message,
    String? structuredDetailJson,
  }) async {
    // Forwarded to the remote host's plugin-node-finished
    // endpoint. Server side maps to `api_sequencer_plugin_node_finished`.
    // The remote backend will likely need to dispatch the plugin on the
    // host side too — does not yet wire the remote dispatch path
    // (that lands with the remote-protocol pack); for now this
    // is a faithful forwarder so the wire format is stable from day 1.
    await _post(
      SequencerApi.pluginNodeFinished,
      body: {
        'nodeId': nodeId,
        'success': success,
        if (message != null) 'message': message,
        if (structuredDetailJson != null)
          'structuredDetailJson': structuredDetailJson,
      },
    );
  }

  @override
  Future<void> sequencerReset() async {
    await _post(SequencerApi.reset);
  }

  @override
  Future<void> sequencerLoadJson(String json) async {
    await _post(SequencerApi.load, body: {'json': json});
  }

  @override
  Future<void> sequencerSetSimulationMode(bool enabled) async {
    await _post(SequencerApi.setSimulationMode, body: {'enabled': enabled});
  }

  @override
  Future<bool> sequencerIsSimulationMode() async {
    // The headless API exposes simulation mode as a write only, so a remote
    // client has no reading of the host executor's flag. Answering `false`
    // keeps the client from asserting simulated hardware it cannot observe;
    // add a wire readback here before any caller treats this as authoritative.
    return false;
  }

  @override
  Future<void> sequencerSetDevices({
    String? cameraId,
    String? mountId,
    String? focuserId,
    String? filterwheelId,
    String? rotatorId,
    List<String>? filterNames,
  }) async {
    await _post(
      SequencerApi.setDevices,
      body: {
        'cameraId': cameraId,
        'mountId': mountId,
        'focuserId': focuserId,
        'filterwheelId': filterwheelId,
        'rotatorId': rotatorId,
        'filterNames': filterNames,
      },
    );
  }

  @override
  Future<void> sequencerApplyRunConfig(String runConfigJson) {
    // The host builds its run configuration from its own settings, which a
    // linked client changes through the settings it shares with the host.
    throw UnsupportedError(
      'The run configuration is applied by the imaging host, not a linked '
      'client.',
    );
  }

  @override
  Future<void> sequencerSetSavePath(String? path) async {
    await _post(SequencerApi.setSavePath, body: {'path': path});
  }

  @override
  Future<void> sequencerSetActiveSequenceRunId(int? sequenceRunId) async {
    // Replay Debug — POST through the standard sequencer
    // sub-API; the network backend just forwards primitives.
    await _post(
      SequencerApi.setActiveSequenceRunId,
      body: {'sequence_run_id': sequenceRunId},
    );
  }

  @override
  Future<void> sequencerUpdatePendingIntegrationCarryOver(
    Map<String, Map<String, double>> carryOver,
  ) async {
    // Remote staging mirrors the FFI path. The headless API owns the
    // deserialisation; an unrecognised endpoint on an older headless build is
    // surfaced rather than swallowed.
    await _post(
      SequencerApi.updatePendingIntegrationCarryOver,
      body: {'carry_over': carryOver},
    );
  }

  @override
  Future<void> sequencerUpdateCloudMotion({
    double? currentCoverPercent,
    double? predictedArrivalMinutes,
    double? predictedOpeningMinutes,
    double? predictedOpeningDurationSecs,
    double? predictedClearSkyAlt,
    double? predictedClearSkyAz,
  }) async {
    // Forwarded to the remote host so the remote rig's
    // executor sees the same analyzer reading the local controller has.
    await _post(
      SequencerApi.updateCloudMotion,
      body: {
        'currentCoverPercent': currentCoverPercent,
        'predictedArrivalMinutes': predictedArrivalMinutes,
        'predictedOpeningMinutes': predictedOpeningMinutes,
        'predictedOpeningDurationSecs': predictedOpeningDurationSecs,
        'predictedClearSkyAlt': predictedClearSkyAlt,
        'predictedClearSkyAz': predictedClearSkyAz,
      },
    );
  }

  @override
  Future<void> sequencerUpdateWeatherVerdict({
    bool? unsafeOverride,
    bool advisory = false,
  }) async {
    // Forwarded to the host so its in-sequencer WeatherUnsafe trigger sees
    // the verdict this controller computed.
    await _post(
      SequencerApi.updateWeatherVerdict,
      body: {'unsafeOverride': unsafeOverride, 'advisory': advisory},
    );
  }

  @override
  Future<void> sequencerSetWeatherOperatorClear({
    required int durationSecs,
    required String reason,
  }) async {
    await _post(
      SequencerApi.weatherOperatorClear,
      body: {'durationSecs': durationSecs, 'reason': reason},
    );
  }

  @override
  Future<String?> sequencerGetCloudMotionJson() async {
    // Fetched lazily by the dashboard tick. The remote
    // endpoint mirrors the local FRB call.
    try {
      final response = await _get(SequencerApi.getCloudMotion);
      if (!response.containsKey('cloud_motion')) {
        throw const FormatException(
          'GET /api/sequencer/cloud-motion returned no `cloud_motion` field',
        );
      }
      final value = response['cloud_motion'];
      if (value == null || value is String) return value as String?;
      throw FormatException(
        'GET /api/sequencer/cloud-motion returned a non-string '
        '`cloud_motion` field (${value.runtimeType})',
      );
    } on ServerError catch (error) {
      // Compatibility with masters that predate this optional dashboard
      // endpoint. Every other host/transport failure remains visible.
      if (error.httpStatus == 404) return null;
      rethrow;
    }
  }

  /// Remote-only: put this client's open plan into the host's sequence
  /// editor, so the host runs and mirrors the plan the operator sees here.
  ///
  /// [sequence] null closes the host's editor. [isDirty] carries whether the
  /// plan has changes not yet saved to the library. Throws when the host
  /// refuses, for example while its run holds the editor (409).
  Future<void> putOpenEditorSequence(
    Map<String, dynamic>? sequence, {
    int? databaseId,
    required bool isDirty,
  }) async {
    await _put(
      SequencerApi.putEditorSequence,
      body: <String, dynamic>{
        'open': sequence != null,
        if (sequence != null) 'sequence': sequence,
        if (databaseId != null) 'databaseId': databaseId,
        'isDirty': isDirty,
      },
    );
  }

  /// Remote-only: whether the host has a run in flight (running, paused,
  /// recovering, stopping). An unreadable state counts as in flight, so a
  /// caller deciding whether to offer recovery errs toward leaving it alone.
  Future<bool> hostRunInFlight() async {
    try {
      final status = await sequencerGetStatus();
      return !const {
        'idle',
        'completed',
        'failed',
        'cancelled',
        'stopped',
        'error',
      }.contains(status.state.toLowerCase());
    } catch (_) {
      return true;
    }
  }

  /// Remote-only: stop the host's run through its own executor, keeping or
  /// discarding its resume point as the operator chose.
  Future<void> sequencerStopOnHost({required bool preserveCheckpoint}) async {
    await _post(
      SequencerApi.stop,
      body: <String, dynamic>{'preserveCheckpoint': preserveCheckpoint},
    );
  }

  /// Remote-only: fetch the host's live autopilot preview decision so the
  /// slave's scheduler banner mirrors the real host pick instead of recomputing
  /// against its empty local catalog (which always yields "nothing eligible").
  /// Not part of the abstract backend — only a NetworkBackend slave calls this.
  Future<SchedulerDecision> getSchedulerPreview() async {
    final response = await _get(SchedulerApi.previewDecision);
    return SchedulerDecision.fromJson(Map<String, dynamic>.from(response));
  }

  @override
  Future<void> sequencerUpdateConditionsScore(ConditionsScore? score) async {
    await _post(
      SequencerApi.updateConditionsScore,
      body: {'score': score?.toJson()},
    );
  }

  @override
  Future<AdaptiveSwapSnapshot?> sequencerGetAdaptiveSwapSnapshot() async {
    final response = await _get(SequencerApi.getAdaptiveSwap);
    final value = response['adaptive_swap'];
    if (value == null) return null;
    if (value is String) return AdaptiveSwapDriver.decodeSnapshotJson(value);
    if (value is Map<String, dynamic>) {
      return AdaptiveSwapSnapshot.fromJson(value);
    }
    if (value is Map) {
      return AdaptiveSwapSnapshot.fromJson(Map<String, dynamic>.from(value));
    }
    throw StateError(
      'Malformed adaptive_swap response: expected object, string, or null; '
      'got ${value.runtimeType}',
    );
  }

  @override
  Future<void> sequencerUpdateSkyBrightness({required double? mag}) async {
    // Forwarded to the remote host so the remote rig's
    // executor sees the same SkyBrightnessTracker reading the local
    // controller has. Older headless servers may not implement the
    // endpoint; we don't swallow errors here (the user explicitly
    // pushed and would want to know).
    await _post(SequencerApi.updateSkyBrightness, body: {'mag': mag});
  }

  @override
  Future<void> recoveryTryNow() async {
    await _post(SequencerApi.recoveryTryNow, body: const {});
  }

  @override
  Future<void> recoveryAbort() async {
    await _post(SequencerApi.recoveryAbort, body: const {});
  }

  @override
  Future<String?> getCurrentRecoveryJson() async {
    final response = await _get(SequencerApi.getCurrentRecovery);
    // The server returns `{"context": null}` for an idle executor or
    // `{"context": "<json>"}` while recovering.
    final ctx = response['context'];
    if (ctx == null) return null;
    return ctx as String;
  }

  @override
  Future<String> getRecoveryHistoryJson() async {
    final response = await _get(SequencerApi.getRecoveryHistory);
    return (response['history'] as String?) ?? '[]';
  }

  @override
  Future<SequencerStatus> sequencerGetStatus() async {
    final response = await _get(SequencerApi.status);
    return SequencerStatus(
      state: response['state'] as String? ?? 'Idle',
      currentNodeId: response['currentNodeId'] as String?,
      currentNodeName: response['currentNodeName'] as String?,
      progress: (response['progress'] as num?)?.toDouble() ?? 0.0,
      message: response['message'] as String?,
      runVitals: response['runVitals'] is Map<String, dynamic>
          ? SequencerRunVitals.fromJson(
              response['runVitals'] as Map<String, dynamic>,
            )
          : null,
      guidingStopReason: response['guidingStopReason'] as String?,
      reportsGuidingStopReason: response.containsKey('guidingStopReason'),
    );
  }

  @override
  Future<void> sequencerSetCheckpointDir(String path) async {
    await _post(SequencerApi.setCheckpointDir, body: {'path': path});
  }

  @override
  Future<bool> hasCheckpoint() async {
    final response = await _get(SequencerApi.hasCheckpoint);
    return response['hasCheckpoint'] as bool? ?? false;
  }

  @override
  Future<CheckpointInfo?> getCheckpointInfo() async {
    final response = await _get(SequencerApi.getCheckpointInfo);
    if (response['info'] == null) return null;
    return CheckpointInfo.fromJson(response['info'] as Map<String, dynamic>);
  }

  @override
  Future<void> resumeFromCheckpoint() async {
    await _post(SequencerApi.resumeFromCheckpoint, body: {});
  }

  @override
  Future<void> sequencerRequestMeridianFlip() async {
    await _post(SequencerApi.requestMeridianFlip, body: {});
  }

  @override
  Future<void> performMeridianFlip({
    required String mountId,
    String? cameraId,
    String? focuserId,
    String? coverCalibratorId,
    required String targetName,
    required double targetRaHours,
    required double targetDecDegrees,
    required bool pauseGuiding,
    required bool autoCenter,
    required bool refocusAfter,
    required bool resumeGuiding,
    required double settleTimeSecs,
  }) async {
    await _post(
      SequencerApi.performMeridianFlip,
      body: {
        'mountId': mountId,
        if (cameraId != null) 'cameraId': cameraId,
        if (focuserId != null) 'focuserId': focuserId,
        if (coverCalibratorId != null) 'coverCalibratorId': coverCalibratorId,
        'targetName': targetName,
        'targetRaHours': targetRaHours,
        'targetDecDegrees': targetDecDegrees,
        'pauseGuiding': pauseGuiding,
        'autoCenter': autoCenter,
        'refocusAfter': refocusAfter,
        'resumeGuiding': resumeGuiding,
        'settleTimeSecs': settleTimeSecs,
      },
    );
  }

  @override
  Future<void> discardCheckpoint() async {
    await _post(SequencerApi.discardCheckpoint, body: {});
  }

  @override
  Future<void> saveCheckpoint() async {
    await _post(SequencerApi.saveCheckpoint, body: {});
  }

  @override
  Future<LocationSettings> getLocationFromInternet() async {
    final response = await _get(ProfileApi.getLocationFromInternet);
    return LocationSettings(
      latitude: (response['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (response['longitude'] as num?)?.toDouble() ?? 0.0,
      elevation: (response['elevation'] as num?)?.toDouble() ?? 0.0,
    );
  }

  @override
  Future<CameraStatus> getCameraStatus(String deviceId) async {
    final response = await _get(
      EquipmentApi.cameraStatus,
      query: {'deviceId': deviceId},
    );
    return CameraStatus.fromJson(response);
  }

  @override
  Future<MountStatus> getMountStatus(String deviceId) async {
    final response = await _get(
      EquipmentApi.mountStatus,
      query: {'deviceId': deviceId},
    );
    return MountStatus.fromJson(response);
  }

  @override
  Future<FocuserStatus> getFocuserStatus(String deviceId) async {
    final response = await _get(
      EquipmentApi.focuserStatus,
      query: {'deviceId': deviceId},
    );
    return FocuserStatus.fromJson(response);
  }

  @override
  Future<FilterWheelStatus> getFilterWheelStatus(String deviceId) async {
    final response = await _get(
      EquipmentApi.filterWheelStatus,
      query: {'deviceId': deviceId},
    );
    return FilterWheelStatus.fromJson(response);
  }

  @override
  Future<RotatorStatus> getRotatorStatus(String deviceId) async {
    final response = await _get(
      EquipmentApi.rotatorStatus,
      query: {'deviceId': deviceId},
    );
    return RotatorStatus.fromJson(response);
  }

  void _requireRemoteCapabilityFields(
    Map<String, dynamic> response,
    String endpoint,
    List<String> fields,
  ) {
    final missing = fields
        .where((field) => !response.containsKey(field))
        .toList();
    if (missing.isNotEmpty) {
      throw FormatException(
        'GET /api/$endpoint returned no `${missing.join('`, `')}` '
        'field${missing.length == 1 ? '' : 's'}',
      );
    }
  }

  @override
  Future<CameraCapabilities?> getCameraCapabilities(String deviceId) async {
    try {
      final response = await _get(
        EquipmentApi.cameraCapabilities,
        query: {'deviceId': deviceId},
      );
      _requireRemoteCapabilityFields(
        response,
        'equipment/camera/capabilities',
        const ['maxWidth', 'maxHeight', 'bitDepth'],
      );
      return CameraCapabilities.fromJson(response);
    } on ServerError catch (error) {
      if (error.httpStatus == 404) return null;
      rethrow;
    }
  }

  @override
  Future<MountCapabilities?> getMountCapabilities(String deviceId) async {
    try {
      final response = await _get(
        EquipmentApi.mountCapabilities,
        query: {'deviceId': deviceId},
      );
      _requireRemoteCapabilityFields(
        response,
        'equipment/mount/capabilities',
        const ['canSlew', 'canPark', 'canSetTracking'],
      );
      return MountCapabilities.fromJson(response);
    } on ServerError catch (error) {
      if (error.httpStatus == 404) return null;
      rethrow;
    }
  }

  @override
  Future<FocuserCapabilities?> getFocuserCapabilities(String deviceId) async {
    try {
      final response = await _get(
        EquipmentApi.focuserCapabilities,
        query: {'deviceId': deviceId},
      );
      _requireRemoteCapabilityFields(
        response,
        'equipment/focuser/capabilities',
        const ['maxPosition', 'maxIncrement', 'absolute'],
      );
      return FocuserCapabilities.fromJson(response);
    } on ServerError catch (error) {
      if (error.httpStatus == 404) return null;
      rethrow;
    }
  }

  @override
  Future<FilterWheelCapabilities?> getFilterWheelCapabilities(
    String deviceId,
  ) async {
    try {
      final response = await _get(
        EquipmentApi.filterWheelCapabilities,
        query: {'deviceId': deviceId},
      );
      _requireRemoteCapabilityFields(
        response,
        'equipment/filter-wheel/capabilities',
        const ['positionCount', 'filterNames', 'focusOffsets'],
      );
      return FilterWheelCapabilities.fromJson(response);
    } on ServerError catch (error) {
      if (error.httpStatus == 404) return null;
      rethrow;
    }
  }

  @override
  Future<RotatorCapabilities?> getRotatorCapabilities(String deviceId) async {
    try {
      final response = await _get(
        EquipmentApi.rotatorCapabilities,
        query: {'deviceId': deviceId},
      );
      _requireRemoteCapabilityFields(
        response,
        'equipment/rotator/capabilities',
        const ['canReverse', 'canMoveAbsolute', 'canHalt'],
      );
      return RotatorCapabilities.fromJson(response);
    } on ServerError catch (error) {
      if (error.httpStatus == 404) return null;
      rethrow;
    }
  }

  Future<List<DeviceQuirk>> deviceQuirks(String deviceId) async {
    final response = await _get(
      EquipmentApi.deviceQuirks,
      query: {'deviceId': deviceId},
    );
    return [
      for (final quirk in response['quirks'] as List<dynamic>)
        DeviceQuirk.fromJson(quirk as Map<String, dynamic>),
    ];
  }
}
