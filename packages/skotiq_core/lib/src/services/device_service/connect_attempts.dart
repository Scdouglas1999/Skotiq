import 'dart:async';

/// What a native `Connected` event means, given this app's own connects.
enum ConnectedMeaning {
  /// The connect in flight opened the driver; its bring-up is still running.
  opened,

  /// The opening event of a connect that has since failed and is being let
  /// go of. The device is on its way out; the slot keeps showing the failure.
  stale,

  /// A connect this app had given up on (the call failed or timed out) came
  /// up after all. The device is connected and still needs its bring-up.
  late,

  /// No connect of this app's is involved: the native side reconnected the
  /// device, or another party (a linked client, the host) connected it.
  outside,
}

enum _Phase { inFlight, releasing, failed }

/// This app's own connect attempts, by device id.
///
/// The native side announces every connection change as an event, and the
/// connect call that caused it reports the same change as its result. The two
/// arrive in no fixed order, so the meaning of an event depends on where the
/// app's own attempt for that device stands. This is the one place that is
/// kept, and the one place the device service asks before it writes a slot
/// from an event.
class ConnectAttempts {
  ConnectAttempts({
    this.releaseWindow = const Duration(seconds: 10),
    this.lateWindow = const Duration(minutes: 2),
  });

  /// How long a failed attempt waits for the `Disconnected` of its release
  /// before the device counts as simply not connected.
  final Duration releaseWindow;

  /// How long after a failed attempt a `Connected` for the device still
  /// counts as that attempt coming up late. After it, a connection is
  /// somebody else's.
  final Duration lateWindow;

  final Map<String, _Phase> _phases = {};
  final Map<String, Timer> _timers = {};

  void began(String deviceId) => _set(deviceId, _Phase.inFlight);

  /// The device is connected and brought up.
  void cameUp(String deviceId) => _set(deviceId, null);

  /// The attempt failed. [releasing] when the driver had opened and the app
  /// is now disconnecting it; the `Disconnected` that follows is not a drop.
  void failed(String deviceId, {required bool releasing}) {
    if (releasing) {
      _set(deviceId, _Phase.releasing);
      _timers[deviceId] = Timer(releaseWindow, () => _setFailed(deviceId));
    } else {
      _setFailed(deviceId);
    }
  }

  /// The release of a failed attempt did not go through, so no
  /// `Disconnected` is coming.
  void releaseFailed(String deviceId) {
    if (_phases[deviceId] == _Phase.releasing) _setFailed(deviceId);
  }

  ConnectedMeaning onConnected(String deviceId) {
    switch (_phases[deviceId]) {
      case _Phase.inFlight:
        return ConnectedMeaning.opened;
      case _Phase.releasing:
        return ConnectedMeaning.stale;
      case _Phase.failed:
        _set(deviceId, null);
        return ConnectedMeaning.late;
      case null:
        return ConnectedMeaning.outside;
    }
  }

  /// Whether a `Disconnected` for [deviceId] is the release of a failed
  /// attempt rather than a device that dropped. A failed attempt is over
  /// either way; one in flight is not (the event is from before it).
  bool onDisconnected(String deviceId) {
    final phase = _phases[deviceId];
    if (phase != _Phase.inFlight) _set(deviceId, null);
    return phase == _Phase.releasing;
  }

  /// Whether this app has a connect of [deviceId] that is in flight or has
  /// just failed. A `Connecting` or `Error` for it then belongs to that
  /// connect: the connect has already set the slot, and its failure is
  /// reported by the connect call to whoever asked for it.
  bool isOwn(String deviceId) => _phases.containsKey(deviceId);

  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _phases.clear();
  }

  void _setFailed(String deviceId) {
    _set(deviceId, _Phase.failed);
    _timers[deviceId] = Timer(lateWindow, () => _set(deviceId, null));
  }

  void _set(String deviceId, _Phase? phase) {
    _timers.remove(deviceId)?.cancel();
    if (phase == null) {
      _phases.remove(deviceId);
    } else {
      _phases[deviceId] = phase;
    }
  }
}
