part of '../device_service.dart';

/// How long an identical `(deviceId, message)` failed connect is told only
/// once (see [_DeviceServiceEventHandling._handleDeviceError]). It is still
/// logged and still shown on the equipment card.
const Duration _deviceErrorToastWindow = Duration(seconds: 60);
final Map<String, DateTime> _recentDeviceErrorToasts = <String, DateTime>{};

/// How often a focuser that reads as moving is re-read from the device, and
/// for how long, when the move that started it never reports its end.
const Duration _focuserMoveSettleInterval = Duration(seconds: 3);
const Duration _focuserMoveSettleLimit = Duration(minutes: 10);

extension _DeviceServiceEventHandling on DeviceService {
  /// A move started elsewhere (the sequencer, an autofocus run, the host) has
  /// no end event when it fails. While the focuser reads as moving, its status
  /// is the authority: once the device says it has stopped, so does the app.
  void _watchFocuserMoveSettle() {
    _focuserMoveSettleWatch?.cancel();
    final deadline = DateTime.now().add(_focuserMoveSettleLimit);
    var inFlight = false;
    _focuserMoveSettleWatch = Timer.periodic(_focuserMoveSettleInterval, (
      timer,
    ) async {
      final state = _ref.read(focuserStateProvider);
      final deviceId = state.deviceId;
      if (_disposed ||
          !state.isMoving ||
          deviceId == null ||
          DateTime.now().isAfter(deadline)) {
        timer.cancel();
        return;
      }
      // A move this service drives settles the state itself.
      if (inFlight || _isFocuserMoveRunning) return;
      inFlight = true;
      try {
        final status = await _backend.getFocuserStatus(deviceId);
        if (_disposed || !timer.isActive) return;
        if (_ref.read(focuserStateProvider).deviceId != deviceId) return;
        if (!status.moving) {
          final notifier = _ref.read(focuserStateProvider.notifier);
          notifier.updatePosition(status.position);
          notifier.setMoving(false);
          timer.cancel();
        }
      } catch (_) {
        // An unreadable focuser keeps its last state; the next tick retries.
      } finally {
        inFlight = false;
      }
    });
  }

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
      logSafely(
        _ref,
        (logger) => logger.warning(
          'getConnectedDevices lookup failed for $deviceId: $e',
          source: 'DeviceService',
        ),
      );
    }
    // The model the profile slot expects at this id: after the bus enumerated
    // in another order the cached discovery below still names the device
    // that used to be here, and the host refuses any device but this model.
    final expected = _expectedSlotName(type, deviceId);
    if (expected != null) return expected;
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

  /// The model the active profile's [type] slot expects at [deviceId], or
  /// null (see [_expectedModelFor]).
  String? _expectedSlotName(DeviceType type, String deviceId) {
    final slot = type.slot;
    return slot.checksModel ? _expectedModelFor(slot.noun, deviceId) : null;
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
      logSafely(
        _ref,
        (logger) => logger.warning(
          'discovery name lookup failed for $deviceId: $e',
          source: 'DeviceService',
        ),
      );
    }
    return null;
  }

  void _handleEquipmentEvent(SkotiqEvent event) {
    final equipment = equipmentEventOf(event);
    if (equipment == null) return;
    final failedConnect = _connecting.isFailedConnect(event);
    final data = event.data;
    switch (equipment) {
      // Connection events
      case bridge.EquipmentEvent_Connecting(:final deviceType, :final deviceId):
        _applyDeviceConnecting(deviceType, deviceId);
        break;

      case bridge.EquipmentEvent_Connected(:final deviceType, :final deviceId):
        _applyDeviceConnected(deviceType, deviceId);
        break;

      case bridge.EquipmentEvent_Disconnected(
        :final deviceType,
        :final deviceId,
      ):
        _handleDeviceDisconnected(deviceType, deviceId);
        break;

      // Driver errors published from Rust via report_error /
      // connect_device_internal / heartbeat. They set the matching device
      // state to error, so the equipment card subtitle renders the driver's
      // message.
      case bridge.EquipmentEvent_Error(
        :final deviceType,
        :final deviceId,
        :final message,
      ):
        _handleDeviceError(
          deviceType: deviceType,
          deviceId: deviceId,
          message: message,
          errorCode:
              data['error_code']?.toString() ?? data['errorCode']?.toString(),
          severity: event.severity,
          failedConnect: failedConnect,
        );
        break;

      case bridge.EquipmentEvent_CameraSettingsChanged():
        applyCameraSettings(_ref.container, data);
        break;

      case bridge.EquipmentEvent_CameraRetainedCapturesChanged():
        _ref.read(retainedCapturesRevisionProvider.notifier).state++;
        break;

      // AutofocusProgress and FocuserBacklashCalibrationProgress arrive as
      // property changes too; no device setting has their names.
      case bridge.EquipmentEvent_PropertyChanged():
        // Gain, offset, binning, slot names and the other settings the native
        // DeviceManager publishes whoever changed them.
        applyDevicePropertyChange(_ref.container, data);
        break;

      // The camera's own temperature reading, published natively from the
      // status reads (CameraTemperatureChanged), and the cooler, focuser,
      // filter wheel and rotator events: one applier shared with the slave's
      // mirror, which ignores events for a device not in the slot.
      case bridge.EquipmentEvent_CameraTemperatureChanged() ||
          bridge.EquipmentEvent_FilterChanging() ||
          bridge.EquipmentEvent_FilterChanged() ||
          bridge.EquipmentEvent_RotatorMoveStarted() ||
          bridge.EquipmentEvent_RotatorMoveCompleted() ||
          bridge.EquipmentEvent_CameraCoolingStarted() ||
          bridge.EquipmentEvent_CameraCoolingReached() ||
          bridge.EquipmentEvent_CameraWarmingStarted() ||
          bridge.EquipmentEvent_CameraWarmingCompleted():
        applyDeviceStateEvent(_ref.container, equipment);
        break;

      // Mount Slew Events
      case bridge.EquipmentEvent_MountSlewStarted(:final deviceId):
        if (!_isSlotMount(deviceId)) break;
        _ref.read(mountStateProvider.notifier).setSlewing(true);
        break;

      // Sent once the mount has arrived. It carries the commanded target, not
      // a reading, so the position stays whatever the mount last reported.
      case bridge.EquipmentEvent_MountSlewCompleted(:final deviceId):
        if (!_isSlotMount(deviceId)) break;
        _ref.read(mountStateProvider.notifier).setSlewing(false);
        _tell(
          NotificationCategory.mountMoved,
          title: 'Mount',
          body: 'Slew completed',
          runStep: true,
          quietOn: const {
            AppScreen.dashboard,
            AppScreen.imaging,
            AppScreen.planetarium,
            AppScreen.sequencer,
          },
        );
        break;

      // Mount Tracking Events
      case bridge.EquipmentEvent_MountTrackingStarted(:final deviceId):
        if (!_isSlotMount(deviceId)) break;
        _ref.read(mountStateProvider.notifier).setTracking(true);
        break;

      case bridge.EquipmentEvent_MountTrackingStopped(:final deviceId):
        if (!_isSlotMount(deviceId)) break;
        _ref.read(mountStateProvider.notifier).setTracking(false);
        break;

      // Mount Park Events
      case bridge.EquipmentEvent_MountParkStarted(:final deviceId):
        if (!_isSlotMount(deviceId)) break;
        _ref.read(mountStateProvider.notifier).setSlewing(true);
        break;

      case bridge.EquipmentEvent_MountParkCompleted(:final deviceId):
        if (!_isSlotMount(deviceId)) break;
        _ref.read(mountStateProvider.notifier).setSlewing(false);
        _ref.read(mountStateProvider.notifier).setParked(true);
        _ref.read(mountStateProvider.notifier).setTracking(false);
        _tell(
          NotificationCategory.mountMoved,
          title: 'Mount',
          body: 'Mount parked',
          quietOn: const {AppScreen.imaging, AppScreen.equipment},
        );
        break;

      case bridge.EquipmentEvent_MountUnparked(:final deviceId):
        if (!_isSlotMount(deviceId)) break;
        _ref.read(mountStateProvider.notifier).setParked(false);
        _tell(
          NotificationCategory.mountMoved,
          title: 'Mount',
          body: 'Mount unparked',
          quietOn: const {AppScreen.imaging, AppScreen.equipment},
        );
        break;

      // Focuser Events
      case bridge.EquipmentEvent_FocuserMoveStarted():
        if (applyDeviceStateEvent(_ref.container, equipment)) {
          _watchFocuserMoveSettle();
        }
        break;

      case bridge.EquipmentEvent_FocuserMoveCompleted():
        if (applyDeviceStateEvent(_ref.container, equipment)) {
          _focuserMoveSettleWatch?.cancel();
          _focuserMoveSettleWatch = null;
        }
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
      case bridge.EquipmentEvent_HeartbeatStarted():
        _heartbeat.onHeartbeatStarted(data['device_id'] as String?);
        break;

      case bridge.EquipmentEvent_HeartbeatStatusChanged():
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

      case bridge.EquipmentEvent_HeartbeatReconnecting():
        _heartbeat.onReconnecting(
          deviceId: data['device_id'] as String?,
          attempt: (data['attempt'] as num?)?.toInt(),
          maxAttempts: (data['max_attempts'] as num?)?.toInt(),
        );
        break;

      case bridge.EquipmentEvent_HeartbeatReconnected():
        _heartbeat.onReconnected(
          deviceId: data['device_id'] as String?,
          afterAttempts: (data['after_attempts'] as num?)?.toInt(),
        );
        break;

      case bridge.EquipmentEvent_HeartbeatStopped():
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

      case bridge.EquipmentEvent_DeviceDiscovered() ||
          bridge.EquipmentEvent_DeviceLost():
        break;
    }
  }

  /// Whether a `deviceType`/`deviceId` event is about the profile's guide
  /// camera, which has no slot of its own and must not take the camera's.
  /// Whether a mount event is about the mount in the app's slot. An event
  /// without an id (a host older than the id on mount events) is.
  bool _isSlotMount(String deviceId) =>
      deviceId.isEmpty ||
      readDeviceSlot(_ref.container, DeviceType.mount).deviceId == deviceId;

  bool _isGuideCameraEvent(String? deviceType, String? deviceId) {
    if (deviceTypeFromWireName(deviceType ?? '') != DeviceType.camera ||
        deviceId == null) {
      return false;
    }
    // The cameras' ids were just moved (the bus enumerated them in another
    // order) and the profile may not show it yet: the main camera can be at
    // the guide camera's old id.
    if (_slotExpectation('camera')?.deviceId == deviceId) return false;
    final guide = _slotExpectation('guide camera')?.deviceId;
    if (guide == deviceId) return true;
    return isProfileGuideCamera(
      _ref.read(activeEquipmentProfileProvider),
      deviceId,
    );
  }

  /// Handle device connection event from the native EventBus.
  void _applyDeviceConnected(String deviceType, String deviceId) {
    if (_isGuideCameraEvent(deviceType, deviceId)) return;
    // Resolve a friendly model name so the authoritative backend 'Connected'
    // event does not overwrite the device name with the raw device id.
    // Prefer the startup-discovery model name (e.g. "ZWO ASI1600MM-Cool");
    // when discovery hasn't seen the device, fall back to the id-pattern
    // formatter rather than the bare id.
    // Unknown wire types leave every notifier untouched, exactly as the
    // eleven-case switch this replaced did (it had no default branch).
    final type = deviceTypeFromWireName(deviceType);
    final resolvedName =
        (type == null ? null : _expectedSlotName(type, deviceId)) ??
        _discoveryNameFromId(deviceId) ??
        _friendlyNameFromId(deviceId);
    final meaning = _attempts.onConnected(deviceId);
    if (meaning == ConnectedMeaning.stale) {
      // The connect this event belongs to has failed and the device is being
      // let go of; the slot keeps showing why.
      logSafely(
        _ref,
        (logger) => logger.info(
          'Ignoring Connected for $deviceType ($deviceId): its connect '
          'failed and the device is being released',
          source: 'DeviceService',
        ),
      );
      return;
    }
    if (type != null) {
      readDeviceConnectionNotifier(_ref.container, type)
        ..setConnecting(deviceId, resolvedName)
        ..setConnected();
      // A new connection starts with no stale readings.
      _ref.read(deviceReadHealthProvider.notifier).clear(type);
      if (meaning == ConnectedMeaning.late) {
        unawaited(_finishLateConnect(type, deviceId, resolvedName));
      }
    }

    // Reset the reconnect lifecycle for every device type, then drive
    // sequence-resume for camera/mount from this authoritative event. This
    // also lets a manual or out-of-band connection recover a device whose
    // bounded automatic retry budget was exhausted.
    if (type != null) {
      unawaited(
        _reconnectCoordinator.onAuthoritativeDeviceConnected(type, deviceId),
      );
    }
  }

  void _applyDeviceConnecting(String deviceType, String deviceId) {
    if (_isGuideCameraEvent(deviceType, deviceId)) return;
    // This service's own connect has already set the slot, and may since
    // have failed.
    if (_attempts.isOwn(deviceId)) return;
    // See _applyDeviceConnected: prefer the discovery model name over the raw
    // id so the "Connecting…" label and card show the friendly name.
    final resolvedName =
        _discoveryNameFromId(deviceId) ?? _friendlyNameFromId(deviceId);
    final type = deviceTypeFromWireName(deviceType);
    if (type != null) {
      readDeviceConnectionNotifier(
        _ref.container,
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
    if (tracked == null || tracked.isEmpty) {
      // A slot that holds no device but shows why a connect failed keeps
      // saying so; only a new connect or the user clears it.
      return readDeviceSlot(_ref.container, type).connectionState !=
          DeviceConnectionState.error;
    }
    if (tracked == eventDeviceId) return true;
    logSafely(
      _ref,
      (logger) => logger.warning(
        'Ignoring stale ${type.name} Disconnected for $eventDeviceId; '
        'currently-tracked ${type.name} is $tracked',
        source: 'DeviceService',
      ),
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

    // The app let go of a device whose connect did not come up. The connect
    // already left the slot showing why; nothing was lost.
    if (_attempts.onDisconnected(deviceId)) {
      logSafely(
        _ref,
        (logger) => logger.info(
          'Released $deviceType ($deviceId) after a connect that did not '
          'come up',
          source: 'DeviceService',
        ),
      );
      return;
    }

    logSafely(
      _ref,
      (logger) => logger.warning(
        'Device disconnected: $deviceType ($deviceId) at '
        '${DateTime.now().toIso8601String()}',
        source: 'DeviceService',
      ),
    );

    // The guide camera is the guider's: losing it is a guiding problem, which
    // the guider reports. It is not the imaging camera and has no slot.
    if (_isGuideCameraEvent(deviceType, deviceId)) return;

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
        logSafely(
          _ref,
          (logger) => logger.warning(
            'Ignoring stale camera Disconnected for $deviceId; '
            'currently-tracked camera is $trackedCameraId',
            source: 'DeviceService',
          ),
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
      readDeviceConnectionNotifier(_ref.container, type).setDisconnected();
    }
    _reconnectCoordinator.onDeviceLost(type, deviceId);
  }

  /// Handle a driver/heartbeat error event published from Rust.
  ///
  /// Logs it, puts the device's slot in error for an error-level event so
  /// the equipment card shows the driver's message, and records it in the
  /// error history. The operator is told once: a lost device by the
  /// notification router's equipment row, a warning by the error bridge, and
  /// a connect somebody else started that did not succeed ([failedConnect])
  /// here, on the router's equipment row, because only this service can say
  /// whether it was this app's own connect, which its caller tells.
  void _handleDeviceError({
    required String? deviceType,
    required String? deviceId,
    required String? message,
    required String? errorCode,
    required EventSeverity severity,
    required bool failedConnect,
  }) {
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

    logSafely(
      _ref,
      (logger) => logger.error(
        'Driver error: type=${deviceType ?? "unknown"} '
        'id=${deviceId ?? "unknown"} code=${errorCode ?? "none"} :: '
        '$fullMessage',
        source: 'DeviceService',
      ),
    );

    // The failure of this service's own connect. The connect call leaves the
    // slot showing it and hands it to whoever asked for the connect, so it
    // is told there, once.
    if (deviceId != null && _attempts.isOwn(deviceId)) return;

    final type = deviceTypeFromWireName(deviceType ?? '');
    final isGuideCamera = _isGuideCameraEvent(deviceType, deviceId);
    // An error while the slot is connecting this device is a connect that
    // somebody else started (the native reconnect, the host, another client)
    // and that did not succeed; say that rather than only the driver's words.
    var toldMessage = fullMessage;
    if (type == null) {
      logSafely(
        _ref,
        (logger) => logger.warning(
          'Error event for unknown device type "$deviceType"; '
          'no state notifier updated. Message: $fullMessage',
          source: 'DeviceService',
        ),
      );
    } else if (!isGuideCamera && severity.index >= EventSeverity.error.index) {
      // A warning-level Error is a notice about a device that still works
      // (a setting not restored, a connect-check note): it leaves the slot as
      // it is.
      final before = readDeviceSlot(_ref.container, type);
      if (before.connectionState == DeviceConnectionState.connecting &&
          before.deviceId == deviceId) {
        final verb = before.lastError == null ? 'connect' : 'reconnect';
        toldMessage = 'The ${type.noun} did not $verb: $fullMessage';
      }
      readDeviceConnectionNotifier(
        _ref.container,
        type,
      ).setError(Exception(fullMessage));
    }

    logSafely(
      _ref,
      (logger) => logger.log(
        switch (severity) {
          EventSeverity.info => LogLevel.info,
          EventSeverity.warning => LogLevel.warning,
          EventSeverity.error => LogLevel.error,
          EventSeverity.critical => LogLevel.critical,
        },
        toldMessage,
        source: 'device:driver_error',
      ),
    );

    if (!failedConnect || severity.index < EventSeverity.error.index) return;

    // A flapping device retries its connect over and over: an identical
    // (device, message) failure is told once per window.
    final now = DateTime.now();
    final dedupKey = '${deviceId ?? deviceType ?? '?'}::$toldMessage';
    final lastShown = _recentDeviceErrorToasts[dedupKey];
    if (lastShown != null &&
        now.difference(lastShown) < _deviceErrorToastWindow) {
      return;
    }
    _recentDeviceErrorToasts[dedupKey] = now;
    if (_recentDeviceErrorToasts.length > 128) {
      _recentDeviceErrorToasts.removeWhere(
        (_, t) => now.difference(t) > _deviceErrorToastWindow,
      );
    }
    final critical = severity == EventSeverity.critical;
    _tell(
      NotificationCategory.equipmentDisconnected,
      title: critical ? 'Critical: Device' : '${deviceType ?? "Device"} Error',
      body: describeError(toldMessage, domain: ErrorDomain.device).full,
      severity: severity,
    );
  }

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
