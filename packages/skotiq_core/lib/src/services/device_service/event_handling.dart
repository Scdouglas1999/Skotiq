part of '../device_service.dart';

/// Rate-limit window for repeated identical device-error TOASTS (see
/// [_DeviceServiceEventHandling._handleDeviceError]). Within this window an
/// identical `(deviceId, message)` error is still logged and still reflected in
/// the equipment-card error state, but is NOT re-toasted — so a flapping device
/// (e.g. a flaky network safety monitor reconnecting every few seconds) can
/// never flood the notification stream, independent of any per-device heartbeat
/// policy.
const Duration _deviceErrorToastWindow = Duration(seconds: 60);
final Map<String, DateTime> _recentDeviceErrorToasts = <String, DateTime>{};

extension _DeviceServiceEventHandling on DeviceService {
  void _markUserInitiatedDisconnect(String deviceId) =>
      _reconnectCoordinator.markUserInitiatedDisconnect(deviceId);

  void _clearUserInitiatedDisconnect(String deviceId) =>
      _reconnectCoordinator.clearUserInitiatedDisconnect(deviceId);

  /// Resolve a display name without running discovery, from the devices the
  /// backend already reports as connected.
  Future<String> _resolveDeviceDisplayName(
    DeviceType type,
    String deviceId,
  ) async {
    try {
      final connected = await _backend.getConnectedDevices();
      for (final device in connected) {
        if (device.id == deviceId && device.deviceType == type) {
          if (device.name.isNotEmpty) {
            return device.name;
          }
        }
      }
    } on Object catch (e) {
      _safeLog(
        (logger) => logger.warning(
          'getConnectedDevices lookup failed for $deviceId: $e',
          source: 'DeviceService',
        ),
        'resolve-device-name',
      );
    }
    // Before connect completes the backend's connected list is empty, so fall
    // back to the friendly model name captured during startup discovery (e.g.
    // "ZWO ASI1600MM-Cool"). This is the same source the rest of the UI uses,
    // so a profile connect-all — which only knows the persisted device id —
    // still shows the model name on the card instead of the raw id.
    final discoveryName = _discoveryNameFromId(deviceId);
    if (discoveryName != null) {
      return discoveryName;
    }
    return _friendlyNameFromId(deviceId);
  }

  /// The friendly model name for [deviceId] from the last device-discovery
  /// scan, or `null` when discovery hasn't seen this id (or only knows it by
  /// its raw id). Read synchronously from [unifiedDiscoveryProvider]'s cached
  /// results — no scan is triggered.
  String? _discoveryNameFromId(String deviceId) {
    try {
      final raw = _ref.read(unifiedDiscoveryProvider).rawDevices;
      for (final device in raw) {
        if (device.id == deviceId &&
            device.name.isNotEmpty &&
            device.name != deviceId) {
          return device.name;
        }
      }
    } on Object catch (e) {
      _safeLog(
        (logger) => logger.warning(
          'discovery name lookup failed for $deviceId: $e',
          source: 'DeviceService',
        ),
        'discovery-device-name',
      );
    }
    return null;
  }

  void _handleEquipmentEvent(SkotiqEvent event) {
    final data = event.data;
    switch (event.eventType) {
      // Connection events
      case 'Connecting':
        final deviceType = data['device_type'] as String?;
        final deviceId = data['device_id'] as String?;
        if (deviceType != null && deviceId != null) {
          _applyDeviceConnecting(deviceType, deviceId);
        }
        break;

      case 'Connected':
        final deviceType = data['device_type'] as String?;
        final deviceId = data['device_id'] as String?;
        if (deviceType != null && deviceId != null) {
          _applyDeviceConnected(deviceType, deviceId);
        }
        break;

      case 'Disconnected':
        final deviceType = data['device_type'] as String?;
        final deviceId = data['device_id'] as String?;
        _handleDeviceDisconnected(deviceType, deviceId);
        break;

      // Driver errors published from Rust via report_error /
      // connect_device_internal / heartbeat. The payload is routed through the
      // structured errorService (which also pushes a UI notification) AND sets
      // the matching device state to error, so the equipment card subtitle
      // renders the actual driver message.
      case 'Error':
        _handleDeviceError(
          deviceType: data['device_type'] as String?,
          deviceId: data['device_id'] as String?,
          message: data['message'] as String?,
          errorCode:
              data['error_code']?.toString() ?? data['errorCode']?.toString(),
          severity: event.severity,
        );
        break;

      // Legacy camera temperature event (keep for backward compatibility)
      case 'CameraTemperatureChanged':
        final temp = (data['temperature'] as num).toDouble();
        final power = (data['coolerPower'] as num).toDouble();
        _ref.read(cameraStateProvider.notifier).updateTemperature(temp, power);
        break;

      // Legacy mount position event (keep for backward compatibility)
      case 'MountPositionChanged':
        final ra = (data['ra'] as num).toDouble();
        final dec = (data['dec'] as num).toDouble();
        final alt = (data['altitude'] as num?)?.toDouble() ?? 0.0;
        final az = (data['azimuth'] as num?)?.toDouble() ?? 0.0;
        _ref.read(mountStateProvider.notifier).updatePosition(ra, dec, alt, az);

        if (data['isSlewing'] != null) {
          _ref
              .read(mountStateProvider.notifier)
              .setSlewing(data['isSlewing'] as bool);
        }
        if (data['isTracking'] != null) {
          _ref
              .read(mountStateProvider.notifier)
              .setTracking(data['isTracking'] as bool);
        }
        if (data['isParked'] != null) {
          _ref
              .read(mountStateProvider.notifier)
              .setParked(data['isParked'] as bool);
        }
        break;

      // Mount Slew Events
      case 'MountSlewStarted':
        final ra = (data['ra'] as num?)?.toDouble();
        final dec = (data['dec'] as num?)?.toDouble();
        _ref.read(mountStateProvider.notifier).setSlewing(true);
        if (ra != null && dec != null) {
          // Optionally update target position
        }
        break;

      case 'MountSlewCompleted':
        final ra = (data['ra'] as num?)?.toDouble();
        final dec = (data['dec'] as num?)?.toDouble();
        _ref.read(mountStateProvider.notifier).setSlewing(false);
        if (ra != null && dec != null) {
          _ref
              .read(mountStateProvider.notifier)
              .updatePosition(ra, dec, 0.0, 0.0);
        }
        // Smart notification - only show if not on imaging/planetarium screens
        _ref
            .read(smartNotificationServiceProvider)
            .showSuccessIfNotOnScreens(
              message: 'Slew completed',
              relevantScreens: [
                AppScreen.imaging,
                AppScreen.planetarium,
                AppScreen.sequencer,
              ],
              title: 'Mount',
            );
        break;

      // Mount Tracking Events
      case 'MountTrackingStarted':
        _ref.read(mountStateProvider.notifier).setTracking(true);
        break;

      case 'MountTrackingStopped':
        _ref.read(mountStateProvider.notifier).setTracking(false);
        break;

      // Mount Park Events
      case 'MountParkStarted':
        _ref.read(mountStateProvider.notifier).setSlewing(true);
        break;

      case 'MountParkCompleted':
        _ref.read(mountStateProvider.notifier).setSlewing(false);
        _ref.read(mountStateProvider.notifier).setParked(true);
        _ref.read(mountStateProvider.notifier).setTracking(false);
        // Smart notification
        _ref
            .read(smartNotificationServiceProvider)
            .showSuccessIfNotOnScreens(
              message: 'Mount parked',
              relevantScreens: [AppScreen.imaging, AppScreen.equipment],
              title: 'Mount',
            );
        break;

      case 'MountUnparked':
        _ref.read(mountStateProvider.notifier).setParked(false);
        // Smart notification
        _ref
            .read(smartNotificationServiceProvider)
            .showSuccessIfNotOnScreens(
              message: 'Mount unparked',
              relevantScreens: [AppScreen.imaging, AppScreen.equipment],
              title: 'Mount',
            );
        break;

      // Legacy focuser position event (keep for backward compatibility)
      case 'FocuserPositionChanged':
        final pos = data['position'] as int;
        _ref.read(focuserStateProvider.notifier).updatePosition(pos);
        if (data['isMoving'] != null) {
          _ref
              .read(focuserStateProvider.notifier)
              .setMoving(data['isMoving'] as bool);
        }
        if (data['temperature'] != null) {
          _ref
              .read(focuserStateProvider.notifier)
              .updateTemperature((data['temperature'] as num).toDouble());
        }
        break;

      // Focuser Events
      case 'FocuserMoveStarted':
        _ref.read(focuserStateProvider.notifier).setMoving(true);
        break;

      case 'FocuserMoveCompleted':
        final position = data['position'] as int?;
        _ref.read(focuserStateProvider.notifier).setMoving(false);
        if (position != null) {
          _ref.read(focuserStateProvider.notifier).updatePosition(position);
        }
        break;

      case 'FocuserTemperatureChanged':
        final temperature = (data['temperature'] as num?)?.toDouble();
        if (temperature != null) {
          _ref
              .read(focuserStateProvider.notifier)
              .updateTemperature(temperature);
        }
        break;

      // Legacy filter wheel position event (keep for backward compatibility)
      case 'FilterWheelPositionChanged':
        final pos = data['position'] as int;
        _ref.read(filterWheelStateProvider.notifier).updatePosition(pos);
        if (data['isMoving'] != null) {
          _ref
              .read(filterWheelStateProvider.notifier)
              .setMoving(data['isMoving'] as bool);
        }
        break;

      // Filter Wheel Events
      case 'FilterChanging':
        _ref.read(filterWheelStateProvider.notifier).setMoving(true);
        break;

      case 'FilterChanged':
        final position = data['position'] as int?;
        _ref.read(filterWheelStateProvider.notifier).setMoving(false);
        if (position != null) {
          _ref.read(filterWheelStateProvider.notifier).updatePosition(position);
        }
        break;

      // Rotator Events
      case 'RotatorMoveStarted':
        _ref.read(rotatorStateProvider.notifier).setMoving(true);
        break;

      case 'RotatorMoveCompleted':
        final angle = (data['angle'] as num?)?.toDouble();
        _ref.read(rotatorStateProvider.notifier).setMoving(false);
        if (angle != null) {
          _ref.read(rotatorStateProvider.notifier).updatePosition(angle);
        }
        break;

      // Camera Cooling Events
      case 'CameraCoolingStarted':
        final targetTemp = (data['target_temp'] as num?)?.toDouble();
        _ref.read(cameraStateProvider.notifier).setCooling(true);
        if (targetTemp != null) {
          _ref.read(cameraStateProvider.notifier).setTargetTemp(targetTemp);
        }
        break;

      case 'CameraCoolingReached':
        final temp = (data['temperature'] as num?)?.toDouble();
        if (temp != null) {
          _ref.read(cameraStateProvider.notifier).updateTemperature(temp, 0.0);
        }
        break;

      case 'CameraWarmingStarted':
        _ref.read(cameraStateProvider.notifier).setCooling(false);
        break;

      case 'CameraWarmingCompleted':
        // Warming finished - no additional action needed
        break;

      // Heartbeat-health routing.
      //
      // The Rust heartbeat monitor publishes status changes via the
      // equipment EventBus. We forward them into the dedicated
      // `deviceHeartbeatHealthProvider` so per-device cards can render
      // a colored indicator without each card subscribing to the
      // entire equipment event stream itself. Connection-state
      // notifiers and the driver-error handler
      // are intentionally untouched here — heartbeat health is a
      // separate gradient layered on top of connection state.
      //
      // Each case wraps the dispatch in a try/catch because the
      // notifier provider may be unavailable mid-disposal (e.g. during
      // a backend swap) and we never want a heartbeat-routing failure
      // to mask the higher-priority connection events that share this
      // method.
      case 'HeartbeatStarted':
        _heartbeat.onHeartbeatStarted(data['device_id'] as String?);
        break;

      case 'HeartbeatStatusChanged':
        final hbStatus = data['status'] as String?;
        _heartbeat.onStatusChanged(
          deviceId: data['device_id'] as String?,
          status: hbStatus,
          consecutiveFailures: (data['consecutive_failures'] as num?)?.toInt(),
          lastRttMs: DeviceHeartbeatRouter.coerceIntFromBigInt(
            data['last_rtt_ms'],
          ),
        );
        // The heartbeat-lost path emits no standalone
        // `EquipmentEvent::Disconnected`, so this canonical
        // `HeartbeatStatusChanged{Disconnected}` status is what drives the
        // disconnect side effects: clearing the per-device heartbeat health
        // dot and honouring the per-type auto-reconnect preference. State
        // transition and reconnect only — the operator-facing notification
        // comes solely from the accompanying `Error` event, so one lost
        // device still raises one toast.
        if (hbStatus != null && hbStatus.toLowerCase() == 'disconnected') {
          _handleDeviceDisconnected(
            data['device_type'] as String?,
            data['device_id'] as String?,
          );
        }
        break;

      case 'HeartbeatReconnecting':
        _heartbeat.onReconnecting(
          deviceId: data['device_id'] as String?,
          attempt: (data['attempt'] as num?)?.toInt(),
          maxAttempts: (data['max_attempts'] as num?)?.toInt(),
        );
        break;

      case 'HeartbeatReconnected':
        _heartbeat.onReconnected(
          deviceId: data['device_id'] as String?,
          afterAttempts: (data['after_attempts'] as num?)?.toInt(),
        );
        break;

      case 'HeartbeatStopped':
        // Heartbeat monitoring intentionally stopped (e.g. user
        // disconnected the device through the UI). Clear the entry so
        // the indicator returns to the gray "unknown" baseline. The
        // matching `Disconnected` event handler also clears, but the
        // events are emitted independently and either may arrive
        // first.
        final stoppedId = data['device_id'] as String?;
        if (stoppedId != null && stoppedId.isNotEmpty) {
          _heartbeat.clearDevice(stoppedId);
        }
        break;
    }
  }

  // Heartbeat event routing + start/stop helpers live in
  // [DeviceHeartbeatRouter] (`_heartbeat`). DeviceService just hands
  // event payloads to it from `_handleEquipmentEvent` and calls
  // `_heartbeat.start` / `_heartbeat.stop` from connect/disconnect
  // flows; see `device_heartbeat_router.dart`.

  /// Handle device connection event from the native EventBus.
  void _applyDeviceConnected(String deviceType, String deviceId) {
    // Resolve a friendly model name so the authoritative backend 'Connected'
    // event does not overwrite the device name with the raw device id.
    // Prefer the startup-discovery model name (e.g. "ZWO ASI1600MM-Cool");
    // when discovery hasn't seen the device, fall back to the id-pattern
    // formatter rather than the bare id.
    final resolvedName =
        _discoveryNameFromId(deviceId) ?? _friendlyNameFromId(deviceId);
    // Unknown wire types leave every notifier untouched, exactly as the
    // eleven-case switch this replaced did (it had no default branch).
    final type = deviceTypeFromWireName(deviceType);
    if (type != null) {
      readDeviceConnectionNotifier(_ref, type)
        ..setConnecting(deviceId, resolvedName)
        ..setConnected();
    }

    // Reset the reconnect lifecycle for every device type, then drive
    // sequence-resume for camera/mount from this authoritative event. This
    // also lets a manual or out-of-band connection recover a device whose
    // bounded automatic retry budget was exhausted.
    final lower = deviceType.toLowerCase();
    unawaited(
      _reconnectCoordinator.onAuthoritativeDeviceConnected(lower, deviceId),
    );
  }

  void _applyDeviceConnecting(String deviceType, String deviceId) {
    // See _applyDeviceConnected: prefer the discovery model name over the raw
    // id so the "Connecting…" label and card show the friendly name.
    final resolvedName =
        _discoveryNameFromId(deviceId) ?? _friendlyNameFromId(deviceId);
    final type = deviceTypeFromWireName(deviceType);
    if (type != null) {
      readDeviceConnectionNotifier(
        _ref,
        type,
      ).setConnecting(deviceId, resolvedName);
    }
  }

  /// Whether a `Disconnected` event for [eventDeviceId] may tear down the
  /// equipment notifier for [type].
  ///
  /// The notifiers' `setDisconnected()` resets the WHOLE slot (including
  /// `deviceId`) and takes no device id, so it cannot tell which device the
  /// event was about. Applying it to a foreign or stale id therefore erases the
  /// identity of the device that IS connected, while the native device registry
  /// (the authority behind `GET /api/devices/connected` and every driver
  /// command) still holds it. That divergence is unrecoverable through the
  /// public API: `POST /api/devices/disconnect` gates on this notifier, so it
  /// answers `device_not_connected` for a device that is listed as connected and
  /// still reporting live status — the driver can then only be released by
  /// restarting the process.
  ///
  /// An empty slot is allowed through (idempotent no-op) so genuine teardown
  /// ordering is unaffected.
  bool _disconnectEventOwnsSlot(DeviceType type, String eventDeviceId) {
    final tracked = _slotDeviceIdFor(type);
    if (tracked == null || tracked.isEmpty || tracked == eventDeviceId) {
      return true;
    }
    _safeLog(
      (logger) => logger.warning(
        'Ignoring stale ${type.name} Disconnected for $eventDeviceId; '
        'currently-tracked ${type.name} is $tracked',
        source: 'DeviceService',
      ),
      'disconnect-slot-guard-${type.name}',
    );
    return false;
  }

  /// Handle device disconnection event
  void _handleDeviceDisconnected(String? deviceType, String? deviceId) {
    if (deviceType == null || deviceId == null) return;

    // Clear the heartbeat health entry so the per-card indicator falls back to
    // "unknown" (gray dot) rather than getting stuck on the last-known value.
    // Done unconditionally up-front so a clear failure here cannot block the
    // per-device-type teardown below.
    _heartbeat.clearDevice(deviceId);

    // The disconnect is the forensic record of a lost device, so it goes
    // through _safeLog: a logger that cannot be reached demotes the line to
    // stderr instead of dropping it.
    _safeLog(
      (logger) => logger.warning(
        'Device disconnected: $deviceType ($deviceId) at '
        '${DateTime.now().toIso8601String()}',
        source: 'DeviceService',
      ),
      'device-disconnected-$deviceType',
    );

    // Check if this is a critical device and sequence is running
    final isCriticalDevice =
        deviceType.toLowerCase() == 'camera' ||
        deviceType.toLowerCase() == 'mount';
    if (isCriticalDevice) {
      _handleCriticalDeviceDisconnect(deviceType, deviceId);
    }

    // Update connection state based on device type. Unknown wire types fall
    // out here having only cleared heartbeat health and logged, exactly as the
    // eleven-case switch this replaced did (it had no default branch).
    final type = deviceTypeFromWireName(deviceType);
    if (type == null) return;

    if (type == DeviceType.camera) {
      // Only tear down camera-scoped polling state if the
      // disconnect event is for the camera we're actually tracking.
      // A stale event for a previously-disconnected camera must not
      // kill polling/IDs for the CURRENT camera.
      final trackedCameraId = _temperaturePoller.connectedCameraId;
      if (trackedCameraId != null && trackedCameraId == deviceId) {
        _temperaturePoller.stop();
      } else if (trackedCameraId != null) {
        _safeLog(
          (logger) => logger.warning(
            'Ignoring stale camera Disconnected for $deviceId; '
            'currently-tracked camera is $trackedCameraId',
            source: 'DeviceService',
          ),
          'camera-disconnect-guard',
        );
      }
    } else if (type == DeviceType.filterWheel) {
      _lastAppliedFilterOffsetByWheel.remove(deviceId);
    }

    // The notifier wipe is NOT device-id aware on its own — see
    // [_disconnectEventOwnsSlot].
    if (_disconnectEventOwnsSlot(type, deviceId)) {
      // The three position-verified device types run a polling loop that must
      // not keep publishing against a device that just went away; bumping the
      // generation retires the in-flight verify.
      switch (type) {
        case DeviceType.focuser:
          _focuserVerifyGeneration++;
        case DeviceType.filterWheel:
          _filterWheelVerifyGeneration++;
        case DeviceType.rotator:
          _rotatorVerifyGeneration++;
        default:
          break;
      }
      readDeviceConnectionNotifier(_ref, type).setDisconnected();
    }
    unawaited(_attemptReconnect(type, deviceId));
  }

  /// Handle a driver/heartbeat error event published from Rust.
  ///
  /// Three responsibilities:
  ///   1. Always log (driver, device id, message, error code if any).
  ///   2. Update the matching device-type StateNotifier with the error
  ///      so equipment-card subtitles render it.
  ///   3. Surface to the user via the structured errorService (which
  ///      also pushes to the UI notification stream).
  ///
  /// Fail-loud: this method MUST NOT swallow the payload. Individual
  /// downstream emissions are wrapped so one channel failing (e.g.
  /// notification provider mid-disposal) cannot mask the others.
  void _handleDeviceError({
    required String? deviceType,
    required String? deviceId,
    required String? message,
    required String? errorCode,
    required EventSeverity severity,
  }) {
    // Compose a human-readable error string. Even if device_type or
    // device_id are missing we still want the message visible.
    final composedMessage = StringBuffer();
    if (message != null && message.isNotEmpty) {
      composedMessage.write(message);
    } else {
      composedMessage.write('Driver reported an error (no message provided)');
    }
    if (errorCode != null && errorCode.isNotEmpty) {
      composedMessage.write(' [code: $errorCode]');
    }
    final fullMessage = composedMessage.toString();

    // 1. Log loudly with full context.
    _safeLog(
      (logger) => logger.error(
        'Driver error: type=${deviceType ?? "unknown"} '
        'id=${deviceId ?? "unknown"} code=${errorCode ?? "none"} :: '
        '$fullMessage',
        source: 'DeviceService',
      ),
      'device-error-log',
    );

    // 2. Update the matching device-type state notifier so equipment
    //    cards display the error in their subtitle.
    final exception = Exception(
      fullMessage,
    ); // setError expects Object — wrap once.
    final type = deviceTypeFromWireName(deviceType ?? '');
    if (type == null) {
      _safeLog(
        (logger) => logger.warning(
          'Error event for unknown device type "$deviceType"; '
          'no state notifier updated. Message: $fullMessage',
          source: 'DeviceService',
        ),
        'device-error-unknown-type',
      );
    } else {
      readDeviceConnectionNotifier(_ref, type).setError(exception);
    }

    // Rate-limit the user-facing surface so a flapping device cannot flood it.
    // Steps 1 (full logger record) and 2 (equipment-card error state) above run
    // on EVERY error; here we suppress an identical (deviceId, message) toast +
    // structured-history entry within the dedup window. The logger record from
    // step 1 still captures every occurrence for diagnostics, so nothing is lost.
    final now = DateTime.now();
    final dedupKey = '${deviceId ?? deviceType ?? '?'}::$fullMessage';
    final lastShown = _recentDeviceErrorToasts[dedupKey];
    if (lastShown != null &&
        now.difference(lastShown) < _deviceErrorToastWindow) {
      return;
    }
    _recentDeviceErrorToasts[dedupKey] = now;
    // Opportunistic cleanup so the map can't grow unbounded on long sessions.
    if (_recentDeviceErrorToasts.length > 128) {
      _recentDeviceErrorToasts.removeWhere(
        (_, t) => now.difference(t) > _deviceErrorToastWindow,
      );
    }

    // 3. Surface via the structured errorService. This routes through
    //    the error history (visible in diagnostics) AND pushes a UI
    //    notification toast (errorService internally calls
    //    uiNotificationProvider for error/critical severities).
    try {
      final errSvc = _ref.read(errorServiceProvider);
      final mappedSeverity = switch (severity) {
        EventSeverity.info => ErrorSeverity.info,
        EventSeverity.warning => ErrorSeverity.warning,
        EventSeverity.error => ErrorSeverity.error,
        EventSeverity.critical => ErrorSeverity.critical,
      };
      // Use deviceType for the structured entry's title. If absent we
      // still want the entry recorded, so default to "Device".
      errSvc.logDeviceError(
        operation: 'driver_error',
        message: fullMessage,
        deviceType: deviceType ?? 'Device',
        deviceId: deviceId,
        severity: mappedSeverity,
        context: errorCode == null ? null : {'error_code': errorCode},
      );
    } on Object catch (errSvcErr) {
      _safeLog(
        (logger) => logger.warning(
          'errorService emission for driver error failed: $errSvcErr '
          '(original: $fullMessage)',
          source: 'DeviceService',
        ),
        'device-error-errorservice',
      );
      // Fallback: try uiNotificationProvider directly so the user
      // still sees the message even if errorService is unavailable.
      try {
        _ref
            .read(uiNotificationProvider.notifier)
            .showError(
              fullMessage,
              title: '${deviceType ?? "Device"} Error',
              duration: const Duration(seconds: 12),
            );
      } on Object catch (uiErr) {
        _safeLog(
          (logger) => logger.warning(
            'UI notification fallback also failed: $uiErr '
            '(original: $fullMessage)',
            source: 'DeviceService',
          ),
          'device-error-ui-fallback',
        );
      }
    }
  }

  /// Schedule a reconnection attempt via the [DeviceReconnectCoordinator].
  Future<void> _attemptReconnect(DeviceType type, String deviceId) =>
      _reconnectCoordinator.attemptReconnect(type, deviceId);

  Future<void> _handleCriticalDeviceDisconnect(
    String deviceType,
    String deviceId,
  ) => _reconnectCoordinator.handleCriticalDeviceDisconnect(
    deviceType,
    deviceId,
  );

  void _handleSequencerEvent(SkotiqEvent event) {
    applySequencerEventToSequenceProviders(_ref.read, event);
  }
}
