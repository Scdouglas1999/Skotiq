part of '../device_handlers.dart';

extension FilterWheelDeviceHandlers on DeviceHandlers {
  // Filter wheel control

  Future<Response> handleFilterWheelSetPosition(Request request) async {
    _logInfo('[API] POST /api/filter-wheel/position');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final position = requireInt(payload, 'position', min: 0);

    // Why: only the lower bound was checked, so an out-of-range slot reached the
    // driver and came back as a 500. Observed on a real ZWO EFW (8 slots):
    //   POST {"position": 99} -> 500 {"error":"internal_error","message":
    //   "Failed to move native filter wheel native:zwo_efw:0 to slot 99:
    //   Invalid parameter: Invalid position 99. Valid range: 0-7"}
    // The driver had already identified it as a parameter error and named the
    // valid range, so answering `internal_error` both misreported a plain bad
    // request as a server fault and invited retry-on-5xx clients to retry it.
    // `filterCount <= 0` means the wheel did not report a slot count, in which
    // case there is nothing to validate against.
    final status = await _tryFilterWheelStatus(deviceId);
    if (status != null &&
        status.filterCount > 0 &&
        position >= status.filterCount) {
      throw BadRequestError(
        field: 'position',
        expected: '0 to ${status.filterCount - 1}',
        message:
            'Filter slot $position is outside the range 0 to '
            '${status.filterCount - 1} reported by $deviceId '
            '(${status.filterCount} slots)',
      );
    }

    final commandId = commandCorrelator?.beginCommand(
      operation: 'filter-wheel.set-position',
      deviceId: deviceId,
    );

    // The host's slot wheel moves through DeviceService, as from the host
    // UI, so the per-filter focus offset applies whoever asked.
    await runDeviceCommand(
      deviceId,
      () => deviceCommandsOf(
        container,
      ).filterWheelSetPosition(deviceId, position),
    );

    return jsonOk({
      if (commandId != null) 'commandId': commandId,
      'status': 'ok',
    });
  }

  Future<Response> handleFilterWheelGetNames(Request request) async {
    final deviceId = request.url.queryParameters['deviceId']?.trim() ?? '';
    if (deviceId.isEmpty) {
      throw BadRequestError(
        field: 'deviceId',
        expected: 'string',
        message: "Missing 'deviceId' query parameter",
      );
    }

    // Call the names-only FFI directly. The backend's filterWheelGetNames
    // reads the full filter-wheel status,
    // which makes an unrelated ASCOM Position failure discard valid Names.
    final names = await bridge_error.apiFilterwheelGetNames(deviceId: deviceId);

    return jsonOk({'names': names});
  }

  Future<Response> handleFilterWheelSetNames(Request request) async {
    _logInfo('[API] POST /api/filter-wheel/names');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final names = requireList<String>(payload, 'names');

    await runDeviceCommand(
      deviceId,
      () => deviceCommandsOf(container).filterWheelSetNames(deviceId, names),
    );

    return jsonOk({'status': 'ok'});
  }

  /// Remote GET for the current filter-wheel position/state.
  ///
  /// Reads the live backend status when a wheel is connected, never the UI
  /// StateNotifier: control requests issued through the headless API call the
  /// backend directly, and not every vendor driver emits a matching event, so
  /// the cache can still name the old slot after the wheel has moved.
  ///
  /// The response shape matches the task spec:
  ///   { "position": int|null, "name": string|null, "isMoving": bool }
  /// Position is null when the wheel is disconnected or has not yet
  /// reported a starting slot. Name is null when no slot label is
  /// available for the current position (driver returned a short array
  /// or the wheel is disconnected).
  Future<Response> handleFilterWheelGetPosition(Request request) async {
    final state = container.read(filterWheelStateProvider);
    final deviceId = request.url.queryParameters['deviceId'] ?? state.deviceId;
    if (deviceId != null && deviceId.isNotEmpty) {
      final backend = container.read(deviceBackendProvider);
      final status = await backend.getFilterWheelStatus(deviceId);
      final position = status.connected ? status.position : null;
      final name =
          position != null &&
              position >= 0 &&
              position < status.filterNames.length
          ? status.filterNames[position]
          : null;
      return jsonOk({
        'position': position,
        'name': name,
        'isMoving': status.moving,
      });
    }

    return jsonOk({
      'position': state.currentPosition,
      'name': state.currentFilterName,
      'isMoving': state.isMoving,
    });
  }

  Future<Response> handleFilterWheelSetByName(Request request) async {
    _logInfo('[API] POST /api/filter-wheel/set-by-name');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final name = requireString(payload, 'name');

    // Why: an unknown filter name raised a bare Dart `ArgumentError` deeper in
    // the stack, which the top-level guard rendered as a 500. Observed on a real
    // ZWO EFW:
    //   POST {"name":"NoSuchFilter"} -> 500 {"error":"internal_error","message":
    //   "Invalid argument(s): Filter \"NoSuchFilter\" not found on device
    //   native:zwo_efw:0"}
    // A name the operator mistyped is a bad request, and the response should
    // also say which names ARE available so the caller can correct it without a
    // second round trip.
    final status = await _tryFilterWheelStatus(deviceId);
    final names = status?.filterNames ?? const <String>[];
    if (names.isNotEmpty && !names.contains(name)) {
      throw BadRequestError(
        field: 'name',
        expected: 'one of: ${names.join(', ')}',
        message:
            'Filter "$name" is not present on $deviceId. '
            'Available filters: ${names.join(', ')}',
      );
    }

    // Through the same path as a move by slot, focus offset included.
    await runDeviceCommand(
      deviceId,
      () => deviceCommandsOf(container).filterWheelSetByName(deviceId, name),
    );

    return jsonOk({'status': 'ok'});
  }

  /// Read filter-wheel status for the range/name checks, tolerating a failure.
  ///
  /// Why it must not propagate: these guards were added to stop a bad slot or
  /// name reaching the driver, not to add a new way for a valid request to fail.
  /// A wheel behind a camera on a shared USB bus can transiently fault a status
  /// poll while the move itself would have worked, so an unreadable status skips
  /// the guard and lets the driver arbitrate, as it did before.
  Future<FilterWheelStatus?> _tryFilterWheelStatus(String deviceId) async {
    try {
      return await container
          .read(deviceBackendProvider)
          .getFilterWheelStatus(deviceId);
    } catch (error) {
      _logInfo(
        'filter-wheel validation skipped for $deviceId: '
        'status read failed ($error)',
      );
      return null;
    }
  }
}
