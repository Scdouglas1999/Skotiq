part of '../device_handlers.dart';

extension CameraDeviceHandlers on DeviceHandlers {
  // Camera control

  /// Reject exposure parameters the camera has told us it cannot honour.
  ///
  /// Vendor SDKs clamp an out-of-range request instead of failing it, and the
  /// app then echoes the *requested* value back as the camera's live setting —
  /// gain 99999 reported on a sensor that never left 600, a subframe origin
  /// silently relocated to somewhere else on the sensor. A wrong number the
  /// operator cannot see is worse than a rejected request, so a parameter
  /// outside the advertised capabilities becomes a 400 naming the range.
  ///
  /// A failed capability read skips the guard rather than failing the request:
  /// this stops unhonourable parameters, it does not add a new way for a valid
  /// exposure to fail. Same contract as the cooling-target range check in
  /// [handleCameraSetCooling].
  Future<void> _validateExposureAgainstCapabilities({
    required DeviceBackend backend,
    required String deviceId,
    required int? gain,
    required int? offset,
    required int binX,
    required int binY,
    required int? x,
    required int? y,
    required int? width,
    required int? height,
  }) async {
    CameraCapabilities? caps;
    try {
      caps = await backend.getCameraCapabilities(deviceId);
    } catch (error) {
      _logInfo(
        'exposure range check skipped for $deviceId: '
        'capability read failed ($error)',
      );
      return;
    }
    if (caps == null) {
      // No capabilities AND not connected means the caller named a device
      // that does not exist. The exposure path flattens the driver's typed
      // `DeviceNotFound` into a plain string on its way up, so it lands in
      // the error middleware's `orElse` and becomes a 500:
      //   POST /api/camera/expose {"deviceId":"native:zwo:9"}
      //   -> 500 {"error":"internal_error",
      //           "message":"Exposure failed: Device native:zwo:9 not found"}
      // Naming a device that isn't there is a client mistake, and answering
      // 5xx also invites retry-on-5xx clients to retry something that can
      // never succeed.
      final connected = await backend.getConnectedDevices();
      if (!connected.any((device) => device.id == deviceId)) {
        throw HandlerFailure(
          code: 'device_not_found',
          message:
              'No connected camera with id "$deviceId". '
              'Use GET /api/devices/connected for the current list.',
          statusCode: HttpStatus.notFound,
          details: {'deviceId': deviceId},
        );
      }
      return;
    }

    _requireWithinRange(
      value: gain,
      min: caps.gainMin,
      max: caps.gainMax,
      field: 'gain',
      deviceId: deviceId,
    );
    _requireWithinRange(
      value: offset,
      min: caps.offsetMin,
      max: caps.offsetMax,
      field: 'offset',
      deviceId: deviceId,
    );

    // Binning. `maxBinX`/`maxBinY` are non-nullable in the model; a driver
    // that does not publish a maximum reports 0, which we treat as unknown.
    if (caps.maxBinX > 0 && binX > caps.maxBinX) {
      throw BadRequestError(
        field: 'binX',
        expected: '1 to ${caps.maxBinX}',
        message:
            'Binning $binX is outside the range 1 to ${caps.maxBinX} '
            'reported by $deviceId',
      );
    }
    if (caps.maxBinY > 0 && binY > caps.maxBinY) {
      throw BadRequestError(
        field: 'binY',
        expected: '1 to ${caps.maxBinY}',
        message:
            'Binning $binY is outside the range 1 to ${caps.maxBinY} '
            'reported by $deviceId',
      );
    }
    if (!caps.canAsymmetricBin && binX != binY) {
      throw BadRequestError(
        field: 'binY',
        expected: 'binY equal to binX ($binX)',
        message:
            '$deviceId does not support asymmetric binning; '
            'binX ($binX) and binY ($binY) must match',
      );
    }

    // Subframe. x/y/width/height are in BINNED pixels — verified on the rig:
    // a bin 2x2 request for the full binned frame (2328x1760) returns
    // exactly 2328x1760, so the usable extent is the sensor divided by the
    // bin factor.
    if (x == null || y == null || width == null || height == null) return;
    if (caps.maxWidth <= 0 || caps.maxHeight <= 0) return;
    final binnedWidth = caps.maxWidth ~/ binX;
    final binnedHeight = caps.maxHeight ~/ binY;
    if (x + width > binnedWidth || y + height > binnedHeight) {
      throw BadRequestError(
        field: 'subframe',
        expected: 'x + width <= $binnedWidth and y + height <= $binnedHeight',
        message:
            'Subframe ${width}x$height at ($x, $y) does not fit inside the '
            '${binnedWidth}x$binnedHeight frame $deviceId provides at '
            'bin ${binX}x$binY',
      );
    }
  }

  void _requireWithinRange({
    required int? value,
    required int? min,
    required int? max,
    required String field,
    required String deviceId,
  }) {
    if (value == null || min == null || max == null) return;
    if (value < min || value > max) {
      throw BadRequestError(
        field: field,
        expected: '$min to $max',
        message:
            '$field $value is outside the range $min to $max reported by '
            '$deviceId',
      );
    }
  }

  Future<Response> handleCameraExpose(Request request) async {
    _logInfo('[API] POST /api/camera/expose');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final exposureTime = requireDouble(
      payload,
      'exposureTime',
      min: 0.001,
      max: 86400,
    );
    final frameTypeStr = optionalString(payload, 'frameType') ?? 'light';
    final frameType = _parseFrameType(frameTypeStr);
    final binX = optionalInt(payload, 'binX', min: 1, max: 16) ?? 1;
    final binY = optionalInt(payload, 'binY', min: 1, max: 16) ?? 1;

    // A partial ROI is never useful: silently treating it as full-frame can
    // turn a carefully framed test exposure into a multi-megabyte download.
    // Require all four coordinates together and reject impossible dimensions
    // before registering a command or touching the camera driver.
    const subframeFields = ['x', 'y', 'width', 'height'];
    final suppliedSubframeFields = subframeFields
        .where((field) => payload[field] != null)
        .length;
    if (suppliedSubframeFields != 0 &&
        suppliedSubframeFields != subframeFields.length) {
      throw BadRequestError(
        field: 'subframe',
        expected: 'x, y, width, and height together',
        message:
            'Subframe requires x, y, width, and height; omit all four for full frame',
      );
    }
    final x = optionalInt(payload, 'x', min: 0);
    final y = optionalInt(payload, 'y', min: 0);
    final width = optionalInt(payload, 'width', min: 1);
    final height = optionalInt(payload, 'height', min: 1);
    final gain = optionalInt(payload, 'gain', min: 0);
    final offset = optionalInt(payload, 'offset', min: 0);

    final backend = container.read(deviceBackendProvider);

    // Refuse to start a second exposure on a camera that is already exposing.
    //
    // The second request reprograms ROI / binning / gain on the sensor
    // mid-exposure and destroys BOTH frames: a subframe request arriving
    // during a full-frame light fails the in-flight exposure and its own, and
    // the SDK reports only "ZWO camera reported a failed exposure" for each.
    // Two collaborating clients (the desktop UI and a phone, or the sequencer
    // and a live-view poller) would therefore silently destroy a long
    // exposure, both told only "internal error". The app already knows an
    // exposure is running, so the honest answer is 409 naming the state.
    //
    // This is a guard, not a lock: a request that arrives inside the window
    // between this read and `cameraStartExposure` can still collide. Removing
    // that last race needs a per-camera lock in the driver; this closes the
    // case that is actually reachable from two polling clients.
    try {
      final status = await backend.getCameraStatus(deviceId);
      const busyStates = {
        CameraState.exposing,
        CameraState.reading,
        CameraState.download,
      };
      if (busyStates.contains(status.state)) {
        throw HandlerFailure(
          code: 'exposure_in_progress',
          message:
              'An exposure is already in progress on $deviceId '
              '(camera is ${status.state.name}). Wait for it to finish or '
              'POST /api/camera/abort first.',
          statusCode: HttpStatus.conflict,
          details: {'deviceId': deviceId, 'state': status.state.name},
        );
      }
    } on HandlerFailure {
      rethrow;
    } catch (error) {
      // A failed status read must not block a legitimate exposure; same
      // contract as the capability guard below.
      _logInfo('busy check skipped for $deviceId: status read failed ($error)');
    }

    // Reject exposure parameters the camera cannot honour rather than
    // letting the vendor SDK silently clamp them and reporting success.
    // Runs before `beginCommand` so a rejected request never registers a
    // command id. See [_validateExposureAgainstCapabilities].
    await _validateExposureAgainstCapabilities(
      backend: backend,
      deviceId: deviceId,
      gain: gain,
      offset: offset,
      binX: binX,
      binY: binY,
      x: x,
      y: y,
      width: width,
      height: height,
    );

    // register the command BEFORE kicking off the exposure so a
    // FrameAccepted event that arrives during `await
    // backend.cameraStartExposure` (rare but possible on fast cameras) can
    // still be correlated.
    final commandId = commandCorrelator?.beginCommand(
      operation: 'camera.expose',
      deviceId: deviceId,
    );

    try {
      await backend.cameraStartExposure(
        deviceId: deviceId,
        exposureTime: exposureTime,
        frameType: frameType,
        gain: gain,
        offset: offset,
        binX: binX,
        binY: binY,
        x: x,
        y: y,
        width: width,
        height: height,
      );
    } catch (error, stackTrace) {
      final message = error.toString();
      final isBridgeCancellation =
          error is bridge_error.SkotiqError &&
          error.maybeMap(
            exposureCancelled: (_) => true,
            cancelled: (_) => true,
            operationFailed: (failure) =>
                failure.field0.trim() == 'Exposure cancelled',
            orElse: () => false,
          );
      if (isBridgeCancellation ||
          message == 'Exposure cancelled' ||
          message.endsWith(': Exposure cancelled')) {
        throw HandlerFailure(
          code: 'exposure_cancelled',
          message: 'Exposure cancelled',
          statusCode: HttpStatus.conflict,
          details: {'deviceId': deviceId},
          cause: error,
          stackTrace: stackTrace,
        );
      }
      rethrow;
    }

    // `cameraStartExposure` does NOT return at shutter-open: it completes the
    // whole expose -> read -> download -> store workflow before resolving (the
    // remote client documents this and sizes its HTTP timeout to
    // requestTimeout + exposureTime because of it). So by the time this line
    // runs the frame is finished and stored — reporting `status: "exposing"`
    // described a state that had already ended, and a client that polled
    // `/api/equipment/camera/status` on the strength of it saw `idle` and had
    // no way to tell "not started yet" from "already done".
    //
    // The blocking contract is deliberate and depended upon, so it is kept;
    // only the description is corrected. Read the terminal state back rather
    // than asserting one — if the driver ended in `error`, say `error`.
    String terminalState = CameraState.idle.name;
    try {
      terminalState = (await backend.getCameraStatus(deviceId)).state.name;
    } catch (error) {
      _logInfo(
        'terminal state read failed for $deviceId after exposure ($error)',
      );
    }
    return jsonOk({
      if (commandId != null) 'commandId': commandId,
      // `complete` = the exposure ran to completion and the frame is stored;
      // fetch it from /api/camera/last-image[/jpeg] or /api/imaging/raw-data.
      'status': 'complete',
      'state': terminalState,
    });
  }

  /// POST /api/camera/abort
  ///
  /// Implements the shared stop/abort no-op contract — see [kWasRunningField].
  /// Observed live on a real ZWO ASI1600MM-Cool with the camera idle:
  ///   POST /api/camera/abort -> 200 {"status":"aborted"}
  /// which reads as "the exposure was stopped" when there was no exposure at
  /// all. The camera state is already known here, so the response can say so.
  Future<Response> handleCameraAbort(Request request) async {
    _logInfo('[API] POST /api/camera/abort');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');

    final backend = container.read(deviceBackendProvider);

    // Issue the abort even when the state read fails. Refusing to abort
    // because the exposure state could not be confirmed would turn a failed
    // diagnostic into a failed safety action.
    var wasRunning = true;
    try {
      final status = await backend.getCameraStatus(deviceId);
      const busyStates = {
        CameraState.exposing,
        CameraState.reading,
        CameraState.download,
      };
      wasRunning = busyStates.contains(status.state);
    } catch (error) {
      _logInfo(
        'abort precondition check skipped for $deviceId: '
        'status read failed ($error)',
      );
    }

    if (!wasRunning) {
      // No command is registered: nothing was actuated, so there is no
      // device command for a later event to correlate against.
      return jsonOk({
        'status': 'aborted',
        kWasRunningField: false,
        'message':
            'No exposure was in progress on $deviceId; nothing to abort.',
      });
    }

    final commandId = commandCorrelator?.beginCommand(
      operation: 'camera.abort',
      deviceId: deviceId,
    );

    await backend.cameraAbortExposure(deviceId);

    return jsonOk({
      if (commandId != null) 'commandId': commandId,
      'status': 'aborted',
      kWasRunningField: true,
    });
  }

  /// The route that lists the frames already written to disk, named by the
  /// empty-preview answer so a client has somewhere to go.
  static const String kCapturedImageLibraryRoute = '/api/images';

  /// The body of an empty-live-preview 404, scoped to what is actually empty.
  ///
  /// `scope: process` is the machine-readable half: the buffer belongs to this
  /// server process, so a client can tell "this rig has never exposed" apart
  /// from "this rig was restarted since it did" without parsing English.
  static Map<String, Object?> _emptyPreviewBody(String deviceId) => {
    'error': 'no_live_preview',
    'scope': 'process',
    'library': kCapturedImageLibraryRoute,
    'message':
        'No live preview for $deviceId in this server process — the preview '
        'buffer holds the last exposure taken since the server started, and '
        'no exposure has run yet. Frames already captured are listed by '
        '$kCapturedImageLibraryRoute.',
  };

  /// GET /api/camera/last-image
  ///
  /// Preferred remote wire format: `?format=jpeg` or
  /// [handleCameraGetLastImageJpeg] (`/api/camera/last-image/jpeg`).
  ///
  /// The default JSON response embeds full RGBA `displayData` and is kept
  /// for backward compatibility only; new remote clients must not rely on it.
  Future<Response> handleCameraGetLastImage(Request request) async {
    final format = request.url.queryParameters['format']?.toLowerCase();
    if (format == 'jpeg' || format == 'jpg') {
      return handleCameraGetLastImageJpeg(request);
    }

    final deviceId = request.url.queryParameters['deviceId'] ?? '';
    final backend = container.read(deviceBackendProvider);
    final image = await backend.cameraGetLastImage(deviceId);

    if (image == null) {
      return jsonOk({
        'image': null,
        'legacy': true,
        'preferredFormat': 'jpeg',
        'preferredEndpoint': '/api/camera/last-image/jpeg',
      });
    }

    // JSON encodes each RGBA byte as a decimal number plus punctuation. A
    // 4656x3520 frame therefore expanded to >200 MB on the wire and pushed the
    // headless process past 1 GB while serializing one response. Keep the
    // compatibility endpoint only for genuinely small images; large sensors
    // must use the bounded binary JPEG endpoint.
    const maxLegacyDisplayBytes = 16 * 1024 * 1024;
    if (image.displayData.length > maxLegacyDisplayBytes) {
      return jsonResponse({
        'error': 'legacy_image_too_large',
        'message':
            'This image is too large for the legacy JSON representation. '
            'Request the JPEG endpoint instead.',
        'legacy': true,
        'width': image.width,
        'height': image.height,
        'displayBytes': image.displayData.length,
        'maxLegacyDisplayBytes': maxLegacyDisplayBytes,
        'preferredFormat': 'jpeg',
        'preferredEndpoint': '/api/camera/last-image/jpeg',
      }, statusCode: HttpStatus.requestEntityTooLarge);
    }

    final timestamp = capturedImageTimestampUtc(image.timestamp);
    return jsonOk({
      'legacy': true,
      'preferredFormat': 'jpeg',
      'preferredEndpoint': '/api/camera/last-image/jpeg',
      'image': {
        'width': image.width,
        'height': image.height,
        'displayData': image.displayData,
        'histogram': image.histogram,
        'stats': {
          'min': image.stats.min,
          'max': image.stats.max,
          'mean': image.stats.mean,
          'median': image.stats.median,
          'stdDev': image.stats.stdDev,
          'hfr': image.stats.hfr,
          'starCount': image.stats.starCount,
        },
        'exposureTime': image.exposureTime,
        'timestamp': timestamp,
        'isColor': image.isColor,
      },
    });
  }

  /// GET /api/camera/last-image/jpeg
  ///
  /// Returns the host-authoritative stretched display buffer as JPEG.
  /// Metadata (stats, histogram, source dimensions) travels in `x-image-meta`.
  ///
  /// **The 404 is about this server process, not about the night.** What backs
  /// this endpoint is the driver's in-memory last-frame buffer, which is empty
  /// until an exposure runs and is gone when the process restarts. Both empty
  /// answers — the null and the driver's own `noImageAvailable` — said "No
  /// image has been captured yet" / "capture an exposure first", which a client
  /// printed verbatim over a library holding a full night's frames: measured on
  /// a rig relaunched against the same database, this 404 and a gallery of 14
  /// captures from the same evening were on one screen. They now say which
  /// emptiness this is and name [kCapturedImageLibraryRoute], where the frames
  /// already on disk are listed.
  Future<Response> handleCameraGetLastImageJpeg(Request request) async {
    final query = request.url.queryParameters;
    final deviceId = (query['deviceId'] ?? '').trim();
    if (deviceId.isEmpty) {
      throw BadRequestError(
        field: 'deviceId',
        expected: 'string',
        message: "Missing 'deviceId' query parameter",
      );
    }

    // `maxWidth=0` is the internal sentinel for "original size" and remains
    // the default when omitted. A caller that supplies the parameter must send
    // a useful, bounded dimension rather than accidentally requesting an
    // unbounded allocation with a typo or negative value.
    final maxWidth =
        optionalQueryInt(query, 'maxWidth', min: 1, max: 16384) ?? 0;
    final quality = optionalQueryInt(query, 'quality', min: 1, max: 100) ?? 85;

    final backend = container.read(deviceBackendProvider);
    // A driver with nothing buffered may answer null or raise
    // `noImageAvailable`; both are the same fact and get the same sentence.
    // Only that one variant is caught — every other backend error stays on the
    // error translator's path, so "not connected" and "driver timed out" keep
    // their own status and their own words instead of being repainted as an
    // empty preview.
    CapturedImageResult? image;
    try {
      image = await backend.cameraGetLastImage(deviceId);
    } on bridge_error.SkotiqError catch (error) {
      final isEmptyBuffer = error.maybeMap(
        noImageAvailable: (_) => true,
        orElse: () => false,
      );
      if (!isEmptyBuffer) rethrow;
      image = null;
    }

    if (image == null) {
      return jsonNotFound(_emptyPreviewBody(deviceId));
    }

    final encoded = await encodeCapturedImageDisplayBufferToJpeg(
      image,
      maxWidth: maxWidth,
      quality: quality,
    );
    if (encoded == null) {
      return jsonInternalServerError({
        'error': 'bad_image_buffer',
        'message': 'Display buffer size mismatch.',
      });
    }

    final timestamp = capturedImageTimestampUtc(image.timestamp);
    return contentResponse(
      encoded.bytes,
      contentType: 'image/jpeg',
      contentLength: encoded.bytes.length,
      headers: {
        'cache-control': 'no-store, no-cache, must-revalidate',
        'x-image-width': encoded.sourceWidth.toString(),
        'x-image-height': encoded.sourceHeight.toString(),
        'x-image-encoded-width': encoded.encodedWidth.toString(),
        'x-image-encoded-height': encoded.encodedHeight.toString(),
        'x-image-meta': encoded.metaHeaderValue,
        'x-frame-timestamp': timestamp,
        'x-frame-exposure-secs': image.exposureTime.toString(),
        // The HFR and the name of the measurement travel together — see
        // [kFrameHfrBasisHeader] for why an unqualified number here misleads.
        if (image.stats.hfr != null) ...{
          'x-frame-hfr': image.stats.hfr!.toString(),
          kFrameHfrBasisHeader: kFrameHfrBasisLivePreview,
        },
        'x-frame-star-count': image.stats.starCount.toString(),
      },
    );
  }

  /// GET /api/camera/live-view/frame
  ///
  /// Returns a JPEG live-view frame from the host-native preview pipeline when
  /// the connected camera driver supports it (gPhoto2 DSLRs, Fujifilm live view).
  ///
  /// Poll this endpoint at 2–5 Hz for a simple remote viewer. For push delivery,
  /// clients may also open `GET /api/run-watch/frame-thumbnail` (last capture) or
  /// subscribe to imaging SSE events on `/api/run-watch/events`.
  ///
  /// Query params:
  ///   deviceId — required connected camera id
  Future<Response> handleCameraLiveViewFrame(Request request) async {
    final deviceId = request.url.queryParameters['deviceId']?.trim() ?? '';
    if (deviceId.isEmpty) {
      throw BadRequestError(
        field: 'deviceId',
        expected: 'string',
        message: "Missing 'deviceId' query parameter",
      );
    }

    final backend = container.read(deviceBackendProvider);
    List<DeviceInfo> connected = [];
    try {
      connected = await backend.getConnectedDevices();
    } catch (e) {
      _logInfo('live-view: getConnectedDevices failed: $e');
    }
    final isCamera = connected.any(
      (d) => d.id == deviceId && d.deviceType == DeviceType.camera,
    );
    if (!isCamera) {
      return jsonNotFound({
        'error': 'camera_not_connected',
        'message': 'Camera $deviceId is not connected.',
        'deviceId': deviceId,
      });
    }

    try {
      final jpeg = await backend.cameraLiveViewFrame(deviceId);
      if (jpeg.isEmpty) {
        return jsonServiceUnavailable({
          'error': 'live_view_unavailable',
          'message': 'Camera returned an empty live-view frame.',
          'deviceId': deviceId,
        });
      }

      return contentResponse(
        jpeg,
        contentType: 'image/jpeg',
        contentLength: jpeg.length,
        headers: {
          'cache-control': 'no-store, no-cache, must-revalidate',
          'x-live-view-source': 'native_preview',
          'x-frame-device-id': deviceId,
        },
      );
    } on bridge_error.SkotiqError catch (e) {
      final message = e.maybeMap(
        operationFailed: (v) => v.field0,
        notSupported: (v) =>
            'Live view is not supported for ${v.deviceId} (${v.operation})',
        orElse: () => 'Live view capture failed',
      );
      _logInfo('live-view unavailable for $deviceId: $message');
      return jsonServiceUnavailable({
        'error': 'live_view_unavailable',
        'message': message,
        'deviceId': deviceId,
        'hint':
            'Use GET /api/run-watch/frame-thumbnail for the last captured frame, '
            'or connect a camera with native preview support (gPhoto2 / Fujifilm).',
      });
    } catch (e) {
      _logInfo('live-view failed for $deviceId: $e');
      return jsonServiceUnavailable({
        'error': 'live_view_unavailable',
        'message': 'Failed to capture live-view frame.',
        'deviceId': deviceId,
      });
    }
  }

  Future<Response> handleCameraSetCooling(Request request) async {
    _logInfo('[API] POST /api/camera/cooling');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final enabled = requireBool(payload, 'enabled');
    final targetTemp = optionalDouble(payload, 'targetTemp');

    final backend = container.read(deviceBackendProvider);
    // Why: a physically impossible setpoint was accepted and then reported back
    // as the live target. Observed on a real ZWO ASI1600MM-Cool, whose own
    // capabilities report coolerMinTempC -40 / coolerMaxTempC 30:
    //   POST {"enabled":true,"targetTemp":-300} -> 200 {"status":"ok"}
    //   GET  /api/camera/cooling -> {"coolerOn":true,"targetTemp":-300.0,...}
    // and identically for +999. The setpoint is unreachable, so the cooler can
    // never converge: any "wait for the sensor to reach target" step waits
    // forever, and the reported target is a value the hardware will never honour.
    // Only validated when a target is actually supplied and the camera
    // advertises a range (both bounds present).
    if (targetTemp != null) {
      // A failed capability read skips the guard rather than failing the
      // request: this check was added to stop an unreachable setpoint, not to
      // add a new way for a valid cooling command to fail.
      CameraCapabilities? caps;
      try {
        caps = await backend.getCameraCapabilities(deviceId);
      } catch (error) {
        _logInfo(
          'cooling range check skipped for $deviceId: '
          'capability read failed ($error)',
        );
        caps = null;
      }
      final minTemp = caps?.coolerMinTempC;
      final maxTemp = caps?.coolerMaxTempC;
      if (minTemp != null &&
          maxTemp != null &&
          (targetTemp < minTemp || targetTemp > maxTemp)) {
        throw BadRequestError(
          field: 'targetTemp',
          expected: '$minTemp to $maxTemp',
          message:
              'Cooling target ${targetTemp}C is outside the range $minTemp to '
              '${maxTemp}C reported by $deviceId',
        );
      }
    }

    await backend.cameraSetCooling(
      deviceId: deviceId,
      enabled: enabled,
      targetTemp: targetTemp,
    );

    return jsonOk({'status': 'ok'});
  }

  /// GET /api/camera/cooling — dedicated cooling-state snapshot.
  ///
  /// Why a focused endpoint vs. polling /api/equipment/camera/status: the
  /// cooling panel only needs four fields and we don't want to round-trip the
  /// full sensor/binning/gain payload at the cooling poll cadence. Source of
  /// truth is the same CameraStatus model — we just project the cooling
  /// fields out of it.
  Future<Response> handleCameraGetCooling(Request request) async {
    final deviceId = request.url.queryParameters['deviceId'] ?? '';
    if (deviceId.isEmpty) {
      throw BadRequestError(
        field: 'deviceId',
        expected: 'string',
        message: "Missing 'deviceId' query parameter",
      );
    }
    final backend = container.read(deviceBackendProvider);
    final status = await backend.getCameraStatus(deviceId);
    return jsonOk({
      'coolerOn': status.coolerOn,
      'targetTemp': status.targetTemp,
      'sensorTemp': status.sensorTemp,
      'coolerPower': status.coolerPower,
      'canCool': status.canCool,
    });
  }

  /// GET /api/camera/readout-modes — list available readout modes.
  ///
  /// Why a focused endpoint vs. /api/equipment/camera/capabilities: the
  /// readout-mode dropdown only needs the string list, not the full
  /// capabilities payload (bayer pattern, sensor geometry, supported binning,
  /// etc.). Source of truth remains CameraCapabilities — we project the
  /// `readoutModes` field out of it.
  Future<Response> handleCameraGetReadoutModes(Request request) async {
    final deviceId = request.url.queryParameters['deviceId'] ?? '';
    if (deviceId.isEmpty) {
      throw BadRequestError(
        field: 'deviceId',
        expected: 'string',
        message: "Missing 'deviceId' query parameter",
      );
    }
    final backend = container.read(deviceBackendProvider);
    final caps = await backend.getCameraCapabilities(deviceId);
    if (caps == null) {
      return jsonNotFound({
        'error': 'Device not found or capabilities unavailable',
      });
    }
    return jsonOk({'readoutModes': caps.readoutModes});
  }

  /// GET /api/camera/recommended-settings — manufacturer-recommended
  /// gain/offset values, when the vendor SDK exposes them.
  ///
  /// Mirrors the FFI shape: the JSON body is the exact projection of
  /// [CameraRecommendedSettings] (unityGain, hcgGain, defaultOffset,
  /// recommendedCoolingSetpointC, notes). Nullable fields are emitted as JSON
  /// `null` so remote clients recover the same honest "not reported" state the
  /// FFI backend sees rather than a fabricated default.
  /// Older remote hosts won't expose this route — the network backend's
  /// fallback handles the resulting 404 by returning an empty recommendation.
  ///
  /// Errors bubble out as the standard `{code, message, ...}` envelope so
  /// network-backend callers can tell "SDK failed" from "route missing".
  Future<Response> handleCameraGetRecommendedSettings(Request request) async {
    final deviceId = request.url.queryParameters['deviceId'] ?? '';
    if (deviceId.isEmpty) {
      throw BadRequestError(
        field: 'deviceId',
        expected: 'string',
        message: "Missing 'deviceId' query parameter",
      );
    }
    final backend = container.read(deviceBackendProvider);
    final recommended = await backend.cameraGetRecommendedSettings(deviceId);
    return jsonOk({
      'unityGain': recommended.unityGain,
      'hcgGain': recommended.hcgGain,
      'defaultOffset': recommended.defaultOffset,
      'recommendedCoolingSetpointC': recommended.recommendedCoolingSetpointC,
      'notes': recommended.notes,
    });
  }

  Future<Response> handleCameraSetReadoutMode(Request request) async {
    _logInfo('[API] POST /api/camera/readoutMode');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final modeIndex = requireInt(payload, 'modeIndex', min: 0);

    final backend = container.read(deviceBackendProvider);
    await backend.cameraSetReadoutMode(deviceId, modeIndex);

    return jsonOk({'status': 'ok'});
  }

  Future<Response> handleCameraSetGain(Request request) async {
    _logInfo('[API] POST /api/camera/gain');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final gain = requireInt(payload, 'gain', min: 0);

    final backend = container.read(deviceBackendProvider);
    // Same silent-clamp problem as POST /api/camera/expose; see
    // [_validateExposureAgainstCapabilities].
    await _validateExposureAgainstCapabilities(
      backend: backend,
      deviceId: deviceId,
      gain: gain,
      offset: null,
      binX: 1,
      binY: 1,
      x: null,
      y: null,
      width: null,
      height: null,
    );
    await backend.cameraSetGain(deviceId, gain);

    return jsonOk({'status': 'ok'});
  }

  Future<Response> handleCameraSetOffset(Request request) async {
    _logInfo('[API] POST /api/camera/offset');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final offset = requireInt(payload, 'offset', min: 0);

    final backend = container.read(deviceBackendProvider);
    // Same silent-clamp problem as POST /api/camera/expose; see
    // [_validateExposureAgainstCapabilities].
    await _validateExposureAgainstCapabilities(
      backend: backend,
      deviceId: deviceId,
      gain: null,
      offset: offset,
      binX: 1,
      binY: 1,
      x: null,
      y: null,
      width: null,
      height: null,
    );
    await backend.cameraSetOffset(deviceId, offset);

    return jsonOk({'status': 'ok'});
  }

  // Mount control
}
