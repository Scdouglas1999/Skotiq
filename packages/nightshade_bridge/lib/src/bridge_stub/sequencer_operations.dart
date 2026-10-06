part of '../bridge_stub.dart';

double calculateSequencerProgressFraction({
  required String state,
  required int completedExposures,
  required int totalExposures,
}) {
  if (state.toLowerCase() == 'completed') return 1.0;
  if (totalExposures <= 0) return 0.0;
  return (completedExposures / totalExposures).clamp(0.0, 1.0);
}

extension _NativeBridgeSequencerOperations on _NativeBridgeImplementation {
  // Sequencer API

  /// Guard, call, log — the shape every pass-through to the generated
  /// sequencer API shares.
  ///
  /// [op] names the operation in both the fail-closed error and the failure
  /// log, so it must match the method's own name. [okLog] is the success line;
  /// omit it for operations whose success is already visible in the sequencer
  /// event stream.
  Future<T> _native<T>(
    String op,
    Future<T> Function() body, {
    String? okLog,
  }) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired(op);
    }

    try {
      final result = await body();
      if (okLog != null) {
        developer.log('[Bridge] $okLog', name: 'NativeBridge', level: 800);
      }
      return result;
    } catch (e) {
      developer.log(
        '[Bridge] Error in $op: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  String? get loadedSequenceJson => _loadedSequenceJson;

  /// Subscribe to sequencer events (must be called to receive sequencer events)
  /// This sets up the event forwarding from the Rust sequencer to the main event stream
  Future<void> sequencerSubscribeEvents() async {
    if (_sequencerEventsSubscribed) return; // Already subscribed

    if (!_nativeAvailable) {
      _nativeBridgeRequired('sequencerSubscribeEvents');
    }

    try {
      await gen_api.apiSequencerSubscribeEvents();
      _sequencerEventsSubscribed = true;
      developer.log(
        '[Bridge] Subscribed to sequencer events via native',
        name: 'NativeBridge',
        level: 800,
      );
    } catch (e) {
      developer.log(
        '[Bridge] Error subscribing to sequencer events: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Load a sequence from JSON
  Future<void> sequencerLoadJson(String json) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('sequencerLoadJson');
    }

    try {
      await gen_api.apiSequencerLoadJson(json: json);
      _loadedSequenceJson = json;
    } catch (e) {
      developer.log(
        '[Bridge] Error loading sequence via native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Set connected devices for the sequencer
  Future<void> sequencerSetDevices({
    String? cameraId,
    String? mountId,
    String? focuserId,
    String? filterwheelId,
    String? rotatorId,
    List<String>? filterNames,
    Map<String, int>? filterFocusOffsets,
  }) => _native(
    'sequencerSetDevices',
    () => gen_api.apiSequencerSetDevices(
      cameraId: cameraId,
      mountId: mountId,
      focuserId: focuserId,
      filterwheelId: filterwheelId,
      rotatorId: rotatorId,
      filterNames: filterNames,
      filterFocusOffsets: filterFocusOffsets,
    ),
    okLog:
        'Set sequencer devices: camera=$cameraId, mount=$mountId, focuser=$focuserId, filterwheel=$filterwheelId, rotator=$rotatorId, filterNames=$filterNames, filterFocusOffsets=$filterFocusOffsets',
  );

  /// Set the safety fail mode for the sequencer
  Future<void> sequencerSetSafetyFailMode(String mode) => _native(
    'sequencerSetSafetyFailMode',
    () => gen_api.apiSequencerSetSafetyFailMode(mode: mode),
    okLog: 'Set sequencer safety fail mode: $mode',
  );

  /// Set whether quality problems the sequencer judges stop the run
  Future<void> sequencerSetStopOnQualityProblems(bool stop) => _native(
    'sequencerSetStopOnQualityProblems',
    () => gen_api.apiSequencerSetStopOnQualityProblems(
      stopOnQualityProblems: stop,
    ),
    okLog: 'Set sequencer quality policy: stop on quality problems=$stop',
  );

  /// Set whether the standard weather and dawn triggers may park the rig
  Future<void> sequencerSetParkPolicy({
    required bool parkOnUnsafeWeather,
    required bool parkBeforeDawn,
  }) => _native(
    'sequencerSetParkPolicy',
    () => gen_api.apiSequencerSetParkPolicy(
      parkOnUnsafeWeather: parkOnUnsafeWeather,
      parkBeforeDawn: parkBeforeDawn,
    ),
    okLog:
        'Set sequencer park policy: park on unsafe weather=$parkOnUnsafeWeather, '
        'park before dawn=$parkBeforeDawn',
  );

  /// Set how many times a failed camera exposure and a failed filter-wheel
  /// move are retried before the failure counts
  Future<void> sequencerSetDeviceRetries({
    required int cameraRetries,
    required int filterWheelRetries,
  }) => _native(
    'sequencerSetDeviceRetries',
    () => gen_api.apiSequencerSetDeviceRetries(
      cameraRetries: cameraRetries,
      filterWheelRetries: filterWheelRetries,
    ),
    okLog:
        'Set sequencer device retries: camera=$cameraRetries, '
        'filter wheel=$filterWheelRetries',
  );

  /// Set the safety/humidity polling interval for the sequencer
  Future<void> sequencerSetSafetyCheckIntervalSeconds(int seconds) => _native(
    'sequencerSetSafetyCheckIntervalSeconds',
    () => gen_api.apiSequencerSetSafetyCheckIntervalSeconds(seconds: seconds),
    okLog: 'Set sequencer safety check interval: ${seconds}s',
  );

  /// Set the save path for sequencer images
  Future<void> sequencerSetSavePath({String? path}) => _native(
    'sequencerSetSavePath',
    () => gen_api.apiSequencerSetSavePath(path: path),
    okLog: 'Set sequencer save path: ${path ?? "<none>"}',
  );

  /// Replay Debug — stamp the active `sequence_runs.id` on the
  /// Rust executor so every emitted `DecisionEvent` carries the FK.
  ///
  /// Wrapper around the FRB-generated `apiSequencerSetActiveSequenceRunId`
  /// in `api/sequencer.dart`, which itself gracefully degrades when the
  /// underlying `RustLib` binding hasn't been regenerated.
  Future<void> sequencerSetActiveSequenceRunId({int? sequenceRunId}) => _native(
    'sequencerSetActiveSequenceRunId',
    () => gen_api.apiSequencerSetActiveSequenceRunId(
      sequenceRunId: sequenceRunId,
    ),
    okLog: 'Set active sequence_run_id: ${sequenceRunId ?? "<none>"}',
  );

  /// Replay Debug — runtime toggle for the decision-logging
  /// broadcast channel.
  Future<void> sequencerSetDecisionLoggingEnabled({required bool enabled}) =>
      _native(
        'sequencerSetDecisionLoggingEnabled',
        () => gen_api.apiSequencerSetDecisionLoggingEnabled(enabled: enabled),
        okLog: 'Set decision logging enabled: $enabled',
      );

  /// Update dither configuration on the running sequencer
  Future<void> sequencerUpdateDitherConfig({
    required double pixels,
    required double settlePixels,
    required double settleTime,
    required double settleTimeout,
    required bool raOnly,
  }) => _native(
    'sequencerUpdateDitherConfig',
    () => gen_api.apiSequencerUpdateDitherConfig(
      pixels: pixels,
      settlePixels: settlePixels,
      settleTime: settleTime,
      settleTimeout: settleTimeout,
      raOnly: raOnly,
    ),
    okLog:
        'Updated sequencer dither config: pixels=$pixels, settlePixels=$settlePixels, settleTime=$settleTime, settleTimeout=$settleTimeout, raOnly=$raOnly',
  );

  /// Push the operator's meridian-flip settings onto the standard
  /// `meridian_flip` trigger, which otherwise runs on Rust defaults for the
  /// whole night.
  Future<void> sequencerUpdateMeridianFlipConfig({
    required String configJson,
  }) => _native(
    'sequencerUpdateMeridianFlipConfig',
    () => gen_api.apiSequencerUpdateMeridianFlipConfig(configJson: configJson),
    okLog: 'Updated sequencer meridian-flip trigger config',
  );

  /// Update location on the running sequencer
  Future<void> sequencerUpdateLocation({
    required double latitude,
    required double longitude,
  }) => _native(
    'sequencerUpdateLocation',
    () => gen_api.apiSequencerUpdateLocation(
      latitude: latitude,
      longitude: longitude,
    ),
    okLog: 'Updated sequencer location: lat=$latitude, lon=$longitude',
  );

  /// Update filter focus offsets on the running sequencer
  Future<void> sequencerUpdateFilterOffsets({
    required Map<String, int> offsets,
  }) => _native(
    'sequencerUpdateFilterOffsets',
    () => gen_api.apiSequencerUpdateFilterOffsets(offsets: offsets),
    okLog: 'Updated sequencer filter offsets: $offsets',
  );

  /// Stage per-target / per-filter carry-over integration on
  /// the executor so the next sequencerStart() seeds the
  /// IntegrationBudget tracker. See [api_sequencer_update_pending_integration_carry_over]
  /// for semantics; empty inner map zeroes a target's carry-over.
  Future<void> sequencerUpdatePendingIntegrationCarryOver({
    required Map<String, Map<String, double>> carryOver,
  }) => _native(
    'sequencerUpdatePendingIntegrationCarryOver',
    () => gen_api.apiSequencerUpdatePendingIntegrationCarryOver(
      carryOver: carryOver,
    ),
    okLog: 'Staged integration carry-over for ${carryOver.length} targets',
  );

  /// Push the operator's autofocus settings so trigger-fired refocus uses
  /// them.
  ///
  /// Without this the only source of trigger-autofocus tuning is an Autofocus
  /// node inside the sequence, so a sequence without one runs every
  /// interval-fired refocus on library defaults.
  Future<void> sequencerUpdateAutofocusConfig({required String configJson}) =>
      _native(
        'sequencerUpdateAutofocusConfig',
        () => gen_api.apiSequencerUpdateAutofocusConfig(configJson: configJson),
        okLog: 'Pushed trigger-autofocus config',
      );

  /// Update the autofocus-interval trigger cadence at
  /// runtime. The bridge rejects 0 (the trigger evaluator treats 0 as
  /// disabled; use the per-trigger `enabled` toggle for that intent).
  Future<void> sequencerUpdateAutofocusInterval({
    required int everyNFrames,
  }) => _native(
    'sequencerUpdateAutofocusInterval',
    () =>
        gen_api.apiSequencerUpdateAutofocusInterval(everyNFrames: everyNFrames),
    okLog: 'Updated sequencer autofocus-interval cadence: $everyNFrames frames',
  );

  /// Update the global default image-grading thresholds. When
  /// `enabled` is false, grading is disabled globally (per-node
  /// `quality_check` on TakeExposure still wins). The four threshold
  /// fields are optional and respected only when enabled.
  Future<void> sequencerUpdateDefaultQualityCheck({
    double? hfrThreshold,
    double? hfrBaselinePercent,
    double? eccentricityThreshold,
    int? starCountMin,
    required int maxConsecutiveRejects,
    required bool enabled,
  }) => _native(
    'sequencerUpdateDefaultQualityCheck',
    () => gen_api.apiSequencerUpdateDefaultQualityCheck(
      hfrThreshold: hfrThreshold,
      hfrBaselinePercent: hfrBaselinePercent,
      eccentricityThreshold: eccentricityThreshold,
      starCountMin: starCountMin,
      maxConsecutiveRejects: maxConsecutiveRejects,
      enabled: enabled,
    ),
    okLog:
        'Updated default_quality_check: enabled=$enabled, hfr=$hfrThreshold, baseline=$hfrBaselinePercent%, ecc=$eccentricityThreshold, stars=$starCountMin, maxRejects=$maxConsecutiveRejects',
  );

  /// Update the reject-folder override. Pass `null` or empty
  /// string to fall back to `<save_path>/Reject/`.
  Future<void> sequencerUpdateRejectFolderPath({String? path}) => _native(
    'sequencerUpdateRejectFolderPath',
    () => gen_api.apiSequencerUpdateRejectFolderPath(path: path),
    okLog: 'Updated reject_folder_path: ${path ?? "<default>"}',
  );

  /// Push observer / equipment identification so the next FITS
  /// save stamps real keywords (OBSERVER, TELESCOP, FOCALLEN, APTDIA,
  /// INSTRUME, SITEELEV). Every field is optional — empty / null fields
  /// are omitted from FITS rather than emitted as sentinels.
  Future<void> sequencerUpdateObserverProfile({
    String? observerName,
    double? siteElevationM,
    String? cameraMake,
    String? cameraModel,
    String? telescopeName,
    double? telescopeFocalLengthMm,
    double? telescopeApertureMm,
  }) => _native(
    'sequencerUpdateObserverProfile',
    () => gen_api.apiSequencerUpdateObserverProfile(
      observerName: observerName,
      siteElevationM: siteElevationM,
      cameraMake: cameraMake,
      cameraModel: cameraModel,
      telescopeName: telescopeName,
      telescopeFocalLengthMm: telescopeFocalLengthMm,
      telescopeApertureMm: telescopeApertureMm,
    ),
    okLog:
        'Updated observer_profile: observer=$observerName, telescope=$telescopeName, camera=$cameraMake $cameraModel',
  );

  /// Start the loaded sequence
  Future<void> sequencerStart() async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('sequencerStart');
    }

    // Ensure event subscription is set up before starting
    await sequencerSubscribeEvents();

    try {
      await gen_api.apiSequencerStart();
      _sequencerState = SequencerState.running;
    } catch (e) {
      developer.log(
        '[Bridge] Error starting sequence via native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Pause the running sequence
  Future<void> sequencerPause() async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('sequencerPause');
    }

    try {
      await gen_api.apiSequencerPause();
      _sequencerState = SequencerState.paused;
    } catch (e) {
      developer.log(
        '[Bridge] Error pausing sequence via native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Resume a paused sequence
  Future<void> sequencerResume() async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('sequencerResume');
    }

    try {
      await gen_api.apiSequencerResume();
      _sequencerState = SequencerState.running;
    } catch (e) {
      developer.log(
        '[Bridge] Error resuming sequence via native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Stop the running sequence
  Future<void> sequencerStop({String? origin}) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('sequencerStop');
    }

    try {
      await gen_api.apiSequencerStop(origin: origin);
      _sequencerState = SequencerState.idle;
      _loadedSequenceJson = null;
    } catch (e) {
      developer.log(
        '[Bridge] Error stopping sequence via native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Skip the current node
  Future<void> sequencerSkip() =>
      _native('sequencerSkip', () => gen_api.apiSequencerSkip());

  /// Jump execution to a specific node id. Preceding
  /// siblings are marked Skipped; the currently-running instruction
  /// completes first. Throws if the executor is not running.
  Future<void> sequencerSkipToNode({required String nodeId}) => _native(
    'sequencerSkipToNode',
    () => gen_api.apiSequencerSkipToNode(nodeId: nodeId),
  );

  /// Report the verdict of a plugin-dispatched
  /// `NodeType::PluginNode` back to the Rust executor. The Rust side
  /// has a pending oneshot keyed on [nodeId]; the verdict resolves it
  /// and the awaiting instruction returns Success / Failure.
  Future<void> sequencerPluginNodeFinished({
    required String nodeId,
    required bool success,
    String? message,
    String? structuredDetailJson,
  }) => _native(
    'sequencerPluginNodeFinished',
    () => gen_api.apiSequencerPluginNodeFinished(
      nodeId: nodeId,
      success: success,
      message: message,
      structuredDetailJson: structuredDetailJson,
    ),
  );

  /// Reset the sequencer
  Future<void> sequencerReset() async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('sequencerReset');
    }

    try {
      await gen_api.apiSequencerReset();
      _sequencerState = SequencerState.idle;
      _loadedSequenceJson = null;
    } catch (e) {
      developer.log(
        '[Bridge] Error resetting sequencer via native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Get the current sequencer state
  SequencerState getSequencerState() => _sequencerState;

  /// Set simulation mode (use mock devices instead of real hardware)
  Future<void> sequencerSetSimulationMode(bool enabled) async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('sequencerSetSimulationMode');
    }

    try {
      await gen_api.apiSequencerSetSimulationMode(enabled: enabled);
      _simulationMode = enabled;
      developer.log(
        '[Bridge] Simulation mode via native: ${enabled ? "enabled" : "disabled"}',
        name: 'NativeBridge',
        level: 800,
      );
    } catch (e) {
      developer.log(
        '[Bridge] Error setting simulation mode via native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Check if simulation mode is enabled
  bool isSimulationMode() => _simulationMode;

  /// Get sequencer status
  Future<SequencerStatus> sequencerGetStatus() async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('sequencerGetStatus');
    }

    try {
      final nativeState = await gen_api.apiSequencerGetState();
      final progress = calculateSequencerProgressFraction(
        state: nativeState.state,
        completedExposures: nativeState.completedExposures,
        totalExposures: nativeState.totalExposures,
      );
      return SequencerStatus(
        state: nativeState.state,
        currentNodeId: nativeState.currentNodeId,
        currentNodeName: nativeState.currentNodeName,
        progress: progress,
        message: nativeState.message,
      );
    } catch (e) {
      developer.log(
        '[Bridge] Error getting sequencer status via native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  // Checkpoint / crash recovery

  /// Set the checkpoint directory
  Future<void> sequencerSetCheckpointDir(String path) => _native(
    'sequencerSetCheckpointDir',
    () => gen_api.apiSequencerSetCheckpointDir(path: path),
  );

  /// Check if a checkpoint exists
  Future<bool> sequencerHasCheckpoint() => _native(
    'sequencerHasCheckpoint',
    () => gen_api.apiSequencerHasCheckpoint(),
  );

  /// Get checkpoint info
  Future<CheckpointInfoApi?> sequencerGetCheckpointInfo() async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('sequencerGetCheckpointInfo');
    }

    try {
      final nativeInfo = await gen_api.apiSequencerGetCheckpointInfo();
      if (nativeInfo == null) return null;
      // Map from FRB-generated type to local type
      return CheckpointInfoApi(
        sequenceName: nativeInfo.sequenceName,
        timestamp: nativeInfo.timestamp,
        completedExposures: nativeInfo.completedExposures,
        completedIntegrationSecs: nativeInfo.completedIntegrationSecs,
        canResume: nativeInfo.canResume,
        ageSeconds: nativeInfo.ageSeconds.toInt(),
      );
    } catch (e) {
      developer.log(
        '[Bridge] Error getting checkpoint info via native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Standalone meridian flip (canonical flip engine, outside a sequence).
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
  }) => _native(
    'performMeridianFlip',
    () => gen_api.apiPerformMeridianFlip(
      mountId: mountId,
      cameraId: cameraId,
      focuserId: focuserId,
      coverCalibratorId: coverCalibratorId,
      targetName: targetName,
      targetRaHours: targetRaHours,
      targetDecDegrees: targetDecDegrees,
      pauseGuiding: pauseGuiding,
      autoCenter: autoCenter,
      refocusAfter: refocusAfter,
      resumeGuiding: resumeGuiding,
      settleTimeSecs: settleTimeSecs,
    ),
  );

  /// Resume from checkpoint
  Future<void> sequencerResumeFromCheckpoint() async {
    if (!_nativeAvailable) {
      _nativeBridgeRequired('sequencerResumeFromCheckpoint');
    }

    try {
      await gen_api.apiSequencerResumeFromCheckpoint();
      _sequencerState = SequencerState.running;
    } catch (e) {
      developer.log(
        '[Bridge] Error resuming from checkpoint via native: $e',
        name: 'NativeBridge',
        level: 1000,
      );
      rethrow;
    }
  }

  /// Discard checkpoint
  Future<void> sequencerDiscardCheckpoint() => _native(
    'sequencerDiscardCheckpoint',
    () => gen_api.apiSequencerClearCheckpoint(),
  );

  /// Save checkpoint
  Future<void> sequencerSaveCheckpoint() => _native(
    'sequencerSaveCheckpoint',
    () => gen_api.apiSequencerSaveCheckpoint(),
  );
}
