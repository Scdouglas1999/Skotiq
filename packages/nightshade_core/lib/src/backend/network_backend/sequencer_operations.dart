part of '../network_backend.dart';

mixin _NetworkBackendSequencerOperations on _NetworkBackendTransport {
  Future<Map<String, dynamic>> awaitJobResultOrLegacy(
    Map<String, dynamic> response, {
    required String operation,
    required Duration timeout,
  });

  // Plate solving

  @override
  Future<PlateSolveResult> plateSolve({
    required String imagePath,
    double? ra,
    double? dec,
    double? fovDegrees,
    int? timeoutSeconds,
  }) async {
    final start = await _post('plate-solve', {
      'imagePath': imagePath,
      if (ra != null) 'ra': ra,
      if (dec != null) 'dec': dec,
      if (fovDegrees != null) 'fov': fovDegrees,
      if (timeoutSeconds != null) 'timeoutSeconds': timeoutSeconds,
    });
    final response = await awaitJobResultOrLegacy(
      start,
      operation: 'plate solve',
      timeout: Duration(seconds: (timeoutSeconds ?? 300) + 30),
    );

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

  // Plate solver setup
  //
  // These run against the HOST's filesystem (the machine wired to the rig).
  // On the phone the settings page must probe the host — never the phone —
  // so we forward to the host's `/api/plate-solver/*` endpoints which call
  // the host's `bridge_api.apiPlatesolve*`.

  @override
  Future<PlateSolverDetection> detectPlateSolvers() async {
    final response = await _get('plate-solver/detect');
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
    final response = await _post('plate-solver/verify', {
      'executablePath': executablePath,
    });
    return PlateSolverInfo(
      path: response['path'] as String,
      flavour: response['flavour'] as String,
      versionLine: response['versionLine'] as String,
    );
  }

  @override
  Future<PlateSolverPreference> getPlateSolverConfig() async {
    final response = await _get('plate-solver/config');
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
    await _post('plate-solver/config', {
      'astapPath': pref.astapPath,
      'astrometryPath': pref.astrometryPath,
      'catalogPath': pref.catalogPath,
      'solverChoice': pref.choice.serialized,
    });
  }

  // Sequencer control

  @override
  Future<void> sequencerStart() async {
    await _post('sequencer/start');
  }

  @override
  Future<void> sequencerStop({String? origin}) async {
    // A remote client's stop is an operator action; the origin is not
    // forwarded because the host treats an unlabelled stop as operator.
    await _post('sequencer/stop');
  }

  /// Host-authoritative secondary-rig status. These operations deliberately
  /// live on [NetworkBackend] rather than the generic sequencer role because
  /// the local implementation is still an FRB-owned background capture loop.
  Future<Map<String, dynamic>> secondaryRigGetStatus() {
    return _get('sequencer/secondary-rig');
  }

  Future<void> secondaryRigStart(Map<String, dynamic> config) async {
    await _post('sequencer/secondary-rig/start', config);
  }

  Future<void> secondaryRigStop() async {
    await _post('sequencer/secondary-rig/stop');
  }

  @override
  Future<void> sequencerPause() async {
    await _post('sequencer/pause');
  }

  @override
  Future<void> sequencerResume() async {
    await _post('sequencer/resume');
  }

  @override
  Future<void> sequencerSkip() async {
    await _post('sequencer/skip');
  }

  @override
  Future<void> sequencerSkipToNode(String nodeId) async {
    // Forwarded to the remote host's sequencer.skip-to-node
    // endpoint. Server side maps to api_sequencer_skip_to_node.
    await _post('sequencer/skip-to-node', {'nodeId': nodeId});
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
    await _post('sequencer/plugin-node-finished', {
      'nodeId': nodeId,
      'success': success,
      if (message != null) 'message': message,
      if (structuredDetailJson != null)
        'structuredDetailJson': structuredDetailJson,
    });
  }

  @override
  Future<void> sequencerReset() async {
    await _post('sequencer/reset');
  }

  @override
  Future<void> sequencerLoadJson(String json) async {
    await _post('sequencer/load', {'json': json});
  }

  @override
  Future<void> sequencerSetSimulationMode(bool enabled) async {
    await _post('sequencer/simulation', {'enabled': enabled});
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
    Map<String, int>? filterFocusOffsets,
  }) async {
    await _post('sequencer/devices', {
      'cameraId': cameraId,
      'mountId': mountId,
      'focuserId': focuserId,
      'filterwheelId': filterwheelId,
      'rotatorId': rotatorId,
      'filterNames': filterNames,
      'filterFocusOffsets': filterFocusOffsets,
    });
  }

  @override
  Future<void> sequencerSetSafetyFailMode(String mode) async {
    await _post('sequencer/safety-fail-mode', {'mode': mode});
  }

  @override
  Future<void> sequencerSetParkPolicy({
    required bool parkOnUnsafeWeather,
    required bool parkBeforeDawn,
  }) async {
    await _post('sequencer/park-policy', {
      'parkOnUnsafeWeather': parkOnUnsafeWeather,
      'parkBeforeDawn': parkBeforeDawn,
    });
  }

  @override
  Future<void> sequencerSetSafetyCheckIntervalSeconds(int seconds) async {
    await _post('sequencer/safety-check-interval', {'seconds': seconds});
  }

  @override
  Future<void> sequencerSetSavePath(String? path) async {
    await _post('sequencer/save-path', {'path': path});
  }

  @override
  Future<void> sequencerSetActiveSequenceRunId(int? sequenceRunId) async {
    // Replay Debug — POST through the standard sequencer
    // sub-API; the network backend just forwards primitives.
    await _post('sequencer/active-sequence-run-id', {
      'sequence_run_id': sequenceRunId,
    });
  }

  @override
  Future<void> sequencerSetDecisionLoggingEnabled(bool enabled) async {
    // Replay Debug — runtime toggle.
    await _post('sequencer/decision-logging-enabled', {'enabled': enabled});
  }

  @override
  Future<void> sequencerUpdateDitherConfig({
    required double pixels,
    required double settlePixels,
    required double settleTime,
    required double settleTimeout,
    required bool raOnly,
  }) async {
    await _post('sequencer/update-dither-config', {
      'pixels': pixels,
      'settlePixels': settlePixels,
      'settleTime': settleTime,
      'settleTimeout': settleTimeout,
      'raOnly': raOnly,
    });
  }

  @override
  Future<void> sequencerUpdateMeridianFlipConfig(String configJson) async {
    await _post('sequencer/update-meridian-flip-config', {
      'configJson': configJson,
    });
  }

  @override
  Future<void> sequencerUpdateLocation({
    required double latitude,
    required double longitude,
  }) async {
    await _post('sequencer/update-location', {
      'latitude': latitude,
      'longitude': longitude,
    });
  }

  @override
  Future<void> sequencerUpdateFilterOffsets(Map<String, int> offsets) async {
    await _post('sequencer/update-filter-offsets', {'offsets': offsets});
  }

  @override
  Future<void> sequencerUpdatePendingIntegrationCarryOver(
    Map<String, Map<String, double>> carryOver,
  ) async {
    // Remote staging mirrors the FFI path. The headless API owns the
    // deserialisation; an unrecognised endpoint on an older headless build is
    // surfaced rather than swallowed.
    await _post('sequencer/update-pending-integration-carry-over', {
      'carry_over': carryOver,
    });
  }

  @override
  Future<void> sequencerUpdateAutofocusInterval(int everyNFrames) async {
    // Forwarded to the remote host's runtime-config update
    // endpoint. Server side maps to api_sequencer_update_autofocus_interval.
    await _post('sequencer/update-autofocus-interval', {
      'everyNFrames': everyNFrames,
    });
  }

  @override
  Future<void> sequencerUpdateAutofocusConfig(String configJson) async {
    await _post('sequencer/update-autofocus-config', {
      'configJson': configJson,
    });
  }

  @override
  Future<void> sequencerUpdateDefaultQualityCheck({
    double? hfrThreshold,
    double? hfrBaselinePercent,
    double? eccentricityThreshold,
    int? starCountMin,
    required int maxConsecutiveRejects,
    required bool enabled,
  }) async {
    // Forwarded to the remote host. Server side maps to
    // api_sequencer_update_default_quality_check.
    await _post('sequencer/update-default-quality-check', {
      'hfrThreshold': hfrThreshold,
      'hfrBaselinePercent': hfrBaselinePercent,
      'eccentricityThreshold': eccentricityThreshold,
      'starCountMin': starCountMin,
      'maxConsecutiveRejects': maxConsecutiveRejects,
      'enabled': enabled,
    });
  }

  @override
  Future<void> sequencerUpdateRejectFolderPath(String? path) async {
    // Forwarded to the remote host. Server side maps to
    // api_sequencer_update_reject_folder_path.
    await _post('sequencer/update-reject-folder-path', {'path': path});
  }

  @override
  Future<void> sequencerUpdateObserverProfile({
    String? observerName,
    double? siteElevationM,
    String? cameraMake,
    String? cameraModel,
    String? telescopeName,
    double? telescopeFocalLengthMm,
    double? telescopeApertureMm,
  }) async {
    // Forwarded to the remote host. Server side maps to
    // api_sequencer_update_observer_profile.
    await _post('sequencer/update-observer-profile', {
      'observerName': observerName,
      'siteElevationM': siteElevationM,
      'cameraMake': cameraMake,
      'cameraModel': cameraModel,
      'telescopeName': telescopeName,
      'telescopeFocalLengthMm': telescopeFocalLengthMm,
      'telescopeApertureMm': telescopeApertureMm,
    });
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
    await _post('sequencer/update-cloud-motion', {
      'currentCoverPercent': currentCoverPercent,
      'predictedArrivalMinutes': predictedArrivalMinutes,
      'predictedOpeningMinutes': predictedOpeningMinutes,
      'predictedOpeningDurationSecs': predictedOpeningDurationSecs,
      'predictedClearSkyAlt': predictedClearSkyAlt,
      'predictedClearSkyAz': predictedClearSkyAz,
    });
  }

  @override
  Future<void> sequencerUpdateWeatherVerdict({bool? unsafeOverride}) async {
    // Full-night audit 2026-06-04 (defense-in-depth) — forwarded to the remote
    // host so the remote rig's in-sequencer WeatherUnsafe trigger sees the same
    // weather-safety verdict the local controller computed.
    await _post('sequencer/update-weather-verdict', {
      'unsafeOverride': unsafeOverride,
    });
  }

  @override
  Future<String?> sequencerGetCloudMotionJson() async {
    // Fetched lazily by the dashboard tick. The remote
    // endpoint mirrors the local FRB call.
    try {
      final response = await _get('sequencer/cloud-motion');
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

  /// G2 (remote-only): fetch the master's currently-open editor sequence so a
  /// slave connecting mid-session can seed its sequencer canvas immediately
  /// instead of waiting for the master's next edit-triggered mirror frame.
  ///
  /// Returns the same payload shape the live editor mirror broadcasts over the
  /// WS `/events` stream (`{sequence, databaseId?, isDirty}`), suitable for
  /// feeding straight into `_applySequenceEditorMirror`. Returns `null` when no
  /// sequence is open host-side (`{open: false}`) or the endpoint is missing on
  /// an older headless host. Not part of the abstract backend — only a
  /// NetworkBackend slave ever calls this.
  Future<Map<String, dynamic>?> getOpenEditorSequence() async {
    final response = await _get('sequencer/editor-sequence');
    if (response['open'] != true) return null;
    final sequence = response['sequence'];
    if (sequence is! Map) return null;
    return <String, dynamic>{
      'sequence': Map<String, dynamic>.from(sequence),
      if (response['databaseId'] is int) 'databaseId': response['databaseId'],
      'isDirty': response['isDirty'] == true,
      // Carry the active-plan owner through to _applySequenceEditorMirror so a
      // mid-session slave learns who owns the host's plan on connect. Absent on
      // an older host -> parsed back to manual by ActivePlanOwnerWire.fromWire.
      if (response['activePlanOwner'] != null)
        'activePlanOwner': response['activePlanOwner'],
    };
  }

  /// Remote-only: fetch the host's live autopilot preview decision so the
  /// slave's scheduler banner mirrors the real host pick instead of recomputing
  /// against its empty local catalog (which always yields "nothing eligible").
  /// Not part of the abstract backend — only a NetworkBackend slave calls this.
  Future<SchedulerDecision> getSchedulerPreview() async {
    final response = await _get('scheduler/preview');
    return SchedulerDecision.fromJson(Map<String, dynamic>.from(response));
  }

  @override
  Future<void> sequencerUpdateConditionsScore(ConditionsScore? score) async {
    await _post('sequencer/update-conditions-score', {
      'score': score?.toJson(),
    });
  }

  @override
  Future<AdaptiveSwapSnapshot?> sequencerGetAdaptiveSwapSnapshot() async {
    final response = await _get('sequencer/adaptive-swap');
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
    await _post('sequencer/update-sky-brightness', {'mag': mag});
  }

  @override
  Future<void> sequencerUpdateDefaultAdaptiveExposure({
    required bool enabled,
    required double targetSnr,
    required double referenceSkyBrightnessMag,
    required double minExposureSecs,
    required double maxExposureSecs,
    required Map<String, bool> perFilterEnabled,
    required Map<String, double> perFilterMinSecs,
    required Map<String, double> perFilterMaxSecs,
  }) async {
    await _post('sequencer/update-default-adaptive-exposure', {
      'enabled': enabled,
      'targetSnr': targetSnr,
      'referenceSkyBrightnessMag': referenceSkyBrightnessMag,
      'minExposureSecs': minExposureSecs,
      'maxExposureSecs': maxExposureSecs,
      'perFilterEnabled': perFilterEnabled,
      'perFilterMinSecs': perFilterMinSecs,
      'perFilterMaxSecs': perFilterMaxSecs,
    });
  }

  @override
  Future<void> sequencerClearDefaultAdaptiveExposure() async {
    await _post('sequencer/clear-default-adaptive-exposure', const {});
  }

  // Recovery mode

  @override
  Future<void> recoveryTryNow() async {
    await _post('sequencer/recovery/try-now', const {});
  }

  @override
  Future<void> recoveryAbort() async {
    await _post('sequencer/recovery/abort', const {});
  }

  @override
  Future<void> updateRecoveryConfig({
    required double retryIntervalSecs,
    required double maxDurationSecs,
    required bool stopTrackingDuringRecovery,
    required bool abortOnMeridian,
    required bool audibleAlertWhenEntered,
    required bool parkAndCloseWhenRecoveryGivesUp,
  }) async {
    await _post('sequencer/recovery/update-config', {
      'retryIntervalSecs': retryIntervalSecs,
      'maxDurationSecs': maxDurationSecs,
      'stopTrackingDuringRecovery': stopTrackingDuringRecovery,
      'abortOnMeridian': abortOnMeridian,
      'audibleAlertWhenEntered': audibleAlertWhenEntered,
      'parkAndCloseWhenRecoveryGivesUp': parkAndCloseWhenRecoveryGivesUp,
    });
  }

  @override
  Future<String?> getCurrentRecoveryJson() async {
    final response = await _get('sequencer/recovery/current');
    // The server returns `{"context": null}` for an idle executor or
    // `{"context": "<json>"}` while recovering.
    final ctx = response['context'];
    if (ctx == null) return null;
    return ctx as String;
  }

  @override
  Future<String> getRecoveryHistoryJson() async {
    final response = await _get('sequencer/recovery/history');
    return (response['history'] as String?) ?? '[]';
  }

  @override
  Future<SequencerStatus> sequencerGetStatus() async {
    final response = await _get('sequencer/status');
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
    );
  }

  // Checkpoint / Crash Recovery

  @override
  Future<void> sequencerSetCheckpointDir(String path) async {
    await _post('sequencer/checkpoint/dir', {'path': path});
  }

  @override
  Future<bool> hasCheckpoint() async {
    final response = await _get('sequencer/checkpoint/has');
    return response['hasCheckpoint'] as bool? ?? false;
  }

  @override
  Future<CheckpointInfo?> getCheckpointInfo() async {
    final response = await _get('sequencer/checkpoint/info');
    if (response['info'] == null) return null;
    return CheckpointInfo.fromJson(response['info'] as Map<String, dynamic>);
  }

  @override
  Future<void> resumeFromCheckpoint() async {
    await _post('sequencer/checkpoint/resume', {});
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
    await _post('sequencer/meridian-flip', {
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
    });
  }

  @override
  Future<void> discardCheckpoint() async {
    await _post('sequencer/checkpoint/discard', {});
  }

  @override
  Future<void> saveCheckpoint() async {
    await _post('sequencer/checkpoint/save', {});
  }

  @override
  Future<LocationSettings> getLocationFromInternet() async {
    final response = await _get('location');
    return LocationSettings(
      latitude: (response['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (response['longitude'] as num?)?.toDouble() ?? 0.0,
      elevation: (response['elevation'] as num?)?.toDouble() ?? 0.0,
    );
  }

  // Equipment status

  @override
  Future<CameraStatus> getCameraStatus(String deviceId) async {
    final response = await _get('equipment/camera/status', {
      'deviceId': deviceId,
    });
    return CameraStatus.fromJson(response);
  }

  @override
  Future<MountStatus> getMountStatus(String deviceId) async {
    final response = await _get('equipment/mount/status', {
      'deviceId': deviceId,
    });
    return MountStatus.fromJson(response);
  }

  @override
  Future<FocuserStatus> getFocuserStatus(String deviceId) async {
    final response = await _get('equipment/focuser/status', {
      'deviceId': deviceId,
    });
    return FocuserStatus.fromJson(response);
  }

  @override
  Future<FilterWheelStatus> getFilterWheelStatus(String deviceId) async {
    final response = await _get('equipment/filter-wheel/status', {
      'deviceId': deviceId,
    });
    return FilterWheelStatus.fromJson(response);
  }

  @override
  Future<RotatorStatus> getRotatorStatus(String deviceId) async {
    final response = await _get('equipment/rotator/status', {
      'deviceId': deviceId,
    });
    return RotatorStatus.fromJson(response);
  }

  // Device capabilities

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
      final response = await _get('equipment/camera/capabilities', {
        'deviceId': deviceId,
      });
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
      final response = await _get('equipment/mount/capabilities', {
        'deviceId': deviceId,
      });
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
      final response = await _get('equipment/focuser/capabilities', {
        'deviceId': deviceId,
      });
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
      final response = await _get('equipment/filter-wheel/capabilities', {
        'deviceId': deviceId,
      });
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
      final response = await _get('equipment/rotator/capabilities', {
        'deviceId': deviceId,
      });
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
}
