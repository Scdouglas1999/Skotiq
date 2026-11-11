part of '../device_handlers.dart';

extension RotatorDeviceHandlers on DeviceHandlers {

  Future<Response> handleRotatorMoveTo(Request request) async {
    _logInfo('[API] POST /api/rotator/move-to');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final angle = requireDouble(payload, 'angle');

    final commandId = commandCorrelator?.beginCommand(
      operation: 'rotator.move-to',
      deviceId: deviceId,
    );

    await runDeviceCommand(
      deviceId,
      () => deviceCommandsOf(container).rotatorMoveTo(deviceId, angle),
    );

    return jsonOk({
      if (commandId != null) 'commandId': commandId,
      'status': 'moving',
    });
  }

  Future<Response> handleRotatorMoveRelative(Request request) async {
    _logInfo('[API] POST /api/rotator/move-relative');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final delta = requireDouble(payload, 'delta');

    await runDeviceCommand(
      deviceId,
      () => deviceCommandsOf(container).rotatorMoveRelative(deviceId, delta),
    );

    return jsonOk({'status': 'moving'});
  }

  Future<Response> handleRotatorGetStatus(Request request) async {
    final deviceId = request.url.queryParameters['deviceId']?.trim() ?? '';
    if (deviceId.isEmpty) {
      throw BadRequestError(
        field: 'deviceId',
        expected: 'string',
        message: "Missing 'deviceId' query parameter",
      );
    }

    final backend = container.read(deviceBackendProvider);
    final angle = await backend.rotatorGetAngle(deviceId);

    return jsonOk({'position': angle});
  }

  Future<Response> handleRotatorHalt(Request request) async {
    _logInfo('[API] POST /api/rotator/halt');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');

    await runDeviceCommand(
      deviceId,
      () => deviceCommandsOf(container).rotatorHalt(deviceId),
    );

    return jsonOk({'status': 'halted'});
  }

  /// POST /api/rotator/set-reverse — write the driver's reverse-direction
  /// flag (IRotatorV3 `Reverse`). Only valid when the driver reports
  /// `canReverse`; unsupported drivers surface the backend error.
  Future<Response> handleRotatorSetReverse(Request request) async {
    _logInfo('[API] POST /api/rotator/set-reverse');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final reverse = requireBool(payload, 'reverse');

    await runDeviceCommand(
      deviceId,
      () => deviceCommandsOf(container).rotatorSetReverse(deviceId, reverse),
    );

    return jsonOk({'status': 'ok', 'reverse': reverse});
  }

  /// POST /api/rotator/sync — sync rotator reported sky angle to the supplied
  /// position angle (degrees) without moving the hardware. Used by the "Sync
  /// to image PA" workflow after a plate solve.
  ///
  /// Why this isn't a synonym for /api/rotator/move-to: ASCOM IRotatorV3
  /// separates Sync (mechanical-vs-sky offset adjustment) from MoveAbsolute
  /// (motion). Conflating them would slew the rotator every time the operator
  /// hit "Sync to image", which is the opposite of the intended effect.
  ///
  /// Body: `{deviceId, positionAngle}` — `positionAngle` is the canonical
  /// field; `angle` is accepted as an alias for compatibility with older
  /// clients that mirrored the move-to body shape.
  Future<Response> handleRotatorSync(Request request) async {
    _logInfo('[API] POST /api/rotator/sync');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    // Why accept both `positionAngle` and `angle`: the canonical field name
    // is `positionAngle` (matches plate-solve terminology), but the move-to
    // endpoint uses `angle` and earlier dashboard builds reused that key.
    final pa =
        optionalDouble(payload, 'positionAngle') ??
        optionalDouble(payload, 'angle');
    if (pa == null) {
      throw BadRequestError(
        field: 'positionAngle',
        expected: 'number',
        message: "Body must include 'positionAngle' (degrees)",
      );
    }

    await runDeviceCommand(
      deviceId,
      () => deviceCommandsOf(container).rotatorSyncToPa(deviceId, pa),
    );

    return jsonOk({'status': 'synced'});
  }
}
