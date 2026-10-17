import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// Handlers for auxiliary device endpoints (Switch and Cover Calibrator)
class AuxiliaryHandlers {
  final ProviderContainer container;

  AuxiliaryHandlers(this.container);

  Future<List<DeviceInfo>> _connectedDevicesByType(DeviceType type) async {
    final backend = container.read(deviceBackendProvider);
    final connectedDevices = await backend.getConnectedDevices();
    return connectedDevices.where((d) => d.deviceType == type).toList();
  }

  Future<Map<String, dynamic>> _readSwitchStatus(
    String deviceId,
    String deviceName,
  ) async {
    final caps = await bridge.apiGetSwitchCapabilities(deviceId: deviceId);
    final logger = container.read(loggingServiceProvider);
    final switches = await Future.wait(
      caps.switches.map((s) async {
        double? liveValue;
        try {
          liveValue = await bridge.apiSwitchGetValue(
            deviceId: deviceId,
            switchId: s.index,
          );
        } catch (error, stackTrace) {
          logger.warning(
            'Live switch value read failed for $deviceId channel ${s.index}: '
            '$error',
            source: 'AuxiliaryHandlers',
            fields: {
              'deviceId': deviceId,
              'switchId': s.index,
              'stack': stackTrace.toString(),
            },
          );
        }

        return <String, dynamic>{
          'id': s.index,
          'name': s.name,
          'type': s.isBoolean ? 'boolean' : 'analog',
          'value': liveValue == null
              ? null
              : s.isBoolean
              ? liveValue > 0.5
              : liveValue,
          'minValue': s.isBoolean ? null : s.minValue,
          'maxValue': s.isBoolean ? null : s.maxValue,
          'step': s.isBoolean ? null : s.step,
          'canWrite': s.canWrite,
          'description': s.description,
          if (liveValue == null) 'readError': 'read_failed',
        };
      }),
    );

    return {
      'connected': true,
      'deviceId': deviceId,
      'deviceName': deviceName,
      'switchCount': caps.switchCount,
      'switches': switches,
    };
  }

  String _mapCoverState(bridge.CoverState state) {
    switch (state) {
      case bridge.CoverState.notPresent:
        return 'notPresent';
      case bridge.CoverState.closed:
        return 'closed';
      case bridge.CoverState.moving:
        return 'moving';
      case bridge.CoverState.open:
        return 'open';
      case bridge.CoverState.unknown:
        return 'unknown';
      case bridge.CoverState.error:
        return 'error';
    }
  }

  String _mapCalibratorState(bridge.CalibratorState state) {
    switch (state) {
      case bridge.CalibratorState.notPresent:
        return 'notPresent';
      case bridge.CalibratorState.off:
        return 'off';
      case bridge.CalibratorState.notReady:
        return 'notReady';
      case bridge.CalibratorState.ready:
        return 'ready';
      case bridge.CalibratorState.unknown:
        return 'unknown';
      case bridge.CalibratorState.error:
        return 'error';
    }
  }

  /// GET /api/switch/status
  Future<Response> handleSwitchStatus(Request request) async {
    final deviceId = request.url.queryParameters['deviceId'] ?? '';
    final switchDevices = await _connectedDevicesByType(DeviceType.switch_);

    if (deviceId.isEmpty) {
      if (switchDevices.isEmpty) {
        return jsonOk({
          'devicesConnected': 0,
          'devices': <Map<String, dynamic>>[],
          'message': 'No switch devices connected',
        });
      }

      // Why: per-device read errors are reported as `error` fields per entry
      // rather than failing the whole request — one bad device shouldn't blind
      // the caller to other working ones.
      //
      // Emit a stable `read_failed` code rather than the raw exception
      // message, which would leak Dart type names onto the wire. The full
      // detail is logged for operator triage.
      final logger = container.read(loggingServiceProvider);
      final deviceStatuses = <Map<String, dynamic>>[];
      for (final d in switchDevices) {
        try {
          deviceStatuses.add(await _readSwitchStatus(d.id, d.name));
        } catch (e, stackTrace) {
          logger.error(
            'Switch read failed for ${d.id}: $e',
            source: 'AuxiliaryHandlers',
            fields: {
              'deviceId': d.id,
              'deviceName': d.name,
              'stack': stackTrace.toString(),
            },
          );
          deviceStatuses.add({
            'connected': false,
            'deviceId': d.id,
            'deviceName': d.name,
            'error': 'read_failed',
            'message': 'Switch status read failed',
          });
        }
      }

      return jsonOk({
        'devicesConnected': switchDevices.length,
        'devices': deviceStatuses,
      });
    }

    final matchingSwitches = switchDevices.where((d) => d.id == deviceId);
    if (matchingSwitches.isEmpty) {
      return jsonNotFound({
        'connected': false,
        'deviceId': deviceId,
        'error': 'Switch device not connected',
      });
    }
    final switchDevice = matchingSwitches.first;
    return jsonOk(await _readSwitchStatus(switchDevice.id, switchDevice.name));
  }

  /// POST /api/switch/set
  Future<Response> handleSwitchSet(Request request) async {
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final switchId = requireInt(payload, 'switchId');
    final value = payload['value'];

    if (value == null) {
      throw BadRequestError(field: 'value', expected: 'boolean or number');
    }

    final connected = await _connectedDevicesByType(DeviceType.switch_);
    if (!connected.any((d) => d.id == deviceId)) {
      return jsonNotFound({
        'error': 'Switch device not connected',
        'deviceId': deviceId,
      });
    }

    final maxSwitches = await bridge.apiSwitchGetMax(deviceId: deviceId);
    if (switchId < 0 || switchId >= maxSwitches) {
      throw BadRequestError(
        field: 'switchId',
        expected: 'integer',
        message: 'switchId out of range (0..${maxSwitches - 1})',
      );
    }

    if (value is bool) {
      await bridge.apiSwitchSetState(
        deviceId: deviceId,
        switchId: switchId,
        state: value,
      );
    } else if (value is num) {
      await bridge.apiSwitchSetValue(
        deviceId: deviceId,
        switchId: switchId,
        value: value.toDouble(),
      );
    } else {
      throw BadRequestError(field: 'value', expected: 'boolean or number');
    }

    return jsonOk({
      'status': 'ok',
      'deviceId': deviceId,
      'switchId': switchId,
      'value': value,
    });
  }

  /// GET /api/cover/status
  Future<Response> handleCoverStatus(Request request) async {
    final deviceId = request.url.queryParameters['deviceId'] ?? '';
    if (deviceId.isEmpty) {
      throw BadRequestError(
        field: 'deviceId',
        expected: 'string',
        message: 'deviceId query parameter is required',
      );
    }

    final covers = await _connectedDevicesByType(DeviceType.coverCalibrator);
    final matchingCovers = covers.where((d) => d.id == deviceId);
    if (matchingCovers.isEmpty) {
      return jsonNotFound({
        'connected': false,
        'deviceId': deviceId,
        'error': 'Cover calibrator not connected',
      });
    }
    final device = matchingCovers.first;

    final status = await bridge.apiCoverCalibratorGetStatus(deviceId: deviceId);
    final hasCover = status.coverState != bridge.CoverState.notPresent;
    final hasCalibrator =
        status.calibratorState != bridge.CalibratorState.notPresent;

    return jsonOk({
      'connected': status.connected,
      'deviceId': deviceId,
      'deviceName': device.name,
      'coverState': _mapCoverState(status.coverState),
      'calibratorState': _mapCalibratorState(status.calibratorState),
      'brightness': status.brightness,
      'maxBrightness': status.maxBrightness,
      'hasCover': hasCover,
      'hasCalibrator': hasCalibrator,
    });
  }

  /// Returns a 404 "not connected" response when [deviceId] is not a currently
  /// connected cover/calibrator, else null. The cover mutation endpoints
  /// (open/close/brightness/calibrator) otherwise call straight into the native
  /// bridge, which throws an opaque 500 when no cover is attached — a remote
  /// tablet user closing the cover with nothing connected would see
  /// `internal_error`. This mirrors the switch/dome handlers so every accessory
  /// control degrades to the same clean 404.
  Future<Response?> _coverNotConnectedResponse(String deviceId) async {
    final covers = await _connectedDevicesByType(DeviceType.coverCalibrator);
    if (!covers.any((d) => d.id == deviceId)) {
      return jsonNotFound({
        'connected': false,
        'deviceId': deviceId,
        'error': 'Cover calibrator not connected',
      });
    }
    return null;
  }

  /// POST /api/cover/open
  Future<Response> handleCoverOpen(Request request) async {
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final notConnected = await _coverNotConnectedResponse(deviceId);
    if (notConnected != null) return notConnected;
    await bridge.apiCoverCalibratorOpenCover(deviceId: deviceId);
    return jsonOk({'status': 'opening', 'deviceId': deviceId});
  }

  /// POST /api/cover/close
  Future<Response> handleCoverClose(Request request) async {
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final notConnected = await _coverNotConnectedResponse(deviceId);
    if (notConnected != null) return notConnected;
    await bridge.apiCoverCalibratorCloseCover(deviceId: deviceId);
    return jsonOk({'status': 'closing', 'deviceId': deviceId});
  }

  /// POST /api/cover/brightness
  Future<Response> handleCoverBrightness(Request request) async {
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final brightness = requireInt(payload, 'brightness', min: 0);
    final notConnected = await _coverNotConnectedResponse(deviceId);
    if (notConnected != null) return notConnected;
    await bridge.apiCoverCalibratorCalibratorOn(
      deviceId: deviceId,
      brightness: brightness,
    );
    return jsonOk({
      'status': 'ok',
      'deviceId': deviceId,
      'brightness': brightness,
    });
  }

  /// POST /api/cover/calibrator-on
  Future<Response> handleCalibratorOn(Request request) async {
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final brightness = optionalInt(payload, 'brightness', min: 0) ?? 128;
    final notConnected = await _coverNotConnectedResponse(deviceId);
    if (notConnected != null) return notConnected;
    await bridge.apiCoverCalibratorCalibratorOn(
      deviceId: deviceId,
      brightness: brightness,
    );
    return jsonOk({
      'status': 'on',
      'deviceId': deviceId,
      'brightness': brightness,
    });
  }

  /// POST /api/cover/calibrator-off
  Future<Response> handleCalibratorOff(Request request) async {
    final payload = await readJsonObject(request);
    final deviceId = requireString(payload, 'deviceId');
    final notConnected = await _coverNotConnectedResponse(deviceId);
    if (notConnected != null) return notConnected;
    await bridge.apiCoverCalibratorCalibratorOff(deviceId: deviceId);
    return jsonOk({'status': 'off', 'deviceId': deviceId});
  }
}
