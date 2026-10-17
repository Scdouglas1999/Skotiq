// Capability-driven UI provider layer.
//
// This file is a Riverpod facade over the device capability queries exposed
// by `SkotiqBackend.getXCapabilities`. It exists so per-device UI widgets
// can gate controls (cooling toggle, mount park button, dome shutter, etc.)
// on whether the connected driver actually reports support for them.
//
// Why a separate file from `providers/capability_provider.dart`:
//   * The older provider exposes data only and lets every call site decide
//     how to treat null/error — most use a fail-OPEN default (`?? true`).
//   * This file adds an explicit fail-CLOSED helper (`gateCapability`)
//     because shipping a dead button is worse than hiding a real one. A
//     missing capability is a loud signal, not a fallback.
//   * It also adds a Dome capability provider (the legacy file has none) and
//     a reconnect-aware invalidator so connecting a different physical
//     device flushes stale capability data.
//
// Refresh model:
//   * Each provider is a `FutureProvider.family<…?, String>` keyed by
//     deviceId. When the deviceId changes (different device selected), Riverpod
//     rebuilds with the new key automatically — no manual invalidation needed.
//   * For same-deviceId reconnects (e.g., USB reconnect bumping the cooler
//     state), the equipment state notifier is responsible for invalidating
//     the matching capability provider on the connected transition. That
//     hook is installed by `installCapabilityRefreshOnConnect(ref)`, which
//     should be wired during app bootstrap.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_diag;
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_caps;

import '../../backend/network_backend.dart';
import '../../models/backend/device_capabilities.dart';
import '../../models/equipment/equipment_models.dart';
import '../backend_provider.dart';
import 'camera_state_provider.dart';
import 'cover_calibrator_state_provider.dart';
import 'dome_state_provider.dart';
import 'filter_wheel_state_provider.dart';
import 'focuser_state_provider.dart';
import 'mount_state_provider.dart';
import 'rotator_state_provider.dart';

// Capability providers — typed-Dart returns, null on query failure.

/// Camera capabilities for [deviceId].
///
/// Returns null when:
///   * deviceId is empty (no device selected)
///   * the backend's capability query returned null (driver couldn't be queried)
///
/// Throws when the backend's capability query itself threw (e.g., bridge
/// crash). Callers MUST treat a thrown future as "capability unknown" and
/// fail closed — see [gateCapability].
final equipmentCameraCapabilitiesProvider =
    FutureProvider.family<CameraCapabilities?, String>((ref, deviceId) async {
      if (deviceId.isEmpty) return null;
      final backend = ref.watch(deviceBackendProvider);
      return backend.getCameraCapabilities(deviceId);
    });

/// Mount capabilities for [deviceId]. See [equipmentCameraCapabilitiesProvider].
final equipmentMountCapabilitiesProvider =
    FutureProvider.family<MountCapabilities?, String>((ref, deviceId) async {
      if (deviceId.isEmpty) return null;
      final backend = ref.watch(deviceBackendProvider);
      return backend.getMountCapabilities(deviceId);
    });

/// Focuser capabilities for [deviceId]. See [equipmentCameraCapabilitiesProvider].
final equipmentFocuserCapabilitiesProvider =
    FutureProvider.family<FocuserCapabilities?, String>((ref, deviceId) async {
      if (deviceId.isEmpty) return null;
      final backend = ref.watch(deviceBackendProvider);
      return backend.getFocuserCapabilities(deviceId);
    });

/// Filter wheel capabilities for [deviceId]. See [equipmentCameraCapabilitiesProvider].
final equipmentFilterWheelCapabilitiesProvider =
    FutureProvider.family<FilterWheelCapabilities?, String>((
      ref,
      deviceId,
    ) async {
      if (deviceId.isEmpty) return null;
      final backend = ref.watch(deviceBackendProvider);
      return backend.getFilterWheelCapabilities(deviceId);
    });

/// Rotator capabilities for [deviceId]. See [equipmentCameraCapabilitiesProvider].
final equipmentRotatorCapabilitiesProvider =
    FutureProvider.family<RotatorCapabilities?, String>((ref, deviceId) async {
      if (deviceId.isEmpty) return null;
      final backend = ref.watch(deviceBackendProvider);
      return backend.getRotatorCapabilities(deviceId);
    });

/// Dome capability fetcher — overridable for tests.
///
/// Production calls the FRB bridge directly because the [SkotiqBackend]
/// abstraction does not yet have a `getDomeCapabilities` method, and adding
/// one belongs to a backend-shape change outside the scope of.
typedef DomeCapabilityFetcher =
    Future<DomeCapabilities?> Function(String deviceId);

/// Injection point for tests. Restored to the production fetcher by default.
///
/// Tests overwrite this in `setUp` to avoid loading the native FFI shim.
/// The fetcher returns `null` on "capability unknown" and throws on
/// catastrophic failure — the same contract as the other backend.getXCapabilities
/// methods.
final domeCapabilityFetcherProvider = Provider<DomeCapabilityFetcher>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return backend.getDomeCapabilities;
  }
  return (deviceId) async {
    final caps = await bridge_diag.apiGetDomeCapabilities(deviceId: deviceId);
    return _fromBridgeDomeCapabilities(caps);
  };
});

/// Dome capabilities for [deviceId].
///
/// Bridges the typed FRB struct into the pure-Dart [DomeCapabilities] used
/// elsewhere. Same null/throw semantics as the other capability providers.
final equipmentDomeCapabilitiesProvider =
    FutureProvider.family<DomeCapabilities?, String>((ref, deviceId) async {
      if (deviceId.isEmpty) return null;
      final fetcher = ref.watch(domeCapabilityFetcherProvider);
      return fetcher(deviceId);
    });

/// Capability and live-status snapshot for a combined dust-cover/flat-panel
/// device. A device may implement either half, so presence is explicit.
class CoverCalibratorCapabilitySnapshot {
  final bool coverPresent;
  final bool calibratorPresent;
  final CoverStatus? coverStatus;
  final CalibratorStatus? calibratorStatus;
  final int? brightness;
  final int maxBrightness;

  const CoverCalibratorCapabilitySnapshot({
    required this.coverPresent,
    required this.calibratorPresent,
    required this.maxBrightness,
    this.coverStatus,
    this.calibratorStatus,
    this.brightness,
  });
}

typedef CoverCalibratorCapabilityFetcher =
    Future<CoverCalibratorCapabilitySnapshot?> Function(String deviceId);

final coverCalibratorCapabilityFetcherProvider =
    Provider<CoverCalibratorCapabilityFetcher>((ref) {
      final backend = ref.watch(backendProvider);
      if (backend is NetworkBackend) {
        return (deviceId) async {
          final status = await backend.getCoverStatus(deviceId);
          return CoverCalibratorCapabilitySnapshot(
            coverPresent: status['hasCover'] == true,
            calibratorPresent: status['hasCalibrator'] == true,
            coverStatus: _coverStatusFromWire(status['coverState']),
            calibratorStatus: _calibratorStatusFromWire(
              status['calibratorState'],
            ),
            brightness: (status['brightness'] as num?)?.toInt(),
            maxBrightness: (status['maxBrightness'] as num?)?.toInt() ?? 0,
          );
        };
      }
      return (deviceId) async {
        final caps = await bridge_diag.apiGetCoverCalibratorCapabilities(
          deviceId: deviceId,
        );
        return CoverCalibratorCapabilitySnapshot(
          coverPresent: caps.coverPresent,
          calibratorPresent: caps.calibratorPresent,
          coverStatus: _coverStatusFromWire(caps.coverState?.name),
          calibratorStatus: _calibratorStatusFromWire(
            caps.calibratorState?.name,
          ),
          brightness: caps.brightness,
          maxBrightness: caps.maxBrightness,
        );
      };
    });

final equipmentCoverCalibratorCapabilitiesProvider =
    FutureProvider.family<CoverCalibratorCapabilitySnapshot?, String>((
      ref,
      deviceId,
    ) async {
      if (deviceId.isEmpty) return null;
      final fetcher = ref.watch(coverCalibratorCapabilityFetcherProvider);
      return fetcher(deviceId);
    });

CoverStatus? _coverStatusFromWire(Object? value) => switch (value) {
  'notPresent' => CoverStatus.notPresent,
  'closed' => CoverStatus.closed,
  'moving' => CoverStatus.moving,
  'open' => CoverStatus.open,
  'unknown' => CoverStatus.unknown,
  'error' => CoverStatus.error,
  _ => null,
};

CalibratorStatus? _calibratorStatusFromWire(Object? value) => switch (value) {
  'notPresent' => CalibratorStatus.notPresent,
  'off' => CalibratorStatus.off,
  'notReady' => CalibratorStatus.notReady,
  'ready' => CalibratorStatus.ready,
  'unknown' => CalibratorStatus.unknown,
  'error' => CalibratorStatus.error,
  _ => null,
};

DomeCapabilities _fromBridgeDomeCapabilities(bridge_caps.DomeCapabilities src) {
  return DomeCapabilities(
    canSetAzimuth: src.canSetAzimuth,
    canPark: src.canPark,
    canFindHome: src.canFindHome,
    canSetShutter: src.canSetShutter,
    canSyncAzimuth: src.canSyncAzimuth,
    canSlave: src.canSlave,
    canAbort: src.canAbort,
  );
}

// Fail-closed gate helper.

/// Read a single capability flag from an `AsyncValue<T?>` with fail-CLOSED
/// semantics. Returns the value of `extract(caps)` when capabilities are
/// loaded and present; returns `false` when:
///   * The capability query errored (the bridge threw — driver is broken)
///   * The capability query returned null (driver did not report)
///
/// Returns `loadingDefault` (default `false`) while the future is still in
/// flight. UI code that wants "show the control optimistically until we
/// know better" should pass `loadingDefault: true`; UI code that wants the
/// safest possible default (hide the control) should leave it as `false`.
///
/// Fail closed because an offered control that does nothing, or throws a raw
/// driver error, is worse than an absent one: the operator cannot tell it
/// apart from a working control that failed.
bool gateCapability<T>(
  AsyncValue<T?> caps,
  bool Function(T caps) extract, {
  bool loadingDefault = false,
}) {
  return caps.when(
    data: (value) {
      if (value == null) return false;
      return extract(value);
    },
    loading: () => loadingDefault,
    error: (_, __) => false,
  );
}

// Connect-driven refresh.

/// Eagerly subscribes to the per-device state providers and invalidates the
/// matching capability provider whenever a device transitions into the
/// connected state.
///
/// A device that reconnects under the same id may report a different
/// capability set, and the capability provider caches per family key — without
/// the invalidate the UI keeps serving the pre-reconnect answer.
///
/// Eager-init this from app bootstrap (`container.read(...)`) so the
/// listeners attach before the first device connects. The provider lives
/// for the lifetime of the container; disposal of the container closes the
/// subscriptions automatically.
final capabilityRefreshOnConnectProvider = Provider<void>((ref) {
  _listenForConnect<CameraStateSnapshot>(
    ref,
    cameraStateProvider,
    deviceIdOf: (s) => s.deviceId,
    isConnected: (s) => s.connectionState == DeviceConnectionState.connected,
    invalidate: (id) => ref.invalidate(equipmentCameraCapabilitiesProvider(id)),
  );
  _listenForConnect<MountState>(
    ref,
    mountStateProvider,
    deviceIdOf: (s) => s.deviceId,
    isConnected: (s) => s.connectionState == DeviceConnectionState.connected,
    invalidate: (id) => ref.invalidate(equipmentMountCapabilitiesProvider(id)),
  );
  _listenForConnect<FocuserState>(
    ref,
    focuserStateProvider,
    deviceIdOf: (s) => s.deviceId,
    isConnected: (s) => s.connectionState == DeviceConnectionState.connected,
    invalidate: (id) =>
        ref.invalidate(equipmentFocuserCapabilitiesProvider(id)),
  );
  _listenForConnect<FilterWheelState>(
    ref,
    filterWheelStateProvider,
    deviceIdOf: (s) => s.deviceId,
    isConnected: (s) => s.connectionState == DeviceConnectionState.connected,
    invalidate: (id) =>
        ref.invalidate(equipmentFilterWheelCapabilitiesProvider(id)),
  );
  _listenForConnect<RotatorState>(
    ref,
    rotatorStateProvider,
    deviceIdOf: (s) => s.deviceId,
    isConnected: (s) => s.connectionState == DeviceConnectionState.connected,
    invalidate: (id) =>
        ref.invalidate(equipmentRotatorCapabilitiesProvider(id)),
  );
  _listenForConnect<DomeState>(
    ref,
    domeStateProvider,
    deviceIdOf: (s) => s.deviceId,
    isConnected: (s) => s.connectionState == DeviceConnectionState.connected,
    invalidate: (id) => ref.invalidate(equipmentDomeCapabilitiesProvider(id)),
  );
  _listenForConnect<CoverCalibratorState>(
    ref,
    coverCalibratorStateProvider,
    deviceIdOf: (s) => s.deviceId,
    isConnected: (s) => s.connectionState == DeviceConnectionState.connected,
    invalidate: (id) =>
        ref.invalidate(equipmentCoverCalibratorCapabilitiesProvider(id)),
  );
});

void _listenForConnect<T>(
  Ref ref,
  ProviderListenable<T> provider, {
  required String? Function(T) deviceIdOf,
  required bool Function(T) isConnected,
  required void Function(String deviceId) invalidate,
}) {
  ref.listen<T>(provider, (previous, next) {
    // Fire only on the disconnected/connecting → connected EDGE so we don't
    // thrash the cache on every status tick.
    final wasConnected = previous != null && isConnected(previous);
    final nowConnected = isConnected(next);
    if (!wasConnected && nowConnected) {
      final id = deviceIdOf(next);
      if (id != null && id.isNotEmpty) {
        invalidate(id);
      }
    }
  });
}
