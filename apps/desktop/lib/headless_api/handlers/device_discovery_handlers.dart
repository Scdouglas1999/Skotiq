/// Device-discovery HTTP handlers for the headless API.
///
/// Owns the catalog endpoints under `/api/devices/*`:
///   * `POST /api/devices/discover` — discover every device, optionally
///     filtered by `?deviceType=`. Per-driver discovery errors are surfaced
///     in the response body instead of being silently swallowed.
///   * `GET /api/devices` — what the last discover found, without
///     discovering: a discovery enumerates vendor SDKs and can probe serial
///     ports, which no status read may do while the rig images.
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

  /// In-flight full (all-types) discovery, shared by concurrent callers. Null
  /// when no sweep is running. See [_fullDiscoveryCoalesced].
  Future<_Sweep>? _inFlightFullDiscovery;

  /// What the last discover found, by type, and when.
  final Map<DeviceType, List<DeviceInfo>> _found = {};
  DateTime? _foundAt;

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logWarning(String message, {Map<String, Object?>? fields}) => _logger
      .warning(message, source: 'DeviceDiscoveryHandlers', fields: fields);
  void _logInfo(String message) =>
      _logger.info(message, source: 'DeviceDiscoveryHandlers');
  void _logError(String message) =>
      _logger.error(message, source: 'DeviceDiscoveryHandlers');

  /// `GET /api/devices` — what the last discover found, optionally filtered
  /// by `?deviceType=`, with `discoveredAt` (null before the first).
  Future<Response> handleGetDevices(Request request) async {
    final requestId = requestIdFrom(request);
    _logInfo('[API][$requestId] GET /api/devices');
    final deviceType = _requestedType(request);
    final devices = deviceType == null
        ? _merged(_found.values)
        : (_found[deviceType] ?? const <DeviceInfo>[]);
    return jsonOk({
      'devices': devices.map(_deviceRow).toList(),
      'discoveredAt': _foundAt?.toUtc().toIso8601String(),
    });
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

  /// One entry per device id: a device reported under two type sweeps is
  /// listed once.
  static List<DeviceInfo> _merged(Iterable<List<DeviceInfo>> lists) {
    final byId = <String, DeviceInfo>{};
    for (final list in lists) {
      for (final device in list) {
        byId[device.id] = device;
      }
    }
    return byId.values.toList();
  }

  /// `POST /api/devices/discover` — discover every supported device type,
  /// optionally filtered by `?deviceType=`. Per-driver failures are surfaced
  /// in `discoveryErrors` so the dashboard can render an actionable warning
  /// per category.
  Future<Response> handleDiscoverDevices(Request request) async {
    final requestId = requestIdFrom(request);
    _logInfo('[API][$requestId] POST /api/devices/discover');
    final deviceType = _requestedType(request);
    try {
      final backend = container.read(deviceBackendProvider);

      List<DeviceInfo> allDevices = [];
      // Per-type errors travel in the response rather than being swallowed: a
      // persistent driver failure (missing TouptekSdk DLL, INDI server
      // unreachable) is otherwise indistinguishable from an empty rig, and the
      // dashboard needs the difference to warn per category.
      final discoveryErrors = <String, String>{};
      if (deviceType != null) {
        try {
          allDevices = await backend.discoverDevices(deviceType);
          _found[deviceType] = allDevices;
          _foundAt = DateTime.now();
        } catch (e, stackTrace) {
          discoveryErrors[deviceType.name] = _sanitizeDiscoveryError(e);
          _logWarning(
            '[API][$requestId] Discovery failed for ${deviceType.name}: $e',
            fields: {
              'requestId': requestId,
              'deviceType': deviceType.name,
              'error': '$e',
              'stack': '$stackTrace',
            },
          );
        }
      } else {
        // Full (all-types) sweep, single-flighted: concurrent discover
        // callers share ONE in-flight discovery instead of each launching their
        // own 11-type fan-out (see [_fullDiscoveryCoalesced]).
        final result = await _fullDiscoveryCoalesced(requestId);
        allDevices = _merged(result.byType.values);
        discoveryErrors.addAll(result.errors);
      }

      return jsonOk({
        "devices": allDevices.map(_deviceRow).toList(),
        if (discoveryErrors.isNotEmpty) 'discoveryErrors': discoveryErrors,
      });
    } catch (e, stackTrace) {
      _logError('[API][$requestId] Discover devices error: $e\n$stackTrace');
      return jsonInternalServerError({"error": "Internal server error"});
    }
  }

  /// Single-flight wrapper around [_discoverAllTypes].
  ///
  /// A full sweep probes every vendor SDK once per [DeviceType] and the native
  /// layer serialises those probes (the ASCOM STA worker, INDI sockets), so
  /// concurrent discover callers must coalesce: N independent fan-outs
  /// would queue N×(type-count) probes behind each other until they time out.
  /// One sweep runs at a time and late callers await the in-flight future. The
  /// slot is cleared on completion, so the next call after a sweep finishes
  /// runs a fresh discovery and hot-plug changes are still picked up.
  Future<_Sweep> _fullDiscoveryCoalesced(String requestId) async {
    final existing = _inFlightFullDiscovery;
    if (existing != null) {
      _logInfo('[API][$requestId] joining in-flight device discovery');
      return existing;
    }
    final future = _discoverAllTypes(requestId);
    _inFlightFullDiscovery = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlightFullDiscovery, future)) {
        _inFlightFullDiscovery = null;
      }
    }
  }

  /// Fan out discovery across every [DeviceType] concurrently and merge.
  ///
  /// Each `discoverDevices` call is an independent async FFI round-trip, so we
  /// join with `Future.wait` to cut wall-clock time to the slowest single type
  /// rather than the sum. Correctness is order-independent: results reduce into
  /// an id-keyed map (a single physical device reported under multiple type
  /// sweeps collapses to one entry). Per-type failures map to `errors[dt.name]`
  /// so persistent driver faults surface instead of being swallowed.
  /// `errors` writes from the per-future catch blocks need no lock — Dart's
  /// event loop runs each catch body as one atomic turn.
  Future<_Sweep> _discoverAllTypes(String requestId) async {
    final backend = container.read(deviceBackendProvider);
    final errors = <String, String>{};
    final futures = DeviceType.values.map((dt) async {
      try {
        return MapEntry(dt, await backend.discoverDevices(dt));
      } catch (e, stackTrace) {
        errors[dt.name] = _sanitizeDiscoveryError(e);
        _logWarning(
          '[API][$requestId] Discovery failed for ${dt.name}: $e',
          fields: {
            'requestId': requestId,
            'deviceType': dt.name,
            'error': '$e',
            'stack': '$stackTrace',
          },
        );
        return MapEntry(dt, const <DeviceInfo>[]);
      }
    });

    final byType = Map.fromEntries(await Future.wait(futures));
    _found
      ..clear()
      ..addAll(byType);
    _foundAt = DateTime.now();
    return (byType: byType, errors: errors);
  }

  String _sanitizeDiscoveryError(Object error) {
    final raw = error.toString();
    if (raw.startsWith('Exception: ')) {
      return raw.substring('Exception: '.length);
    }
    return raw;
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

/// One discovery of every type: what each type found, and the types whose
/// discovery failed with why.
typedef _Sweep = ({
  Map<DeviceType, List<DeviceInfo>> byType,
  Map<String, String> errors,
});
