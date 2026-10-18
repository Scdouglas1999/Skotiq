part of '../device_handlers.dart';

extension MountDeviceHandlers on DeviceHandlers {
  Future<Response> handleMountSlew(Request request) async {
    _logInfo('[API] POST /api/mount/slew');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final ra = requireDouble(payload, 'ra', min: 0, max: 24);
    final dec = requireDouble(payload, 'dec', min: -90, max: 90);

    final commandId = commandCorrelator?.beginCommand(
      operation: 'mount.slew',
      deviceId: deviceId,
    );

    final backend = container.read(deviceBackendProvider);
    await backend.mountSlewToCoordinates(deviceId, ra, dec);

    return jsonOk({
      if (commandId != null) 'commandId': commandId,
      'status': 'slewing',
    });
  }

  Future<Response> handleMountSync(Request request) async {
    _logInfo('[API] POST /api/mount/sync');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final ra = requireDouble(payload, 'ra', min: 0, max: 24);
    final dec = requireDouble(payload, 'dec', min: -90, max: 90);

    final backend = container.read(deviceBackendProvider);
    await backend.mountSync(deviceId, ra, dec);

    return jsonOk({'status': 'synced'});
  }

  Future<Response> handleMountPark(Request request) async {
    _logInfo('[API] POST /api/mount/park');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');

    final commandId = commandCorrelator?.beginCommand(
      operation: 'mount.park',
      deviceId: deviceId,
    );

    final backend = container.read(deviceBackendProvider);
    await backend.mountPark(deviceId);

    return jsonOk({
      if (commandId != null) 'commandId': commandId,
      'status': 'parking',
    });
  }

  Future<Response> handleMountUnpark(Request request) async {
    _logInfo('[API] POST /api/mount/unpark');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');

    final commandId = commandCorrelator?.beginCommand(
      operation: 'mount.unpark',
      deviceId: deviceId,
    );

    final backend = container.read(deviceBackendProvider);
    await backend.mountUnpark(deviceId);

    return jsonOk({
      if (commandId != null) 'commandId': commandId,
      'status': 'unparked',
    });
  }

  Future<Response> handleMountSetTracking(Request request) async {
    _logInfo('[API] POST /api/mount/tracking');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final enabled = requireBool(payload, 'enabled');

    final backend = container.read(deviceBackendProvider);
    await backend.mountSetTracking(deviceId, enabled);

    return jsonOk({'status': 'ok'});
  }

  Future<Response> handleMountPulseGuide(Request request) async {
    _logInfo('[API] POST /api/mount/pulse-guide');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final direction = requireString(payload, 'direction');
    if (!const {
      'north',
      'south',
      'east',
      'west',
    }.contains(direction.toLowerCase())) {
      throw BadRequestError(
        field: 'direction',
        expected: 'north|south|east|west',
        message: 'direction must be north, south, east, or west',
      );
    }
    final durationMs = requireInt(payload, 'durationMs', min: 1);

    final backend = container.read(deviceBackendProvider);
    await backend.mountPulseGuide(
      deviceId: deviceId,
      direction: direction,
      durationMs: durationMs,
    );

    return jsonOk({'status': 'ok'});
  }

  Future<Response> handleMountAbort(Request request) async {
    _logInfo('[API] POST /api/mount/abort');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');

    final backend = container.read(deviceBackendProvider);
    await backend.mountAbort(deviceId);

    return jsonOk({'status': 'aborted'});
  }

  /// GET `/api/mount/site-capabilities` — which directions this driver can
  /// honour, so a remote client can grey out what will not work rather than
  /// offering it and reporting a failure afterwards.
  Future<Response> handleMountSiteCapabilities(Request request) async {
    _logInfo('[API] GET /api/mount/site-capabilities');
    final backend = container.read(deviceBackendProvider);
    final deviceId = _requireQueryDeviceId(request);
    final caps = await backend.mountSiteCapabilities(deviceId);
    return jsonOk({
      'canReadSite': caps.canReadSite,
      'canWriteSite': caps.canWriteSite,
      'canReadTime': caps.canReadTime,
      'canWriteTime': caps.canWriteTime,
    });
  }

  /// GET `/api/mount/site` — the site the mount itself holds. Longitude is
  /// EAST-positive, matching every other coordinate this API carries.
  Future<Response> handleMountGetSite(Request request) async {
    _logInfo('[API] GET /api/mount/site');
    final backend = container.read(deviceBackendProvider);
    final deviceId = _requireQueryDeviceId(request);
    final site = await backend.mountGetSite(deviceId);
    return jsonOk({
      'latitudeDeg': site.latitudeDeg,
      'longitudeDeg': site.longitudeDeg,
      'elevationM': site.elevationM,
    });
  }

  /// POST `/api/mount/site` — write a site into the mount.
  Future<Response> handleMountSetSite(Request request) async {
    _logInfo('[API] POST /api/mount/site');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final latitudeDeg = requireDouble(
      payload,
      'latitudeDeg',
      min: -90,
      max: 90,
    );
    final longitudeDeg = requireDouble(
      payload,
      'longitudeDeg',
      min: -180,
      max: 180,
    );
    final elevationM = optionalDouble(
      payload,
      'elevationM',
      min: -500,
      max: 9000,
    );

    final backend = container.read(deviceBackendProvider);
    await backend.mountSetSite(deviceId, latitudeDeg, longitudeDeg, elevationM);
    return jsonOk({'status': 'ok'});
  }

  /// GET `/api/mount/time` — the mount's own clock.
  Future<Response> handleMountGetTime(Request request) async {
    _logInfo('[API] GET /api/mount/time');
    final backend = container.read(deviceBackendProvider);
    final deviceId = _requireQueryDeviceId(request);
    final time = await backend.mountGetTime(deviceId);
    return jsonOk({
      'utcUnixSeconds': time.utcUnixSeconds,
      'utcOffsetHours': time.utcOffsetHours,
    });
  }

  /// POST `/api/mount/time` — write a clock into the mount. `utcOffsetHours`
  /// is east of UTC in the ordinary sense: US Eastern Standard is -5.
  Future<Response> handleMountSetTime(Request request) async {
    _logInfo('[API] POST /api/mount/time');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final utcUnixSeconds = requireInt(payload, 'utcUnixSeconds');
    final utcOffsetHours = requireDouble(
      payload,
      'utcOffsetHours',
      min: -14,
      max: 14,
    );

    final backend = container.read(deviceBackendProvider);
    await backend.mountSetTime(deviceId, utcUnixSeconds, utcOffsetHours);
    return jsonOk({'status': 'ok'});
  }

  /// The `deviceId` query parameter, or a 400 naming it.
  String _requireQueryDeviceId(Request request) {
    final deviceId = (request.url.queryParameters['deviceId'] ?? '').trim();
    if (deviceId.isEmpty) {
      throw BadRequestError(
        field: 'deviceId',
        expected: 'string',
        message: "Missing 'deviceId' query parameter",
      );
    }
    return deviceId;
  }

  Future<Response> handleMountGetStatus(Request request) async {
    final backend = container.read(deviceBackendProvider);

    // Resolve the target mount. When the caller omits `deviceId` (the common
    // case for a tablet that just wants "the" mount), fall back to the single
    // connected mount instead of passing an empty id straight to the backend,
    // which the backend answers with an opaque 500 ("Device not found:"). Only
    // when no mount is connected do we surface a clean 400.
    var deviceId = request.url.queryParameters['deviceId'] ?? '';
    if (deviceId.isEmpty) {
      final connected = await backend.getConnectedDevices();
      final mounts = connected
          .where((d) => d.deviceType == DeviceType.mount)
          .toList();
      if (mounts.isEmpty) {
        throw BadRequestError(
          field: 'deviceId',
          expected: 'string',
          message:
              'deviceId query parameter is required (no mount is connected)',
        );
      }
      deviceId = mounts.first.id;
    }

    // Use getMountStatus (returns the domain MountStatus with a real toJson())
    // rather than mountGetStatus (returns the raw flutter_rust_bridge object,
    // which has no toJson and so makes jsonEncode throw -> internal_error for
    // every remote client). Both route through the same native apiGetMountStatus
    // under the hood, so simulator and real mounts are handled identically.
    final status = await backend.getMountStatus(deviceId);

    return jsonOk(status.toJson());
  }

  Future<Response> handleMountSetTrackingRate(Request request) async {
    _logInfo('[API] POST /api/mount/set-tracking-rate');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final rate = requireInt(payload, 'rate', min: 0, max: 3);

    final backend = container.read(deviceBackendProvider);
    await backend.mountSetTrackingRate(deviceId, rate);

    return jsonOk({'status': 'ok'});
  }

  Future<Response> handleMountMoveAxis(Request request) async {
    _logInfo('[API] POST /api/mount/move-axis');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final axis = requireInt(payload, 'axis', min: 0, max: 1);
    final rate = requireDouble(payload, 'rate');

    final backend = container.read(deviceBackendProvider);
    await backend.mountMoveAxis(deviceId, axis, rate);

    return jsonOk({'status': 'ok'});
  }

  Future<Response> handleMountSlewAltAz(Request request) async {
    _logInfo('[API] POST /api/mount/slew-alt-az');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final altitude = requireDouble(payload, 'altitude', min: -90, max: 90);
    final azimuth = requireDouble(payload, 'azimuth', min: 0, max: 360);

    final commandId = commandCorrelator?.beginCommand(
      operation: 'mount.slew-alt-az',
      deviceId: deviceId,
    );

    final backend = container.read(deviceBackendProvider);
    await backend.mountSlewAltAz(deviceId, altitude, azimuth);

    return jsonOk({
      if (commandId != null) 'commandId': commandId,
      'status': 'slewing',
    });
  }

  /// POST `/api/mount/home` (and its older spelling `/api/mount/find-home`).
  ///
  /// Sends the mount to its home position. Homing is not parking: the mount
  /// is left unparked and commandable. Answers once the driver has accepted
  /// the command (`status: homing`); progress and arrival come from
  /// `GET /api/mount/status` (`slewing`, `atHome`, and
  /// `availability.at_home`, which says whether the driver can report
  /// arrival at all).
  ///
  /// * 400 `capability_unsupported` — the mount has no home position.
  /// * 409 `mount_parked` — the mount is parked; it is NOT unparked here,
  ///   the client unparks it first.
  Future<Response> handleMountHome(Request request) async {
    _logInfo('[API] POST /${request.url.path}');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');

    final backend = container.read(deviceBackendProvider);
    final capabilities = await backend.getMountCapabilities(deviceId);
    if (capabilities == null) {
      throw HandlerFailure(
        code: 'capabilities_unavailable',
        statusCode: 409,
        message:
            'Mount $deviceId did not report its capabilities; check that it '
            'is connected before sending it home',
        details: {'deviceId': deviceId},
      );
    }
    if (!capabilities.canFindHome) {
      throw HandlerFailure(
        code: 'capability_unsupported',
        statusCode: 400,
        message:
            'Mount $deviceId cannot find home: its driver does not report a '
            'home position (canFindHome is false)',
        details: {'deviceId': deviceId, 'capability': 'canFindHome'},
      );
    }
    final status = await backend.getMountStatus(deviceId);
    if (status.parked) {
      throw HandlerFailure(
        code: 'mount_parked',
        statusCode: 409,
        message: 'Mount $deviceId is parked. Unpark it before sending it home.',
        details: {'deviceId': deviceId},
      );
    }

    final commandId = commandCorrelator?.beginCommand(
      operation: 'mount.home',
      deviceId: deviceId,
    );

    await backend.mountFindHome(deviceId);

    return jsonOk({
      if (commandId != null) 'commandId': commandId,
      'status': 'homing',
    });
  }
}
