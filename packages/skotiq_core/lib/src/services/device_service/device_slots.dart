part of '../device_service.dart';

extension _DeviceServiceSlots on DeviceService {
  /// Release the device about to be displaced from its type slot.
  ///
  /// Each device type owns exactly ONE notifier slot. Connecting a second
  /// device of the same type overwrote that slot while the incumbent's driver
  /// connection stayed open, and because every disconnect path matches on the
  /// slot's `deviceId`, the displaced device became unaddressable — its
  /// ASCOM/native handle stayed open for the rest of the session. Verified on
  /// the rig: after a simulator mount took the slot, a real NYX-101 kept
  /// answering position polls, `/api/devices/connected` listed both mounts, and
  /// `POST /api/devices/disconnect` for the real one returned
  /// `device_id_mismatch` — so nothing could ever close it. The same hole is
  /// reachable from the equipment dropdown and from activating a profile that
  /// names a different device for a type.
  ///
  /// Hand the slot over through the incumbent's own `_disconnectX` so the
  /// type-specific teardown (cooler off, heartbeat stop, pollers) still runs.
  ///
  /// Fail-soft: a displaced device whose cable is already gone must not block
  /// the incoming connect, so a failed teardown is logged and swallowed.
  Future<void> _releaseDisplacedDevice(
    DeviceType type,
    String incomingDeviceId,
  ) async {
    final currentId = _slotDeviceIdFor(type);
    if (currentId == null ||
        currentId.isEmpty ||
        currentId == incomingDeviceId) {
      return;
    }
    _safeLog(
      (l) => l.info(
        'Connecting ${type.name} $incomingDeviceId displaces $currentId; '
        'disconnecting the incumbent first so its driver handle is released',
        source: 'DeviceService',
      ),
      'device-slot-handover',
    );
    try {
      await _disconnect(type);
    } catch (e) {
      _safeLog(
        (l) => l.warning(
          'Displaced ${type.name} $currentId did not disconnect cleanly: $e',
          source: 'DeviceService',
        ),
        'device-slot-handover-failed',
      );
    }
  }

  /// deviceId currently held in [type]'s notifier slot, or `null` when the
  /// slot is empty. `setDisconnected()` resets the state object, so a
  /// non-null id here means a device still owns the slot.
  String? _slotDeviceIdFor(DeviceType type) =>
      readDeviceSlot(_ref.container, type).deviceId;

  /// The id of the device of [type] that is connected RIGHT NOW, or `null`.
  ///
  /// An equipment profile is connection intent, not live command authority:
  /// falling back to it while disconnected can send a command to a stale device
  /// on the current backend. So this reads only live connection state, and an
  /// empty id counts as no device.
  ///
  /// The per-type `_getCameraDeviceId` / `_getFocuserDeviceId` /
  /// `_getRotatorDeviceId` / `_getFilterWheelDeviceId` / `_getGuiderDeviceId`
  /// wrappers all delegate here; four of them keep a `Future` return type
  /// purely because ~20 call sites `await` them.
  String? _connectedDeviceIdFor(DeviceType type) {
    final slot = readDeviceSlot(_ref.container, type);
    final deviceId = slot.deviceId;
    if (slot.connectionState == DeviceConnectionState.connected &&
        deviceId != null &&
        deviceId.isNotEmpty) {
      return deviceId;
    }
    return null;
  }

  /// Whether [deviceId] is STILL the connected device of [type] — the guard a
  /// long-running move/verify loop re-checks between polls, so a disconnect (or
  /// a swap to a different device in the same slot) stops it.
  bool _isStillConnectedTo(DeviceType type, String deviceId) {
    final slot = readDeviceSlot(_ref.container, type);
    return slot.connectionState == DeviceConnectionState.connected &&
        slot.deviceId == deviceId;
  }
}
