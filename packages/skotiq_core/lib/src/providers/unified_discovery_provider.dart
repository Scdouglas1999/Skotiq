import '../errors/error_text.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../backend/skotiq_backend.dart';
import '../models/equipment/unified_device.dart';
import '../models/equipment/discovery_state.dart';
import '../services/device_matching_service.dart';
import 'backend_provider.dart';
import 'settings_provider.dart';
import '../models/backend/backend_types.dart';
import 'device_service_providers.dart';

/// The one bucket a linked client's discovery fills: its host answers for
/// every driver in a single sweep (see `_getAvailableBackends`).
const DriverType linkedHostScanBucket = DriverType.native;

final deviceMatchingServiceProvider = Provider<DeviceMatchingService>((ref) {
  return DeviceMatchingService();
});

final unifiedDiscoveryProvider =
    StateNotifierProvider<UnifiedDiscoveryNotifier, UnifiedDiscoveryState>((
      ref,
    ) {
      return UnifiedDiscoveryNotifier(ref);
    });

/// Notifier for managing unified device discovery across all backends
class UnifiedDiscoveryNotifier extends StateNotifier<UnifiedDiscoveryState> {
  static const _discoveryTimeout = Duration(seconds: 45);
  final Ref _ref;
  bool _cancelled = false;
  int _operationGeneration = 0;
  Future<void>? _scan;

  UnifiedDiscoveryNotifier(this._ref) : super(const UnifiedDiscoveryState()) {
    _ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (previous != null && !identical(previous, next)) {
        _invalidateInFlightDiscovery();
        state = const UnifiedDiscoveryState();
      }
    });
  }

  /// Scan every backend available on this platform, in parallel, and
  /// replace the found devices with what it finds.
  ///
  /// One scan runs at a time: a scan asked for while one runs (the header's
  /// Scan, a linked client's, the API's) joins it.
  Future<void> discoverAll({
    bool includeIndi = true,
    bool includeAlpaca = true,
  }) {
    final running = _scan;
    if (running != null) return running;
    late final Future<void> scan;
    scan = _discoverAll(includeIndi: includeIndi, includeAlpaca: includeAlpaca)
        .whenComplete(() {
          if (identical(_scan, scan)) _scan = null;
        });
    return _scan = scan;
  }

  Future<void> _discoverAll({
    required bool includeIndi,
    required bool includeAlpaca,
  }) async {
    final generation = _startDiscovery();

    final backends = discoveryBackendsForPolicy(
      _getAvailableBackends(),
      includeIndi: includeIndi,
      includeAlpaca: includeAlpaca,
    );

    // Clear stale grouped/raw results before rescan so a failed or
    // partial scan never leaves yesterday's devices on screen.
    state = _discoveringStateForBackends(backends);

    final results = await Future.wait([
      for (final backend in backends) _discoverBackend(backend),
    ]);

    if (!_canPublish(generation)) return;

    final allDevices = <DeviceInfo>[];
    final updatedStates = <DriverType, BackendDiscoveryState>{};

    for (final result in results) {
      updatedStates[result.backend] = BackendDiscoveryState(
        backend: result.backend,
        status: result.error != null
            ? DiscoveryStatus.error
            : DiscoveryStatus.completed,
        error: result.error,
        devices: result.devices,
        completedAt: DateTime.now(),
      );

      allDevices.addAll(result.devices);
    }

    final matchingService = _ref.read(deviceMatchingServiceProvider);
    final groupedDevices = matchingService.groupDevices(allDevices);

    state = state.copyWith(
      backendStates: updatedStates,
      rawDevices: allDevices,
      groupedDevices: groupedDevices,
    );
  }

  void cancel() {
    _invalidateInFlightDiscovery();
  }

  void clear() {
    _invalidateInFlightDiscovery();
    state = const UnifiedDiscoveryState();
  }

  int _startDiscovery() {
    _cancelled = false;
    return ++_operationGeneration;
  }

  bool _canPublish(int generation) {
    return !_cancelled && generation == _operationGeneration;
  }

  void _invalidateInFlightDiscovery() {
    _cancelled = true;
    _operationGeneration++;
    _scan = null;
  }

  /// [backends] marked discovering, and no devices.
  UnifiedDiscoveryState _discoveringStateForBackends(
    List<DriverType> backends,
  ) => UnifiedDiscoveryState(
    backendStates: {
      for (final backend in backends)
        backend: BackendDiscoveryState(
          backend: backend,
          status: DiscoveryStatus.discovering,
        ),
    },
  );

  /// Get list of backends available on this platform
  List<DriverType> _getAvailableBackends() {
    // Remote-client mode: the headless host owns every driver (ASCOM, native,
    // Alpaca, INDI, simulator) and reports them all through one network
    // backend. Splitting them into per-driver buckets here is wrong — a
    // connect-triggered rescan clears each stale bucket and re-filters by
    // DriverType, which drops the host's devices and makes the whole list
    // vanish. Collapse to a single bucket so the full remote list is always
    // merged and rebuilt as one unit. (The scan at launch is a host start-up
    // step and never runs on a client.)
    if (_ref.read(isRemoteModeProvider)) {
      return const [linkedHostScanBucket];
    }

    final backends = <DriverType>[
      // Simulator always available
      DriverType.simulator,
      // Native always available (may find no devices)
      DriverType.native,
      // Alpaca available on all platforms
      DriverType.alpaca,
      // INDI available on all platforms
      DriverType.indi,
    ];

    // ASCOM only on Windows
    if (Platform.isWindows) {
      backends.insert(1, DriverType.ascom);
    }

    return backends;
  }

  Future<_BackendResult> _discoverBackend(DriverType backend) async {
    try {
      final deviceService = _ref.read(deviceServiceProvider);
      final settings = await _ref.read(appSettingsProvider.future);

      List<DeviceInfo> devices = [];
      final errors = <String>[];

      switch (backend) {
        case DriverType.ascom:
        case DriverType.native:
        case DriverType.simulator:
          // In remote mode the single bucket carries every driver the host
          // reports, so the per-DriverType filter below must be skipped or it
          // would discard ASCOM/Alpaca/native devices that don't match the
          // bucket's nominal type.
          final isRemote = _ref.read(isRemoteModeProvider);
          // Discover all device types in PARALLEL for faster discovery
          final typeFutures = DeviceType.values.map((type) async {
            try {
              final typeDevices = await deviceService
                  .discoverDevices(type)
                  .timeout(_discoveryTimeout);
              if (isRemote) {
                return typeDevices;
              }
              // Filter to only include devices from this backend
              return typeDevices.where((d) => d.driverType == backend).toList();
            } on TimeoutException {
              errors.add(
                '${type.displayName} discovery timed out after '
                '${_discoveryTimeout.inSeconds} seconds',
              );
              return <DeviceInfo>[];
            } catch (e) {
              errors.add('${type.displayName} discovery failed: $e');
              return <DeviceInfo>[];
            }
          });
          final results = await Future.wait(typeFutures);
          for (final typeDevices in results) {
            devices.addAll(typeDevices);
          }
          break;

        case DriverType.indi:
          final indiHost = settings.indiServerHost;
          final indiPort = settings.indiServerPort;
          if (indiHost.isNotEmpty) {
            try {
              devices = await deviceService
                  .discoverIndiAtAddress(indiHost, indiPort)
                  .timeout(_discoveryTimeout);
            } catch (e) {
              return _BackendResult(
                backend: backend,
                devices: [],
                error: 'INDI server connection failed: ${e.toString()}',
              );
            }
          }
          break;

        case DriverType.alpaca:
          final alpacaHost = settings.alpacaServerHost;
          final alpacaPort = settings.alpacaServerPort;
          if (alpacaHost.isNotEmpty) {
            try {
              devices = await deviceService
                  .discoverAlpacaAtAddress(alpacaHost, alpacaPort)
                  .timeout(_discoveryTimeout);
            } catch (e) {
              return _BackendResult(
                backend: backend,
                devices: [],
                error: 'Alpaca server connection failed: ${e.toString()}',
              );
            }
          }
          break;
      }

      return _BackendResult(
        backend: backend,
        devices: devices,
        error: errors.isEmpty ? null : errors.join('; '),
      );
    } catch (e) {
      return _BackendResult(
        backend: backend,
        devices: [],
        error: userFacingError(e),
      );
    }
  }
}

/// Apply automatic-discovery protocol choices to the platform's available
/// backends. Manual discovery keeps both flags true; startup supplies the
/// persisted INDI and Alpaca choices.
List<DriverType> discoveryBackendsForPolicy(
  Iterable<DriverType> available, {
  required bool includeIndi,
  required bool includeAlpaca,
}) {
  return available
      .where((backend) {
        if (backend == DriverType.indi) return includeIndi;
        if (backend == DriverType.alpaca) return includeAlpaca;
        return true;
      })
      .toList(growable: false);
}

class _BackendResult {
  final DriverType backend;
  final List<DeviceInfo> devices;
  final String? error;

  const _BackendResult({
    required this.backend,
    required this.devices,
    this.error,
  });
}

final unifiedSafetyMonitorsProvider = Provider<List<UnifiedDevice>>((ref) {
  final discovery = ref.watch(unifiedDiscoveryProvider);
  return discovery.getDevicesByType(DeviceType.safetyMonitor);
});
