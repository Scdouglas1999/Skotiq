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
    final bridgeDevices = await bridge.NativeBridge.discoverDevices(bridgeType);

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
      discover: () =>
          bridge_api.apiDiscoverIndiAtAddress(host: host, port: port),
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
      discover: () =>
          bridge_api.apiDiscoverAlpacaAtAddress(host: host, port: port),
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
  Future<void> connectDevice(DeviceType deviceType, String deviceId) async {
    final bridgeType = _toBridgeDeviceType(deviceType);
    await bridge.NativeBridge.connectDevice(bridgeType, deviceId);
  }

  @override
  Future<void> disconnectDevice(DeviceType deviceType, String deviceId) async {
    final bridgeType = _toBridgeDeviceType(deviceType);
    await bridge.NativeBridge.disconnectDevice(bridgeType, deviceId);
  }

  @override
  Future<void> rescanDevices() async {
    // Local host: drive the Rust hot-plug diff pass directly. This invalidates
    // the native discovery cache and emits device_discovered/device_lost events
    // for any deltas (see bridge/src/api/hotplug.rs::api_rescan_devices).
    await bridge_api.apiRescanDevices();
  }

  @override
  Future<List<DeviceInfo>> getConnectedDevices() async {
    final bridgeDevices = await bridge.NativeBridge.getConnectedDevices();

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
    await bridge_api.apiCameraStartExposureConfigured(
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
    await bridge.NativeBridge.cancelExposure(deviceId);
  }

  @override
  Future<Uint8List> cameraLiveViewFrame(String deviceId) async {
    return bridge_api.apiCameraCapturePreview(deviceId: deviceId);
  }

  @override
  Future<CapturedImageResult?> cameraGetLastImage(String deviceId) async {
    final bridgeImage = await bridge_api.apiGetLastImage(deviceId: deviceId);

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
    return await bridge_api.apiGetLastRawImageData(deviceId: deviceId);
  }

  @override
  Future<void> saveFitsFromLastCapture({
    required String deviceId,
    required String filePath,
    required FitsWriteHeader headerData,
  }) async {
    await bridge_api.apiSaveFitsFromLastCapture(
      deviceId: deviceId,
      filePath: filePath,
      headerData: _toBridgeFitsHeader(headerData),
    );
  }

  @override
  Future<void> clearDeviceImage(String deviceId) async {
    await bridge_api.apiClearDeviceImage(deviceId: deviceId);
  }

  @override
  Future<void> cameraSetCooling({
    required String deviceId,
    required bool enabled,
    double? targetTemp,
  }) async {
    await bridge.NativeBridge.setCameraCooler(deviceId, enabled, targetTemp);
  }

  @override
  Future<void> cameraSetReadoutMode(String deviceId, int modeIndex) async {
    await bridge.NativeBridge.setReadoutMode(
      deviceId: deviceId,
      modeIndex: modeIndex,
    );
  }

  @override
  Future<void> cameraSetGain(String deviceId, int gain) async {
    await bridge.NativeBridge.setCameraGain(deviceId, gain);
  }

  @override
  Future<void> cameraSetOffset(String deviceId, int offset) async {
    await bridge.NativeBridge.setCameraOffset(deviceId, offset);
  }

  @override
  Future<bridge_caps.CameraRecommendedSettings> cameraGetRecommendedSettings(
    String deviceId,
  ) async {
    // Direct passthrough: the Rust bridge returns an empty struct when the
    // vendor SDK doesn't expose a recommendation, so we never need to invent
    // values here. Errors propagate to the caller — silent fallbacks would
    // hide SDK failures.
    return await bridge_api.apiCameraGetRecommendedSettings(deviceId: deviceId);
  }
}
