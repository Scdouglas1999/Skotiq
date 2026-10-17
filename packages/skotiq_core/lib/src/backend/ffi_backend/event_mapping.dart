part of '../ffi_backend.dart';

extension _FfiBackendEventMapping on _FfiBackendBase {
  /// Extract eventType string and data map from an EventPayload
  (String, Map<String, dynamic>) _extractPayloadInfo(dynamic payload) {
    // Handle guiding events with proper field extraction
    if (payload is bridge.EventPayload_Guiding) {
      final guidingEvent = payload.field0;
      return _extractGuidingEventInfo(guidingEvent);
    }

    // Handle equipment events with proper field extraction
    if (payload is bridge.EventPayload_Equipment) {
      return _extractEquipmentEventInfo(payload.field0);
    }

    // Handle sequencer events with proper field extraction
    if (payload is bridge.EventPayload_Sequencer) {
      return _extractSequencerEventInfo(payload.field0);
    }

    // Handle imaging events with proper field extraction
    if (payload is bridge.EventPayload_Imaging) {
      return _extractImagingEventInfo(payload.field0);
    }

    // Handle safety events with proper field extraction
    if (payload is bridge.EventPayload_Safety) {
      return _extractSafetyEventInfo(payload.field0);
    }

    // Handle system events with proper field extraction
    if (payload is bridge.EventPayload_System) {
      return _extractSystemEventInfo(payload.field0);
    }

    // Handle polar alignment events
    if (payload is bridge.EventPayload_PolarAlignment) {
      final pa = payload.field0;
      return (
        'PolarAlignment',
        {
          'azimuth_error': pa.azimuthError,
          'altitude_error': pa.altitudeError,
          'total_error': pa.totalError,
          'current_ra': pa.currentRa,
          'current_dec': pa.currentDec,
          'target_ra': pa.targetRa,
          'target_dec': pa.targetDec,
        },
      );
    }

    if (payload is bridge.EventPayload_PolarAlignmentStatus) {
      final status = payload.field0;
      return (
        'PolarAlignmentStatus',
        {'status': status.status, 'phase': status.phase, 'point': status.point},
      );
    }

    if (payload is bridge.EventPayload_PolarAlignmentImage) {
      final img = payload.field0;
      return (
        'PolarAlignmentImage',
        {
          'image_data': img.imageData,
          'width': img.width,
          'height': img.height,
          'solved_ra': img.solvedRa,
          'solved_dec': img.solvedDec,
          'point': img.point,
          'phase': img.phase,
        },
      );
    }

    if (payload is bridge.EventPayload_DepthLock) {
      return _extractDepthLockEventInfo(payload.field0);
    }

    // For other event types, use string parsing as fallback
    final payloadStr = payload.toString();
    final match = RegExp(r'^EventPayload\.(\w+)\(').firstMatch(payloadStr);
    final eventType = match?.group(1) ?? 'unknown';
    return (eventType, {'payload': payloadStr});
  }

  /// Extract event type and data from a DepthLockEvent.
  ///
  /// The goal store publishes under the `imaging` category, where
  /// `GoalUpdated` alone would be ambiguous against the exposure events, so
  /// every type string keeps the `DepthLock` prefix. Revisions are `u64` on
  /// the wire and become plain ints here like everywhere else.
  (String, Map<String, dynamic>) _extractDepthLockEventInfo(
    dynamic depthLockEvent,
  ) {
    if (depthLockEvent is bridge.DepthLockEvent_GoalUpdated) {
      return (
        'DepthLockGoalUpdated',
        {
          'goal_id': depthLockEvent.goalId,
          'revision': depthLockEvent.revision.toInt(),
          'filter_name': depthLockEvent.filterName,
          'state': depthLockEvent.state,
          'score': depthLockEvent.score,
          'conservative_score': depthLockEvent.conservativeScore,
          'threshold': depthLockEvent.threshold,
          'uncertainty_adu': depthLockEvent.uncertaintyAdu,
          'coverage': depthLockEvent.coverage,
          'evidence_frames': depthLockEvent.evidenceFrames,
          'confirmation_frames': depthLockEvent.confirmationFrames,
          'reason': depthLockEvent.reason,
          'automatic_completion': depthLockEvent.automaticCompletion,
          // camelCase on purpose: the forecast fields were added to the wire
          // after the rest of this payload and the UI reads them by these
          // names. Renaming either side now would silently blank the
          // "N frames to go" line on every already-shipped client.
          'framesRemaining': depthLockEvent.framesRemaining,
          'reachable': depthLockEvent.reachable,
        },
      );
    } else if (depthLockEvent is bridge.DepthLockEvent_EvidenceRejected) {
      return (
        'DepthLockEvidenceRejected',
        {
          'goal_id': depthLockEvent.goalId,
          'revision': depthLockEvent.revision.toInt(),
          'source_path': depthLockEvent.sourcePath,
          'reason': depthLockEvent.reason,
        },
      );
    } else if (depthLockEvent is bridge.DepthLockEvent_AnalysisDropped) {
      return (
        'DepthLockAnalysisDropped',
        {
          'source_path': depthLockEvent.sourcePath,
          'reason': depthLockEvent.reason,
        },
      );
    } else if (depthLockEvent is bridge.DepthLockEvent_GoalChanged) {
      return (
        'DepthLockGoalChanged',
        {
          'goal_id': depthLockEvent.goalId,
          'revision': depthLockEvent.revision.toInt(),
          'change': depthLockEvent.change,
        },
      );
    }
    return _unreadEvent(depthLockEvent, 'DepthLockEvent', 'DepthLock');
  }

  /// Extract event type and data from a SafetyEvent
  (String, Map<String, dynamic>) _extractSafetyEventInfo(dynamic safetyEvent) {
    if (safetyEvent is bridge.SafetyEvent_WeatherUnsafe) {
      return ('WeatherUnsafe', {'reason': safetyEvent.reason});
    } else if (safetyEvent is bridge.SafetyEvent_WeatherSafe) {
      return ('WeatherSafe', {});
    } else if (safetyEvent is bridge.SafetyEvent_EmergencyStop) {
      return ('EmergencyStop', {'reason': safetyEvent.reason});
    } else if (safetyEvent is bridge.SafetyEvent_ParkInitiated) {
      return ('ParkInitiated', {'reason': safetyEvent.reason});
    } else if (safetyEvent is bridge.SafetyEvent_ParkCompleted) {
      return ('ParkCompleted', {});
    }
    return _unreadEvent(safetyEvent, 'SafetyEvent', 'safety');
  }

  /// Extract event type and data from a SystemEvent
  (String, Map<String, dynamic>) _extractSystemEventInfo(dynamic systemEvent) {
    if (systemEvent is bridge.SystemEvent_Initialized) {
      return ('Initialized', {});
    } else if (systemEvent is bridge.SystemEvent_ShuttingDown) {
      return ('ShuttingDown', {});
    } else if (systemEvent is bridge.SystemEvent_Error) {
      return ('Error', {'message': systemEvent.message});
    } else if (systemEvent is bridge.SystemEvent_DiskSpaceLow) {
      return ('DiskSpaceLow', {'available_gb': systemEvent.availableGb});
    } else if (systemEvent is bridge.SystemEvent_Notification) {
      return (
        'Notification',
        {
          'title': systemEvent.title,
          'message': systemEvent.message,
          'level': systemEvent.level,
          if (systemEvent.explicitTransports != null)
            'explicit_transports': systemEvent.explicitTransports,
        },
      );
    } else if (systemEvent is bridge.SystemEvent_EventsDropped) {
      return (
        'EventsDropped',
        {
          'dropped_count': systemEvent.droppedCount,
          'total_dropped': systemEvent.totalDropped,
        },
      );
    }
    return _unreadEvent(systemEvent, 'SystemEvent', 'system');
  }

  /// Extract event type and data from an EquipmentEvent
  (String, Map<String, dynamic>) _extractEquipmentEventInfo(
    dynamic equipmentEvent,
  ) {
    // Connection events
    if (equipmentEvent is bridge.EquipmentEvent_Connecting) {
      return (
        'Connecting',
        {
          'device_type': equipmentEvent.deviceType,
          'device_id': equipmentEvent.deviceId,
        },
      );
    } else if (equipmentEvent is bridge.EquipmentEvent_Connected) {
      return (
        'Connected',
        {
          'device_type': equipmentEvent.deviceType,
          'device_id': equipmentEvent.deviceId,
        },
      );
    } else if (equipmentEvent is bridge.EquipmentEvent_Disconnected) {
      return (
        'Disconnected',
        {
          'device_type': equipmentEvent.deviceType,
          'device_id': equipmentEvent.deviceId,
        },
      );
    } else if (equipmentEvent is bridge.EquipmentEvent_PropertyChanged) {
      if (equipmentEvent.property == 'AutofocusProgress') {
        return (
          'AutofocusProgress',
          {
            'device_type': equipmentEvent.deviceType,
            'device_id': equipmentEvent.deviceId,
            'detail': equipmentEvent.value,
          },
        );
      }
      if (equipmentEvent.property == 'FocuserBacklashCalibrationProgress') {
        return (
          'FocuserBacklashCalibrationProgress',
          {
            'device_type': equipmentEvent.deviceType,
            'device_id': equipmentEvent.deviceId,
            'detail': equipmentEvent.value,
          },
        );
      }
      return (
        'PropertyChanged',
        {
          'device_type': equipmentEvent.deviceType,
          'device_id': equipmentEvent.deviceId,
          'property': equipmentEvent.property,
          'value': equipmentEvent.value,
        },
      );
    } else if (equipmentEvent is bridge.EquipmentEvent_Error) {
      return (
        'Error',
        {
          'device_type': equipmentEvent.deviceType,
          'device_id': equipmentEvent.deviceId,
          'message': equipmentEvent.message,
        },
      );
    }
    // Mount events
    else if (equipmentEvent is bridge.EquipmentEvent_MountSlewStarted) {
      return (
        'MountSlewStarted',
        {'ra': equipmentEvent.ra, 'dec': equipmentEvent.dec},
      );
    } else if (equipmentEvent is bridge.EquipmentEvent_MountSlewCompleted) {
      return (
        'MountSlewCompleted',
        {'ra': equipmentEvent.ra, 'dec': equipmentEvent.dec},
      );
    } else if (equipmentEvent is bridge.EquipmentEvent_MountTrackingStarted) {
      return ('MountTrackingStarted', {});
    } else if (equipmentEvent is bridge.EquipmentEvent_MountTrackingStopped) {
      return ('MountTrackingStopped', {});
    } else if (equipmentEvent is bridge.EquipmentEvent_MountParkStarted) {
      return ('MountParkStarted', {});
    } else if (equipmentEvent is bridge.EquipmentEvent_MountParkCompleted) {
      return ('MountParkCompleted', {});
    } else if (equipmentEvent is bridge.EquipmentEvent_MountUnparked) {
      return ('MountUnparked', {});
    }
    // Focuser events
    else if (equipmentEvent is bridge.EquipmentEvent_FocuserMoveStarted) {
      return (
        'FocuserMoveStarted',
        {'target_position': equipmentEvent.targetPosition},
      );
    } else if (equipmentEvent is bridge.EquipmentEvent_FocuserMoveCompleted) {
      return ('FocuserMoveCompleted', {'position': equipmentEvent.position});
    } else if (equipmentEvent
        is bridge.EquipmentEvent_FocuserTemperatureChanged) {
      return (
        'FocuserTemperatureChanged',
        {'temperature': equipmentEvent.temperature},
      );
    }
    // Filter wheel events
    else if (equipmentEvent is bridge.EquipmentEvent_FilterChanging) {
      return (
        'FilterChanging',
        {
          'from_position': equipmentEvent.fromPosition,
          'to_position': equipmentEvent.toPosition,
          'filter_name': equipmentEvent.filterName,
        },
      );
    } else if (equipmentEvent is bridge.EquipmentEvent_FilterChanged) {
      return (
        'FilterChanged',
        {
          'position': equipmentEvent.position,
          'filter_name': equipmentEvent.filterName,
        },
      );
    }
    // Rotator events
    else if (equipmentEvent is bridge.EquipmentEvent_RotatorMoveStarted) {
      return (
        'RotatorMoveStarted',
        {'target_angle': equipmentEvent.targetAngle},
      );
    } else if (equipmentEvent is bridge.EquipmentEvent_RotatorMoveCompleted) {
      return ('RotatorMoveCompleted', {'angle': equipmentEvent.angle});
    }
    // Camera events
    else if (equipmentEvent is bridge.EquipmentEvent_CameraCoolingStarted) {
      return (
        'CameraCoolingStarted',
        {'target_temp': equipmentEvent.targetTemp},
      );
    } else if (equipmentEvent is bridge.EquipmentEvent_CameraCoolingReached) {
      return (
        'CameraCoolingReached',
        {'temperature': equipmentEvent.temperature},
      );
    } else if (equipmentEvent is bridge.EquipmentEvent_CameraWarmingStarted) {
      return ('CameraWarmingStarted', {});
    } else if (equipmentEvent is bridge.EquipmentEvent_CameraWarmingCompleted) {
      return ('CameraWarmingCompleted', {});
    }
    // Heartbeat events. Rust publishes these from
    // `device_manager::heartbeat` so per-device-card health indicators
    // can react in real time. Each variant is mapped to a string event
    // type and a snake_case data map so the Dart-side handler in
    // `DeviceService` can dispatch without referencing FRB-generated
    // types directly.
    else if (equipmentEvent is bridge.EquipmentEvent_HeartbeatStarted) {
      return (
        'HeartbeatStarted',
        {
          'device_type': equipmentEvent.deviceType,
          'device_id': equipmentEvent.deviceId,
          'interval_secs': equipmentEvent.intervalSecs,
        },
      );
    } else if (equipmentEvent is bridge.EquipmentEvent_HeartbeatStopped) {
      return (
        'HeartbeatStopped',
        {
          'device_type': equipmentEvent.deviceType,
          'device_id': equipmentEvent.deviceId,
        },
      );
    } else if (equipmentEvent is bridge.EquipmentEvent_HeartbeatStatusChanged) {
      // `status` is the FRB-generated HeartbeatStatus enum; the handler
      // matches on its `.name` (`healthy`, `degraded`, `disconnected`,
      // `reconnecting`, `reconnected`) so we don't leak the FRB type
      // into the rest of the codebase.
      return (
        'HeartbeatStatusChanged',
        {
          'device_type': equipmentEvent.deviceType,
          'device_id': equipmentEvent.deviceId,
          'status': equipmentEvent.status.name,
          'consecutive_failures': equipmentEvent.consecutiveFailures,
          if (equipmentEvent.lastRttMs != null)
            'last_rtt_ms': equipmentEvent.lastRttMs,
        },
      );
    } else if (equipmentEvent is bridge.EquipmentEvent_HeartbeatReconnecting) {
      return (
        'HeartbeatReconnecting',
        {
          'device_type': equipmentEvent.deviceType,
          'device_id': equipmentEvent.deviceId,
          'attempt': equipmentEvent.attempt,
          'max_attempts': equipmentEvent.maxAttempts,
        },
      );
    } else if (equipmentEvent is bridge.EquipmentEvent_HeartbeatReconnected) {
      return (
        'HeartbeatReconnected',
        {
          'device_type': equipmentEvent.deviceType,
          'device_id': equipmentEvent.deviceId,
          'after_attempts': equipmentEvent.afterAttempts,
        },
      );
    }
    // Hot-plug discovery events. The Rust hot-plug watcher emits these as
    // first-class typed variants; `hotplugEventBridgeProvider` filters on the
    // 'DeviceDiscovered' / 'DeviceLost' event types to refresh the equipment
    // screen. The data map is the same shape the inverse network mapper
    // (`_equipmentEventFromCore`) rebuilds, so the typed variant survives a WS
    // round-trip.
    else if (equipmentEvent is bridge.EquipmentEvent_DeviceDiscovered) {
      return (
        'DeviceDiscovered',
        {
          'device_class': equipmentEvent.deviceClass,
          'driver': equipmentEvent.driver,
          'id': equipmentEvent.id,
          'name': equipmentEvent.name,
          'display_name': equipmentEvent.displayName,
          if (equipmentEvent.uniqueId != null)
            'unique_id': equipmentEvent.uniqueId,
        },
      );
    } else if (equipmentEvent is bridge.EquipmentEvent_DeviceLost) {
      return (
        'DeviceLost',
        {
          'device_class': equipmentEvent.deviceClass,
          'driver': equipmentEvent.driver,
          'id': equipmentEvent.id,
        },
      );
    }
    return _unreadEvent(equipmentEvent, 'EquipmentEvent', 'equipment');
  }

  /// Extract event type and data from a GuidingEvent
  (String, Map<String, dynamic>) _extractGuidingEventInfo(
    dynamic guidingEvent,
  ) {
    if (guidingEvent is bridge.GuidingEvent_Correction) {
      return (
        'GuideStep',
        {
          'RADistanceRaw': guidingEvent.raRaw,
          'DECDistanceRaw': guidingEvent.decRaw,
          'RADistance': guidingEvent.ra,
          'DECDistance': guidingEvent.dec,
        },
      );
    } else if (guidingEvent is bridge.GuidingEvent_GuidingStarted) {
      return ('GuidingStarted', {});
    } else if (guidingEvent is bridge.GuidingEvent_GuidingStopped) {
      return ('GuidingStopped', {});
    } else if (guidingEvent is bridge.GuidingEvent_Connected) {
      return ('Connected', {});
    } else if (guidingEvent is bridge.GuidingEvent_Disconnected) {
      return ('Disconnected', {});
    } else if (guidingEvent is bridge.GuidingEvent_Paused) {
      return ('Paused', {});
    } else if (guidingEvent is bridge.GuidingEvent_Resumed) {
      return ('Resumed', {});
    } else if (guidingEvent is bridge.GuidingEvent_LostStar) {
      return ('StarLost', {});
    } else if (guidingEvent is bridge.GuidingEvent_Settled) {
      return ('SettleDone', {'rms': guidingEvent.rms});
    } else if (guidingEvent is bridge.GuidingEvent_DitherStarted) {
      return ('DitherStarted', {'pixels': guidingEvent.pixels});
    } else if (guidingEvent is bridge.GuidingEvent_DitherCompleted) {
      return ('DitherCompleted', {});
    } else if (guidingEvent is bridge.GuidingEvent_Looping) {
      return ('LoopingExposures', {});
    } else if (guidingEvent is bridge.GuidingEvent_Settling) {
      return ('Settling', {});
    } else if (guidingEvent is bridge.GuidingEvent_Calibrating) {
      return ('Calibrating', {});
    } else if (guidingEvent is bridge.GuidingEvent_CalibrationComplete) {
      return ('CalibrationComplete', {});
    } else if (guidingEvent is bridge.GuidingEvent_StarSelected) {
      return ('StarSelected', {'X': guidingEvent.x, 'Y': guidingEvent.y});
    } else if (guidingEvent is bridge.GuidingEvent_AppState) {
      return ('AppState', {'State': guidingEvent.state});
    } else if (guidingEvent is bridge.GuidingEvent_GuideStats) {
      return (
        'GuideStats',
        {'SNR': guidingEvent.snr, 'StarMass': guidingEvent.starMass},
      );
    }

    return _unreadEvent(guidingEvent, 'GuidingEvent', 'guiding');
  }

  /// Extract event type and data from a SequencerEvent
  (String, Map<String, dynamic>) _extractSequencerEventInfo(
    dynamic sequencerEvent,
  ) {
    if (sequencerEvent is bridge.SequencerEvent_Started) {
      return ('Started', {'sequence_name': sequencerEvent.sequenceName});
    } else if (sequencerEvent is bridge.SequencerEvent_Paused) {
      return ('Paused', {});
    } else if (sequencerEvent is bridge.SequencerEvent_Resumed) {
      return ('Resumed', {});
    } else if (sequencerEvent is bridge.SequencerEvent_Stopped) {
      // The run id the bridge carries comes across too: it is what tells one
      // run's stop episode from the next one's when the router decides the
      // single phone push a stop earns (see `StopPushArbiter`). The dashboard
      // fold already reads it off the bridge-typed event.
      return (
        'Stopped',
        {
          if (sequencerEvent.sequenceRunId != null)
            'sequence_run_id': sequencerEvent.sequenceRunId,
        },
      );
    } else if (sequencerEvent is bridge.SequencerEvent_Completed) {
      return ('Completed', {});
    } else if (sequencerEvent is bridge.SequencerEvent_Failed) {
      // Terminal failure. Maps to the eventType the executor's
      // `case 'SequenceFailed'` branch already handles — that branch was
      // unreachable while the native side flattened this onto the generic
      // `Error` payload, so failed runs never finalized.
      return ('SequenceFailed', {'error': sequencerEvent.error});
    } else if (sequencerEvent is bridge.SequencerEvent_NodeStarted) {
      return (
        'NodeStarted',
        {
          'node_id': sequencerEvent.nodeId,
          'node_type': sequencerEvent.nodeType,
        },
      );
    } else if (sequencerEvent is bridge.SequencerEvent_NodeCompleted) {
      return (
        'NodeCompleted',
        {'node_id': sequencerEvent.nodeId, 'status': sequencerEvent.status},
      );
    } else if (sequencerEvent is bridge.SequencerEvent_Progress) {
      return (
        'Progress',
        {'current': sequencerEvent.current, 'total': sequencerEvent.total},
      );
    } else if (sequencerEvent is bridge.SequencerEvent_TargetChanged) {
      return (
        'TargetChanged',
        {
          'target_name': sequencerEvent.targetName,
          'ra': sequencerEvent.ra,
          'dec': sequencerEvent.dec,
        },
      );
    } else if (sequencerEvent is bridge.SequencerEvent_TargetCompleted) {
      return ('TargetCompleted', {'target_name': sequencerEvent.targetName});
    } else if (sequencerEvent is bridge.SequencerEvent_ExposureStarted) {
      return (
        'ExposureStarted',
        {
          'frame': sequencerEvent.frame,
          'total': sequencerEvent.total,
          'filter': sequencerEvent.filter,
          'duration_secs': sequencerEvent.durationSecs,
        },
      );
    } else if (sequencerEvent is bridge.SequencerEvent_ExposureCompleted) {
      return (
        'ExposureCompleted',
        {
          'frame': sequencerEvent.frame,
          'total': sequencerEvent.total,
          'duration_secs': sequencerEvent.durationSecs,
        },
      );
    } else if (sequencerEvent is bridge.SequencerEvent_Error) {
      return ('Error', {'message': sequencerEvent.message});
    } else if (sequencerEvent is bridge.SequencerEvent_MeridianFlipOutcome) {
      return (
        'MeridianFlipOutcome',
        {
          'outcome': sequencerEvent.outcome,
          'target_name': sequencerEvent.targetName,
          'new_pier_side': sequencerEvent.newPierSide,
          'duration_secs': sequencerEvent.durationSecs,
          'attempts': sequencerEvent.attempts,
          'failed_steps': sequencerEvent.failedSteps,
          'error': sequencerEvent.error,
          'action_taken': sequencerEvent.actionTaken,
        },
      );
    } else if (sequencerEvent is bridge.SequencerEvent_TriggerFired) {
      return (
        'TriggerFired',
        {
          'trigger_id': sequencerEvent.triggerId,
          'trigger_name': sequencerEvent.triggerName,
          'action': sequencerEvent.action,
        },
      );
    } else if (sequencerEvent is bridge.SequencerEvent_InstructionProgress) {
      return (
        'InstructionProgress',
        {
          'node_id': sequencerEvent.nodeId,
          'instruction': sequencerEvent.instruction,
          'progress_percent': sequencerEvent.progressPercent,
          'detail': sequencerEvent.detail,
        },
      );
    } else if (sequencerEvent
        is bridge.SequencerEvent_InstructionProgressStructured) {
      return (
        'InstructionProgressStructured',
        {
          'node_id': sequencerEvent.nodeId,
          'instruction': sequencerEvent.instruction,
          'progress_percent': sequencerEvent.progressPercent,
          'detail_kind': sequencerEvent.detailKind,
          'detail_json': sequencerEvent.detailJson,
        },
      );
    } else if (sequencerEvent is bridge.SequencerEvent_FrameAccepted) {
      // Typed grading payload. Carries every metric the
      // dashboard's quality panel needs without parsing the legacy
      // `InstructionProgress.detail` string.
      //
      // `save_path` is now carried alongside the
      // metrics so the thumbnail strip can render an inline preview of
      // accepted frames. Mirrors the existing `reject_path` flow on
      // FrameRejected.
      return (
        'FrameAccepted',
        {
          'node_id': sequencerEvent.nodeId,
          'frame': sequencerEvent.frame,
          'total': sequencerEvent.total,
          'hfr': sequencerEvent.hfr,
          'eccentricity': sequencerEvent.eccentricity,
          'star_count': sequencerEvent.starCount,
          'accepted_total': sequencerEvent.acceptedTotal,
          'rejected_total': sequencerEvent.rejectedTotal,
          'save_path': sequencerEvent.savePath,
          ...frameCaptureToEventData(sequencerEvent.capture),
        },
      );
    } else if (sequencerEvent is bridge.SequencerEvent_FrameRejected) {
      return (
        'FrameRejected',
        {
          'node_id': sequencerEvent.nodeId,
          'frame': sequencerEvent.frame,
          'total': sequencerEvent.total,
          'reason': sequencerEvent.reason,
          'hfr': sequencerEvent.hfr,
          'eccentricity': sequencerEvent.eccentricity,
          'star_count': sequencerEvent.starCount,
          'reject_path': sequencerEvent.rejectPath,
          'consecutive_rejects': sequencerEvent.consecutiveRejects,
          'accepted_total': sequencerEvent.acceptedTotal,
          'rejected_total': sequencerEvent.rejectedTotal,
          ...frameCaptureToEventData(sequencerEvent.capture),
        },
      );
    } else if (sequencerEvent is bridge.SequencerEvent_SchedulerDecision) {
      // Typed scheduler payload. The score table
      // is flattened to a list of plain maps so it survives the
      // `Map<String, dynamic>` data envelope without losing fields.
      return (
        'SchedulerDecision',
        {
          'node_id': sequencerEvent.nodeId,
          'decision_counter': sequencerEvent.decisionCounter,
          'picked_target_id': sequencerEvent.pickedTargetId,
          'picked_target_name': sequencerEvent.pickedTargetName,
          'picked_score': sequencerEvent.pickedScore,
          'scores': sequencerEvent.scores
              .map(
                (s) => {
                  'target_id': s.targetId,
                  'target_name': s.targetName,
                  'total_score': s.totalScore,
                  'runnable': s.runnable,
                  'reason': s.reason,
                },
              )
              .toList(growable: false),
        },
      );
    } else if (sequencerEvent is bridge.SequencerEvent_IntegrationBudget) {
      return (
        'IntegrationBudget',
        {
          'target_id': sequencerEvent.targetId,
          'filter': sequencerEvent.filter,
          'completed_secs': sequencerEvent.completedSecs,
          'budget_secs': sequencerEvent.budgetSecs,
          'fraction': sequencerEvent.fraction,
          'budget_met': sequencerEvent.budgetMet,
        },
      );
    } else if (sequencerEvent is bridge.SequencerEvent_DepthGoalCompleted) {
      // A Smart Exposure plan that stopped early. The numbers are the
      // evidence the verdict rested on, so the run history can explain the
      // transition without going back to the goal store.
      return (
        'DepthGoalCompleted',
        {
          'node_id': sequencerEvent.nodeId,
          'filter_name': sequencerEvent.filterName,
          'goal_id': sequencerEvent.goalId,
          'revision': sequencerEvent.revision.toInt(),
          'evidence_frames': sequencerEvent.evidenceFrames,
          'confirmation_frames': sequencerEvent.confirmationFrames,
          'score': sequencerEvent.score,
          'threshold': sequencerEvent.threshold,
        },
      );
    } else if (sequencerEvent is bridge.SequencerEvent_PluginNodeRequested) {
      // Surface the plugin-node dispatch request so the
      // Dart `SequenceExecutor` can route it to `PluginNodeExecutor`
      // and reply via `sequencerPluginNodeFinished`.
      return (
        'PluginNodeRequested',
        {
          'node_id': sequencerEvent.nodeId,
          'plugin_id': sequencerEvent.pluginId,
          'node_type_id': sequencerEvent.nodeTypeId,
          'config_json': sequencerEvent.configJson,
          'display_name': sequencerEvent.displayName,
          'timeout_secs': sequencerEvent.timeoutSecs,
        },
      );
    } else if (sequencerEvent is bridge.SequencerEvent_PluginNodeProgress) {
      // Plugin-authored intermediate progress payload.
      // Informational; the sequence executor logs it and the dashboard
      // plugin-node panel can subscribe via its own provider.
      return (
        'PluginNodeProgress',
        {
          'node_id': sequencerEvent.nodeId,
          'plugin_id': sequencerEvent.pluginId,
          'node_type_id': sequencerEvent.nodeTypeId,
          'detail_json': sequencerEvent.detailJson,
        },
      );
    } else if (sequencerEvent is bridge.SequencerEvent_PhotometryFrame) {
      // Typed science-photometry frame payload. Serialized field-for-field so
      // the typed variant survives the wire/JSON envelope and the network
      // backend can rebuild it (see `_sequencerEventFromCore`). The legacy
      // `InstructionProgress` 'Science Photometry' detail string is emitted
      // separately by the Rust executor and is unaffected by this branch.
      return (
        'PhotometryFrame',
        {
          'node_id': sequencerEvent.nodeId,
          'target_designation': sequencerEvent.targetDesignation,
          'reference_stars': sequencerEvent.referenceStars,
          'frame': sequencerEvent.frame,
          'total': sequencerEvent.total,
          'filter': sequencerEvent.filter,
          'exposure_secs': sequencerEvent.exposureSecs,
          'airmass': sequencerEvent.airmass,
          'fwhm_arcsec': sequencerEvent.fwhmArcsec,
          'snr': sequencerEvent.snr,
          'mjd_obs': sequencerEvent.mjdObs,
          'frame_start_unix': sequencerEvent.frameStartUnix,
          'accepted': sequencerEvent.accepted,
          'reject_reason': sequencerEvent.rejectReason,
          'reduce_live': sequencerEvent.reduceLive,
          'apply_differential': sequencerEvent.applyDifferential,
        },
      );
    } else if (sequencerEvent
        is bridge.SequencerEvent_PhotometryCadenceBroken) {
      return (
        'PhotometryCadenceBroken',
        {
          'node_id': sequencerEvent.nodeId,
          'frame': sequencerEvent.frame,
          'total': sequencerEvent.total,
          'gap_secs': sequencerEvent.gapSecs,
          'max_gap_secs': sequencerEvent.maxGapSecs,
          'cadence_breaks': sequencerEvent.cadenceBreaks,
        },
      );
    } else if (sequencerEvent is bridge.SequencerEvent_PhotometrySummary) {
      return (
        'PhotometrySummary',
        {
          'node_id': sequencerEvent.nodeId,
          'target_designation': sequencerEvent.targetDesignation,
          'filter': sequencerEvent.filter,
          'frames_captured': sequencerEvent.framesCaptured,
          'cadence_breaks': sequencerEvent.cadenceBreaks,
          'last_reject_reason': sequencerEvent.lastRejectReason,
        },
      );
    } else if (sequencerEvent is bridge.SequencerEvent_RecoveryStarted) {
      return (
        'RecoveryStarted',
        recoveryFieldsFromTyped(
          startedAtIso: sequencerEvent.startedAtIso,
          causeKind: sequencerEvent.causeKind,
          causeCustomLabel: sequencerEvent.causeCustomLabel,
          lastAttemptAtIso: sequencerEvent.lastAttemptAtIso,
          attemptCount: sequencerEvent.attemptCount,
          maxAttempts: sequencerEvent.maxAttempts,
          retryIntervalSecs: sequencerEvent.retryIntervalSecs,
          maxDurationSecs: sequencerEvent.maxDurationSecs,
          phase: sequencerEvent.phase,
          lastError: sequencerEvent.lastError,
        ),
      );
    } else if (sequencerEvent is bridge.SequencerEvent_RecoveryProgress) {
      return (
        'RecoveryProgress',
        recoveryFieldsFromTyped(
          startedAtIso: sequencerEvent.startedAtIso,
          causeKind: sequencerEvent.causeKind,
          causeCustomLabel: sequencerEvent.causeCustomLabel,
          lastAttemptAtIso: sequencerEvent.lastAttemptAtIso,
          attemptCount: sequencerEvent.attemptCount,
          maxAttempts: sequencerEvent.maxAttempts,
          retryIntervalSecs: sequencerEvent.retryIntervalSecs,
          maxDurationSecs: sequencerEvent.maxDurationSecs,
          phase: sequencerEvent.phase,
          lastError: sequencerEvent.lastError,
        ),
      );
    } else if (sequencerEvent is bridge.SequencerEvent_RecoveryCompleted) {
      return (
        'RecoveryCompleted',
        recoveryFieldsFromTyped(
          startedAtIso: sequencerEvent.startedAtIso,
          causeKind: sequencerEvent.causeKind,
          causeCustomLabel: sequencerEvent.causeCustomLabel,
          lastAttemptAtIso: sequencerEvent.lastAttemptAtIso,
          attemptCount: sequencerEvent.attemptCount,
          maxAttempts: sequencerEvent.maxAttempts,
          retryIntervalSecs: sequencerEvent.retryIntervalSecs,
          maxDurationSecs: sequencerEvent.maxDurationSecs,
          phase: sequencerEvent.phase,
          lastError: sequencerEvent.lastError,
        ),
      );
    } else if (sequencerEvent is bridge.SequencerEvent_RecoveryGaveUp) {
      return (
        'RecoveryGaveUp',
        recoveryFieldsFromTyped(
          startedAtIso: sequencerEvent.startedAtIso,
          causeKind: sequencerEvent.causeKind,
          causeCustomLabel: sequencerEvent.causeCustomLabel,
          lastAttemptAtIso: sequencerEvent.lastAttemptAtIso,
          attemptCount: sequencerEvent.attemptCount,
          maxAttempts: sequencerEvent.maxAttempts,
          retryIntervalSecs: sequencerEvent.retryIntervalSecs,
          maxDurationSecs: sequencerEvent.maxDurationSecs,
          phase: sequencerEvent.phase,
          lastError: sequencerEvent.lastError,
          abortedByUser: sequencerEvent.abortedByUser,
        ),
      );
    }
    // Replay Debug — `SequencerEvent_DecisionLogged` is the
    // typed payload from the Rust bridge. The Dart class is generated
    // on FRB regen (the Rust side already declares the variant in
    // `bridge/src/event.rs`); until that regen lands, we fall back to
    // detecting the variant by reflective discriminant + string
    // matching the runtime type name. Once the freezed class is in
    // place, this whole `if` chain can be replaced with a direct
    // `sequencerEvent is bridge.SequencerEvent_DecisionLogged` check
    // (see the FrameAccepted / FrameRejected branches above). The
    // runtime contract — the Rust side emits a struct with the same
    // field names — does not change.
    final eventTypeName = sequencerEvent.runtimeType.toString();
    if (eventTypeName.contains('DecisionLogged')) {
      // Use `dynamic` so the runtime-shape access compiles even
      // before the freezed class is generated. Every field is
      // documented in `bridge/src/event.rs::SequencerEvent::DecisionLogged`.
      final dynamic d = sequencerEvent;
      try {
        return (
          'DecisionLogged',
          {
            'timestamp_iso': d.timestampIso as String,
            'category': d.category as String,
            'summary': d.summary as String,
            'details_json': d.detailsJson as String,
            'node_id': d.nodeId as String?,
            'sequence_run_id': d.sequenceRunId as int?,
          },
        );
      } catch (_) {
        // Fall through to the unknown-variant fallback below; the
        // dynamic lookup can only fail if the generated class shape
        // unexpectedly diverges from the Rust struct.
      }
    }

    // A variant with no case above is still an ordinary event of a real night —
    // `exposureAdjusted` reached here on every adaptive-exposure frame — and it
    // is fanned out verbatim to the run-watch feed, the web dashboard and the
    // mobile client. `toString()` on the generated union writes source text
    // ("SequencerEvent.exposureAdjusted(nodeId: exp_r, adaptedSecs: 2.0, …)"),
    // which is what those clients then printed at the operator. The generated
    // class name carries the variant without the constructor call around it, so
    // the event is NAMED, and the sentence beside it says plainly that this
    // build reads no further into it.
    return _unreadEvent(sequencerEvent, 'SequencerEvent', 'sequencer');
  }

  /// The honest shape for a union variant this build has no case for, shared
  /// by every event family's fallback: the event is NAMED by its variant, and
  /// the only prose beside it is a sentence written for a person — never the
  /// generated class's `toString()`, which is Dart source text and reached
  /// operators verbatim on the run-watch feed.
  static (String, Map<String, dynamic>) _unreadEvent(
    dynamic event,
    String union,
    String family,
  ) {
    final variant = _variantName(event.runtimeType.toString(), union);
    return (
      'Unknown$union',
      {
        'variant': variant,
        'message':
            'This build has no reading for the $variant $family event, so '
            'only its name is reported.',
      },
    );
  }

  /// The union variant a generated `<union>_<Variant>` class stands for.
  ///
  /// Falls back to the runtime type name itself when the generator changes its
  /// naming: an unexpected name is still the truest thing available about the
  /// event, where a placeholder would name nothing.
  static String _variantName(String runtimeTypeName, String union) {
    final prefix = '${union}_';
    return runtimeTypeName.startsWith(prefix)
        ? runtimeTypeName.substring(prefix.length)
        : runtimeTypeName;
  }

  /// Extract event type and data from an ImagingEvent
  (String, Map<String, dynamic>) _extractImagingEventInfo(
    dynamic imagingEvent,
  ) {
    if (imagingEvent is bridge.ImagingEvent_ExposureStarted) {
      return (
        'ExposureStarted',
        {
          'duration_secs': imagingEvent.durationSecs,
          // `.name`, not `.toString()`: this is a wire field. `toString()` on a
          // Dart enum yields "FrameType.light", so every remote subscriber
          // (mobile companion, web dashboard, another rig) received a value it
          // could not match against the "light"/"dark"/"flat"/"bias" vocabulary
          // used everywhere else on the wire. Observed verbatim on the live
          // rig's /api/run-watch/events stream:
          //   data: {... "eventType":"ExposureStarted","data":{"duration_secs":2.0,
          //          "frame_type":"FrameType.light"}}
          'frame_type': imagingEvent.frameType.name,
        },
      );
    } else if (imagingEvent is bridge.ImagingEvent_ExposureStartedWithFrame) {
      return (
        'ExposureStarted',
        {
          'duration_secs': imagingEvent.durationSecs,
          'frame': imagingEvent.frameNumber,
          'total': imagingEvent.totalFrames,
          'frame_type': imagingEvent.frameType.name,
        },
      );
    } else if (imagingEvent is bridge.ImagingEvent_ExposureProgress) {
      return (
        'ExposureProgress',
        {
          'progress': imagingEvent.progress,
          'remainingSecs': imagingEvent.remainingSecs,
        },
      );
    } else if (imagingEvent is bridge.ImagingEvent_ExposureCompleted) {
      return (
        'ExposureCompleted',
        {
          'file_path': imagingEvent.filePath,
          'hfr': imagingEvent.hfr,
          'stars_detected': imagingEvent.starsDetected,
        },
      );
    } else if (imagingEvent is bridge.ImagingEvent_ExposureCompletedWithFrame) {
      return (
        'ExposureCompleted',
        {
          'frame': imagingEvent.frameNumber,
          'total': imagingEvent.totalFrames,
          'hfr': imagingEvent.hfr,
          'stars_detected': imagingEvent.starsDetected,
        },
      );
    } else if (imagingEvent is bridge.ImagingEvent_ExposureFailed) {
      return ('ExposureFailed', {'error': imagingEvent.error});
    } else if (imagingEvent is bridge.ImagingEvent_ExposureCancelled) {
      return ('ExposureCancelled', {});
    } else if (imagingEvent is bridge.ImagingEvent_DownloadStarted) {
      return ('DownloadStarted', {});
    } else if (imagingEvent is bridge.ImagingEvent_DownloadCompleted) {
      return ('DownloadCompleted', {});
    } else if (imagingEvent is bridge.ImagingEvent_ImageReady) {
      return (
        'ImageReady',
        {'width': imagingEvent.width, 'height': imagingEvent.height},
      );
    } else if (imagingEvent is bridge.ImagingEvent_ImageSaved) {
      return ('ImageSaved', {'file_path': imagingEvent.filePath});
    } else if (imagingEvent is bridge.ImagingEvent_TemperatureChanged) {
      return (
        'TemperatureChanged',
        {
          'temp_celsius': imagingEvent.tempCelsius,
          'cooler_power': imagingEvent.coolerPower,
        },
      );
    } else if (imagingEvent is bridge.ImagingEvent_ExposureComplete) {
      // Legacy event type - map to 'ExposureComplete' for compatibility with imaging_service.dart
      return ('ExposureComplete', {'success': imagingEvent.success});
    } else if (imagingEvent is bridge.ImagingEvent_ExposureFailedOld) {
      return ('ExposureFailed', {'reason': imagingEvent.reason});
    } else if (imagingEvent is bridge.ImagingEvent_IntegrationProgress) {
      // Post-session integration progress. The post-session seam filters these
      // by category == Imaging + eventType == 'IntegrationProgress' and reads
      // data['phase'] / data['fraction'] (see post_session_seam.dart) — the
      // 'phase' and 'fraction' keys must be spelled exactly as below.
      return (
        'IntegrationProgress',
        {
          'phase': imagingEvent.phase,
          'fraction': imagingEvent.fraction,
          if (imagingEvent.framesDone != null)
            'frames_done': imagingEvent.framesDone,
          if (imagingEvent.framesTotal != null)
            'frames_total': imagingEvent.framesTotal,
        },
      );
    }
    return _unreadEvent(imagingEvent, 'ImagingEvent', 'imaging');
  }

  EventSeverity _fromBridgeSeverity(dynamic severity) {
    final name = severity.toString().split('.').last;
    switch (name) {
      case 'info':
        return EventSeverity.info;
      case 'warning':
        return EventSeverity.warning;
      case 'error':
        return EventSeverity.error;
      case 'critical':
        return EventSeverity.critical;
      default:
        return EventSeverity.info;
    }
  }

  EventCategory _fromBridgeCategory(dynamic category) {
    final name = category.toString().split('.').last;
    switch (name) {
      case 'equipment':
        return EventCategory.equipment;
      case 'imaging':
        return EventCategory.imaging;
      case 'guiding':
        return EventCategory.guiding;
      case 'sequencer':
        return EventCategory.sequencer;
      case 'safety':
        return EventCategory.safety;
      case 'system':
        return EventCategory.system;
      case 'polarAlignment':
        return EventCategory.polarAlignment;
      default:
        return EventCategory.system;
    }
  }
}
