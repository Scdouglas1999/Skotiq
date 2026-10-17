part of '../bridge_stub.dart';

extension _NativeBridgeDiscoveryOperations on _NativeBridgeImplementation {
  // Device discovery

  /// Discover available devices of a specific type.
  ///
  /// This queries the native bridge, which covers every family — ASCOM
  /// drivers from the Windows registry, Alpaca devices on the network, INDI
  /// servers, native vendor SDKs and PHD2. Without the native bridge there is
  /// nothing to enumerate and the result is empty.
  ///
  /// Results are cached for 60 seconds. Call [invalidateDiscoveryCache] to
  /// force a fresh discovery. A single sweep discovers ALL device types so
  /// that concurrent callers (e.g. 5 parallel calls at startup) share one
  /// network scan instead of each launching their own.
  Future<List<DeviceInfo>> discoverDevices(DeviceType deviceType) async {
    // Fast path: return from cache if still valid for this type
    final now = DateTime.now();
    if (_discoveryCacheTime != null &&
        now.difference(_discoveryCacheTime!) < _discoveryCacheTtl &&
        _discoveryCache.containsKey(deviceType)) {
      return List.unmodifiable(_discoveryCache[deviceType]!);
    }

    // If a sweep is already running, wait for it and then return cached result
    if (_discoverySweepInProgress != null) {
      await _discoverySweepInProgress!.future;
      // After the sweep, result should be in cache
      if (_discoveryCache.containsKey(deviceType)) {
        return List.unmodifiable(_discoveryCache[deviceType]!);
      }
      // Sweep finished but didn't populate this type (shouldn't happen, but
      // return empty rather than silently looping)
      return const [];
    }

    // We are the first caller â€” run a full sweep for ALL device types
    final sweepCompleter = Completer<void>();
    _discoverySweepInProgress = sweepCompleter;

    try {
      await _runFullDiscoverySweep();
    } finally {
      _discoverySweepInProgress = null;
      sweepCompleter.complete();
    }

    return List.unmodifiable(_discoveryCache[deviceType] ?? const []);
  }

  /// Run a single discovery sweep that populates [_discoveryCache] for every
  /// [DeviceType]. This is called at most once per cache TTL window.
  Future<void> _runFullDiscoverySweep() async {
    // Prepare empty lists for every device type
    final allDevices = <DeviceType, List<DeviceInfo>>{};
    for (final dt in DeviceType.values) {
      allDevices[dt] = <DeviceInfo>[];
    }

    // 1. Native bridge discovery (includes ASCOM, native ZWO, Alpaca, etc.)
    if (_nativeAvailable) {
      // Discover all types in parallel through native bridge
      final futures = <Future<void>>[];
      for (final dt in DeviceType.values) {
        futures.add(() async {
          try {
            final genDeviceType = _toGenDeviceType(dt);
            final nativeDevices = await gen_api.apiDiscoverDevices(
              deviceType: genDeviceType,
            );

            for (final nativeDev in nativeDevices) {
              allDevices[dt]!.add(
                DeviceInfo(
                  id: nativeDev.id,
                  name: nativeDev.name,
                  deviceType: _fromGenDeviceType(nativeDev.deviceType),
                  driverType: _fromGenDriverType(nativeDev.driverType),
                  description: nativeDev.description,
                  driverVersion: nativeDev.driverVersion,
                  displayName: nativeDev.displayName,
                ),
              );
            }
          } catch (e) {
            if (!e.toString().contains('RustLib') &&
                !e.toString().contains('not initialized')) {
              developer.log(
                '[Discovery] Native discovery error for ${dt.displayName}: $e',
                name: 'NativeBridge',
                level: 900,
              );
            }
          }
        }());
      }
      await Future.wait(futures);
    }

    // Populate cache and print a single summary line
    for (final devices in allDevices.values) {
      final seenIds = <String>{};
      devices.removeWhere((device) => !seenIds.add(device.id));
    }

    _discoveryCache.clear();
    _discoveryCache.addAll(allDevices);
    _discoveryCacheTime = DateTime.now();

    // Build a compact summary of non-empty types
    final parts = <String>[];
    for (final dt in DeviceType.values) {
      final count = allDevices[dt]!.length;
      if (count > 0) {
        parts.add(
          '$count ${dt.displayName.toLowerCase()}${count == 1 ? '' : 's'}',
        );
      }
    }
    if (parts.isNotEmpty) {
      developer.log(
        '[Discovery] Complete: ${parts.join(', ')}',
        name: 'NativeBridge',
        level: 800,
      );
    } else {
      developer.log(
        '[Discovery] Complete: no devices found',
        name: 'NativeBridge',
        level: 800,
      );
    }
  }

  /// Convert local DeviceType to generated DeviceType
  gen_device.DeviceType _toGenDeviceType(DeviceType deviceType) {
    switch (deviceType) {
      case DeviceType.camera:
        return gen_device.DeviceType.camera;
      case DeviceType.mount:
        return gen_device.DeviceType.mount;
      case DeviceType.focuser:
        return gen_device.DeviceType.focuser;
      case DeviceType.filterWheel:
        return gen_device.DeviceType.filterWheel;
      case DeviceType.guider:
        return gen_device.DeviceType.guider;
      case DeviceType.dome:
        return gen_device.DeviceType.dome;
      case DeviceType.rotator:
        return gen_device.DeviceType.rotator;
      case DeviceType.weather:
        return gen_device.DeviceType.weather;
      case DeviceType.safetyMonitor:
        return gen_device.DeviceType.safetyMonitor;
      case DeviceType.switch_:
        return gen_device.DeviceType.switch_;
      case DeviceType.coverCalibrator:
        return gen_device.DeviceType.coverCalibrator;
    }
  }

  /// Convert generated DeviceType to local DeviceType
  DeviceType _fromGenDeviceType(gen_device.DeviceType deviceType) {
    switch (deviceType) {
      case gen_device.DeviceType.camera:
        return DeviceType.camera;
      case gen_device.DeviceType.mount:
        return DeviceType.mount;
      case gen_device.DeviceType.focuser:
        return DeviceType.focuser;
      case gen_device.DeviceType.filterWheel:
        return DeviceType.filterWheel;
      case gen_device.DeviceType.guider:
        return DeviceType.guider;
      case gen_device.DeviceType.dome:
        return DeviceType.dome;
      case gen_device.DeviceType.rotator:
        return DeviceType.rotator;
      case gen_device.DeviceType.weather:
        return DeviceType.weather;
      case gen_device.DeviceType.safetyMonitor:
        return DeviceType.safetyMonitor;
      case gen_device.DeviceType.switch_:
        return DeviceType.switch_;
      case gen_device.DeviceType.coverCalibrator:
        return DeviceType.coverCalibrator;
    }
  }

  /// Convert generated DriverType to local DriverType
  DriverType _fromGenDriverType(gen_device.DriverType driverType) {
    switch (driverType) {
      case gen_device.DriverType.ascom:
        return DriverType.ascom;
      case gen_device.DriverType.alpaca:
        return DriverType.alpaca;
      case gen_device.DriverType.indi:
        return DriverType.indi;
      case gen_device.DriverType.native:
        return DriverType.native;
      case gen_device.DriverType.simulator:
        return DriverType.simulator;
    }
  }
}
