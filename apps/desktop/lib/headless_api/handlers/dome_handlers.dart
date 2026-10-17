import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// Handlers for dome control endpoints
class DomeHandlers {
  final ProviderContainer container;

  DomeHandlers(this.container);

  Future<bool> _isConnectedDome(String deviceId) async {
    try {
      final backend = container.read(deviceBackendProvider);
      final connectedDevices = await backend.getConnectedDevices();
      return connectedDevices.any(
        (d) => d.id == deviceId && d.deviceType == DeviceType.dome,
      );
    } catch (e) {
      return false;
    }
  }

  Future<void> _requireCapability({
    required String deviceId,
    required bool supported,
    required String operation,
    required String capability,
  }) async {
    if (supported) return;
    throw HandlerFailure(
      code: 'capability_unsupported',
      statusCode: 400,
      message:
          'Dome $deviceId does not support $operation ($capability is false)',
      details: {'deviceId': deviceId, 'capability': capability},
    );
  }

  String _mapShutterState(bridge.ShutterState state) {
    switch (state) {
      case bridge.ShutterState.open:
        return 'open';
      case bridge.ShutterState.closed:
        return 'closed';
      case bridge.ShutterState.opening:
        return 'opening';
      case bridge.ShutterState.closing:
        return 'closing';
      case bridge.ShutterState.error:
        return 'error';
      case bridge.ShutterState.unknown:
        return 'unknown';
    }
  }

  String _mapShutterStatus(bridge.ShutterStatus? status) {
    if (status == null) return 'unknown';
    switch (status) {
      case bridge.ShutterStatus.open:
        return 'open';
      case bridge.ShutterStatus.closed:
        return 'closed';
      case bridge.ShutterStatus.opening:
        return 'opening';
      case bridge.ShutterStatus.closing:
        return 'closing';
      case bridge.ShutterStatus.unknown:
        return 'unknown';
    }
  }

  /// POST /api/dome/open
  Future<Response> handleDomeOpen(Request request) async {
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    if (!await _isConnectedDome(deviceId)) {
      return jsonNotFound({
        'error': 'Dome not connected',
        'deviceId': deviceId,
      });
    }
    final caps = await bridge.apiGetDomeCapabilities(deviceId: deviceId);
    await _requireCapability(
      deviceId: deviceId,
      supported: caps.canSetShutter,
      operation: 'open shutter',
      capability: 'canSetShutter',
    );
    await bridge.apiDomeOpenShutter(deviceId: deviceId);
    return jsonOk({'status': 'opening', 'deviceId': deviceId});
  }

  /// POST /api/dome/close
  Future<Response> handleDomeClose(Request request) async {
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    if (!await _isConnectedDome(deviceId)) {
      return jsonNotFound({
        'error': 'Dome not connected',
        'deviceId': deviceId,
      });
    }
    final caps = await bridge.apiGetDomeCapabilities(deviceId: deviceId);
    await _requireCapability(
      deviceId: deviceId,
      supported: caps.canSetShutter,
      operation: 'close shutter',
      capability: 'canSetShutter',
    );
    await bridge.apiDomeCloseShutter(deviceId: deviceId);
    return jsonOk({'status': 'closing', 'deviceId': deviceId});
  }

  /// POST /api/dome/slew
  Future<Response> handleDomeSlew(Request request) async {
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    // Why: azimuth must be in [0, 360); the helper raises BadRequestError if
    // the field is missing/wrong-type or out of range, which the middleware
    // translates to a structured 400.
    final azimuth = requireDouble(payload, 'azimuth', min: 0, max: 359.999999);
    if (!await _isConnectedDome(deviceId)) {
      return jsonNotFound({
        'error': 'Dome not connected',
        'deviceId': deviceId,
      });
    }
    final caps = await bridge.apiGetDomeCapabilities(deviceId: deviceId);
    await _requireCapability(
      deviceId: deviceId,
      supported: caps.canSetAzimuth,
      operation: 'slew',
      capability: 'canSetAzimuth',
    );
    await bridge.apiDomeSlewToAzimuth(deviceId: deviceId, azimuth: azimuth);
    return jsonOk({
      'status': 'slewing',
      'deviceId': deviceId,
      'targetAzimuth': azimuth,
    });
  }

  /// POST /api/dome/sync
  ///
  /// Body: `{ "deviceId": "...", "enable": true }` — enables/disables mount slaving.
  Future<Response> handleDomeSync(Request request) async {
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final enable = optionalBool(payload, 'enable') ?? true;
    if (!await _isConnectedDome(deviceId)) {
      return jsonNotFound({
        'error': 'Dome not connected',
        'deviceId': deviceId,
      });
    }

    final caps = await bridge.apiGetDomeCapabilities(deviceId: deviceId);
    await _requireCapability(
      deviceId: deviceId,
      supported: caps.canSlave,
      operation: 'mount sync',
      capability: 'canSlave',
    );

    await bridge.apiDomeSetSlaved(deviceId: deviceId, slaved: enable);
    return jsonOk({
      'status': enable ? 'sync_enabled' : 'sync_disabled',
      'deviceId': deviceId,
      'syncEnabled': enable,
    });
  }

  /// POST /api/dome/park
  Future<Response> handleDomePark(Request request) async {
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    if (!await _isConnectedDome(deviceId)) {
      return jsonNotFound({
        'error': 'Dome not connected',
        'deviceId': deviceId,
      });
    }
    final caps = await bridge.apiGetDomeCapabilities(deviceId: deviceId);
    await _requireCapability(
      deviceId: deviceId,
      supported: caps.canPark,
      operation: 'park',
      capability: 'canPark',
    );
    await bridge.apiDomePark(deviceId: deviceId);
    return jsonOk({'status': 'parking', 'deviceId': deviceId});
  }

  /// POST /api/dome/home
  Future<Response> handleDomeHome(Request request) async {
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    if (!await _isConnectedDome(deviceId)) {
      return jsonNotFound({
        'error': 'Dome not connected',
        'deviceId': deviceId,
      });
    }

    final caps = await bridge.apiGetDomeCapabilities(deviceId: deviceId);
    await _requireCapability(
      deviceId: deviceId,
      supported: caps.canFindHome,
      operation: 'find home',
      capability: 'canFindHome',
    );

    await bridge.apiDomeFindHome(deviceId: deviceId);
    return jsonOk({'status': 'homing', 'deviceId': deviceId});
  }

  /// POST /api/dome/halt
  Future<Response> handleDomeHalt(Request request) async {
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    if (!await _isConnectedDome(deviceId)) {
      return jsonNotFound({
        'error': 'Dome not connected',
        'deviceId': deviceId,
      });
    }

    final caps = await bridge.apiGetDomeCapabilities(deviceId: deviceId);
    await _requireCapability(
      deviceId: deviceId,
      supported: caps.canAbort,
      operation: 'halt',
      capability: 'canAbort',
    );

    await bridge.apiDomeAbortSlew(deviceId: deviceId);
    return jsonOk({'status': 'halted', 'deviceId': deviceId});
  }

  /// GET /api/dome/status
  Future<Response> handleDomeStatus(Request request) async {
    final deviceId = request.url.queryParameters['deviceId'] ?? '';
    if (deviceId.isEmpty) {
      throw BadRequestError(
        field: 'deviceId',
        expected: 'string',
        message: 'deviceId query parameter is required',
      );
    }
    if (!await _isConnectedDome(deviceId)) {
      return jsonNotFound({
        'connected': false,
        'deviceId': deviceId,
        'error': 'Dome not connected',
      });
    }

    final status = await bridge.apiGetDomeStatus(deviceId: deviceId);
    return jsonOk({
      'connected': status.connected,
      'deviceId': deviceId,
      'shutterState': _mapShutterState(status.shutterStatus),
      'azimuth': status.azimuth,
      'altitude': status.altitude,
      'slewing': status.slewing,
      'atHome': status.atHome,
      'atPark': status.atPark,
      'canSetAltitude': status.canSetAltitude,
      'canSetAzimuth': status.canSetAzimuth,
      'canSetShutter': status.canSetShutter,
      'canSyncToMount': status.canSlave,
      'syncEnabled': status.isSlaved,
    });
  }

  /// GET /api/dome/capabilities
  Future<Response> handleDomeCapabilities(Request request) async {
    final deviceId = request.url.queryParameters['deviceId'] ?? '';
    if (deviceId.isEmpty) {
      throw BadRequestError(
        field: 'deviceId',
        expected: 'string',
        message: 'deviceId query parameter is required',
      );
    }
    if (!await _isConnectedDome(deviceId)) {
      return jsonNotFound({
        'error': 'Dome not found or not connected',
        'deviceId': deviceId,
      });
    }

    final caps = await bridge.apiGetDomeCapabilities(deviceId: deviceId);
    return jsonOk({
      'deviceId': deviceId,
      'canSetAzimuth': caps.canSetAzimuth,
      'canSetShutter': caps.canSetShutter,
      'canPark': caps.canPark,
      'canFindHome': caps.canFindHome,
      'canSyncAzimuth': caps.canSyncAzimuth,
      'canSlave': caps.canSlave,
      'canSetSlave': caps.canSlave,
      'canAbort': caps.canAbort,
      'slewing': caps.slewing,
      'atHome': caps.atHome,
      'atPark': caps.atPark,
      'slaved': caps.slaved,
      'azimuth': caps.azimuth,
      'shutterStatus': _mapShutterStatus(caps.shutterStatus),
    });
  }
}
