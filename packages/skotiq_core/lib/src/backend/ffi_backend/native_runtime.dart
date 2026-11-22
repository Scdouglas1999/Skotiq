part of '../ffi_backend.dart';

/// Runs a generated bridge call that must refuse by name when the native
/// library is not loaded.
Future<T> _native<T>(String operation, FutureOr<T> Function() call) =>
    bridge.NativeBridge.run(operation, call);

/// Overall progress the status poll reports for a native sequencer state.
double sequencerProgressFraction({
  required String state,
  required int completedExposures,
  required int totalExposures,
}) {
  if (state.toLowerCase() == 'completed') return 1.0;
  if (totalExposures <= 0) return 0.0;
  return (completedExposures / totalExposures).clamp(0.0, 1.0);
}

/// Native state that outlives any one [FfiBackend]: the Rust side is one per
/// process while backends are recreated on every host switch.
abstract final class _NativeProcessState {
  static bool sequencerEventsSubscribed = false;

  /// Dart-side copy of the flag `sequencerSetSimulationMode` last pushed.
  static bool simulationMode = false;

  static List<bridge.DeviceInfo> lastConnectedDevices = const [];

  /// The native reconnect policy, a fixed table: read once per process.
  static Set<DeviceType>? nativeReconnectedDeviceTypes;

  static final discovery = NativeDiscovery(
    _sweepNativeDiscovery,
    canCache: () => bridge.NativeBridge.isNativeAvailable,
  );
}

/// One discovery sweep covers every device type and is shared by all callers
/// for [ttl], so the parallel per-type calls at startup cost one network
/// scan instead of one each.
final class NativeDiscovery {
  @visibleForTesting
  NativeDiscovery(
    this._sweep, {
    this.ttl = const Duration(seconds: 60),
    bool Function()? canCache,
  }) : _canCache = canCache;

  final Future<Map<bridge.DeviceType, List<bridge.DeviceInfo>>> Function()
  _sweep;
  final Duration ttl;
  final bool Function()? _canCache;

  final Map<bridge.DeviceType, List<bridge.DeviceInfo>> _cache = {};
  DateTime? _cachedAt;
  int _generation = 0;
  Completer<void>? _running;

  Future<List<bridge.DeviceInfo>> devices(bridge.DeviceType deviceType) async {
    while (true) {
      final cachedAt = _cachedAt;
      if (cachedAt != null &&
          DateTime.now().difference(cachedAt) < ttl &&
          _cache.containsKey(deviceType)) {
        return List.unmodifiable(_cache[deviceType]!);
      }

      final running = _running;
      if (running != null) {
        final waitedGen = _generation;
        await running.future;
        if (waitedGen == _generation) {
          // The sweep this caller waited for, cached or not. A sweep that is
          // not allowed to be cached still answers the waiters; the next call
          // misses at the top of the loop because [_cachedAt] is null.
          return List.unmodifiable(_cache[deviceType] ?? const []);
        }
        // forget() invalidated the in-flight sweep; re-enter to start a fresh one.
        continue;
      }

      final sweepGen = _generation;
      final sweep = Completer<void>();
      _running = sweep;
      Map<bridge.DeviceType, List<bridge.DeviceInfo>> found;
      try {
        found = await _sweep();
        if (sweepGen == _generation) {
          _cache
            ..clear()
            ..addAll(found);
          final allowCache = _canCache?.call() ?? true;
          _cachedAt = allowCache ? DateTime.now() : null;
        }
      } finally {
        if (identical(_running, sweep)) {
          _running = null;
        }
        if (!sweep.isCompleted) {
          sweep.complete();
        }
      }
      if (sweepGen != _generation) {
        continue;
      }
      return List.unmodifiable(found[deviceType] ?? const []);
    }
  }

  /// The devices may have changed (a rescan, a device plugged in): the next
  /// caller sweeps again instead of reading the last sweep.
  void forget() {
    _cachedAt = null;
    _generation++;
  }
}

Future<Map<bridge.DeviceType, List<bridge.DeviceInfo>>>
_sweepNativeDiscovery() async {
  final found = <bridge.DeviceType, List<bridge.DeviceInfo>>{
    for (final type in bridge.DeviceType.values) type: <bridge.DeviceInfo>[],
  };

  if (bridge.NativeBridge.isNativeAvailable) {
    await Future.wait([
      for (final type in bridge.DeviceType.values)
        () async {
          try {
            final devices = await bridge.apiDiscoverDevices(deviceType: type);
            final seen = <String>{};
            found[type]!.addAll(devices.where((d) => seen.add(d.id)));
          } catch (e) {
            final text = e.toString();
            if (!text.contains('RustLib') &&
                !text.contains('not initialized')) {
              Log.warning(
                '[Discovery] Native discovery error for ${type.name}: $e',
                source: 'NativeBridge',
              );
            }
          }
        }(),
    ]);
  }

  final counts = [
    for (final entry in found.entries)
      if (entry.value.isNotEmpty) '${entry.value.length} ${entry.key.name}',
  ];
  Log.info(
    counts.isEmpty
        ? '[Discovery] Complete: no devices found'
        : '[Discovery] Complete: ${counts.join(', ')}',
    source: 'NativeBridge',
  );
  return found;
}
