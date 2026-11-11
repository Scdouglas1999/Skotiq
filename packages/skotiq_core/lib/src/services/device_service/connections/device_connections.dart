part of '../../device_service.dart';

/// The one connect and the one disconnect every device type goes through.
///
/// What differs by type is in the [DeviceSlot] table (heartbeat, model check)
/// and in the hooks below: what to read from the device before it counts as
/// connected ([_bringUp]), and what to stop, shut down, restart or drop
/// around a disconnect.
extension _DeviceServiceConnections on DeviceService {
  Future<void> _connect(
    DeviceType type,
    String deviceId, {
    String? host,
    int? port,
  }) {
    return _trackInFlight(() async {
      if (type == DeviceType.guider && isPhd2DeviceId(deviceId)) {
        return _connectPhd2(host: host, port: port);
      }
      final slot = type.slot;
      final notifier = _ref.read(slot.notifier);

      // A format check only. Discovery is not a precondition for connect; the
      // backend decides whether the device is reachable.
      if (!isValidDeviceIdFormat(deviceId)) {
        throw InvalidDeviceIdException(slot.noun, deviceId);
      }

      final deviceName = await _resolveDeviceDisplayName(type, deviceId);
      await _releaseDisplacedDevice(type, deviceId);
      notifier.setConnecting(deviceId, deviceName);

      var opened = false;
      try {
        await _backend.connectDevice(
          type,
          deviceId,
          expectedModel: slot.checksModel
              ? _expectedModelFor(slot.noun, deviceId)
              : null,
        );
        opened = true;
        await _bringUp(type, deviceId, deviceName);
        if (slot.heartbeat) await _startHeartbeat(type, deviceId);
      } catch (e) {
        // The driver opened the device but it never became usable: let go of
        // it. On a linked client the host owns it and decides.
        if (opened && !_hostOwnsDevices) {
          _reconnectCoordinator.expectCleanupDisconnect(deviceId);
          try {
            await _backend.disconnectDevice(type, deviceId);
          } catch (_) {
            // The bring-up failure is the one to report.
            _reconnectCoordinator.takeCleanupDisconnect(deviceId);
          }
        }
        notifier.connectFailed(e);
        rethrow;
      }
    });
  }

  Future<void> _disconnect(DeviceType type) {
    return _trackInFlight(() async {
      final slot = type.slot;
      final deviceId = _ref.read(slot.state).deviceId;
      _quiesce(type);

      // "Nothing connected" is a typed precondition, not a silent no-op, so a
      // bulk disconnect can tell it apart from a disconnect that failed.
      if (deviceId == null || deviceId.isEmpty) {
        throw DeviceNotConnectedException(slot.noun);
      }

      _markUserInitiatedDisconnect(deviceId);
      try {
        await _shutDown(type, deviceId);
        if (slot.heartbeat) {
          await _heartbeat.stop(deviceType: type, deviceId: deviceId);
        }
        if (type == DeviceType.guider && isPhd2DeviceId(deviceId)) {
          await _backend.phd2Disconnect();
        } else {
          await _backend.disconnectDevice(type, deviceId);
        }
      } catch (_) {
        _clearUserInitiatedDisconnect(deviceId);
        _resume(type, deviceId);
        if (slot.heartbeat) await _startHeartbeat(type, deviceId);
        rethrow;
      }
      _ref.read(slot.notifier).setDisconnected();
      _released(type, deviceId);
    });
  }

  /// The heartbeat router logs and swallows its own failures, so a device
  /// without a heartbeat still connects.
  Future<void> _startHeartbeat(DeviceType type, String deviceId) =>
      _heartbeat.start(deviceType: type, deviceId: deviceId, intervalMs: 10000);

  /// Read what the device's card needs and mark the slot connected. Throwing
  /// here fails the connect.
  Future<void> _bringUp(DeviceType type, String deviceId, String deviceName) {
    switch (type) {
      case DeviceType.camera:
        return _bringUpCamera(deviceId, deviceName);
      case DeviceType.mount:
        return _bringUpMount(deviceId, deviceName);
      case DeviceType.focuser:
        return _bringUpFocuser(deviceId);
      case DeviceType.filterWheel:
        return _bringUpFilterWheel(deviceId, deviceName);
      case DeviceType.rotator:
        return _bringUpRotator(deviceId);
      case DeviceType.dome:
        return _bringUpDome(deviceId);
      case DeviceType.weather:
        return _bringUpWeather(deviceId);
      case DeviceType.safetyMonitor:
        return _bringUpSafetyMonitor(deviceId);
      case DeviceType.switch_:
        return _bringUpSwitch();
      case DeviceType.guider:
      case DeviceType.coverCalibrator:
        _ref.read(type.slot.notifier).setConnected();
        return Future.value();
    }
  }

  /// Stop this service's own activity on the device; runs before the
  /// "is anything connected" check, as each of these is safe when idle.
  void _quiesce(DeviceType type) {
    switch (type) {
      case DeviceType.camera:
        // The disconnect decides the cooler, so the warm-up's prior setting
        // is not restored.
        _cancelWarmCamera(restorePriorSetting: false);
        _temperaturePoller.stop();
      case DeviceType.focuser:
        _focuserVerifyGeneration++;
      case DeviceType.rotator:
        _rotatorVerifyGeneration++;
      case DeviceType.filterWheel:
        _filterWheelVerifyGeneration++;
      default:
        break;
    }
  }

  /// Device-side work that must happen while the device is still connected.
  Future<void> _shutDown(DeviceType type, String deviceId) async {
    switch (type) {
      case DeviceType.camera:
        await _coolerOffForDisconnect(deviceId);
      case DeviceType.mount:
        // A card asking about this mount must not outlive it.
        _ref
            .read(pendingMountSiteReconciliationProvider.notifier)
            .clearFor(deviceId);
      default:
        break;
    }
  }

  /// A disconnect failed and the device is still there: restart what
  /// [_quiesce] stopped.
  void _resume(DeviceType type, String deviceId) {
    if (type == DeviceType.camera) _temperaturePoller.start(deviceId);
  }

  /// The device is gone: drop what this service kept for it.
  void _released(DeviceType type, String deviceId) {
    switch (type) {
      case DeviceType.filterWheel:
        _lastAppliedFilterOffsetByWheel.remove(deviceId);
      case DeviceType.dome:
      case DeviceType.weather:
      case DeviceType.safetyMonitor:
        _stopEnvironmentPollingIfIdle();
      default:
        break;
    }
  }

  /// Disconnect everything, the profile's guide camera included.
  ///
  /// A slot with nothing in it is skipped. A device that will not let go is
  /// reported in the result and does not stop the rest.
  Future<DisconnectAllResult> _disconnectAll() async {
    var disconnected = 0;
    final failures = <String>[];
    // The guide camera has no slot of its own; the profile names it.
    final guideCameraId = _ref
        .read(activeEquipmentProfileProvider)
        ?.guideCameraId;
    if (guideCameraId != null && guideCameraId.isNotEmpty) {
      try {
        await _backend.disconnectDevice(DeviceType.camera, guideCameraId);
      } catch (e) {
        _ref
            .read(loggingServiceProvider)
            .info(
              'Guide camera $guideCameraId not disconnected: $e',
              source: 'DeviceService',
            );
      }
    }
    for (final slot in deviceSlots) {
      try {
        await _disconnect(slot.type);
        disconnected++;
      } on DeviceNotConnectedException {
        continue;
      } catch (e) {
        failures.add('${slot.noun}: $e');
      }
    }
    return (disconnected: disconnected, failures: failures);
  }
}
