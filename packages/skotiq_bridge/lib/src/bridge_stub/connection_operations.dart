part of '../bridge_stub.dart';

extension _NativeBridgeConnectionOperations on _NativeBridgeImplementation {
  // Device connection

  DriverType? _inferDriverTypeFromDeviceId(String deviceId) {
    if (deviceId.startsWith('ascom:')) return DriverType.ascom;
    if (deviceId.startsWith('alpaca:')) return DriverType.alpaca;
    if (deviceId.startsWith('indi:')) return DriverType.indi;
    if (deviceId.startsWith('native:')) return DriverType.native;
    if (deviceId.startsWith('sim:') || deviceId.startsWith('simulator:')) {
      return DriverType.simulator;
    }
    return null;
  }

  void _recordConnectedDevice({
    required DeviceType deviceType,
    required String deviceId,
    DriverType? driverType,
    String? name,
    String? displayName,
    String? description,
    String? driverVersion,
  }) {
    _connectedDevices[deviceId] = true;

    final resolvedDriverType =
        driverType ?? _inferDriverTypeFromDeviceId(deviceId);
    if (resolvedDriverType == null) {
      developer.log(
        '[Bridge] Connected device "$deviceId" has no inferable driver type; omitting from fallback connected-device metadata.',
        name: 'NativeBridge',
        level: 900,
      );
      _connectedDeviceInfo.remove(deviceId);
      return;
    }

    final resolvedName = name ?? deviceId;
    _connectedDeviceInfo[deviceId] = DeviceInfo(
      id: deviceId,
      name: resolvedName,
      deviceType: deviceType,
      driverType: resolvedDriverType,
      description: description ?? 'Connected device',
      driverVersion: driverVersion ?? 'unknown',
      displayName: displayName ?? resolvedName,
    );
  }

  /// Connect to a device
  Future<void> connectDevice(DeviceType deviceType, String deviceId) async {
    // Check if this is PHD2 (supports new format: phd2:host:port or legacy: phd2)
    if (_isPhd2DeviceId(deviceId)) {
      String? host;
      int? port;

      if (deviceId.startsWith('phd2://')) {
        final uri = Uri.tryParse(deviceId);
        host = uri?.host;
        port = uri?.port == 0 ? null : uri?.port;
      } else if (deviceId.startsWith('phd2:')) {
        // Parse phd2:host:port format
        final parts = deviceId.split(':');
        if (parts.length >= 3) {
          host = parts[1];
          port = int.tryParse(parts[2]) ?? 4400;
        }
      }

      await phd2Connect(host: host, port: port);
      _recordConnectedDevice(
        deviceType: deviceType,
        deviceId: 'phd2_guider',
        driverType: DriverType.native,
        name: 'PHD2',
        displayName: 'PHD2',
        description: 'PHD2 Guiding',
        driverVersion: 'external',
      );
      return;
    }

    // Native bridge connection (ASCOM, Alpaca, INDI, native vendor SDKs)
    // Rust owns every device family, so a missing native bridge is a hard
    // failure rather than a reason to try a second implementation.
    if (!_nativeAvailable) {
      throw Exception(
        'Cannot connect to $deviceId: Native bridge required but not available',
      );
    }

    try {
      developer.log(
        '[Bridge] Attempting native connection for $deviceId...',
        name: 'NativeBridge',
        level: 800,
      );
      final genDeviceType = _toGenDeviceType(deviceType);
      await gen_api.apiConnectDevice(
        deviceType: genDeviceType,
        deviceId: deviceId,
      );
      developer.log(
        '[Bridge] Successfully connected to $deviceId via native bridge',
        name: 'NativeBridge',
        level: 800,
      );

      _recordConnectedDevice(deviceType: deviceType, deviceId: deviceId);

      // Emit connection event
      _eventController.add(
        _FallbackSkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.equipment,
          eventType: 'Connected',
          data: {'deviceType': deviceType.name, 'deviceId': deviceId},
        ),
      );
    } catch (e, stackTrace) {
      developer.log(
        '[Bridge] Native connection failed for $deviceId',
        name: 'NativeBridge',
        level: 1000,
        error: e,
        stackTrace: stackTrace,
      );
      throw Exception('Failed to connect to $deviceId via native bridge: $e');
    }
  }

  /// Disconnect from a device
  Future<void> disconnectDevice(DeviceType deviceType, String deviceId) async {
    // Handle PHD2 disconnection (supports new format: phd2:host:port or legacy: phd2)
    if (_isPhd2DeviceId(deviceId)) {
      await phd2Disconnect();
    } else if (_nativeAvailable) {
      // Connects are authoritative in Rust, so their matching disconnect must
      // cross the same FFI boundary: clearing only the Dart bookkeeping below
      // leaves the native driver open while every surface reports the device
      // disconnected. A Rust disconnect failure surfaces rather than claiming
      // success.
      try {
        await gen_api.apiDisconnectDevice(
          deviceType: _toGenDeviceType(deviceType),
          deviceId: deviceId,
        );
      } catch (error, stackTrace) {
        developer.log(
          '[Bridge] Native disconnect failed for $deviceId',
          name: 'NativeBridge',
          level: 1000,
          error: error,
          stackTrace: stackTrace,
        );
        rethrow;
      }
    }

    _connectedDevices.remove(deviceId);
    _connectedDeviceInfo.remove(deviceId);

    _eventController.add(
      _FallbackSkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: EventSeverity.info,
        category: EventCategory.equipment,
        eventType: 'Disconnected',
        data: {'deviceType': deviceType.name, 'deviceId': deviceId},
      ),
    );
  }

  /// Get list of connected devices
  Future<List<DeviceInfo>> getConnectedDevices() async {
    // If native bridge is available, use it to get authoritative connected devices list
    if (_nativeAvailable) {
      try {
        final nativeDevices = await gen_api.apiGetConnectedDevices();
        // Sync our local tracking with native state
        _connectedDevices.clear();
        _connectedDeviceInfo.clear();
        for (final device in nativeDevices) {
          _recordConnectedDevice(
            deviceType: _fromGenDeviceType(device.deviceType),
            deviceId: device.id,
            driverType: _fromGenDriverType(device.driverType),
            name: device.name,
            displayName: device.displayName,
            description: device.description,
            driverVersion: device.driverVersion,
          );
        }
        return nativeDevices;
      } catch (e) {
        developer.log(
          '[Bridge] Warning: Failed to get connected devices from native API: $e',
          name: 'NativeBridge',
          level: 900,
        );
        // Fall through to fallback implementation
      }
    }

    // Fallback: return only explicitly tracked metadata captured at connection time.
    return _connectedDeviceInfo.values.toList(growable: false);
  }
}
