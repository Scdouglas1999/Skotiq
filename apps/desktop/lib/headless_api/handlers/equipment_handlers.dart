import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../utils/device_type_parser.dart';
import '../validation.dart';

/// Handlers for equipment status and capabilities endpoints
class EquipmentHandlers {
  final ProviderContainer container;
  EquipmentHandlers(this.container);

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'EquipmentHandlers');

  /// Reads the required `deviceId` query parameter, rejecting a missing or
  /// empty value with a structured 400 rather than letting an empty id reach
  /// the backend (which surfaced as an opaque 500 `"<type>  not found"`).
  String _requireDeviceId(Request request) {
    final deviceId = request.url.queryParameters['deviceId'];
    if (deviceId == null || deviceId.isEmpty) {
      throw BadRequestError(
        field: 'deviceId',
        expected: 'string',
        message: "Missing 'deviceId' query parameter",
      );
    }
    return deviceId;
  }

  // Equipment status

  Future<Response> handleCameraStatus(Request request) async {
    final deviceId = _requireDeviceId(request);
    final backend = container.read(deviceBackendProvider);
    final status = await backend.getCameraStatus(deviceId);
    return jsonOk(status.toJson());
  }

  Future<Response> handleMountStatus(Request request) async {
    final deviceId = _requireDeviceId(request);
    final backend = container.read(deviceBackendProvider);
    final status = await backend.getMountStatus(deviceId);
    return jsonOk(status.toJson());
  }

  Future<Response> handleFocuserStatus(Request request) async {
    final deviceId = _requireDeviceId(request);
    final backend = container.read(deviceBackendProvider);
    final status = await backend.getFocuserStatus(deviceId);
    return jsonOk(status.toJson());
  }

  Future<Response> handleFilterWheelStatus(Request request) async {
    final deviceId = _requireDeviceId(request);
    final backend = container.read(deviceBackendProvider);
    final status = await backend.getFilterWheelStatus(deviceId);
    return jsonOk(status.toJson());
  }

  Future<Response> handleRotatorStatus(Request request) async {
    final deviceId = _requireDeviceId(request);
    final backend = container.read(deviceBackendProvider);
    final status = await backend.getRotatorStatus(deviceId);
    return jsonOk(status.toJson());
  }

  // Equipment capabilities

  Future<Response> handleCameraCapabilities(Request request) async {
    final deviceId = _requireDeviceId(request);
    final backend = container.read(deviceBackendProvider);
    final caps = await backend.getCameraCapabilities(deviceId);
    if (caps == null) {
      return jsonNotFound({
        'error': 'Device not found or capabilities unavailable',
      });
    }
    return jsonOk(caps.toJson());
  }

  Future<Response> handleMountCapabilities(Request request) async {
    final deviceId = _requireDeviceId(request);
    final backend = container.read(deviceBackendProvider);
    final caps = await backend.getMountCapabilities(deviceId);
    if (caps == null) {
      return jsonNotFound({
        'error': 'Device not found or capabilities unavailable',
      });
    }
    return jsonOk(caps.toJson());
  }

  Future<Response> handleFocuserCapabilities(Request request) async {
    final deviceId = _requireDeviceId(request);
    final backend = container.read(deviceBackendProvider);
    final caps = await backend.getFocuserCapabilities(deviceId);
    if (caps == null) {
      return jsonNotFound({
        'error': 'Device not found or capabilities unavailable',
      });
    }
    return jsonOk(caps.toJson());
  }

  Future<Response> handleFilterWheelCapabilities(Request request) async {
    final deviceId = _requireDeviceId(request);
    final backend = container.read(deviceBackendProvider);
    final caps = await backend.getFilterWheelCapabilities(deviceId);
    if (caps == null) {
      return jsonNotFound({
        'error': 'Device not found or capabilities unavailable',
      });
    }
    return jsonOk(caps.toJson());
  }

  Future<Response> handleRotatorCapabilities(Request request) async {
    final deviceId = _requireDeviceId(request);
    final backend = container.read(deviceBackendProvider);
    final caps = await backend.getRotatorCapabilities(deviceId);
    if (caps == null) {
      return jsonNotFound({
        'error': 'Device not found or capabilities unavailable',
      });
    }
    return jsonOk(caps.toJson());
  }

  // Device health monitoring

  Future<Response> handleStartDeviceHeartbeat(Request request) async {
    _logInfo('[API] POST /api/device/heartbeat/start');
    final payload = await readJsonObject(request);
    final deviceTypeStr = requireString(payload, 'device_type');
    final deviceId = requireString(payload, 'device_id');
    final intervalMs = requireInt(payload, 'interval_ms');

    final deviceType = parseDeviceType(deviceTypeStr);
    if (deviceType == null) {
      throw BadRequestError(
        field: 'device_type',
        expected: 'one of: ${DeviceType.values.map((e) => e.name).join(', ')}',
        message: 'Invalid device type: $deviceTypeStr',
      );
    }

    final backend = container.read(deviceBackendProvider);
    await backend.startDeviceHeartbeat(
      deviceType: deviceType,
      deviceId: deviceId,
      intervalMs: intervalMs,
    );
    return jsonOk({'status': 'started'});
  }

  Future<Response> handleStopDeviceHeartbeat(Request request) async {
    _logInfo('[API] POST /api/device/heartbeat/stop');
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'device_id');

    final backend = container.read(deviceBackendProvider);
    await backend.stopDeviceHeartbeat(deviceId);
    return jsonOk({'status': 'stopped'});
  }

  Future<Response> handleGetDeviceHealth(
    Request request,
    String deviceId,
  ) async {
    late final String decodedDeviceId;
    try {
      decodedDeviceId = Uri.decodeComponent(deviceId);
    } on FormatException {
      throw BadRequestError(
        field: 'deviceId',
        expected: 'URL-encoded device identifier',
        message: 'deviceId contains invalid percent encoding',
      );
    }
    final backend = container.read(deviceBackendProvider);
    final (lastComm, isHealthy) = await backend.getDeviceHealth(
      decodedDeviceId,
    );
    return jsonOk({'last_successful_comm': lastComm, 'is_healthy': isHealthy});
  }
}
