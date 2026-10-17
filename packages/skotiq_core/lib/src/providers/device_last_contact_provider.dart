/// Per-device "last successful communication" state for the heartbeat panel.
///
/// The heartbeat monitor in Rust records `last_successful_comm` for **every**
/// device it polls and exposes it through `DeviceBackend.getDeviceHealth`, but
/// nothing on the Dart side ever asked for it. Only `CameraStateNotifier` kept
/// a timestamp of its own, so System Health could age exactly one device: the
/// camera read `OK - 12s ago` while the mount, focuser, filter wheel, dome and
/// weather station read `OK - last contact unknown` forever, and the score
/// above them stayed `100 - Excellent`. A panel whose whole job is to notice a
/// device going quiet could not notice it for five of the six device types.
///
/// Polling rather than listening is deliberate: `HeartbeatStatusChanged` is
/// only published on a *transition* (degraded, disconnected, recovered), never
/// on a healthy poll, so an event subscription can never learn that a steadily
/// healthy device is still answering. `getDeviceHealth` is a read of the
/// device map — cheap enough to ask every [DeviceLastContactNotifier.interval].
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backend_provider.dart';
import 'equipment_health_provider.dart' show connectedDeviceDescriptorsProvider;

/// One device's contact record as the backend reports it.
class DeviceContact {
  /// When the device last answered a heartbeat poll.
  final DateTime lastContact;

  /// Whether the backend still considers that recent enough to call the
  /// device responsive. Rust's threshold is 30 s; we take its answer rather
  /// than re-deriving one so the panel and the monitor cannot disagree.
  final bool isResponsive;

  const DeviceContact({required this.lastContact, required this.isResponsive});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceContact &&
          other.lastContact == lastContact &&
          other.isResponsive == isResponsive;

  @override
  int get hashCode => Object.hash(lastContact, isResponsive);
}

/// Signature of the backend call this notifier polls.
///
/// Returns `(lastSuccessfulCommunicationMs, isHealthy)`; a zero timestamp
/// means "this device has never answered", which is not the same as "answered
/// at the epoch" and must not be rendered as an age.
typedef DeviceHealthProbe = Future<(int, bool)> Function(String deviceId);

/// Holds the latest contact record for every device we are tracking.
class DeviceLastContactNotifier
    extends StateNotifier<Map<String, DeviceContact>> {
  DeviceLastContactNotifier({
    required DeviceHealthProbe probe,
    this.interval = const Duration(seconds: 10),
    bool autoStart = true,
  }) : _probe = probe,
       _autoStart = autoStart,
       super(const <String, DeviceContact>{});

  final DeviceHealthProbe _probe;
  final bool _autoStart;

  /// How often the tracked devices are re-probed.
  final Duration interval;

  Timer? _timer;
  Set<String> _tracked = const <String>{};
  Future<void>? _inFlight;

  /// Device ids currently being polled.
  Set<String> get trackedDevices => _tracked;

  /// Replace the tracked device set (the currently connected devices).
  ///
  /// Drops contact records for devices that are no longer connected so a
  /// disconnected device cannot leave a stale "last contact" behind, and
  /// refreshes immediately so a freshly connected device gets an age on its
  /// first frame instead of after one poll interval.
  void track(Iterable<String> deviceIds) {
    final next = deviceIds.where((id) => id.isNotEmpty).toSet();
    final changed =
        next.length != _tracked.length || !next.every(_tracked.contains);
    _tracked = next;
    if (next.isEmpty) {
      _timer?.cancel();
      _timer = null;
      if (state.isNotEmpty) state = const <String, DeviceContact>{};
      return;
    }
    if (changed) {
      final pruned = Map<String, DeviceContact>.fromEntries(
        state.entries.where((e) => next.contains(e.key)),
      );
      if (pruned.length != state.length) state = pruned;
      unawaited(refresh());
    }
    if (_autoStart) _timer ??= Timer.periodic(interval, (_) => refresh());
  }

  /// Probe every tracked device once. Safe to call directly from a test.
  ///
  /// Concurrent callers join the poll already in flight rather than being
  /// dropped, so `await refresh()` always means "a poll has completed".
  Future<void> refresh() {
    if (!mounted) return Future<void>.value();
    return _inFlight ??= _refresh().whenComplete(() => _inFlight = null);
  }

  Future<void> _refresh() async {
    try {
      final next = Map<String, DeviceContact>.from(state);
      var changed = false;
      for (final id in _tracked.toList(growable: false)) {
        try {
          final (ms, healthy) = await _probe(id);
          if (ms <= 0) {
            // Never answered. Leave the entry absent so the UI keeps saying
            // "last contact unknown" instead of rendering the epoch.
            if (next.remove(id) != null) changed = true;
            continue;
          }
          final record = DeviceContact(
            lastContact: DateTime.fromMillisecondsSinceEpoch(ms),
            isResponsive: healthy,
          );
          if (next[id] != record) {
            next[id] = record;
            changed = true;
          }
        } catch (_) {
          // A backend that cannot answer (disconnected host, device already
          // gone) is not evidence about the device's last contact — keep the
          // previous record rather than inventing or erasing one.
        }
      }
      if (!mounted) return;
      if (changed) state = next;
    } catch (_) {
      // Never let a poll failure escape into the zone; the per-device catch
      // above already handles the expected cases.
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

/// Live contact records for the connected devices.
///
/// Keeps itself pointed at whatever is connected by listening to
/// [connectedDeviceDescriptorsProvider].
final deviceLastContactProvider =
    StateNotifierProvider<
      DeviceLastContactNotifier,
      Map<String, DeviceContact>
    >((ref) {
      final notifier = DeviceLastContactNotifier(
        probe: (deviceId) =>
            ref.read(deviceBackendProvider).getDeviceHealth(deviceId),
      );
      ref.listen(
        connectedDeviceDescriptorsProvider,
        (previous, next) => notifier.track(next.map((d) => d.deviceId)),
        fireImmediately: true,
      );
      return notifier;
    });
