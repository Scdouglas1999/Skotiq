part of '../device_handlers.dart';

extension DeviceConnectionHandlers on DeviceHandlers {
  // Connection lifecycle
  //
  // Every connect routes through `DeviceService.connect<Type>`, never
  // `backend.connectDevice` directly. The service is what runs the
  // per-device-type flow:
  //
  //   * cameras: cool-on-connect, target-temp seeding, recommended-gain
  //     auto-apply, temperature polling, heartbeat monitoring
  //   * mounts: initial status snapshot (RA/Dec/Alt/Az + park/track flags),
  //     heartbeat monitoring
  //   * focusers: status snapshot (position, max position, temperature)
  //   * filter wheels: position settling poll, filter-name sync to driver
  //     from active profile / session
  //   * guiders: PHD2 handshake when applicable
  //
  // It also populates the per-device-type StateNotifier
  // (`cameraStateProvider`, `mountStateProvider`, ...), without which local UI
  // listening to Riverpod state still believes nothing is connected.

  /// POST /api/devices/connect
  ///
  /// Body: `{deviceId, deviceType}`. The `deviceType` value must match one
  /// of [DeviceType]'s names (case-insensitive). Returns
  /// `{status: "connected", deviceId, deviceType}` on success and surfaces
  /// validation/state errors as 4xx with a structured body so a remote
  /// dashboard can render the same "device not found" / "no profile active"
  /// hints the desktop dialog does.
  Future<Response> handleConnectDevice(Request request) async {
    _logInfo('[API] POST /api/devices/connect');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final deviceTypeStr = requireString(payload, 'deviceType');
    final deviceType = parseDeviceType(deviceTypeStr);
    if (deviceType == null) {
      throw BadRequestError(
        field: 'deviceType',
        expected: validDeviceTypeList(),
        message: 'Unknown device type: $deviceTypeStr',
      );
    }

    // Idempotency: if this exact device is already connected or mid-connect,
    // treat the request as a no-op success. A slave whose connect POST timed
    // out (slow serial mount) may re-POST a connect that is actually
    // succeeding; without this short-circuit that second request would
    // re-enter the driver open and pile up on the bus. The slave side is also
    // non-retrying, but the operator (or a double-firing dialog) can still
    // re-issue, so the host must be the authoritative guard.
    final existingState = _connectionStateFor(deviceType);
    final connectedId = _connectedDeviceIdFor(deviceType);
    if (connectedId == deviceId &&
        (existingState == DeviceConnectionState.connected ||
            existingState == DeviceConnectionState.connecting)) {
      _logInfo(
        '[API] POST /api/devices/connect no-op: ${deviceType.name} $deviceId '
        'already ${existingState == DeviceConnectionState.connected ? 'connected' : 'connecting'}',
      );
      return jsonOk({
        'status': 'connected',
        'deviceId': deviceId,
        'deviceType': deviceType.name,
      });
    }

    final service = container.read(deviceServiceProvider);
    try {
      await _dispatchConnect(service, deviceType, deviceId);
    } on _DeviceNotFoundFailure catch (e) {
      throw HandlerFailure(
        code: 'device_not_found',
        message: e.message,
        statusCode: 404,
        details: {'deviceId': deviceId, 'deviceType': deviceType.name},
      );
    } catch (e, stackTrace) {
      // The connect threw after passing discovery — most likely the
      // underlying driver refused (cable unplugged, ASCOM driver not
      // installed, INDI server unreachable, etc.). Surface a 409 (NOT a 502)
      // with the service's own message: 502 is classified transient by the
      // slave's HTTP layer, so a 502 here would invite an auto re-POST that
      // re-enters the serial bus. 409 is a definite, non-retryable result —
      // the remote operator still sees the same diagnostic message the
      // desktop UI surfaces via a snackbar.
      _logWarning(
        '[API] POST /api/devices/connect failed for ${deviceType.name} '
        '$deviceId: $e',
      );
      throw HandlerFailure(
        code: 'device_connect_failed',
        message: connectFailureReason(e),
        statusCode: 409,
        details: {'deviceId': deviceId, 'deviceType': deviceType.name},
        cause: e,
        stackTrace: stackTrace,
      );
    }

    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.equipment,
      action: HostMutationAction.connected,
      entityId: deviceId,
      extra: {'deviceType': deviceType.name, 'deviceId': deviceId},
    );

    return jsonOk({
      'status': 'connected',
      'deviceId': deviceId,
      'deviceType': deviceType.name,
    });
  }

  /// POST /api/devices/disconnect
  ///
  /// Body: `{deviceId, deviceType}`. The disconnect path normally operates on
  /// the device currently held in the matching StateNotifier; we still
  /// require `deviceId` so the caller cannot silently disconnect a
  /// different device than they think they are.
  ///
  /// When the notifier does NOT agree with the request, the DRIVER REGISTRY is
  /// consulted before refusing. The registry (`backend.getConnectedDevices`,
  /// the same source `GET /api/devices/connected` renders and the source every
  /// driver command dispatches through) is the authority on what is actually
  /// open; the notifier is a UI mirror of it, and can lose a device to a stale
  /// `Disconnected` event for a different device of the same type. Refusing on
  /// the mirror alone would strand an open driver — released only by
  /// restarting the process — while `/api/devices/connected` still listed it.
  /// So: if the registry holds the requested device, release it and report
  /// success; only a device neither surface knows about is a 409.
  Future<Response> handleDisconnectDevice(Request request) async {
    _logInfo('[API] POST /api/devices/disconnect');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final deviceTypeStr = requireString(payload, 'deviceType');
    final deviceType = parseDeviceType(deviceTypeStr);
    if (deviceType == null) {
      throw BadRequestError(
        field: 'deviceType',
        expected: validDeviceTypeList(),
        message: 'Unknown device type: $deviceTypeStr',
      );
    }

    final connectedId = _connectedDeviceIdFor(deviceType);
    if (connectedId != deviceId) {
      // The notifier is empty or tracking a different device. Fall back to the
      // driver registry rather than refusing outright.
      final orphanReleased = await _releaseFromDriverRegistry(
        deviceType,
        deviceId,
      );
      if (orphanReleased) {
        publishHostMutationFromContainer(
          container,
          entityType: HostMutationEntity.equipment,
          action: HostMutationAction.disconnected,
          entityId: deviceId,
          extra: {'deviceType': deviceType.name, 'deviceId': deviceId},
        );
        return jsonOk({
          'status': 'disconnected',
          'deviceId': deviceId,
          'deviceType': deviceType.name,
          // The caller asked for a device the equipment state did not know
          // about. Say so rather than reporting a normal teardown, so a
          // dashboard can surface the divergence.
          'releasedFromDriverRegistry': true,
        });
      }

      if (connectedId == null || connectedId.isEmpty) {
        throw HandlerFailure(
          code: 'device_not_connected',
          message: 'No ${deviceType.name} is currently connected',
          statusCode: 409,
          details: {'deviceId': deviceId, 'deviceType': deviceType.name},
        );
      }
      throw HandlerFailure(
        code: 'device_id_mismatch',
        message:
            'Requested deviceId does not match the currently-connected ${deviceType.name}',
        statusCode: 409,
        details: {
          'requestedDeviceId': deviceId,
          'connectedDeviceId': connectedId,
          'deviceType': deviceType.name,
        },
      );
    }

    final service = container.read(deviceServiceProvider);
    try {
      await service.disconnect(deviceType);
    } catch (e, stackTrace) {
      _logWarning(
        '[API] POST /api/devices/disconnect failed for ${deviceType.name} '
        '$deviceId: $e',
      );
      throw HandlerFailure(
        code: 'device_disconnect_failed',
        message: connectFailureReason(e),
        statusCode: 502,
        details: {'deviceId': deviceId, 'deviceType': deviceType.name},
        cause: e,
        stackTrace: stackTrace,
      );
    }

    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.equipment,
      action: HostMutationAction.disconnected,
      entityId: deviceId,
      extra: {'deviceType': deviceType.name, 'deviceId': deviceId},
    );

    return jsonOk({
      'status': 'disconnected',
      'deviceId': deviceId,
      'deviceType': deviceType.name,
    });
  }

  /// Release [deviceId] straight through the driver registry when the equipment
  /// notifier for [deviceType] cannot vouch for it.
  ///
  /// Returns true when the registry held the device and the driver was closed.
  /// Returns false when the registry does not list it, in which case the caller
  /// reports the normal 409 — the request really is about a device nothing has
  /// open.
  ///
  /// `backend.disconnectDevice` is a COMPLETE release: the native
  /// `DeviceManager::disconnect_device` stops that device's heartbeat before
  /// closing the driver. It is used directly (instead of `DeviceService`) because
  /// `DeviceService.disconnect<Type>()` derives its target from the very notifier
  /// that has already lost the device, so it would throw
  /// `DeviceNotConnectedException` and the driver would stay open forever.
  Future<bool> _releaseFromDriverRegistry(
    DeviceType deviceType,
    String deviceId,
  ) async {
    final backend = container.read(deviceBackendProvider);
    List<DeviceInfo> connected;
    try {
      connected = await backend.getConnectedDevices();
    } catch (e) {
      _logWarning(
        '[API] POST /api/devices/disconnect could not read the driver registry '
        'while checking ${deviceType.name} $deviceId: $e',
      );
      return false;
    }

    final held = connected.any(
      (d) => d.id == deviceId && d.deviceType == deviceType,
    );
    if (!held) return false;

    _logWarning(
      '[API] POST /api/devices/disconnect: ${deviceType.name} $deviceId is open '
      'in the driver registry but the equipment state does not track it '
      '(tracked: ${_connectedDeviceIdFor(deviceType) ?? 'none'}). Releasing the '
      'driver directly so it cannot be stranded.',
    );
    try {
      await backend.disconnectDevice(deviceType, deviceId);
    } catch (e, stackTrace) {
      throw HandlerFailure(
        code: 'device_disconnect_failed',
        message: connectFailureReason(e),
        statusCode: 502,
        details: {
          'deviceId': deviceId,
          'deviceType': deviceType.name,
          'releasedFromDriverRegistry': true,
        },
        cause: e,
        stackTrace: stackTrace,
      );
    }
    return true;
  }

  /// Connect through `DeviceService`, which owns the bookkeeping (slot state,
  /// cool-on-connect, heartbeat, filter-name sync).
  Future<void> _dispatchConnect(
    DeviceService service,
    DeviceType type,
    String deviceId,
  ) async {
    try {
      // A linked client's sweep asks for the profile's guide camera as a
      // camera; connected as one it would take the imaging camera's place.
      if (type == DeviceType.camera &&
          isProfileGuideCamera(
            container.read(activeEquipmentProfileProvider),
            deviceId,
          )) {
        await service.connectGuideCamera(deviceId);
      } else {
        await service.connect(type, deviceId);
      }
    } on Exception catch (e) {
      // DeviceService throws `Exception('<Kind> not found: <id>')` when
      // discovery doesn't surface the requested device. Translate that
      // into a structured 404 so remote clients can distinguish
      // "you asked for a device that does not exist" from
      // "the driver failed to open the device".
      // Internal use only: the curated "<Kind> not found: <id>" service
      // message is matched here and re-thrown as a structured 404 below —
      // the raw exception object itself is never serialized.
      final message = '$e';
      if (message.contains('not found:')) {
        throw _DeviceNotFoundFailure(message.replaceFirst('Exception: ', ''));
      }
      rethrow;
    }
  }

  /// Reads the deviceId currently held by the matching equipment
  /// StateNotifier. Used by the disconnect endpoint to verify that the
  /// caller is asking to disconnect the device that is actually connected.
  String? _connectedDeviceIdFor(DeviceType type) =>
      readDeviceSlot(container, type).deviceId;

  /// Reads the current [DeviceConnectionState] held by the matching equipment
  /// StateNotifier. Used by the connect endpoint to short-circuit a redundant
  /// connect (idempotency) when the requested device is already connected or
  /// mid-connect.
  DeviceConnectionState _connectionStateFor(DeviceType type) =>
      readDeviceSlot(container, type).connectionState;
}
