part of '../../device_service.dart';

/// Simulator campaign 2026-07-28 (S1): a read failure moves the device to
/// `error`, and polling only `connected` devices meant the poll loop dropped
/// the source permanently — a sensor that came back stayed unread until the
/// operator reconnected it by hand. Keep polling a faulted device that still
/// has an id so recovery is detected.
bool _shouldPollEnvironmentSource(DeviceConnectionState state) =>
    state == DeviceConnectionState.connected ||
    state == DeviceConnectionState.error;

/// Map the raw ASCOM shutter code onto the UI enum. `null` (driver does not
/// implement the property, or reported an unrecognised code) stays
/// [ShutterStatus.unknown] instead of defaulting to `closed`.
ShutterStatus _shutterStatusFromCode(int? code) {
  switch (code) {
    case 0:
      return ShutterStatus.open;
    case 1:
      return ShutterStatus.closed;
    case 2:
      return ShutterStatus.opening;
    case 3:
      return ShutterStatus.closing;
    case 4:
      return ShutterStatus.error;
    default:
      return ShutterStatus.unknown;
  }
}
