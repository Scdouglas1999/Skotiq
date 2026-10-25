import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

import '../models/backend/event_types.dart' as core;
import 'frame_capture_metadata.dart' show FrameCapture;

/// Reconstructs a typed [bridge.SkotiqEvent] from the collapsed
/// [core.SkotiqEvent] envelope that [FfiBackend] emits onto
/// [NetworkBackend.eventStream] over WebSocket.
///
/// Remote subscribers (`skotiqEventsProvider`, recovery bridge,
/// scheduler trigger stream) depend on the typed `EventPayload_*` shape;
/// this mapper closes the loop on the network path.
bridge.SkotiqEvent bridgeEventFromCoreEvent(core.SkotiqEvent event) {
  final payload = _payloadFromCoreEvent(event);
  return bridge.SkotiqEvent(
    eventId: BigInt.from(event.timestamp),
    timestamp: event.timestamp,
    severity: _bridgeSeverity(event.severity),
    category: _bridgeCategory(event.category),
    payload: payload,
  );
}

/// The event types [bridgeEventFromCoreEvent] rebuilds as the variant the
/// host emitted, per category. Everything else falls to a per-family
/// placeholder there (an error, "weather unsafe", "looping"), which is a
/// statement the host never made.
const Map<core.EventCategory, Set<String>> _faithfulCoreEventTypes = {
  core.EventCategory.sequencer: {
    'Started',
    'Paused',
    'SequencePaused',
    'Resumed',
    'SequenceResumed',
    'Stopped',
    'SequenceStopped',
    'Completed',
    'SequenceCompleted',
    'SequenceFailed',
    'NodeStarted',
    'NodeCompleted',
    'ProgressUpdated',
    'Progress',
    'InstructionProgress',
    'InstructionProgressStructured',
    'TargetChanged',
    'TargetCompleted',
    'ExposureStarted',
    'ExposureCompleted',
    'Error',
    'MeridianFlipOutcome',
    'TriggerFired',
    'FrameAccepted',
    'FrameRejected',
    'SchedulerDecision',
    'IntegrationBudget',
    'ExposureAdjusted',
    'DepthGoalCompleted',
    'PluginNodeRequested',
    'PluginNodeProgress',
    'DecisionLogged',
    'PhotometryFrame',
    'PhotometryCadenceBroken',
    'PhotometrySummary',
    'RecoveryStarted',
    'RecoveryProgress',
    'RecoveryCompleted',
    'RecoveryGaveUp',
  },
  core.EventCategory.guiding: {
    'GuidingStarted',
    'GuidingStopped',
    'StarLost',
    'SettleTimedOut',
    'StopReason',
    'SettleDone',
    'GuideStep',
    'Connected',
    'Disconnected',
    'Paused',
    'Resumed',
    'DitherStarted',
    'DitherCompleted',
    'LoopingExposures',
    'Settling',
    'Calibrating',
    'CalibrationComplete',
    'StarSelected',
    'AppState',
    'GuideStats',
  },
  core.EventCategory.equipment: {
    'Connecting',
    'Connected',
    'Disconnected',
    'PropertyChanged',
    'AutofocusProgress',
    'FocuserBacklashCalibrationProgress',
    'Error',
    'MountSlewStarted',
    'MountSlewCompleted',
    'MountTrackingStarted',
    'MountTrackingStopped',
    'MountParkStarted',
    'MountParkCompleted',
    'MountUnparked',
    'FocuserMoveStarted',
    'FocuserMoveCompleted',
    'FocuserTemperatureChanged',
    'FilterChanging',
    'FilterChanged',
    'RotatorMoveStarted',
    'RotatorMoveCompleted',
    'CameraCoolingStarted',
    'CameraCoolingReached',
    'CameraWarmingStarted',
    'CameraWarmingCompleted',
    'HeartbeatStarted',
    'HeartbeatStopped',
    'HeartbeatStatusChanged',
    'HeartbeatReconnecting',
    'HeartbeatReconnected',
    'DeviceDiscovered',
    'DeviceLost',
  },
  core.EventCategory.safety: {
    'WeatherUnsafe',
    'WeatherSafe',
    'EmergencyStop',
    'ParkInitiated',
    'ParkCompleted',
  },
  core.EventCategory.system: {
    'BackendReconnected',
    'DiskSpaceLow',
    'Initialized',
    'ShuttingDown',
    'Error',
    'Notification',
    'EventsDropped',
  },
  core.EventCategory.imaging: {
    'ExposureStarted',
    'ExposureProgress',
    'ExposureCompleted',
    'ExposureComplete',
    'ExposureCancelled',
    'ExposureFailed',
    'DownloadStarted',
    'DownloadCompleted',
    'ImageReady',
    'ImageSaved',
    'TemperatureChanged',
    'DepthLockGoalUpdated',
    'DepthLockEvidenceRejected',
    'DepthLockAnalysisDropped',
    'DepthLockGoalChanged',
  },
  core.EventCategory.polarAlignment: {'PolarAlignment'},
};

/// The typed event a host emitted, or null when this build cannot rebuild it
/// faithfully: an event type it has no reading for, or a payload missing a
/// required field. A linked client drops such an event from its typed stream
/// instead of reporting something the host never said.
bridge.SkotiqEvent? tryBridgeEventFromCoreEvent(core.SkotiqEvent event) {
  final known = _faithfulCoreEventTypes[event.category];
  if (known == null || !known.contains(event.eventType)) return null;
  try {
    return bridgeEventFromCoreEvent(event);
  } on FormatException {
    return null;
  }
}

bridge.EventSeverity _bridgeSeverity(core.EventSeverity severity) {
  switch (severity) {
    case core.EventSeverity.info:
      return bridge.EventSeverity.info;
    case core.EventSeverity.warning:
      return bridge.EventSeverity.warning;
    case core.EventSeverity.error:
      return bridge.EventSeverity.error;
    case core.EventSeverity.critical:
      return bridge.EventSeverity.critical;
  }
}

bridge.EventCategory _bridgeCategory(core.EventCategory category) {
  switch (category) {
    case core.EventCategory.equipment:
      return bridge.EventCategory.equipment;
    case core.EventCategory.imaging:
      return bridge.EventCategory.imaging;
    case core.EventCategory.guiding:
      return bridge.EventCategory.guiding;
    case core.EventCategory.sequencer:
      return bridge.EventCategory.sequencer;
    case core.EventCategory.safety:
      return bridge.EventCategory.safety;
    case core.EventCategory.system:
      return bridge.EventCategory.system;
    case core.EventCategory.polarAlignment:
      return bridge.EventCategory.polarAlignment;
    case core.EventCategory.job:
    case core.EventCategory.session:
    case core.EventCategory.catalog:
      // These categories have no FRB bridge counterpart —
      // they are produced server-side and consumed via the headless API
      // (run-watch SSE / WS events), never round-tripped through the
      // bridge. Treat as system so any code paths that incidentally hit
      // _bridgeCategory don't lose the event, while keeping the bridge
      // schema unchanged.
      return bridge.EventCategory.system;
  }
}

bridge.EventPayload _payloadFromCoreEvent(core.SkotiqEvent event) {
  switch (event.category) {
    case core.EventCategory.sequencer:
      return bridge.EventPayload.sequencer(
        _sequencerEventFromCore(event.eventType, event.data),
      );
    case core.EventCategory.guiding:
      return bridge.EventPayload.guiding(
        _guidingEventFromCore(event.eventType, event.data),
      );
    case core.EventCategory.equipment:
      return bridge.EventPayload.equipment(
        _equipmentEventFromCore(event.eventType, event.data),
      );
    case core.EventCategory.safety:
      return bridge.EventPayload.safety(
        _safetyEventFromCore(event.eventType, event.data),
      );
    case core.EventCategory.system:
      return bridge.EventPayload.system(
        _systemEventFromCore(event.eventType, event.data),
      );
    case core.EventCategory.imaging:
      // The goal store publishes under `imaging`, so the DepthLock types are
      // separated by their event type before the imaging fallback collapses
      // everything else into an exposure event.
      final depthLock = _depthLockEventFromCore(event.eventType, event.data);
      if (depthLock != null) {
        return bridge.EventPayload.depthLock(depthLock);
      }
      return bridge.EventPayload.imaging(
        _imagingEventFromCore(event.eventType, event.data),
      );
    case core.EventCategory.polarAlignment:
      return bridge.EventPayload.polarAlignment(
        bridge.PolarAlignmentEvent(
          azimuthError: _doubleField(event.data, 'azimuth_error'),
          altitudeError: _doubleField(event.data, 'altitude_error'),
          totalError: _doubleField(event.data, 'total_error'),
          currentRa: _doubleField(event.data, 'current_ra'),
          currentDec: _doubleField(event.data, 'current_dec'),
          targetRa: _doubleField(event.data, 'target_ra'),
          targetDec: _doubleField(event.data, 'target_dec'),
        ),
      );
    case core.EventCategory.job:
    case core.EventCategory.session:
    case core.EventCategory.catalog:
      // These categories live on the headless API side.
      // There is no matching FRB EventPayload variant; route through the
      // system payload so the bridge schema does not need to change.
      // The eventType + data carry the actual content unchanged.
      return bridge.EventPayload.system(
        _systemEventFromCore(event.eventType, event.data),
      );
  }
}

bridge.SequencerEvent _sequencerEventFromCore(
  String eventType,
  Map<String, dynamic> data,
) {
  switch (eventType) {
    case 'Started':
      return bridge.SequencerEvent.started(
        sequenceName: data['sequence_name'] as String? ?? '',
      );
    case 'PhotometryFrame':
      // Rebuild the typed science-photometry frame variant from the wire
      // envelope serialized by `_extractSequencerEventInfo`. Mirrors that
      // branch field-for-field so remote (network-backend) subscribers receive
      // the same typed variant the local FFI path does.
      return bridge.SequencerEvent.photometryFrame(
        nodeId: data['node_id'] as String? ?? '',
        targetDesignation: data['target_designation'] as String? ?? '',
        referenceStars: _stringList(data, 'reference_stars'),
        frame: _intField(data, 'frame'),
        total: _intField(data, 'total'),
        filter: data['filter'] as String? ?? '',
        exposureSecs: _doubleField(data, 'exposure_secs'),
        airmass: _optionalDouble(data, 'airmass'),
        fwhmArcsec: _optionalDouble(data, 'fwhm_arcsec'),
        snr: _optionalDouble(data, 'snr'),
        mjdObs: _doubleField(data, 'mjd_obs'),
        frameStartUnix: _doubleField(data, 'frame_start_unix'),
        accepted: data['accepted'] as bool? ?? false,
        rejectReason: _optionalString(data, 'reject_reason'),
        reduceLive: data['reduce_live'] as bool? ?? false,
        applyDifferential: data['apply_differential'] as bool? ?? false,
      );
    case 'PhotometryCadenceBroken':
      return bridge.SequencerEvent.photometryCadenceBroken(
        nodeId: data['node_id'] as String? ?? '',
        frame: _intField(data, 'frame'),
        total: _intField(data, 'total'),
        gapSecs: _doubleField(data, 'gap_secs'),
        maxGapSecs: _doubleField(data, 'max_gap_secs'),
        cadenceBreaks: _intField(data, 'cadence_breaks'),
      );
    case 'PhotometrySummary':
      return bridge.SequencerEvent.photometrySummary(
        nodeId: data['node_id'] as String? ?? '',
        targetDesignation: data['target_designation'] as String? ?? '',
        filter: data['filter'] as String? ?? '',
        framesCaptured: _intField(data, 'frames_captured'),
        cadenceBreaks: _intField(data, 'cadence_breaks'),
        lastRejectReason: _optionalString(data, 'last_reject_reason'),
      );
    case 'RecoveryStarted':
      return bridge.SequencerEvent.recoveryStarted(
        startedAtIso: _stringField(data, 'started_at_iso'),
        causeKind: _stringField(data, 'cause_kind'),
        causeCustomLabel: _optionalString(data, 'cause_custom_label'),
        lastAttemptAtIso: _optionalString(data, 'last_attempt_at_iso'),
        attemptCount: _intField(data, 'attempt_count'),
        maxAttempts: _intField(data, 'max_attempts'),
        retryIntervalSecs: _doubleField(data, 'retry_interval_secs'),
        maxDurationSecs: _doubleField(data, 'max_duration_secs'),
        phase: _stringField(data, 'phase'),
        lastError: _optionalString(data, 'last_error'),
      );
    case 'RecoveryProgress':
      return bridge.SequencerEvent.recoveryProgress(
        startedAtIso: _stringField(data, 'started_at_iso'),
        causeKind: _stringField(data, 'cause_kind'),
        causeCustomLabel: _optionalString(data, 'cause_custom_label'),
        lastAttemptAtIso: _optionalString(data, 'last_attempt_at_iso'),
        attemptCount: _intField(data, 'attempt_count'),
        maxAttempts: _intField(data, 'max_attempts'),
        retryIntervalSecs: _doubleField(data, 'retry_interval_secs'),
        maxDurationSecs: _doubleField(data, 'max_duration_secs'),
        phase: _stringField(data, 'phase'),
        lastError: _optionalString(data, 'last_error'),
      );
    case 'RecoveryCompleted':
      return bridge.SequencerEvent.recoveryCompleted(
        startedAtIso: _stringField(data, 'started_at_iso'),
        causeKind: _stringField(data, 'cause_kind'),
        causeCustomLabel: _optionalString(data, 'cause_custom_label'),
        lastAttemptAtIso: _optionalString(data, 'last_attempt_at_iso'),
        attemptCount: _intField(data, 'attempt_count'),
        maxAttempts: _intField(data, 'max_attempts'),
        retryIntervalSecs: _doubleField(data, 'retry_interval_secs'),
        maxDurationSecs: _doubleField(data, 'max_duration_secs'),
        phase: _stringField(data, 'phase'),
        lastError: _optionalString(data, 'last_error'),
      );
    case 'RecoveryGaveUp':
      return bridge.SequencerEvent.recoveryGaveUp(
        startedAtIso: _stringField(data, 'started_at_iso'),
        causeKind: _stringField(data, 'cause_kind'),
        causeCustomLabel: _optionalString(data, 'cause_custom_label'),
        lastAttemptAtIso: _optionalString(data, 'last_attempt_at_iso'),
        attemptCount: _intField(data, 'attempt_count'),
        maxAttempts: _intField(data, 'max_attempts'),
        retryIntervalSecs: _doubleField(data, 'retry_interval_secs'),
        maxDurationSecs: _doubleField(data, 'max_duration_secs'),
        phase: _stringField(data, 'phase'),
        lastError: _optionalString(data, 'last_error'),
        abortedByUser: data['aborted_by_user'] as bool? ?? false,
      );
    // Benign lifecycle / progress events map to their real, non-critical
    // variants. They must not reach the `default` arm below, which synthesizes
    // a SequencerEvent.error — flagged critical by isCriticalEvent and shown as
    // a "Sequencer error" banner. Both bare and 'Sequence'-prefixed names are
    // accepted so either emission convention maps.
    case 'Paused':
    case 'SequencePaused':
      return const bridge.SequencerEvent.paused();
    case 'Resumed':
    case 'SequenceResumed':
      return const bridge.SequencerEvent.resumed();
    case 'Stopped':
    case 'SequenceStopped':
      return bridge.SequencerEvent.stopped(
        sequenceRunId: _optionalInt(data, 'sequence_run_id'),
      );
    case 'Completed':
    case 'SequenceCompleted':
      return const bridge.SequencerEvent.completed();
    case 'NodeStarted':
      return bridge.SequencerEvent.nodeStarted(
        nodeId: _stringField(data, 'node_id'),
        nodeType: _stringField(data, 'node_type'),
      );
    case 'NodeCompleted':
      return bridge.SequencerEvent.nodeCompleted(
        nodeId: _stringField(data, 'node_id'),
        status: _stringField(data, 'status'),
      );
    case 'ProgressUpdated':
    case 'Progress':
      return bridge.SequencerEvent.progress(
        current: _intField(data, 'current'),
        total: _intField(data, 'total'),
      );
    case 'InstructionProgress':
      return bridge.SequencerEvent.instructionProgress(
        nodeId: data['node_id'] as String? ?? '',
        instruction: data['instruction'] as String? ?? '',
        progressPercent: _doubleField(data, 'progress_percent'),
        detail: data['detail'] as String? ?? '',
      );
    case 'InstructionProgressStructured':
      return bridge.SequencerEvent.instructionProgressStructured(
        nodeId: data['node_id'] as String? ?? '',
        instruction: data['instruction'] as String? ?? '',
        progressPercent: _doubleField(data, 'progress_percent'),
        detailKind: data['detail_kind'] as String? ?? '',
        detailJson: data['detail_json'] as String? ?? '',
      );
    case 'SequenceFailed':
      return bridge.SequencerEvent.failed(
        error: data['error'] as String? ?? 'Sequence failed',
      );
    case 'TargetChanged':
      return bridge.SequencerEvent.targetChanged(
        targetName: data['target_name'] as String? ?? '',
        ra: _optionalDouble(data, 'ra'),
        dec: _optionalDouble(data, 'dec'),
      );
    case 'TargetCompleted':
      return bridge.SequencerEvent.targetCompleted(
        targetName: data['target_name'] as String? ?? '',
      );
    case 'ExposureStarted':
      return bridge.SequencerEvent.exposureStarted(
        frame: _optionalInt(data, 'frame') ?? 0,
        total: _optionalInt(data, 'total') ?? 0,
        filter: _optionalString(data, 'filter'),
        durationSecs: _doubleField(data, 'duration_secs'),
      );
    case 'ExposureCompleted':
      return bridge.SequencerEvent.exposureCompleted(
        frame: _optionalInt(data, 'frame') ?? 0,
        total: _optionalInt(data, 'total') ?? 0,
        durationSecs: _doubleField(data, 'duration_secs'),
      );
    case 'Error':
      return bridge.SequencerEvent.error(
        message: data['message'] as String? ?? 'Sequencer error',
      );
    case 'MeridianFlipOutcome':
      return bridge.SequencerEvent.meridianFlipOutcome(
        outcome: data['outcome'] as String? ?? '',
        targetName: data['target_name'] as String? ?? '',
        newPierSide: data['new_pier_side'] as String? ?? '',
        durationSecs: _doubleField(data, 'duration_secs'),
        attempts: _optionalInt(data, 'attempts') ?? 0,
        failedSteps: _stringList(data, 'failed_steps'),
        error: _optionalString(data, 'error'),
        actionTaken: _optionalString(data, 'action_taken'),
      );
    case 'TriggerFired':
      return bridge.SequencerEvent.triggerFired(
        triggerId: data['trigger_id'] as String? ?? '',
        triggerName: data['trigger_name'] as String? ?? '',
        action: data['action'] as String? ?? '',
      );
    case 'FrameAccepted':
      return bridge.SequencerEvent.frameAccepted(
        nodeId: data['node_id'] as String? ?? '',
        frame: _optionalInt(data, 'frame') ?? 0,
        total: _optionalInt(data, 'total') ?? 0,
        hfr: _optionalDouble(data, 'hfr'),
        eccentricity: _optionalDouble(data, 'eccentricity'),
        starCount: _optionalInt(data, 'star_count'),
        acceptedTotal: _optionalInt(data, 'accepted_total') ?? 0,
        rejectedTotal: _optionalInt(data, 'rejected_total') ?? 0,
        savePath: _optionalString(data, 'save_path'),
        capture: _frameCaptureFromData(data),
      );
    case 'FrameRejected':
      return bridge.SequencerEvent.frameRejected(
        nodeId: data['node_id'] as String? ?? '',
        frame: _optionalInt(data, 'frame') ?? 0,
        total: _optionalInt(data, 'total') ?? 0,
        reason: data['reason'] as String? ?? '',
        hfr: _optionalDouble(data, 'hfr'),
        eccentricity: _optionalDouble(data, 'eccentricity'),
        starCount: _optionalInt(data, 'star_count'),
        rejectPath: data['reject_path'] as String? ?? '',
        consecutiveRejects: _optionalInt(data, 'consecutive_rejects') ?? 0,
        acceptedTotal: _optionalInt(data, 'accepted_total') ?? 0,
        rejectedTotal: _optionalInt(data, 'rejected_total') ?? 0,
        likelyCauseLabel: _optionalString(data, 'likely_cause_label'),
        evidence: _stringList(data, 'evidence'),
        skyBrightnessAtCapture: _optionalDouble(
          data,
          'sky_brightness_at_capture',
        ),
        cloudCoverAtCapture: _optionalDouble(data, 'cloud_cover_at_capture'),
        windAtCapture: _optionalDouble(data, 'wind_at_capture'),
        guideRmsAtCapture: _optionalDouble(data, 'guide_rms_at_capture'),
        sensorTempAtCapture: _optionalDouble(data, 'sensor_temp_at_capture'),
        capture: _frameCaptureFromData(data),
      );
    case 'SchedulerDecision':
      final scores = data['scores'];
      return bridge.SequencerEvent.schedulerDecision(
        nodeId: data['node_id'] as String? ?? '',
        decisionCounter: _optionalInt(data, 'decision_counter') ?? 0,
        pickedTargetId: _optionalString(data, 'picked_target_id'),
        pickedTargetName: _optionalString(data, 'picked_target_name'),
        pickedScore: _optionalDouble(data, 'picked_score'),
        scores: [
          if (scores is List)
            for (final entry in scores.whereType<Map>())
              bridge.SchedulerScoreEntry(
                targetId: entry['target_id'] as String? ?? '',
                targetName: entry['target_name'] as String? ?? '',
                totalScore: (entry['total_score'] as num?)?.toDouble() ?? 0,
                runnable: entry['runnable'] as bool? ?? false,
                reason: entry['reason'] as String?,
              ),
        ],
      );
    case 'IntegrationBudget':
      return bridge.SequencerEvent.integrationBudget(
        targetId: data['target_id'] as String? ?? '',
        filter: data['filter'] as String? ?? '',
        completedSecs: _doubleField(data, 'completed_secs'),
        budgetSecs: _doubleField(data, 'budget_secs'),
        fraction: _doubleField(data, 'fraction'),
        budgetMet: data['budget_met'] as bool? ?? false,
      );
    case 'ExposureAdjusted':
      return bridge.SequencerEvent.exposureAdjusted(
        nodeId: data['node_id'] as String? ?? '',
        adaptedSecs: _doubleField(data, 'adapted_secs'),
        nominalSecs: _doubleField(data, 'nominal_secs'),
        skyBrightnessMag: _optionalDouble(data, 'sky_brightness_mag'),
        filter: _optionalString(data, 'filter'),
        reason: data['reason'] as String? ?? '',
      );
    case 'PluginNodeRequested':
      return bridge.SequencerEvent.pluginNodeRequested(
        nodeId: data['node_id'] as String? ?? '',
        pluginId: data['plugin_id'] as String? ?? '',
        nodeTypeId: data['node_type_id'] as String? ?? '',
        configJson: data['config_json'] as String? ?? '',
        displayName: _optionalString(data, 'display_name'),
        timeoutSecs: _optionalInt(data, 'timeout_secs') ?? 0,
      );
    case 'PluginNodeProgress':
      return bridge.SequencerEvent.pluginNodeProgress(
        nodeId: data['node_id'] as String? ?? '',
        pluginId: data['plugin_id'] as String? ?? '',
        nodeTypeId: data['node_type_id'] as String? ?? '',
        detailJson: data['detail_json'] as String? ?? '',
      );
    case 'DecisionLogged':
      return bridge.SequencerEvent.decisionLogged(
        timestampIso: data['timestamp_iso'] as String? ?? '',
        category: data['category'] as String? ?? '',
        summary: data['summary'] as String? ?? '',
        detailsJson: data['details_json'] as String? ?? '',
        nodeId: _optionalString(data, 'node_id'),
        sequenceRunId: _optionalInt(data, 'sequence_run_id'),
      );
    case 'DepthGoalCompleted':
      return bridge.SequencerEvent.depthGoalCompleted(
        nodeId: data['node_id'] as String? ?? '',
        filterName: data['filter_name'] as String? ?? '',
        goalId: data['goal_id'] as String? ?? '',
        revision: BigInt.from(_intField(data, 'revision')),
        evidenceFrames: _intField(data, 'evidence_frames'),
        confirmationFrames: _intField(data, 'confirmation_frames'),
        score: _doubleField(data, 'score'),
        threshold: _doubleField(data, 'threshold'),
      );
    default:
      return bridge.SequencerEvent.error(
        message: data['message'] as String? ?? eventType,
      );
  }
}

/// Rebuild a typed [bridge.DepthLockEvent] from the collapsed envelope, or
/// null when [eventType] is not one of the goal store's own events.
///
/// Returning null rather than throwing keeps this a filter: an imaging event
/// that is not a DepthLock one falls through to the imaging mapper untouched.
bridge.DepthLockEvent? _depthLockEventFromCore(
  String eventType,
  Map<String, dynamic> data,
) {
  switch (eventType) {
    case 'DepthLockGoalUpdated':
      return bridge.DepthLockEvent.goalUpdated(
        goalId: data['goal_id'] as String? ?? '',
        revision: BigInt.from(_intField(data, 'revision')),
        filterName: data['filter_name'] as String? ?? '',
        state: data['state'] as String? ?? '',
        score: _optionalDouble(data, 'score'),
        conservativeScore: _optionalDouble(data, 'conservative_score'),
        threshold: _doubleField(data, 'threshold'),
        uncertaintyAdu: _optionalDouble(data, 'uncertainty_adu'),
        coverage: _doubleField(data, 'coverage'),
        evidenceFrames: _intField(data, 'evidence_frames'),
        confirmationFrames: _intField(data, 'confirmation_frames'),
        reason: data['reason'] as String? ?? '',
        automaticCompletion: data['automatic_completion'] as bool? ?? false,
        framesRemaining: (data['framesRemaining'] as num?)?.toInt(),
        // A goal with no forecast yet is not a goal known to be unreachable,
        // so an absent flag reads as "still reachable" rather than the
        // discouraging default.
        reachable: data['reachable'] as bool? ?? true,
      );
    case 'DepthLockEvidenceRejected':
      return bridge.DepthLockEvent.evidenceRejected(
        goalId: data['goal_id'] as String? ?? '',
        revision: BigInt.from(_intField(data, 'revision')),
        sourcePath: data['source_path'] as String? ?? '',
        reason: data['reason'] as String? ?? '',
      );
    case 'DepthLockAnalysisDropped':
      return bridge.DepthLockEvent.analysisDropped(
        sourcePath: data['source_path'] as String? ?? '',
        reason: data['reason'] as String? ?? '',
      );
    case 'DepthLockGoalChanged':
      return bridge.DepthLockEvent.goalChanged(
        goalId: data['goal_id'] as String? ?? '',
        revision: BigInt.from(_intField(data, 'revision')),
        change: data['change'] as String? ?? '',
      );
    default:
      return null;
  }
}

bridge.GuidingEvent _guidingEventFromCore(
  String eventType,
  Map<String, dynamic> data,
) {
  switch (eventType) {
    case 'GuidingStarted':
      return const bridge.GuidingEvent.guidingStarted();
    case 'GuidingStopped':
      return const bridge.GuidingEvent.guidingStopped();
    case 'StarLost':
      return const bridge.GuidingEvent.lostStar();
    case 'SettleTimedOut':
      return bridge.GuidingEvent.settleTimedOut(
        error: data['error'] as String? ?? '',
      );
    case 'StopReason':
      return bridge.GuidingEvent.stopReason(reason: data['reason'] as String?);
    case 'SettleDone':
      return bridge.GuidingEvent.settled(
        rms: (data['rms'] as num?)?.toDouble() ?? 0.0,
      );
    case 'GuideStep':
      return bridge.GuidingEvent.correction(
        ra: (data['RADistance'] as num?)?.toDouble() ?? 0.0,
        dec: (data['DECDistance'] as num?)?.toDouble() ?? 0.0,
        raRaw: (data['RADistanceRaw'] as num?)?.toDouble() ?? 0.0,
        decRaw: (data['DECDistanceRaw'] as num?)?.toDouble() ?? 0.0,
      );
    case 'Connected':
      return const bridge.GuidingEvent.connected();
    case 'Disconnected':
      return const bridge.GuidingEvent.disconnected();
    case 'Paused':
      return const bridge.GuidingEvent.paused();
    case 'Resumed':
      return const bridge.GuidingEvent.resumed();
    case 'DitherStarted':
      return bridge.GuidingEvent.ditherStarted(
        pixels: (data['pixels'] as num?)?.toDouble() ?? 0.0,
      );
    case 'DitherCompleted':
      return const bridge.GuidingEvent.ditherCompleted();
    case 'LoopingExposures':
      return const bridge.GuidingEvent.looping();
    case 'Settling':
      return const bridge.GuidingEvent.settling();
    case 'Calibrating':
      return const bridge.GuidingEvent.calibrating();
    case 'CalibrationComplete':
      return const bridge.GuidingEvent.calibrationComplete();
    case 'StarSelected':
      return bridge.GuidingEvent.starSelected(
        x: (data['X'] as num?)?.toDouble() ?? 0.0,
        y: (data['Y'] as num?)?.toDouble() ?? 0.0,
      );
    case 'AppState':
      return bridge.GuidingEvent.appState(
        state: data['State'] as String? ?? '',
      );
    case 'GuideStats':
      return bridge.GuidingEvent.guideStats(
        snr: (data['SNR'] as num?)?.toDouble() ?? 0.0,
        starMass: (data['StarMass'] as num?)?.toDouble() ?? 0.0,
      );
    default:
      return const bridge.GuidingEvent.looping();
  }
}

bridge.EquipmentEvent _equipmentEventFromCore(
  String eventType,
  Map<String, dynamic> data,
) {
  switch (eventType) {
    case 'MountParkCompleted':
      return const bridge.EquipmentEvent.mountParkCompleted();
    case 'MountUnparked':
      return const bridge.EquipmentEvent.mountUnparked();
    case 'MountParkStarted':
      return const bridge.EquipmentEvent.mountParkStarted();
    case 'MountTrackingStarted':
      return const bridge.EquipmentEvent.mountTrackingStarted();
    case 'MountTrackingStopped':
      return const bridge.EquipmentEvent.mountTrackingStopped();
    case 'MountSlewStarted':
      return bridge.EquipmentEvent.mountSlewStarted(
        ra: _doubleField(data, 'ra'),
        dec: _doubleField(data, 'dec'),
      );
    case 'MountSlewCompleted':
      return bridge.EquipmentEvent.mountSlewCompleted(
        ra: _doubleField(data, 'ra'),
        dec: _doubleField(data, 'dec'),
      );
    case 'FocuserMoveStarted':
      return bridge.EquipmentEvent.focuserMoveStarted(
        targetPosition: _optionalInt(data, 'target_position') ?? 0,
      );
    case 'FocuserMoveCompleted':
      return bridge.EquipmentEvent.focuserMoveCompleted(
        position: _optionalInt(data, 'position') ?? 0,
      );
    case 'FocuserTemperatureChanged':
      return bridge.EquipmentEvent.focuserTemperatureChanged(
        temperature: _doubleField(data, 'temperature'),
      );
    case 'FilterChanging':
      return bridge.EquipmentEvent.filterChanging(
        fromPosition: _optionalInt(data, 'from_position') ?? 0,
        toPosition: _optionalInt(data, 'to_position') ?? 0,
        filterName: _optionalString(data, 'filter_name'),
      );
    case 'FilterChanged':
      return bridge.EquipmentEvent.filterChanged(
        position: _optionalInt(data, 'position') ?? 0,
        filterName: _optionalString(data, 'filter_name'),
      );
    case 'RotatorMoveStarted':
      return bridge.EquipmentEvent.rotatorMoveStarted(
        targetAngle: _doubleField(data, 'target_angle'),
      );
    case 'RotatorMoveCompleted':
      return bridge.EquipmentEvent.rotatorMoveCompleted(
        angle: _doubleField(data, 'angle'),
      );
    case 'CameraCoolingStarted':
      return bridge.EquipmentEvent.cameraCoolingStarted(
        targetTemp: _doubleField(data, 'target_temp'),
      );
    case 'CameraCoolingReached':
      return bridge.EquipmentEvent.cameraCoolingReached(
        temperature: _doubleField(data, 'temperature'),
      );
    case 'CameraWarmingStarted':
      return const bridge.EquipmentEvent.cameraWarmingStarted();
    case 'CameraWarmingCompleted':
      return const bridge.EquipmentEvent.cameraWarmingCompleted();
    case 'Connecting':
      return bridge.EquipmentEvent.connecting(
        deviceType: _stringField(data, 'device_type'),
        deviceId: _stringField(data, 'device_id'),
      );
    case 'AutofocusProgress':
    case 'FocuserBacklashCalibrationProgress':
      // The host flattens these two PropertyChanged properties into their own
      // event types; the property name is the event type and the value is the
      // detail.
      return bridge.EquipmentEvent.propertyChanged(
        deviceType: _stringField(data, 'device_type'),
        deviceId: _stringField(data, 'device_id'),
        property: eventType,
        value: data['detail'] as String? ?? '',
      );
    case 'HeartbeatStarted':
      return bridge.EquipmentEvent.heartbeatStarted(
        deviceType: _stringField(data, 'device_type'),
        deviceId: _stringField(data, 'device_id'),
        intervalSecs: BigInt.from(_optionalInt(data, 'interval_secs') ?? 0),
      );
    case 'HeartbeatStopped':
      return bridge.EquipmentEvent.heartbeatStopped(
        deviceType: _stringField(data, 'device_type'),
        deviceId: _stringField(data, 'device_id'),
      );
    case 'HeartbeatStatusChanged':
      final rtt = _optionalInt(data, 'last_rtt_ms');
      return bridge.EquipmentEvent.heartbeatStatusChanged(
        deviceType: _stringField(data, 'device_type'),
        deviceId: _stringField(data, 'device_id'),
        status: bridge.HeartbeatStatus.values.firstWhere(
          (s) => s.name == data['status'],
          orElse: () => bridge.HeartbeatStatus.degraded,
        ),
        consecutiveFailures: _optionalInt(data, 'consecutive_failures') ?? 0,
        lastRttMs: rtt == null ? null : BigInt.from(rtt),
      );
    case 'HeartbeatReconnecting':
      return bridge.EquipmentEvent.heartbeatReconnecting(
        deviceType: _stringField(data, 'device_type'),
        deviceId: _stringField(data, 'device_id'),
        attempt: _optionalInt(data, 'attempt') ?? 0,
        maxAttempts: _optionalInt(data, 'max_attempts') ?? 0,
      );
    case 'HeartbeatReconnected':
      return bridge.EquipmentEvent.heartbeatReconnected(
        deviceType: _stringField(data, 'device_type'),
        deviceId: _stringField(data, 'device_id'),
        afterAttempts: _optionalInt(data, 'after_attempts') ?? 0,
      );
    case 'Connected':
      return bridge.EquipmentEvent.connected(
        deviceType: _stringField(data, 'device_type'),
        deviceId: _stringField(data, 'device_id'),
      );
    case 'Disconnected':
      return bridge.EquipmentEvent.disconnected(
        deviceType: _stringField(data, 'device_type'),
        deviceId: _stringField(data, 'device_id'),
      );
    case 'PropertyChanged':
      // Other property changes ride the PropertyChanged channel. The
      // mapper rebuilds the typed variant verbatim so round-tripping
      // through WS does not lose the property name or value.
      return bridge.EquipmentEvent.propertyChanged(
        deviceType: _stringField(data, 'device_type'),
        deviceId: _stringField(data, 'device_id'),
        property: _stringField(data, 'property'),
        value: data['value'] as String? ?? '',
      );
    case 'DeviceDiscovered':
      // Hot-plug arrival. Rebuild the typed variant field-for-field from the
      // wire envelope serialized by `_extractEquipmentEventInfo` so remote
      // (network-backend) subscribers receive the same typed variant the local
      // FFI path does and `hotplugEventBridgeProvider` refreshes the list.
      return bridge.EquipmentEvent.deviceDiscovered(
        deviceClass: _stringField(data, 'device_class'),
        driver: _stringField(data, 'driver'),
        id: _stringField(data, 'id'),
        name: data['name'] as String? ?? '',
        displayName: data['display_name'] as String? ?? '',
        uniqueId: _optionalString(data, 'unique_id'),
      );
    case 'DeviceLost':
      return bridge.EquipmentEvent.deviceLost(
        deviceClass: _stringField(data, 'device_class'),
        driver: _stringField(data, 'driver'),
        id: _stringField(data, 'id'),
      );
    default:
      return bridge.EquipmentEvent.error(
        deviceType: _stringField(data, 'device_type'),
        deviceId: _stringField(data, 'device_id'),
        message: data['message'] as String? ?? eventType,
      );
  }
}

bridge.SafetyEvent _safetyEventFromCore(
  String eventType,
  Map<String, dynamic> data,
) {
  switch (eventType) {
    case 'WeatherSafe':
      return const bridge.SafetyEvent.weatherSafe();
    case 'EmergencyStop':
      return bridge.SafetyEvent.emergencyStop(
        reason: data['reason'] as String? ?? 'Emergency stop',
      );
    case 'ParkInitiated':
      return bridge.SafetyEvent.parkInitiated(
        reason: data['reason'] as String? ?? '',
      );
    case 'ParkCompleted':
      return const bridge.SafetyEvent.parkCompleted();
    default:
      return bridge.SafetyEvent.weatherUnsafe(
        reason:
            data['reason'] as String? ??
            data['message'] as String? ??
            eventType,
      );
  }
}

bridge.SystemEvent _systemEventFromCore(
  String eventType,
  Map<String, dynamic> data,
) {
  switch (eventType) {
    case 'BackendReconnected':
      return const bridge.SystemEvent.initialized();
    case 'DiskSpaceLow':
      return bridge.SystemEvent.diskSpaceLow(
        availableGb: (data['available_gb'] as num?)?.toDouble() ?? 0.0,
      );
    case 'Initialized':
      return const bridge.SystemEvent.initialized();
    case 'ShuttingDown':
      return const bridge.SystemEvent.shuttingDown();
    case 'Error':
      return bridge.SystemEvent.error(
        message: data['message'] as String? ?? 'System error',
      );
    case 'Notification':
      final transports = data['explicit_transports'];
      return bridge.SystemEvent.notification(
        title: data['title'] as String? ?? '',
        message: data['message'] as String? ?? '',
        level: data['level'] as String? ?? 'info',
        explicitTransports: transports is List
            ? transports.whereType<String>().toList()
            : null,
      );
    case 'EventsDropped':
      return bridge.SystemEvent.eventsDropped(
        droppedCount: BigInt.from(_optionalInt(data, 'dropped_count') ?? 0),
        totalDropped: BigInt.from(_optionalInt(data, 'total_dropped') ?? 0),
      );
    default:
      return bridge.SystemEvent.error(
        message: data['message'] as String? ?? eventType,
      );
  }
}

bridge.ImagingEvent _imagingEventFromCore(
  String eventType,
  Map<String, dynamic> data,
) {
  // The inverse of `FfiBackend._extractImagingEventInfo`, so a linked client's
  // typed stream (event log, run feed) names each host imaging event as the
  // host's own stream does instead of reading every one as a completion.
  switch (eventType) {
    case 'ExposureStarted':
      final frameType = bridge.FrameType.values.firstWhere(
        (t) => t.name == data['frame_type'],
        orElse: () => bridge.FrameType.light,
      );
      final frame = data['frame'];
      if (frame is num) {
        final total = data['total'];
        return bridge.ImagingEvent.exposureStartedWithFrame(
          durationSecs: _doubleField(data, 'duration_secs'),
          frameType: frameType,
          frameNumber: frame.toInt(),
          totalFrames: total is num ? total.toInt() : null,
        );
      }
      return bridge.ImagingEvent.exposureStarted(
        durationSecs: _doubleField(data, 'duration_secs'),
        frameType: frameType,
      );
    case 'ExposureProgress':
      return bridge.ImagingEvent.exposureProgress(
        progress: _doubleField(data, 'progress'),
        remainingSecs: _doubleField(data, 'remainingSecs'),
      );
    case 'ExposureCompleted':
      final frame = data['frame'];
      final stars = data['stars_detected'];
      if (frame is num) {
        final total = data['total'];
        return bridge.ImagingEvent.exposureCompletedWithFrame(
          frameNumber: frame.toInt(),
          totalFrames: total is num ? total.toInt() : null,
          hfr: _doubleField(data, 'hfr'),
          starsDetected: stars is num ? stars.toInt() : 0,
        );
      }
      return bridge.ImagingEvent.exposureCompleted(
        filePath: _optionalString(data, 'file_path'),
        hfr: _doubleField(data, 'hfr'),
        starsDetected: stars is num ? stars.toInt() : 0,
      );
    case 'ExposureCancelled':
      return const bridge.ImagingEvent.exposureCancelled();
    case 'DownloadStarted':
      return const bridge.ImagingEvent.downloadStarted();
    case 'DownloadCompleted':
      return const bridge.ImagingEvent.downloadCompleted();
    case 'ImageReady':
      final width = data['width'];
      final height = data['height'];
      return bridge.ImagingEvent.imageReady(
        width: width is num ? width.toInt() : 0,
        height: height is num ? height.toInt() : 0,
      );
    case 'ImageSaved':
      return bridge.ImagingEvent.imageSaved(
        filePath: _optionalString(data, 'file_path') ?? '',
      );
    case 'TemperatureChanged':
      return bridge.ImagingEvent.temperatureChanged(
        tempCelsius: _doubleField(data, 'temp_celsius'),
        coolerPower: _doubleField(data, 'cooler_power'),
      );
    case 'ExposureFailed':
      final error = _optionalString(data, 'error');
      if (error != null) {
        return bridge.ImagingEvent.exposureFailed(error: error);
      }
      return bridge.ImagingEvent.exposureFailedOld(
        reason: data['reason'] as String? ?? 'Exposure failed',
      );
    default:
      return bridge.ImagingEvent.exposureComplete(
        success: data['success'] as bool? ?? true,
      );
  }
}

String _stringField(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value is String && value.isNotEmpty) return value;
  throw FormatException('Missing required string field "$key" in event data');
}

String? _optionalString(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value == null) return null;
  if (value is String && value.isEmpty) return null;
  return value as String?;
}

int _intField(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value is int) return value;
  if (value is num) return value.toInt();
  throw FormatException('Missing required int field "$key" in event data');
}

double _doubleField(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return 0.0;
}

int? _optionalInt(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value is num) return value.toInt();
  // In process the host's map can still hold the bridge's BigInt; the wire
  // encoder turns it into a number.
  if (value is BigInt) return value.toInt();
  return null;
}

bridge.FrameCaptureMetadata _frameCaptureFromData(Map<String, dynamic> data) {
  final c = FrameCapture.fromEventData(data);
  return bridge.FrameCaptureMetadata(
    gain: c.gain,
    offset: c.offset,
    sensorTempC: c.sensorTempC,
    coolerPowerPercent: c.coolerPowerPercent,
    mountRaHours: c.mountRaHours,
    mountDecDegrees: c.mountDecDegrees,
    mountAltitudeDeg: c.mountAltitudeDeg,
    mountAzimuthDeg: c.mountAzimuthDeg,
    pierSide: c.pierSide,
    focuserPosition: c.focuserPosition,
    focuserTemperatureC: c.focuserTemperatureC,
    rotatorAngleDeg: c.rotatorAngleDeg,
    exposureSecs: c.exposureSecs ?? 0,
    binX: c.binX ?? 1,
    binY: c.binY ?? 1,
    frameType: c.frameType ?? 'light',
    targetId: c.targetId,
  );
}

double? _optionalDouble(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value is num) return value.toDouble();
  return null;
}

List<String> _stringList(Map<String, dynamic> data, String key) {
  final value = data[key];
  if (value is List) {
    return value.whereType<String>().toList(growable: false);
  }
  return const [];
}

/// Shared recovery field map for [FfiBackend._extractSequencerEventInfo]
/// and the inverse mapper above.
Map<String, dynamic> recoveryFieldsFromTyped({
  required String startedAtIso,
  required String causeKind,
  String? causeCustomLabel,
  String? lastAttemptAtIso,
  required int attemptCount,
  required int maxAttempts,
  required double retryIntervalSecs,
  required double maxDurationSecs,
  required String phase,
  String? lastError,
  bool? abortedByUser,
}) {
  return {
    'started_at_iso': startedAtIso,
    'cause_kind': causeKind,
    'cause_custom_label': causeCustomLabel,
    'last_attempt_at_iso': lastAttemptAtIso,
    'attempt_count': attemptCount,
    'max_attempts': maxAttempts,
    'retry_interval_secs': retryIntervalSecs,
    'max_duration_secs': maxDurationSecs,
    'phase': phase,
    'last_error': lastError,
    if (abortedByUser != null) 'aborted_by_user': abortedByUser,
  };
}
