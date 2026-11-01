import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../utils/device_type_parser.dart';
import '../validation.dart';

/// Handlers for equipment status and capabilities endpoints
class EquipmentHandlers {
  final ProviderContainer container;
  EquipmentHandlers(this.container, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  /// How long one device status read answers every client that asks for the
  /// same device. Each read is a driver round trip (an ASCOM mount read takes
  /// about 130 ms), so without sharing, every connected companion's poll adds
  /// its own driver traffic on the imaging host.
  static const Duration statusShareWindow = Duration(milliseconds: 750);

  final Map<String, ({DateTime startedAt, Future<Map<String, dynamic>> json})>
  _sharedStatus = {};

  /// Run [read] for [key] unless a read for the same key started within
  /// [statusShareWindow]; then answer with that read's result. A failed read
  /// is not shared.
  Future<Map<String, dynamic>> _sharedStatusRead(
    String key,
    Future<Map<String, dynamic>> Function() read,
  ) {
    final now = _now();
    final recent = _sharedStatus[key];
    if (recent != null &&
        now.difference(recent.startedAt) < statusShareWindow) {
      return recent.json;
    }
    final json = read();
    _sharedStatus[key] = (startedAt: now, json: json);
    json.catchError((Object _) {
      if (identical(_sharedStatus[key]?.json, json)) _sharedStatus.remove(key);
      return const <String, dynamic>{};
    });
    return json;
  }

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
    return jsonOk(
      await _sharedStatusRead(
        'camera|$deviceId',
        () async => (await backend.getCameraStatus(deviceId)).toJson(),
      ),
    );
  }

  Future<Response> handleMountStatus(Request request) async {
    final deviceId = _requireDeviceId(request);
    final backend = container.read(deviceBackendProvider);
    return jsonOk(
      await _sharedStatusRead(
        'mount|$deviceId',
        () async => (await backend.getMountStatus(deviceId)).toJson(),
      ),
    );
  }

  Future<Response> handleFocuserStatus(Request request) async {
    final deviceId = _requireDeviceId(request);
    final backend = container.read(deviceBackendProvider);
    return jsonOk(
      await _sharedStatusRead(
        'focuser|$deviceId',
        () async => (await backend.getFocuserStatus(deviceId)).toJson(),
      ),
    );
  }

  Future<Response> handleFilterWheelStatus(Request request) async {
    final deviceId = _requireDeviceId(request);
    final backend = container.read(deviceBackendProvider);
    return jsonOk(
      await _sharedStatusRead(
        'filterWheel|$deviceId',
        () async => (await backend.getFilterWheelStatus(deviceId)).toJson(),
      ),
    );
  }

  Future<Response> handleRotatorStatus(Request request) async {
    final deviceId = _requireDeviceId(request);
    final backend = container.read(deviceBackendProvider);
    return jsonOk(
      await _sharedStatusRead(
        'rotator|$deviceId',
        () async => (await backend.getRotatorStatus(deviceId)).toJson(),
      ),
    );
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
