import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../backend/skotiq_backend.dart';
import '../models/equipment/unified_device.dart';
import '../models/equipment/discovery_state.dart';
import '../services/device_service.dart';
import '../services/device_matching_service.dart';
import 'backend_provider.dart';
import 'settings_provider.dart';

/// Provider for the device matching service
final deviceMatchingServiceProvider = Provider<DeviceMatchingService>((ref) {
  return DeviceMatchingService();
});

/// Provider for unified device discovery state
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

  UnifiedDiscoveryNotifier(this._ref) : super(const UnifiedDiscoveryState()) {
    _ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (previous != null && !identical(previous, next)) {
        _invalidateInFlightDiscovery();
        state = const UnifiedDiscoveryState();
      }
    });
  }

  /// Discover devices from all available backends in parallel
  ///
  /// This will:
  /// 1. Start discovery on all available backends simultaneously
  /// 2. Track progress per-backend
  /// 3. Group discovered devices using fuzzy matching
  /// 4. Update state as results come in
  Future<void> discoverAll({
    bool includeIndi = true,
    bool includeAlpaca = true,
  }) async {
    final generation = _startDiscovery();

    // Get backends that are available on this platform
    final backends = discoveryBackendsForPolicy(
      _getAvailableBackends(),
      includeIndi: includeIndi,
      includeAlpaca: includeAlpaca,
    );

    // Clear stale grouped/raw results before rescan so a failed or
    // partial scan never leaves yesterday's devices on screen.
    state = _discoveringStateForBackends(backends);

    // Discover from all backends in parallel
    final futures = <Future<_BackendResult>>[];
    for (final backend in backends) {
      futures.add(_discoverBackend(backend));
    }

    // Process results as they complete
    final results = await Future.wait(futures);

    if (!_canPublish(generation)) return;

    // Collect all devices
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

    // Group devices using fuzzy matching
    final matchingService = _ref.read(deviceMatchingServiceProvider);
    final groupedDevices = matchingService.groupDevices(allDevices);

    state = state.copyWith(
      backendStates: updatedStates,
      rawDevices: allDevices,
      groupedDevices: groupedDevices,
    );
  }

  /// Discover from a specific backend only
  ///
  /// Useful for adding servers manually (INDI/Alpaca)
  Future<void> discoverBackend(
    DriverType backend, {
    String? host,
    int? port,
  }) async {
    final generation = _startDiscovery();

    // Drop this backend's stale devices as soon as rescan starts.
    state = _discoveringStateForBackends([backend], mergeWithExisting: true);

    // Discover
    final result = await _discoverBackend(backend, host: host, port: port);

    if (!_canPublish(generation)) return;

    // Update state with results
    final updatedStates = Map<DriverType, BackendDiscoveryState>.from(
      state.backendStates,
    );
    updatedStates[backend] = BackendDiscoveryState(
      backend: backend,
      status: result.error != null
          ? DiscoveryStatus.error
          : DiscoveryStatus.completed,
      error: result.error,
      devices: result.devices,
      completedAt: DateTime.now(),
    );

    // Rebuild raw devices from all backends
    final allDevices = <DeviceInfo>[];
    for (final backendState in updatedStates.values) {
      allDevices.addAll(backendState.devices);
    }

    // Re-group devices
    final matchingService = _ref.read(deviceMatchingServiceProvider);
    final groupedDevices = matchingService.groupDevices(allDevices);

    state = state.copyWith(
      backendStates: updatedStates,
      rawDevices: allDevices,
      groupedDevices: groupedDevices,
    );
  }

  /// Discover devices only if results are missing or stale.
  ///
  /// Backends whose last successful discovery completed within [maxAge] are
  /// skipped.  Backends that have never completed or whose results are older
  /// than [maxAge] are rediscovered.  If *all* backends are fresh, this method
  /// returns immediately without any network I/O.
  Future<void> discoverIfNeeded({
    Duration maxAge = const Duration(seconds: 30),
  }) async {
    final now = DateTime.now();
    final backends = _getAvailableBackends();

    final staleBackends = <DriverType>[];
    for (final backend in backends) {
      final bs = state.backendStates[backend];
      if (bs == null ||
          !bs.isSuccess ||
          bs.completedAt == null ||
          now.difference(bs.completedAt!) > maxAge) {
        staleBackends.add(backend);
      }
    }

    if (staleBackends.isEmpty) return;

    // If all backends are stale, just do a full discovery
    if (staleBackends.length == backends.length) {
      await discoverAll();
      return;
    }

    // Otherwise, selectively rediscover only the stale backends
    final generation = _startDiscovery();

    // Clear stale devices for backends being rescanned.
    state = _discoveringStateForBackends(
      staleBackends,
      mergeWithExisting: true,
    );

    // Discover stale backends in parallel
    final futures = <Future<_BackendResult>>[];
    for (final backend in staleBackends) {
      futures.add(_discoverBackend(backend));
    }
    final results = await Future.wait(futures);

    if (!_canPublish(generation)) return;

    // Merge results into existing state
    final updatedStates = Map<DriverType, BackendDiscoveryState>.from(
      state.backendStates,
    );
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
    }

    // Rebuild raw devices from all backends
    final allDevices = <DeviceInfo>[];
    for (final backendState in updatedStates.values) {
      allDevices.addAll(backendState.devices);
    }

    // Re-group devices
    final matchingService = _ref.read(deviceMatchingServiceProvider);
    final groupedDevices = matchingService.groupDevices(allDevices);

    state = state.copyWith(
      backendStates: updatedStates,
      rawDevices: allDevices,
      groupedDevices: groupedDevices,
    );
  }

  /// Refresh discovery for all backends
  Future<void> refresh() async {
    await discoverAll();
  }

  /// Cancel ongoing discovery
  void cancel() {
    _invalidateInFlightDiscovery();
  }

  /// Clear all discovery results
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
  }

  /// Build state with [backends] marked discovering and their device lists cleared.
  ///
  /// When [mergeWithExisting] is true, backends not in [backends] keep their
  /// prior results (used by selective `discoverIfNeeded` refresh).
  UnifiedDiscoveryState _discoveringStateForBackends(
    List<DriverType> backends, {
    bool mergeWithExisting = false,
  }) {
    final updatedStates = mergeWithExisting
        ? Map<DriverType, BackendDiscoveryState>.from(state.backendStates)
        : <DriverType, BackendDiscoveryState>{};

    for (final backend in backends) {
      updatedStates[backend] = BackendDiscoveryState(
        backend: backend,
        status: DiscoveryStatus.discovering,
        devices: const [],
      );
    }

    final allDevices = <DeviceInfo>[];
    for (final backendState in updatedStates.values) {
      if (backendState.status != DiscoveryStatus.discovering) {
        allDevices.addAll(backendState.devices);
      }
    }

    final matchingService = _ref.read(deviceMatchingServiceProvider);
    final groupedDevices = matchingService.groupDevices(allDevices);

    return UnifiedDiscoveryState(
      backendStates: updatedStates,
      rawDevices: allDevices,
      groupedDevices: groupedDevices,
    );
  }

  /// Get list of backends available on this platform
  List<DriverType> _getAvailableBackends() {
    // Remote-client mode: the headless host owns every driver (ASCOM, native,
    // Alpaca, INDI, simulator) and reports them all through one network
    // backend. Splitting them into per-driver buckets here is wrong — a
    // connect-triggered rescan clears each stale bucket and re-filters by
    // DriverType, which drops the host's devices and makes the whole list
    // vanish. Collapse to a single bucket so the full remote list is always
    // merged and rebuilt as one unit. (Mirrors AutoDiscoveryLauncher, which
    // also short-circuits on isRemoteModeProvider.)
    if (_ref.read(isRemoteModeProvider)) {
      return const [DriverType.native];
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

  /// Discover devices from a specific backend
  Future<_BackendResult> _discoverBackend(
    DriverType backend, {
    String? host,
    int? port,
  }) async {
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
          final indiHost = host ?? settings.indiServerHost;
          final indiPort = port ?? settings.indiServerPort;
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
          final alpacaHost = host ?? settings.alpacaServerHost;
          final alpacaPort = port ?? settings.alpacaServerPort;
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
      return _BackendResult(backend: backend, devices: [], error: e.toString());
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

/// Internal result class for backend discovery
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

// Convenience providers for grouped devices by type

/// Provider for unified safety monitors
final unifiedSafetyMonitorsProvider = Provider<List<UnifiedDevice>>((ref) {
  final discovery = ref.watch(unifiedDiscoveryProvider);
  return discovery.getDevicesByType(DeviceType.safetyMonitor);
});
