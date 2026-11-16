/// Device-discovery HTTP handlers for the headless API.
///
/// Owns the catalog endpoints under `/api/devices/*`:
///   * `POST /api/devices/discover` — scan for devices (the app's one scan,
///     shared with the host's own Scan button), answering what it found,
///     optionally only of `?deviceType=`. Per-backend scan errors travel in
///     the response instead of being swallowed.
///   * `GET /api/devices` — the devices the host knows about: connected,
///     named by the active profile, or found by the last scan, with their
///     state and when that scan ran. It never scans: a scan enumerates vendor
///     SDKs and can probe serial ports, which no read may do while the rig
///     images.
///   * `GET /api/devices/discover-indi` — point-source discovery against a
///     specific INDI server (`?host=...&port=...`).
///   * `GET /api/devices/discover-alpaca` — same shape for ASCOM Alpaca.
///   * `GET /api/devices/connected` — currently-connected devices.
///
/// The mutating endpoints (`/api/devices/connect` / `/api/devices/disconnect`)
/// live in [DeviceHandlers] (`device_handlers.dart`) because they need the
/// full DeviceService connect pipeline (StateNotifier updates, heartbeat
/// monitoring, recommended-gain auto-apply). Discovery is read-only and has
/// no such dependency, so it lives here.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:shelf/shelf.dart';

import '../request_context.dart';
import '../response_helpers.dart';
import '../utils/device_type_parser.dart';
import '../validation.dart';
import 'package:skotiq_remote_protocol/wire.dart';
import '../route_table.dart';
import 'package:skotiq_core/utils.dart';

/// Handlers for the device-discovery endpoints.
class DeviceDiscoveryHandlers implements RouteSource {
  @override
  Map<ApiEndpoint, Function> get routes => {
    DeviceDiscoveryApi.getDevices: handleGetDevices,
    DeviceDiscoveryApi.discoverDevices: handleDiscoverDevices,
    DeviceDiscoveryApi.discoverIndiAtAddress: handleDiscoverIndiAtAddress,
    DeviceDiscoveryApi.discoverAlpacaAtAddress: handleDiscoverAlpacaAtAddress,
    DeviceDiscoveryApi.getConnectedDevices: handleGetConnectedDevices,
    DeviceDiscoveryApi.rescanDevices: handleRescanDevices,
  };

  final ProviderContainer container;

  DeviceDiscoveryHandlers(this.container);

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logWarning(String message, {Map<String, Object?>? fields}) => _logger
      .warning(message, source: 'DeviceDiscoveryHandlers', fields: fields);
  void _logInfo(String message) =>
      _logger.info(message, source: 'DeviceDiscoveryHandlers');
  void _logError(String message) =>
      _logger.error(message, source: 'DeviceDiscoveryHandlers');

  /// `GET /api/devices` — the devices the host knows about.
  Future<Response> handleGetDevices(Request request) async {
    _logInfo('[API][${requestIdFrom(request)}] GET /api/devices');
    final known = await container.read(hostKnownDevicesProvider.future);
    return jsonOk(known.toJson());
  }

  /// The `?deviceType=` a request names, or null when it names none.
  ///
  /// An unparseable type is refused, never answered with 200
  /// {"devices":[]}: that would tell the caller authoritatively that the rig
  /// has no such hardware when the word was not understood.
  /// `?deviceType=switch` is the live case: the enum member is `switch_`
  /// because Dart reserves `switch`.
  DeviceType? _requestedType(Request request) {
    final deviceTypeStr = request.url.queryParameters['deviceType'];
    if (deviceTypeStr == null) return null;
    final deviceType = parseDeviceType(deviceTypeStr);
    if (deviceType == null) {
      throw BadRequestError(
        field: 'deviceType',
        expected: 'one of: ${validDeviceTypeList()}',
        message: 'Unknown device type: $deviceTypeStr',
      );
    }
    return deviceType;
  }

  static Map<String, Object?> _deviceRow(DeviceInfo d) => {
    'id': d.id,
    'name': d.name,
    'deviceType': d.deviceType.name,
    'driverType': d.driverType.name,
    'description': d.description,
  };

  /// `POST /api/devices/discover` — scan, and answer what the scan found,
  /// optionally only of `?deviceType=`, with each backend whose scan failed
  /// and why in `discoveryErrors`.
  Future<Response> handleDiscoverDevices(Request request) async {
    final requestId = requestIdFrom(request);
    _logInfo('[API][$requestId] POST /api/devices/discover');
    final deviceType = _requestedType(request);
    try {
      await container.read(unifiedDiscoveryProvider.notifier).discoverAll();
      final scan = container.read(unifiedDiscoveryProvider);
      final discoveryErrors = {
        for (final entry in scan.backendStates.entries)
          if (entry.value.error case final error?) entry.key.name: error,
      };
      for (final entry in discoveryErrors.entries) {
        _logWarning(
          '[API][$requestId] ${entry.key} scan failed: ${entry.value}',
          fields: {'requestId': requestId, 'backend': entry.key},
        );
      }
      return jsonOk({
        'devices': [
          for (final device in scan.rawDevices)
            if (deviceType == null || device.deviceType == deviceType)
              _deviceRow(device),
        ],
        if (discoveryErrors.isNotEmpty) 'discoveryErrors': discoveryErrors,
      });
    } catch (e, stackTrace) {
      _logError('[API][$requestId] Discover devices error: $e\n$stackTrace');
      return jsonInternalServerError({"error": "Internal server error"});
    }
  }

  /// `GET /api/devices/discover-indi?host=&port=` — point-source INDI
  /// discovery. Used by the equipment wizard when the user enters an
  /// explicit INDI server address rather than relying on mDNS.
  Future<Response> handleDiscoverIndiAtAddress(Request request) async {
    final requestId = requestIdFrom(request);
    _logInfo('[API][$requestId] GET /api/devices/discover-indi');
    final query = request.url.queryParameters;
    final host = (query['host'] ?? '').trim();
    if (host.isEmpty) {
      throw BadRequestError(
        field: 'host',
        expected: 'string',
        message: 'host query parameter is required',
      );
    }
    final port = requireQueryInt(query, 'port', min: 1, max: 65535);
    try {
      final backend = container.read(deviceBackendProvider);
      final devices = await backend.discoverIndiAtAddress(host, port);
      return jsonOk({'devices': devices.map((d) => d.toJson()).toList()});
    } catch (e, stackTrace) {
      _logError(
        '[API][$requestId] INDI address discovery error: $e\n$stackTrace',
      );
      return jsonInternalServerError({'error': 'Internal server error'});
    }
  }

  /// `GET /api/devices/discover-alpaca?host=&port=` — point-source ASCOM
  /// Alpaca discovery against an explicit host:port.
  Future<Response> handleDiscoverAlpacaAtAddress(Request request) async {
    final requestId = requestIdFrom(request);
    _logInfo('[API][$requestId] GET /api/devices/discover-alpaca');
    final query = request.url.queryParameters;
    final host = (query['host'] ?? '').trim();
    if (host.isEmpty) {
      throw BadRequestError(
        field: 'host',
        expected: 'string',
        message: 'host query parameter is required',
      );
    }
    final port = requireQueryInt(query, 'port', min: 1, max: 65535);
    try {
      final backend = container.read(deviceBackendProvider);
      final devices = await backend.discoverAlpacaAtAddress(host, port);
      return jsonOk({'devices': devices.map((d) => d.toJson()).toList()});
    } catch (e, stackTrace) {
      _logError(
        '[API][$requestId] Alpaca address discovery error: $e\n$stackTrace',
      );
      return jsonInternalServerError({'error': 'Internal server error'});
    }
  }

  /// `POST /api/devices/rescan` — force the host to re-enumerate its hardware
  /// buses. Counterpart to the equipment-screen "Rescan equipment" button on a
  /// remote client: the host runs the native hot-plug diff (re-walks vendor
  /// SDKs + ASCOM registry, invalidates its discovery cache, emits
  /// device_discovered/device_lost deltas over the event stream).
  ///
  /// On the host the [deviceBackendProvider] resolves to the FfiBackend, so
  /// `rescanDevices()` here calls the same `apiRescanDevices()` the local
  /// desktop path uses. Mutating action (re-enumeration with side effects), so
  /// it is a POST. Failures surface as 500 rather than a silent no-op.
  Future<Response> handleRescanDevices(Request request) async {
    final requestId = requestIdFrom(request);
    _logInfo('[API][$requestId] POST /api/devices/rescan');
    try {
      final backend = container.read(deviceBackendProvider);
      await backend.rescanDevices();
      return jsonOk({'status': 'ok'});
    } catch (e, stackTrace) {
      _logError('[API][$requestId] Rescan devices error: $e\n$stackTrace');
      return jsonInternalServerError({'error': 'Internal server error'});
    }
  }

  /// `GET /api/devices/connected` — currently-connected devices. The
  /// response payload mirrors the GET /api/devices envelope so a client
  /// can render both lists with one renderer.
  Future<Response> handleGetConnectedDevices(Request request) async {
    final requestId = requestIdFrom(request);
    _logInfo('[API][$requestId] GET /api/devices/connected');
    try {
      final backend = container.read(deviceBackendProvider);
      final devices = await backend.getConnectedDevices();
      return jsonOk({
        "devices": devices
            .map(
              (d) => {
                'id': d.id,
                // The name this host's own cards show, so a linked client's
                // cards match them; the driver's name stays in driverName.
                'name': _hostCardName(d) ?? d.name,
                'driverName': d.name,
                'deviceType': d.deviceType.name,
                'driverType': d.driverType.name,
                'description': d.description,
              },
            )
            .toList(),
      });
    } catch (e, stackTrace) {
      _logError(
        '[API][$requestId] Get connected devices error: $e\n$stackTrace',
      );
      return jsonInternalServerError({"error": "Internal server error"});
    }
  }

  String? _hostCardName(DeviceInfo device) {
    try {
      final slot = readDeviceSlot(container, device.deviceType);
      if (slot.deviceId != device.id) return null;
      final name = readDeviceSlotName(container, device.deviceType)?.trim();
      return name == null || name.isEmpty ? null : name;
    } on Object {
      // A headless host has no cards: the driver's name is all there is.
      return null;
    }
  }
}
