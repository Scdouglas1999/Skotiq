part of '../network_backend.dart';

// Long-running device commands use the shared job transport implemented by
// _NetworkBackendRemoteOperations.

mixin _NetworkBackendDeviceOperations on _NetworkBackendTransport {
  Future<Map<String, dynamic>> awaitJobResultOrLegacy(
    Map<String, dynamic> response, {
    required String operation,
    required Duration timeout,
  });

  // Device Discovery & Connection

  // Cache for device discovery to prevent redundant API calls
  List<Map<String, dynamic>>? _cachedDevices;
  Map<DeviceType, List<DeviceInfo>>? _cachedDevicesByType;
  DateTime? _cacheTimestamp;
  static const _cacheDuration = Duration(seconds: 30);
  Future<List<Map<String, dynamic>>>? _ongoingDiscovery;

  @override
  Future<List<DeviceInfo>> discoverDevices(DeviceType deviceType) async {
    // Check if we have a valid cache
    if (_cachedDevices != null &&
        _cacheTimestamp != null &&
        DateTime.now().difference(_cacheTimestamp!) < _cacheDuration) {
      developer.log(
        '[NetworkBackend] Using cached device list (${_cachedDevices!.length} devices)',
        name: 'NetworkBackend',
        level: 800,
      );
      _cachedDevicesByType ??= _indexCachedDevicesByType(_cachedDevices!);
    } else if (_ongoingDiscovery != null) {
      // Another discovery is in progress, wait for it
      developer.log(
        '[NetworkBackend] Waiting for ongoing discovery...',
        name: 'NetworkBackend',
        level: 800,
      );
      _cachedDevices = await _ongoingDiscovery!;
      _cachedDevicesByType = _indexCachedDevicesByType(_cachedDevices!);
    } else {
      // Start new discovery
      developer.log(
        '[NetworkBackend] Starting new device discovery...',
        name: 'NetworkBackend',
        level: 800,
      );
      _ongoingDiscovery = _fetchDevicesFromServer();
      try {
        _cachedDevices = await _ongoingDiscovery!;
        _cachedDevicesByType = _indexCachedDevicesByType(_cachedDevices!);
        _cacheTimestamp = DateTime.now();
        developer.log(
          '[NetworkBackend] Cached ${_cachedDevices!.length} devices',
          name: 'NetworkBackend',
          level: 800,
        );
      } finally {
        _ongoingDiscovery = null;
      }
    }

    final filtered = List<DeviceInfo>.from(
      _cachedDevicesByType?[deviceType] ?? const <DeviceInfo>[],
    );

    developer.log(
      '[NetworkBackend] Returning ${filtered.length} ${deviceType.name} devices',
      name: 'NetworkBackend',
      level: 800,
    );
    return filtered;
  }

  Map<DeviceType, List<DeviceInfo>> _indexCachedDevicesByType(
    List<Map<String, dynamic>> devices,
  ) {
    final byType = <DeviceType, List<DeviceInfo>>{
      for (final type in DeviceType.values) type: <DeviceInfo>[],
    };

    for (var index = 0; index < devices.length; index++) {
      final device = devices[index];
      final typeValue = device['deviceType'] ?? device['type'];
      if (typeValue is! String) {
        throw FormatException(
          'GET /api/devices returned device row $index without a valid '
          '`deviceType`',
        );
      }
      final deviceType = _tryParseCachedDeviceType(typeValue);
      if (deviceType == null) {
        continue;
      }
      final id = device['id'];
      final name = device['name'];
      final driverType = device['driverType'];
      if (id is! String || id.trim().isEmpty) {
        throw FormatException(
          'GET /api/devices returned device row $index without a valid `id`',
        );
      }
      if (name is! String || name.trim().isEmpty) {
        throw FormatException(
          'GET /api/devices returned device $id without a valid `name`',
        );
      }
      if (driverType is! String || driverType.trim().isEmpty) {
        throw FormatException(
          'GET /api/devices returned device $id without a valid `driverType`',
        );
      }
      byType[deviceType]!.add(
        DeviceInfo(
          id: id,
          name: name,
          deviceType: deviceType,
          driverType: _parseDriverType(driverType),
          description: device['description'] as String? ?? '',
          driverVersion: device['driverVersion'] as String? ?? '',
        ),
      );
    }

    return byType;
  }

  DeviceType? _tryParseCachedDeviceType(String value) {
    final normalized = _normalizeDeviceType(value);
    for (final type in DeviceType.values) {
      if (_normalizeDeviceType(type.name) == normalized) {
        return type;
      }
    }
    return null;
  }

  String _normalizeDeviceType(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  Future<List<Map<String, dynamic>>> _fetchDevicesFromServer() async {
    final response = await _get('devices');
    final source = response.containsKey('devices')
        ? response['devices']
        : response['available'];
    return _rowsFromJson<Map<String, dynamic>>(source, (row) => row);
  }

  /// Invalidate device cache (called when "Scan Network" is clicked)
  @override
  void invalidateDeviceCache() {
    developer.log(
      '[NetworkBackend] Cache invalidated',
      name: 'NetworkBackend',
      level: 800,
    );
    _cachedDevices = null;
    _cachedDevicesByType = null;
    _cacheTimestamp = null;
  }

  @override
  Future<List<DeviceInfo>> discoverIndiAtAddress(String host, int port) =>
      _discoverAtAddress(
        endpoint: 'devices/discover-indi',
        host: host,
        port: port,
        fallbackDriverType: DriverType.indi,
      );

  @override
  Future<List<DeviceInfo>> discoverAlpacaAtAddress(String host, int port) =>
      _discoverAtAddress(
        endpoint: 'devices/discover-alpaca',
        host: host,
        port: port,
        fallbackDriverType: DriverType.alpaca,
      );

  /// Shared INDI / Alpaca discovery body: hits the headless API endpoint at
  /// [endpoint] with `host` + `port` query params and decodes each entry in
  /// the `devices` array into a [DeviceInfo]. [fallbackDriverType] is used
  /// only when the server omits or misspells the `driverType` field
  /// (defensive default — the server is supposed to always send it).
  Future<List<DeviceInfo>> _discoverAtAddress({
    required String endpoint,
    required String host,
    required int port,
    required DriverType fallbackDriverType,
  }) async {
    final response = await _get(endpoint, {
      'host': host,
      'port': port.toString(),
    });

    final devices = _rowsFromJson<Map<String, dynamic>>(
      response['devices'],
      (row) => row,
    );
    final results = <DeviceInfo>[];
    for (final d in devices) {
      final id = d['id'];
      final name = d['name'];
      if (id is! String || id.trim().isEmpty) {
        throw FormatException(
          'GET /api/$endpoint returned a device without a valid `id`',
        );
      }
      if (name is! String || name.trim().isEmpty) {
        throw FormatException(
          'GET /api/$endpoint returned device $id without a valid `name`',
        );
      }
      final deviceTypeName = d['deviceType'] as String?;
      // Server-side schema drift would otherwise silently turn an unknown
      // device class into a Camera and the equipment screen would claim a
      // focuser is one. Unknown classes are skipped and logged instead.
      final deviceType = DeviceType.values
          .where((t) => t.name == deviceTypeName)
          .firstOrNull;
      if (deviceType == null) {
        developer.log(
          'discoverAtAddress: dropping device id="$id" name="$name" '
          'with unknown deviceType="$deviceTypeName" from $endpoint',
          name: 'NetworkBackend',
          level: 900, // warning
        );
        continue;
      }
      final driverTypeName = d['driverType'] as String?;
      // Driver type is more tolerant: unknown driver-type means the
      // remote server is a newer version; fall back to the caller's
      // hint (`fallbackDriverType`) which encodes whether this came
      // from the INDI or Alpaca discovery endpoint.
      final driverType =
          DriverType.values
              .where((t) => t.name == driverTypeName)
              .firstOrNull ??
          fallbackDriverType;
      if (driverTypeName != null && driverTypeName != driverType.name) {
        developer.log(
          'discoverAtAddress: device id="$id" reported unknown driverType='
          '"$driverTypeName"; using fallback ${fallbackDriverType.name}',
          name: 'NetworkBackend',
          level: 900,
        );
      }
      results.add(
        DeviceInfo(
          id: id,
          name: name,
          deviceType: deviceType,
          driverType: driverType,
          description: d['description'] as String? ?? '',
          driverVersion: d['driverVersion'] as String? ?? '',
        ),
      );
    }
    return results;
  }

  @override
  Future<void> connectDevice(DeviceType deviceType, String deviceId) {
    return _dedupedConnectOp(deviceType, deviceId, 'devices/connect');
  }

  @override
  Future<void> disconnectDevice(DeviceType deviceType, String deviceId) {
    return _dedupedConnectOp(deviceType, deviceId, 'devices/disconnect');
  }

  /// Shared connect/disconnect dispatch with in-flight dedupe and NO retry.
  ///
  /// Dedupe: if the SAME operation (connect, or disconnect) for the same
  /// `<type>:<id>` is already pending, returns the existing future rather than
  /// firing a second POST — this kills the double-dispatch that piled up on the
  /// host's serial mount. The endpoint is part of the key so a disconnect is
  /// never collapsed into an in-flight connect (or vice versa) and silently
  /// dropped.
  ///
  /// Non-retry: connect/disconnect go through `_post(..., maxAttempts: 1)` so a
  /// slow/timed-out connect is NEVER auto-resent. A slave-side timeout on a
  /// connect that is actually succeeding must be a no-op on the host (which is
  /// now idempotent), not a duplicate POST. GET retries are unaffected.
  Future<void> _dedupedConnectOp(
    DeviceType deviceType,
    String deviceId,
    String endpoint,
  ) {
    final key = '$endpoint|${deviceType.name}:$deviceId';
    final existing = _inFlightConnectOps[key];
    if (existing != null) {
      developer.log(
        '[NetworkBackend] $endpoint already in flight for $key; '
        'reusing pending request',
        name: 'NetworkBackend',
        level: 800,
      );
      return existing;
    }
    final future = () async {
      await _post(
        endpoint,
        {'deviceType': deviceType.name, 'deviceId': deviceId},
        null,
        1,
      );
    }();
    _inFlightConnectOps[key] = future;
    return future.whenComplete(() {
      // Only clear if it's still OUR future (a later op replaced it otherwise).
      if (identical(_inFlightConnectOps[key], future)) {
        _inFlightConnectOps.remove(key);
      }
    });
  }

  @override
  Future<void> rescanDevices() async {
    // Remote client: ask the HOST to re-enumerate its hardware buses. The host
    // handler runs the same Rust hot-plug diff the local path does. After the
    // host rescans we drop our 30s device cache so the next discoverDevices()
    // call re-fetches the fresh host-side list (mirrors invalidateDeviceCache()
    // on "Scan Network"). Errors propagate so the UI shows a real failure
    // instead of a fake "rescan complete" toast.
    await _post('devices/rescan');
    invalidateDeviceCache();
  }

  @override
  Future<List<DeviceInfo>> getConnectedDevices() async {
    final response = await _get('devices/connected');
    return _rowsFromJson(response['devices'], DeviceInfo.fromJson);
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
    // Non-idempotent: starting an exposure actuates the camera. A transient
    // transport retry after a timeout could launch a SECOND exposure on a host
    // that already received and began the first, so this POST is pinned to a
    // single attempt (no auto-retry), mirroring connect/disconnect. The user
    // (or sequencer) re-issues if it genuinely failed.
    await _post(
      'camera/expose',
      {
        'deviceId': deviceId,
        'exposureTime': exposureTime,
        'frameType': frameType.name,
        if (gain != null) 'gain': gain,
        if (offset != null) 'offset': offset,
        'binX': binX,
        'binY': binY,
        if (x != null) 'x': x,
        if (y != null) 'y': y,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
      },
      null,
      1,
      // The host endpoint intentionally completes the entire exposure,
      // download, and processing workflow before responding. Add the requested
      // exposure duration to the transport's normal LAN/tailnet allowance so
      // legitimate long subs do not time out and appear failed remotely.
      Duration(
        milliseconds:
            requestTimeout.inMilliseconds + (exposureTime * 1000).ceil(),
      ),
    );
  }

  @override
  Future<void> cameraAbortExposure(String deviceId) async {
    await _post('camera/abort', {'deviceId': deviceId});
  }

  @override
  Future<Uint8List> cameraLiveViewFrame(String deviceId) async {
    try {
      return await _downloadBytes('camera/live-view/frame', {
        'deviceId': deviceId,
      });
    } on ServerError catch (e) {
      // Error parsing: prefer the machine-readable `code` over
      // the substring-match on `message`. The server emits
      // `live_view_unavailable` when the driver doesn't support live
      // view, and the underlying 503 is surfaced via httpStatus.
      if (e.code == 'live_view_unavailable' ||
          e.code == 'not_supported' ||
          e.httpStatus == 503) {
        throw dart_error.SkotiqError(
          category: dart_error.BackendErrorCategory.validation,
          message: e.message,
        );
      }
      rethrow;
    } on dart_error.SkotiqError catch (e) {
      final msg = e.message.toLowerCase();
      if (msg.contains('503') ||
          msg.contains('live_view_unavailable') ||
          msg.contains('not supported')) {
        throw dart_error.SkotiqError(
          category: dart_error.BackendErrorCategory.validation,
          message: e.message,
        );
      }
      rethrow;
    }
  }

  @override
  Future<CapturedImageResult?> cameraGetLastImage(String deviceId) async {
    try {
      final downloaded = await _downloadBytesWithHeaders(
        'camera/last-image/jpeg',
        {'deviceId': deviceId},
      );
      final metaHeader = _headerValue(downloaded.headers, 'x-image-meta');
      if (metaHeader == null || metaHeader.isEmpty) {
        throw const dart_error.SkotiqError(
          category: dart_error.BackendErrorCategory.validation,
          message:
              'GET /api/camera/last-image/jpeg missing x-image-meta header',
        );
      }
      return capturedImageFromRemoteJpegWire(
        jpegBytes: downloaded.bytes,
        metaHeaderBase64: metaHeader,
      );
    } on ServerError catch (e) {
      // Error parsing: treat 404 or the explicit `no_image`
      // envelope code as "no image cached yet" and return null instead
      // of bubbling an exception. Anything else is a real failure.
      if (e.httpStatus == 404 || e.code == 'no_image') {
        return null;
      }
      rethrow;
    } on dart_error.SkotiqError catch (e) {
      final msg = e.message.toLowerCase();
      if (msg.contains('404') || msg.contains('no_image')) {
        return null;
      }
      rethrow;
    }
  }

  String? _headerValue(Map<String, String> headers, String name) {
    final lower = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == lower) {
        return entry.value;
      }
    }
    return null;
  }

  @override
  Future<void> cameraSetCooling({
    required String deviceId,
    required bool enabled,
    double? targetTemp,
  }) async {
    await _post('camera/cooling', {
      'deviceId': deviceId,
      'enabled': enabled,
      if (targetTemp != null) 'targetTemp': targetTemp,
    });
  }

  @override
  Future<void> cameraSetReadoutMode(String deviceId, int modeIndex) async {
    await _post('camera/readoutMode', {
      'deviceId': deviceId,
      'modeIndex': modeIndex,
    });
  }

  @override
  Future<void> cameraSetGain(String deviceId, int gain) async {
    await _post('camera/gain', {'deviceId': deviceId, 'gain': gain});
  }

  @override
  Future<void> cameraSetOffset(String deviceId, int offset) async {
    await _post('camera/offset', {'deviceId': deviceId, 'offset': offset});
  }

  @override
  Future<CameraRecommendedSettings> cameraGetRecommendedSettings(
    String deviceId,
  ) async {
    // Network backend: the remote host owns the SDK. Query it via the
    // headless API, parsing the same struct shape Rust returns.
    //
    // Fallback policy:
    //   * HTTP 404 / `not_implemented` code → host predates this route. Return
    //     an empty recommendation, logged; the user can still set values
    //     manually from the profile editor.
    //   * Anything else (timeout, malformed JSON, 5xx, transport failure)
    //     rethrows, so the UI shows a real error rather than pretending the
    //     device has no recommendation.
    try {
      final response = await _get('camera/recommended-settings', {
        'deviceId': deviceId,
      });
      return CameraRecommendedSettings(
        unityGain: (response['unityGain'] as num?)?.toInt(),
        hcgGain: (response['hcgGain'] as num?)?.toInt(),
        defaultOffset: (response['defaultOffset'] as num?)?.toInt(),
        // `num?.toDouble()` widens an integer JSON value (e.g. `-10`) to the
        // double the FFI backend reports, and older hosts that omit the field
        // decode as `null` — preserving the honest "not reported" state.
        recommendedCoolingSetpointC:
            (response['recommendedCoolingSetpointC'] as num?)?.toDouble(),
        notes: (response['notes'] as String?) ?? '',
      );
    } on ServerError catch (e) {
      if (e.httpStatus == 404 || e.code == 'not_implemented') {
        developer.log(
          'cameraGetRecommendedSettings not implemented on remote '
          '(${e.code}, HTTP ${e.httpStatus}); returning empty recommendation',
          name: 'NetworkBackend',
          level: 900, // WARNING
        );
        return const CameraRecommendedSettings(notes: '');
      }
      rethrow;
    } on dart_error.SkotiqError catch (e) {
      // `_parseErrorResponse` falls back to a `SkotiqError` with
      // `BackendErrorCategory.connection` for HTTP 404 when the body
      // isn't a recognized error envelope. Treat that specific shape as
      // "route missing" too — any other category propagates.
      if (e.category == dart_error.BackendErrorCategory.connection &&
          e.message.contains('HTTP 404')) {
        developer.log(
          'cameraGetRecommendedSettings route 404 on remote '
          '(${e.message}); returning empty recommendation',
          name: 'NetworkBackend',
          level: 900, // WARNING
        );
        return const CameraRecommendedSettings(notes: '');
      }
      rethrow;
    }
  }

  // Mount control

  @override
  Future<void> mountSlewToCoordinates(
    String deviceId,
    double ra,
    double dec,
  ) async {
    await _post('mount/slew', {'deviceId': deviceId, 'ra': ra, 'dec': dec});
  }

  @override
  Future<void> mountSync(String deviceId, double ra, double dec) async {
    await _post('mount/sync', {'deviceId': deviceId, 'ra': ra, 'dec': dec});
  }

  @override
  Future<void> mountPark(String deviceId) async {
    await _post('mount/park', {'deviceId': deviceId});
  }

  @override
  Future<void> mountUnpark(String deviceId) async {
    await _post('mount/unpark', {'deviceId': deviceId});
  }

  @override
  Future<void> mountSetTracking(String deviceId, bool enabled) async {
    await _post('mount/tracking', {'deviceId': deviceId, 'enabled': enabled});
  }

  @override
  Future<void> mountPulseGuide({
    required String deviceId,
    required String direction,
    required int durationMs,
  }) async {
    // A guide pulse is relative, time-based actuation. If the host applies it
    // but the response times out, retrying would apply a second correction and
    // can turn a small guide error into a large one. Keep this at-most-once,
    // matching move-axis and other non-idempotent hardware commands.
    await _post(
      'mount/pulse-guide',
      {'deviceId': deviceId, 'direction': direction, 'durationMs': durationMs},
      null,
      1,
    );
  }

  @override
  Future<void> mountAbort(String deviceId) async {
    await _post('mount/abort', {'deviceId': deviceId});
  }

  @override
  Future<dynamic> mountGetStatus(String deviceId) async {
    return await _get('mount/status', {'deviceId': deviceId});
  }

  @override
  Future<void> mountSetTrackingRate(String deviceId, int rate) async {
    await _post('mount/set-tracking-rate', {
      'deviceId': deviceId,
      'rate': rate,
    });
  }

  @override
  Future<void> mountMoveAxis(String deviceId, int axis, double rate) async {
    // Non-idempotent relative actuation: a duplicate move-axis after a
    // transient-timeout retry can leave the axis slewing at a rate the operator
    // already cancelled (or double-applied), so this POST is pinned to a single
    // attempt with no auto-retry, mirroring connect/disconnect.
    await _post(
      'mount/move-axis',
      {'deviceId': deviceId, 'axis': axis, 'rate': rate},
      null,
      1,
    );
  }

  @override
  Future<void> mountSlewAltAz(
    String deviceId,
    double altitude,
    double azimuth,
  ) async {
    await _post('mount/slew-alt-az', {
      'deviceId': deviceId,
      'altitude': altitude,
      'azimuth': azimuth,
    });
  }

  @override
  Future<void> mountFindHome(String deviceId) async {
    await _post('mount/find-home', {'deviceId': deviceId});
  }

  @override
  Future<MountSiteCapabilities> mountSiteCapabilities(String deviceId) async {
    final json = await _get('mount/site-capabilities', {'deviceId': deviceId});
    return MountSiteCapabilities(
      canReadSite: json['canReadSite'] as bool? ?? false,
      canWriteSite: json['canWriteSite'] as bool? ?? false,
      canReadTime: json['canReadTime'] as bool? ?? false,
      canWriteTime: json['canWriteTime'] as bool? ?? false,
    );
  }

  @override
  Future<MountSite> mountGetSite(String deviceId) async {
    final json = await _get('mount/site', {'deviceId': deviceId});
    return MountSite(
      latitudeDeg: (json['latitudeDeg'] as num).toDouble(),
      longitudeDeg: (json['longitudeDeg'] as num).toDouble(),
      elevationM: (json['elevationM'] as num?)?.toDouble(),
    );
  }

  @override
  Future<void> mountSetSite(
    String deviceId,
    double latitudeDeg,
    double longitudeDeg,
    double? elevationM,
  ) async {
    await _post('mount/site', {
      'deviceId': deviceId,
      'latitudeDeg': latitudeDeg,
      'longitudeDeg': longitudeDeg,
      if (elevationM != null) 'elevationM': elevationM,
    });
  }

  @override
  Future<MountTimeInfo> mountGetTime(String deviceId) async {
    final json = await _get('mount/time', {'deviceId': deviceId});
    return MountTimeInfo(
      utcUnixSeconds: (json['utcUnixSeconds'] as num).toInt(),
      utcOffsetHours: (json['utcOffsetHours'] as num).toDouble(),
    );
  }

  @override
  Future<void> mountSetTime(
    String deviceId,
    int utcUnixSeconds,
    double utcOffsetHours,
  ) async {
    await _post('mount/time', {
      'deviceId': deviceId,
      'utcUnixSeconds': utcUnixSeconds,
      'utcOffsetHours': utcOffsetHours,
    });
  }

  // Focuser control

  @override
  Future<void> focuserMoveTo(String deviceId, int position) async {
    await _post('focuser/move-to', {
      'deviceId': deviceId,
      'position': position,
    });
  }

  @override
  Future<void> focuserMoveRelative(String deviceId, int delta) async {
    // Non-idempotent: `delta` is applied relative to the current position, so a
    // retried POST after a transient timeout would move the focuser by 2*delta.
    // Pinned to a single attempt (no auto-retry), mirroring connect/disconnect.
    // The absolute `focuser/move-to` above is idempotent and keeps retries.
    await _post(
      'focuser/move-relative',
      {'deviceId': deviceId, 'delta': delta},
      null,
      1,
    );
  }

  @override
  Future<void> focuserHalt(String deviceId) async {
    await _post('focuser/halt', {'deviceId': deviceId});
  }

  @override
  Future<AutofocusResult> autofocusStart({
    required String deviceId,
    required String cameraId,
    required double exposureTime,
    required int stepSize,
    required int stepsOut,
    String method = 'VCurve',
    int binning = 1,
    int? gain,
    int? offset,
    String curveFitting = 'Hyperbolic',
    int numberOfAttempts = 1,
    int exposuresPerPoint = 1,
    double rSquaredThreshold = 0.7,
    double outerCropRatio = 1.0,
    double innerCropRatio = 0.0,
    int useBrightestNStars = 10,
    int focuserSettleTimeMs = 500,
    String backlashCompMethod = 'Overshoot',
    int backlashIn = 350,
    int backlashOut = 0,
    int? measuredBacklashIn,
  }) async {
    final start = await _post('focuser/autofocus/start', {
      'deviceId': deviceId,
      'cameraId': cameraId,
      'exposureTime': exposureTime,
      'stepSize': stepSize,
      'stepsOut': stepsOut,
      'method': method,
      'binning': binning,
      if (gain != null) 'gain': gain,
      if (offset != null) 'offset': offset,
      'curveFitting': curveFitting,
      'numberOfAttempts': numberOfAttempts,
      'exposuresPerPoint': exposuresPerPoint,
      'rSquaredThreshold': rSquaredThreshold,
      'outerCropRatio': outerCropRatio,
      'innerCropRatio': innerCropRatio,
      'useBrightestNStars': useBrightestNStars,
      'focuserSettleTimeMs': focuserSettleTimeMs,
      'backlashCompMethod': backlashCompMethod,
      'backlashIn': backlashIn,
      'backlashOut': backlashOut,
      if (measuredBacklashIn != null) 'measuredBacklashIn': measuredBacklashIn,
    });
    final response = await awaitJobResultOrLegacy(
      start,
      operation: 'autofocus',
      timeout: const Duration(minutes: 30),
    );

    // Parse using pure Dart types from JSON
    return AutofocusResult.fromJson(response);
  }

  @override
  Future<String> focuserBacklashCalibrationStart({
    required String deviceId,
    required String cameraId,
    required String configJson,
  }) async {
    final start = await _post('focuser/backlash-calibration/start', {
      'deviceId': deviceId,
      'cameraId': cameraId,
      'config': configJson,
    });
    final response = await awaitJobResultOrLegacy(
      start,
      operation: 'focuser backlash calibration',
      timeout: _backlashCalibrationTimeout,
    );
    final outcome = response['outcome'];
    if (outcome is! Map) {
      throw StateError(
        'The host finished the backlash calibration but returned no outcome',
      );
    }
    return jsonEncode(outcome);
  }

  @override
  Future<void> focuserBacklashCalibrationCancel() async {
    await _post('focuser/backlash-calibration/cancel', const {});
  }

  @override
  Future<String> focuserBacklashCalibrationPlan({
    required String configJson,
    required int centerPosition,
  }) async {
    final response = await _post('focuser/backlash-calibration/plan', {
      'config': configJson,
      'centerPosition': centerPosition,
    });
    final plan = response['plan'];
    if (plan is! Map) {
      throw StateError('The host returned no backlash calibration plan');
    }
    return jsonEncode(plan);
  }

  /// Both scans plus focuser travel; native caps its own run at 20 minutes, so
  /// the client waits a little longer than that rather than abandoning a run
  /// that is still going.
  static const Duration _backlashCalibrationTimeout = Duration(minutes: 25);

  @override
  Future<void> autofocusCancel() async {
    await _post('focuser/autofocus/cancel');
  }

  // Filter wheel control

  @override
  Future<void> filterWheelSetPosition(String deviceId, int position) async {
    await _post('filter-wheel/position', {
      'deviceId': deviceId,
      'position': position,
    });
  }

  @override
  Future<List<String>> filterWheelGetNames(String deviceId) async {
    final response = await _get('filter-wheel/names', {'deviceId': deviceId});
    return (response['names'] as List).cast<String>();
  }

  @override
  Future<void> filterWheelSetNames(String deviceId, List<String> names) async {
    await _post('filter-wheel/names', {'deviceId': deviceId, 'names': names});
  }

  @override
  Future<void> filterWheelSetByName(String deviceId, String name) async {
    await _post('filter-wheel/set-by-name', {
      'deviceId': deviceId,
      'name': name,
    });
  }

  /// Fetch the current filter-wheel slot, slot name, and
  /// in-motion flag from the headless server. Not on
  /// [SkotiqBackend] because the local FfiBackend already exposes
  /// the same data via `filterWheelStateProvider`; the network surface
  /// is the only one that needs an explicit GET.
  Future<RemoteFilterWheelPosition> getFilterWheelPosition() async {
    final response = await _get('filter-wheel/position');
    return RemoteFilterWheelPosition.fromJson(response);
  }

  // Rotator control

  @override
  Future<void> rotatorMoveTo(String deviceId, double angle) async {
    await _post('rotator/move-to', {'deviceId': deviceId, 'angle': angle});
  }

  @override
  Future<void> rotatorMoveRelative(String deviceId, double delta) async {
    // Non-idempotent: `delta` is applied relative to the current angle, so a
    // retried POST after a transient timeout would rotate by 2*delta. Pinned to
    // a single attempt (no auto-retry), mirroring connect/disconnect. The
    // absolute `rotator/move-to` above is idempotent and keeps retries.
    await _post(
      'rotator/move-relative',
      {'deviceId': deviceId, 'delta': delta},
      null,
      1,
    );
  }

  @override
  Future<double> rotatorGetAngle(String deviceId) async {
    final response = await _get('rotator/status', {'deviceId': deviceId});
    return (response['position'] as num).toDouble();
  }

  @override
  Future<void> rotatorHalt(String deviceId) async {
    await _post('rotator/halt', {'deviceId': deviceId});
  }

  @override
  Future<void> rotatorSetReverse(String deviceId, bool reverse) async {
    await _post('rotator/set-reverse', {
      'deviceId': deviceId,
      'reverse': reverse,
    });
  }

  @override
  Future<void> rotatorSyncToPa(String deviceId, double pa) async {
    await _post('rotator/sync', {'deviceId': deviceId, 'positionAngle': pa});
  }
}
