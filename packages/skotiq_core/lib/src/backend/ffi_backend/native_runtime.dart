part of '../ffi_backend.dart';

/// Runs a generated bridge call that must refuse by name when the native
/// library is not loaded.
Future<T> _native<T>(String operation, FutureOr<T> Function() call) =>
    bridge.NativeBridge.run(operation, call);

/// Guider commands accept every PHD2 spelling but the native guider registry
/// knows PHD2 under one id.
String _canonicalGuiderDeviceId(String deviceId) =>
    isPhd2WireToken(deviceId) ? kPhd2CanonicalId : deviceId;

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

  static final discovery = _NativeDiscovery();
}

/// One discovery sweep covers every device type and is shared by all callers
/// for [_ttl], so the parallel per-type calls at startup cost one network
/// scan instead of one each.
final class _NativeDiscovery {
  static const _ttl = Duration(seconds: 60);

  final Map<bridge.DeviceType, List<bridge.DeviceInfo>> _cache = {};
  DateTime? _cachedAt;
  Completer<void>? _sweep;

  Future<List<bridge.DeviceInfo>> devices(bridge.DeviceType deviceType) async {
    final cachedAt = _cachedAt;
    if (cachedAt != null &&
        DateTime.now().difference(cachedAt) < _ttl &&
        _cache.containsKey(deviceType)) {
      return List.unmodifiable(_cache[deviceType]!);
    }

    final running = _sweep;
    if (running != null) {
      await running.future;
      return List.unmodifiable(_cache[deviceType] ?? const []);
    }

    final sweep = Completer<void>();
    _sweep = sweep;
    try {
      await _runSweep();
    } finally {
      _sweep = null;
      sweep.complete();
    }
    return List.unmodifiable(_cache[deviceType] ?? const []);
  }

  Future<void> _runSweep() async {
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
                developer.log(
                  '[Discovery] Native discovery error for ${type.name}: $e',
                  name: 'NativeBridge',
                  level: 900,
                );
              }
            }
          }(),
      ]);
    }

    _cache
      ..clear()
      ..addAll(found);
    _cachedAt = DateTime.now();

    final counts = [
      for (final entry in found.entries)
        if (entry.value.isNotEmpty) '${entry.value.length} ${entry.key.name}',
    ];
    developer.log(
      counts.isEmpty
          ? '[Discovery] Complete: no devices found'
          : '[Discovery] Complete: ${counts.join(', ')}',
      name: 'NativeBridge',
      level: 800,
    );
  }
}
