import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';
import 'package:skotiq_remote_protocol/wire.dart';
import '../route_table.dart';

class EquipmentHandlers implements RouteSource {
  @override
  Map<ApiEndpoint, Function> get routes => {
    EquipmentApi.cameraStatus: handleCameraStatus,
    EquipmentApi.mountStatus: handleMountStatus,
    EquipmentApi.focuserStatus: handleFocuserStatus,
    EquipmentApi.filterWheelStatus: handleFilterWheelStatus,
    EquipmentApi.rotatorStatus: handleRotatorStatus,
    EquipmentApi.cameraCapabilities: handleCameraCapabilities,
    EquipmentApi.mountCapabilities: handleMountCapabilities,
    EquipmentApi.focuserCapabilities: handleFocuserCapabilities,
    EquipmentApi.filterWheelCapabilities: handleFilterWheelCapabilities,
    EquipmentApi.rotatorCapabilities: handleRotatorCapabilities,
    EquipmentApi.deviceQuirks: handleDeviceQuirks,
    EquipmentApi.getDeviceHealth: handleGetDeviceHealth,
  };

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

  /// Drop every shared status read, so the next status request reads the
  /// device again.
  ///
  /// Called after any command request and on every equipment event. A slave
  /// reads a focuser's status, moves it, then reads it again to confirm the
  /// move; inside [statusShareWindow] that second read was answered with the
  /// first, from before the move, so the slave reported a stall and wrote the
  /// old position over the host's `FocuserMoveCompleted` event.
  void forgetSharedStatus() => _sharedStatus.clear();

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

  /// GET /api/equipment/quirks?deviceId=… — the workarounds the host's
  /// drivers apply to one of its connected devices.
  Future<Response> handleDeviceQuirks(Request request) async {
    final deviceId = _requireDeviceId(request);
    final backend = container.read(backendProvider);
    final quirks = backend is DeviceQuirksBackend
        ? await (backend as DeviceQuirksBackend).deviceQuirks(deviceId)
        : const <DeviceQuirk>[];
    return jsonOk({
      'quirks': [for (final quirk in quirks) quirk.toJson()],
    });
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
