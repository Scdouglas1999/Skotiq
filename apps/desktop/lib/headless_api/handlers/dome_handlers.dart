import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:shelf/shelf.dart';

import '../accessory_devices.dart';
import '../device_commands_route.dart';
import '../response_helpers.dart';
import '../validation.dart';
import 'package:skotiq_remote_protocol/wire.dart';
import '../route_table.dart';

class DomeHandlers implements RouteSource {
  @override
  Map<ApiEndpoint, Function> get routes => {
    DomeApi.open: handleDomeOpen,
    DomeApi.close: handleDomeClose,
    DomeApi.slew: handleDomeSlew,
    DomeApi.domeSync: handleDomeSync,
    DomeApi.park: handleDomePark,
    DomeApi.home: handleDomeHome,
    DomeApi.halt: handleDomeHalt,
    DomeApi.status: handleDomeStatus,
    DomeApi.capabilities: handleDomeCapabilities,
  };

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

  Future<DomeCapabilities> _capabilities(String deviceId) async =>
      await container.read(domeCapabilityFetcherProvider)(deviceId) ??
      const DomeCapabilities();

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
    final caps = await _capabilities(deviceId);
    await _requireCapability(
      deviceId: deviceId,
      supported: caps.canSetShutter,
      operation: 'open shutter',
      capability: 'canSetShutter',
    );
    await deviceCommandsOf(container).domeOpenShutter(deviceId);
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
    final caps = await _capabilities(deviceId);
    await _requireCapability(
      deviceId: deviceId,
      supported: caps.canSetShutter,
      operation: 'close shutter',
      capability: 'canSetShutter',
    );
    await deviceCommandsOf(container).domeCloseShutter(deviceId);
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
    final caps = await _capabilities(deviceId);
    await _requireCapability(
      deviceId: deviceId,
      supported: caps.canSetAzimuth,
      operation: 'slew',
      capability: 'canSetAzimuth',
    );
    await deviceCommandsOf(container).domeSlewToAzimuth(deviceId, azimuth);
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

    final caps = await _capabilities(deviceId);
    await _requireCapability(
      deviceId: deviceId,
      supported: caps.canSlave,
      operation: 'mount sync',
      capability: 'canSlave',
    );

    await deviceCommandsOf(container).domeSetSlaved(deviceId, enable);
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
    final caps = await _capabilities(deviceId);
    await _requireCapability(
      deviceId: deviceId,
      supported: caps.canPark,
      operation: 'park',
      capability: 'canPark',
    );
    await deviceCommandsOf(container).domePark(deviceId);
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

    final caps = await _capabilities(deviceId);
    await _requireCapability(
      deviceId: deviceId,
      supported: caps.canFindHome,
      operation: 'find home',
      capability: 'canFindHome',
    );

    await deviceCommandsOf(container).domeFindHome(deviceId);
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

    final caps = await _capabilities(deviceId);
    await _requireCapability(
      deviceId: deviceId,
      supported: caps.canAbort,
      operation: 'halt',
      capability: 'canAbort',
    );

    await deviceCommandsOf(container).domeAbortSlew(deviceId);
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

    final status = await accessoriesOf(container).readDomeStatus(deviceId);
    return jsonOk({
      'connected': status.connected,
      'deviceId': deviceId,
      'shutterState': status.shutter.name,
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

    final caps = await _capabilities(deviceId);
    return jsonOk({'deviceId': deviceId, ...caps.toJson()});
  }
}
