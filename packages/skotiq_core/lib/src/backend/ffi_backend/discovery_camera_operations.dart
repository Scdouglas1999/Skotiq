part of '../ffi_backend.dart';

/// Strips control characters (CR/LF/tab) and collapses whitespace in device
/// names/descriptions. Serial drivers — e.g. an OnStep mount answering the
/// LX200 `:GVP#` product query — can leak raw `\r\n` from the wire straight
/// into the display name (`"Pegasus NYX-101#\r\n (COM4)"`), which then renders
/// as a broken multi-line entry in device pickers.
String _sanitizeDeviceText(String value) => value
    .replaceAll(RegExp(r'[\x00-\x1f]+'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

mixin _FfiDiscoveryCameraOperations on _FfiBackendBase {
  // Device Discovery & Connection

  @override
  Future<List<DeviceInfo>> discoverDevices(DeviceType deviceType) async {
    final bridgeType = _toBridgeDeviceType(deviceType);
    final bridgeDevices = await _NativeProcessState.discovery.devices(
      bridgeType,
    );

    return bridgeDevices
        .map(
          (d) => DeviceInfo(
            id: d.id,
            name: _sanitizeDeviceText(d.name),
            deviceType: deviceType,
            driverType: _fromBridgeDriverType(d.driverType),
            description: _sanitizeDeviceText(d.description),
            driverVersion: d.driverVersion,
          ),
        )
        .toList();
  }

  @override
  Future<List<DeviceInfo>> discoverIndiAtAddress(String host, int port) async {
    final bridgeDevices = await _discoverAddressDevices(
      label: 'INDI',
      host: host,
      port: port,
      discover: () => bridge.apiDiscoverIndiAtAddress(host: host, port: port),
    );
    return bridgeDevices
        .map(
          (d) => DeviceInfo(
            id: d.id,
            name: _sanitizeDeviceText(d.name),
            deviceType: _fromBridgeDeviceType(d.deviceType),
            driverType: _fromBridgeDriverType(d.driverType),
            description: _sanitizeDeviceText(d.description),
            driverVersion: d.driverVersion,
          ),
        )
        .toList();
  }

  @override
  Future<List<DeviceInfo>> discoverAlpacaAtAddress(
    String host,
    int port,
  ) async {
    final bridgeDevices = await _discoverAddressDevices(
      label: 'Alpaca',
      host: host,
      port: port,
      discover: () => bridge.apiDiscoverAlpacaAtAddress(host: host, port: port),
    );
    return bridgeDevices
        .map(
          (d) => DeviceInfo(
            id: d.id,
            name: _sanitizeDeviceText(d.name),
            deviceType: _fromBridgeDeviceType(d.deviceType),
            driverType: _fromBridgeDriverType(d.driverType),
            description: _sanitizeDeviceText(d.description),
            driverVersion: d.driverVersion,
          ),
        )
        .toList();
  }

  /// Probe a specific INDI/Alpaca endpoint, propagating failure.
  ///
  /// A refused connection reaches the caller as
  /// `SkotiqError::connection_failed`, so "nothing answered at that
  /// address" is never reported as "answered, and listed no devices". The one
  /// caller that must survive an unreachable address — the startup sweep in
  /// `unified_discovery_provider` — wraps this call itself and reports the
  /// failure per backend.
  Future<List<bridge.DeviceInfo>> _discoverAddressDevices({
    required String label,
    required String host,
    required int port,
    required Future<List<bridge.DeviceInfo>> Function() discover,
  }) async {
    return discover();
  }

  @override
  Future<void> connectDevice(
    DeviceType deviceType,
    String deviceId, {
    String? expectedModel,
  }) async {
    // PHD2 is reached through its own client, not the device registry.
    if (isPhd2WireToken(deviceId)) {
      String? host;
      int? port;
      if (deviceId.startsWith('phd2://')) {
        final uri = Uri.tryParse(deviceId);
        host = uri?.host;
        port = uri?.port == 0 ? null : uri?.port;
      } else if (deviceId.startsWith('phd2:')) {
        final parts = deviceId.split(':');
        if (parts.length >= 3) {
          host = parts[1];
          port = int.tryParse(parts[2]) ?? 4400;
        }
      }
      await phd2Connect(host: host ?? 'localhost', port: port ?? 4400);
      return;
    }

    if (!bridge.NativeBridge.isNativeAvailable) {
      throw Exception(
        'Cannot connect to $deviceId: Native bridge required but not available',
      );
    }

    final bridgeType = _toBridgeDeviceType(deviceType);
    try {
      if (expectedModel == null) {
        await bridge.apiConnectDevice(
          deviceType: bridgeType,
          deviceId: deviceId,
        );
      } else {
        await bridge.apiConnectDeviceExpecting(
          deviceType: bridgeType,
          deviceId: deviceId,
          expectedModel: expectedModel,
        );
      }
    } catch (e, stackTrace) {
      _logger.severe('Native connection failed for $deviceId', e, stackTrace);
      throw DeviceConnectException(
        deviceId,
        e,
        reason: bridgeErrorMessage(e),
      );
    }
  }

  @override
  Future<void> disconnectDevice(DeviceType deviceType, String deviceId) async {
    if (isPhd2WireToken(deviceId)) {
      await phd2Disconnect();
      return;
    }
    if (!bridge.NativeBridge.isNativeAvailable) return;
    // A connect is authoritative in Rust, so its disconnect must cross the
    // same boundary and a failure must surface rather than claim success.
    await bridge.apiDisconnectDevice(
      deviceType: _toBridgeDeviceType(deviceType),
      deviceId: deviceId,
    );
  }

  @override
  Future<void> rescanDevices() async {
    // Local host: drive the Rust hot-plug diff pass directly. This invalidates
    // the native discovery cache and emits device_discovered/device_lost events
    // for any deltas (see bridge/src/api/hotplug.rs::api_rescan_devices).
    await bridge.apiRescanDevices();
  }

  /// The quirk table is keyed by the model name for most vendors
  /// (`native:<vendor>:<model>`, as each driver looks its own quirks up) and
  /// by the device id for the rest, so both keys are asked.
  Future<List<DeviceQuirk>> deviceQuirks(String deviceId) async {
    // Only the native vendor drivers have entries; the table logs a warning
    // for an id it cannot key, such as a simulator's.
    final id = DeviceId.parse(deviceId);
    if (!bridge.NativeBridge.isNativeAvailable ||
        id.kind != DeviceDriverKind.native) {
      return const [];
    }
    String? name;
    for (final device in await _connectedNativeDevices()) {
      if (device.id == deviceId) name = device.name;
    }
    final keys = [
      deviceId,
      if (name != null && id.segments.isNotEmpty)
        'native:${id.segments.first}:$name',
    ];
    final seen = <String>{};
    return [
      for (final key in keys)
        for (final quirk in bridge.apiGetDeviceQuirks(deviceId: key))
          if (seen.add('${quirk.category}\n${quirk.description}'))
            DeviceQuirk(
              category: quirk.category,
              description: quirk.description,
            ),
    ];
  }

  /// The native registry's connected devices. If the read fails, the last
  /// list it returned stands in so one failed poll does not report every
  /// device as gone.
  Future<List<bridge.DeviceInfo>> _connectedNativeDevices() async {
    if (bridge.NativeBridge.isNativeAvailable) {
      try {
        return _NativeProcessState.lastConnectedDevices = await bridge
            .apiGetConnectedDevices();
      } catch (e) {
        _logger.warning('Failed to read connected devices from native: $e');
      }
    }
    return _NativeProcessState.lastConnectedDevices;
  }

  @override
  Future<List<DeviceInfo>> getConnectedDevices() async {
    final bridgeDevices = await _connectedNativeDevices();

    return bridgeDevices
        .map(
          (d) => DeviceInfo(
            id: d.id,
            name: _sanitizeDeviceText(d.name),
            deviceType: _fromBridgeDeviceType(d.deviceType),
            driverType: _fromBridgeDriverType(d.driverType),
            description: _sanitizeDeviceText(d.description),
            driverVersion: d.driverVersion,
          ),
        )
        .toList();
  }

  // Camera control

  @override
  Future<void> cameraStartExposure({
    required String deviceId,
    required double exposureTime,
    required FrameType frameType,
    int? gain,
    int? offset,
    int binX = 1,
    int binY = 1,
    int? x,
    int? y,
    int? width,
    int? height,
  }) async {
    await bridge.apiCameraStartExposureConfigured(
      deviceId: deviceId,
      durationSecs: exposureTime,
      gain: gain,
      offset: offset,
      binX: binX,
      binY: binY,
      startX: x,
      startY: y,
      width: width,
      height: height,
      frameType: frameType.name,
    );
  }

  @override
  Future<void> cameraAbortExposure(String deviceId) async {
    await _native(
      'cancelExposure',
      () => bridge.apiCameraCancelExposure(deviceId: deviceId),
    );
  }

  @override
  Future<Uint8List> cameraLiveViewFrame(String deviceId) async {
    return bridge.apiCameraCapturePreview(deviceId: deviceId);
  }

  @override
  Future<CapturedImageResult?> cameraGetLastImage(String deviceId) async {
    final bridgeImage = await bridge.apiGetLastImage(deviceId: deviceId);

    return CapturedImageResult(
      width: bridgeImage.width,
      height: bridgeImage.height,
      displayData: bridgeImage.displayData,
      histogram: bridgeImage.histogram,
      stats: ImageStatsResult(
        min: bridgeImage.stats.min,
        max: bridgeImage.stats.max,
        mean: bridgeImage.stats.mean,
        median: bridgeImage.stats.median,
        stdDev: bridgeImage.stats.stdDev,
        hfr: bridgeImage.stats.hfr,
        eccentricity: bridgeImage.stats.eccentricity,
        fwhm: bridgeImage.stats.fwhm,
        starCount: bridgeImage.stats.starCount,
      ),
      exposureTime: bridgeImage.exposureTime,
      timestamp: bridgeImage.timestamp,
      isColor: bridgeImage.isColor,
    );
  }

  @override
  Future<List<int>> getLastRawImageData(String deviceId) async {
    return await bridge.apiGetLastRawImageData(deviceId: deviceId);
  }

  @override
  Future<void> saveFitsFromLastCapture({
    required String deviceId,
    required String filePath,
    required FitsWriteHeader headerData,
  }) async {
    await bridge.apiSaveFitsFromLastCapture(
      deviceId: deviceId,
      filePath: filePath,
      headerData: _toBridgeFitsHeader(headerData),
    );
  }

  @override
  Future<void> clearDeviceImage(String deviceId) async {
    await bridge.apiClearDeviceImage(deviceId: deviceId);
  }

  @override
  Future<void> cameraSetCooling({
    required String deviceId,
    required bool enabled,
    double? targetTemp,
  }) async {
    await _native(
      'setCameraCooler',
      () => bridge.setCameraCooler(
        deviceId: deviceId,
        enabled: enabled ? 1 : 0,
        targetTemp: targetTemp,
      ),
    );
  }

  @override
  Future<void> cameraSetReadoutMode(String deviceId, int modeIndex) async {
    await _native(
      'setReadoutMode',
      () => bridge.apiCameraSetReadoutMode(
        deviceId: deviceId,
        modeIndex: modeIndex,
      ),
    );
  }

  @override
  Future<void> cameraSetGain(String deviceId, int gain) async {
    await _native(
      'setCameraGain',
      () => bridge.setCameraGain(deviceId: deviceId, gain: gain),
    );
  }

  @override
  Future<void> cameraSetOffset(String deviceId, int offset) async {
    await _native(
      'setCameraOffset',
      () => bridge.setCameraOffset(deviceId: deviceId, offset: offset),
    );
  }

  @override
  Future<bridge.CameraRecommendedSettings> cameraGetRecommendedSettings(
    String deviceId,
  ) async {
    // Direct passthrough: the Rust bridge returns an empty struct when the
    // vendor SDK doesn't expose a recommendation, so we never need to invent
    // values here. Errors propagate to the caller — silent fallbacks would
    // hide SDK failures.
    return await bridge.apiCameraGetRecommendedSettings(deviceId: deviceId);
  }
}
