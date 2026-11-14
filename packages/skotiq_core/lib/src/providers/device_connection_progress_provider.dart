/// Per-device "Connect All" progress state.
///
/// `DeviceService.connectAllFromProfile` emits a [DeviceConnectProgress]
/// for every device in the sweep. This provider materializes those events
/// into a `Map<deviceType, DeviceConnectProgress>` snapshot so UI widgets
/// (per-device chips, banners, etc.) can `ref.watch` the current status of
/// any single device-type without having to subscribe to the stream
/// themselves.
///
/// Lifecycle:
/// * `startSweep()` clears any prior snapshot and marks the sweep as
///   in-flight so the UI can hide stale entries from previous runs.
/// * `record(event)` is called by the caller for every stream event;
///   the latest event per device-type overwrites the prior one (so
///   `connecting → connected` updates the same map slot in place).
/// * `endSweep()` flips `isSweeping` to `false` while preserving the
///   per-device final state so the UI can still render the result.
/// * `clear()` resets the provider for a fresh run.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/backend/device_types.dart' show guideCameraLabel;
import '../services/device_exceptions.dart';

/// Snapshot of the currently-active "Connect All" sweep.
class DeviceConnectionProgressState {
  /// Whether a sweep is currently in flight. UI can use this to hide the
  /// final chips once the user moves on, or to disable the button while
  /// connecting.
  final bool isSweeping;

  /// Per-device-type latest progress event. Key is the canonical device
  /// type string used by [DeviceConnectProgress.deviceType], e.g.
  /// `'camera'`, `'mount'`, ... .
  final Map<String, DeviceConnectProgress> byDeviceType;

  /// What kicked this sweep off, e.g. `'Connect All'` or
  /// `'Startup auto-connect'`. Rendered verbatim by the equipment screen's
  /// progress strip so an operator who finds a red `guider Failed` chip after
  /// launch knows it came from startup and not from a button they pressed.
  final String source;

  /// When the sweep finished, or null while it is still running / never ran.
  ///
  /// The strip outlives the sweep by design (it is how a failure is reviewed),
  /// so it MUST be able to date itself: an undated chip reading `camera
  /// Connected` sits next to a live "No devices connected" empty state after a
  /// Disconnect All and reads as current truth.
  final DateTime? finishedAt;

  const DeviceConnectionProgressState({
    required this.isSweeping,
    required this.byDeviceType,
    this.source = 'Connect All',
    this.finishedAt,
  });

  static const empty = DeviceConnectionProgressState(
    isSweeping: false,
    byDeviceType: <String, DeviceConnectProgress>{},
  );

  /// The outcome per device, counted the way the equipment screen counts
  /// devices: the built-in guider's guide camera is part of the guider, so
  /// it has no entry of its own and a guide camera that did not come up is
  /// the guider's outcome.
  Map<String, DeviceConnectProgress> get byDevice {
    final guideCamera = byDeviceType[guideCameraLabel];
    final guider = byDeviceType['guider'];
    if (guideCamera == null || guider == null) return byDeviceType;
    final devices = Map.of(byDeviceType)..remove(guideCameraLabel);
    if (guideCamera.status != DeviceConnectProgressStatus.connected) {
      devices['guider'] = DeviceConnectProgress(
        deviceType: guider.deviceType,
        deviceId: guider.deviceId,
        status: guideCamera.status,
        error: guideCamera.error,
        errorMessage: guideCamera.errorMessage == null
            ? null
            : 'Its guide camera did not connect: '
                  '${guideCamera.errorMessage}',
      );
    }
    return devices;
  }

  /// How many devices in this sweep ended up connected.
  int get connectedCount => byDevice.values
      .where((e) => e.status == DeviceConnectProgressStatus.connected)
      .length;

  /// The devices that did not connect, one entry per device as in
  /// [byDevice].
  List<DeviceConnectProgress> get failures => [
    for (final event in byDevice.values)
      if (event.status == DeviceConnectProgressStatus.failed) event,
  ];

  DeviceConnectionProgressState copyWith({
    bool? isSweeping,
    Map<String, DeviceConnectProgress>? byDeviceType,
    String? source,
    DateTime? finishedAt,
  }) {
    return DeviceConnectionProgressState(
      isSweeping: isSweeping ?? this.isSweeping,
      byDeviceType: byDeviceType ?? this.byDeviceType,
      source: source ?? this.source,
      finishedAt: finishedAt ?? this.finishedAt,
    );
  }
}

/// StateNotifier that aggregates [DeviceConnectProgress] events into a
/// per-device-type snapshot.
class DeviceConnectionProgressNotifier
    extends StateNotifier<DeviceConnectionProgressState> {
  DeviceConnectionProgressNotifier()
    : super(DeviceConnectionProgressState.empty);

  /// Begin a new sweep. Clears the prior snapshot so stale chips from a
  /// previous "Connect All" don't bleed into this run.
  void startSweep({String source = 'Connect All'}) {
    state = DeviceConnectionProgressState(
      isSweeping: true,
      byDeviceType: const <String, DeviceConnectProgress>{},
      source: source,
    );
  }

  /// Record a single progress event. The latest event per device-type
  /// overwrites the prior one so transitions (`connecting → connected`)
  /// update the same UI slot in place.
  void record(DeviceConnectProgress event) {
    final next = Map<String, DeviceConnectProgress>.from(state.byDeviceType);
    next[event.deviceType] = event;
    state = state.copyWith(byDeviceType: next);
  }

  /// Mark the sweep as finished. The per-device snapshot is preserved so
  /// the UI can still display the final outcome until the user clears it,
  /// stamped with the time it finished so it reads as a record and not as the
  /// devices' current state.
  void endSweep({DateTime? at}) {
    state = state.copyWith(isSweeping: false, finishedAt: at ?? DateTime.now());
  }

  /// Reset to the empty state (no sweep, no per-device entries).
  void clear() {
    state = DeviceConnectionProgressState.empty;
  }
}

/// Riverpod provider exposing the [DeviceConnectionProgressNotifier].
///
/// UI widgets can `ref.watch(deviceConnectionProgressProvider)` to react
/// to per-device progress in real time; the equipment screen pushes events
/// into this provider as it drains
/// `DeviceService.connectAllFromProfile(profile)`.
final deviceConnectionProgressProvider =
    StateNotifierProvider<
      DeviceConnectionProgressNotifier,
      DeviceConnectionProgressState
    >((ref) => DeviceConnectionProgressNotifier());
