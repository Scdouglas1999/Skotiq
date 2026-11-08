part of '../device_handlers.dart';

/// The host's mount motion guard: state and the operator's recovery actions
/// for linked clients. See `MountGuardBackend`.
extension MountGuardHandlers on DeviceHandlers {
  MountGuardBackend _mountGuard() {
    final backend = container.read(backendProvider);
    if (backend is! MountGuardBackend) {
      throw HandlerFailure(
        code: 'mount_guard_unavailable',
        statusCode: 503,
        message: 'This host has no mount guard.',
      );
    }
    return backend as MountGuardBackend;
  }

  /// A refusal from the guard (the mount is still moving, a sync failed) is
  /// the operator's to read, so it goes back as a 409 with its own words.
  Future<T> _guardCall<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on bridge_error.SkotiqError catch (error) {
      throw HandlerFailure(
        code: 'mount_guard_refused',
        statusCode: 409,
        message: bridgeErrorMessage(error) ?? 'The mount guard refused.',
      );
    }
  }

  /// GET `/api/mount/guard`: every mount with an open motion fault or an
  /// unknown position.
  Future<Response> handleMountGuardState(Request request) async {
    final entries = await _mountGuard().mountGuardState();
    return jsonOk({
      'mounts': [for (final e in entries) e.toJson()],
    });
  }

  /// POST `/api/mount/guard/acknowledge`.
  Future<Response> handleMountGuardAcknowledge(Request request) async {
    _logInfo('[API] POST /api/mount/guard/acknowledge');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    await _guardCall(() => _mountGuard().mountGuardAcknowledgeFault(deviceId));
    return jsonOk({'status': 'acknowledged'});
  }

  /// POST `/api/mount/guard/confirm-home`.
  Future<Response> handleMountGuardConfirmHome(Request request) async {
    _logInfo('[API] POST /api/mount/guard/confirm-home');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    await _guardCall(() => _mountGuard().mountGuardConfirmRehomed(deviceId));
    return jsonOk({'status': 'position_restored'});
  }

  /// POST `/api/mount/guard/solve`: take a frame and plate solve it blind.
  Future<Response> handleMountGuardSolve(Request request) async {
    _logInfo('[API] POST /api/mount/guard/solve');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final cameraId = optionalString(payload, 'cameraId');
    final exposure =
        optionalDouble(payload, 'exposureSecs', min: 0.5, max: 60) ?? 5;
    final solve = await _guardCall(
      () => _mountGuard().mountGuardSolve(
        deviceId,
        cameraId: cameraId,
        exposureSecs: exposure,
      ),
    );
    return jsonOk(solve.toJson());
  }

  /// POST `/api/mount/guard/recovery-sync`: sync to a solve the operator
  /// accepted and trust the mount's position again.
  Future<Response> handleMountGuardRecoverySync(Request request) async {
    _logInfo('[API] POST /api/mount/guard/recovery-sync');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final ra = requireDouble(payload, 'raHours', min: 0, max: 24);
    final dec = requireDouble(payload, 'decDegrees', min: -90, max: 90);
    await _guardCall(
      () => _mountGuard().mountGuardRecoverySync(deviceId, ra, dec),
    );
    return jsonOk({'status': 'synced'});
  }
}
