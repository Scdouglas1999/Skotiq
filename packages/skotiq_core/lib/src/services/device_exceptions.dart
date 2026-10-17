/// Typed exceptions thrown by [DeviceService] disconnect methods.
///
/// A disconnect on a device with no `deviceId` in its `*StateProvider` throws
/// [DeviceNotConnectedException]. Callers that iterate every device type (the
/// equipment screen's bulk-disconnect button, [DeviceService.disconnectAll])
/// catch that one type and continue, which keeps a profile's
/// selected-but-never-connected devices out of the toast feed without matching
/// on message text.
///
/// The exception stays narrow: broadening it to cover generic disconnect
/// failures (driver errors, stale handles, timeouts) would swallow the
/// failures the UI has to warn about.
library;

/// Thrown when a `DeviceService.disconnect<Type>()` is invoked on a device
/// that is not currently connected (no `deviceId` in the matching state
/// provider).
///
/// This is a precondition signal, not a hardware-level error. It indicates
/// that the caller asked to disconnect something that was never connected
/// in the first place, so there is nothing to do. UI consumers that issue
/// a "disconnect all" sweep should treat this exception as benign and skip
/// to the next device.
class DeviceNotConnectedException implements Exception {
  /// Friendly identifier of the device that was being disconnected, e.g.
  /// `'camera'`, `'filter wheel'`. Used by callers to compose log lines and
  /// (when appropriate) user-visible messages.
  final String deviceType;

  /// Human-readable description for logging / `toString`.
  final String message;

  const DeviceNotConnectedException(this.deviceType, [String? message])
    : message = message ?? 'No $deviceType is currently connected';

  @override
  String toString() => 'DeviceNotConnectedException($deviceType): $message';
}

/// Thrown when a `DeviceService.connect<Type>()` is called with a device id
/// that does not match any of Skotiq's known driver-prefix conventions
/// (see `kKnownDeviceIdPrefixes` in `utils/device_id.dart`).
///
/// Discovery is the wrong precondition for connect: requiring a fresh hardware
/// scan to validate a reconnect fails whenever the discovery cache has blipped
/// (USB hub flicker, backend swap). Connect does a cheap structural format
/// check and leaves "is this device reachable?" to the backend's
/// `connectDevice`, so only an outright malformed id (no recognized driver
/// prefix) trips this exception; every other failure propagates from the
/// backend.
class InvalidDeviceIdException implements Exception {
  /// The device id that failed format validation.
  final String deviceId;

  /// Friendly device type for the error message, e.g. `'camera'`.
  final String deviceType;

  const InvalidDeviceIdException(this.deviceType, this.deviceId);

  @override
  String toString() =>
      'InvalidDeviceIdException($deviceType): id "$deviceId" does not match '
      'any known driver prefix (ascom:, alpaca:, indi:, native:, simulator:, '
      'phd2, builtin_guider).';
}

/// Normal terminal outcome for a user-cancelled autofocus sweep.
///
/// Kept distinct from hardware/fit failures so UI surfaces can say
/// "cancelled" without alarming the operator or firing failure recovery.
class AutofocusCancelledException implements Exception {
  const AutofocusCancelledException();

  @override
  String toString() => 'Autofocus cancelled';
}

/// Per-device status emitted by [DeviceService.connectAllFromProfile] while
/// a "Connect All" sweep is in flight.
///
/// Replaces a sequential `await connectX(...)` loop that took
/// 30-50 s for a full profile and gave the user no per-device progress.
/// The service now connects every configured device-type in parallel and
/// emits a stream of these progress updates so the UI can render
/// per-device chips with live status without blocking on the slowest
/// device.
enum DeviceConnectProgressStatus {
  /// Sweep has started for this device type but the backend connect call
  /// has not yet returned.
  connecting,

  /// `connectDevice` returned successfully and the state notifier is now
  /// connected.
  connected,

  /// `connectDevice` threw. [DeviceConnectProgress.error] carries the
  /// raw error and [DeviceConnectProgress.errorMessage] a stringified
  /// form for UI display.
  failed,
}

/// Progress event emitted by [DeviceService.connectAllFromProfile].
///
/// A `failed` event carries the backend's error verbatim so the UI can show
/// it. The stream does not throw — per-device failures are reported as
/// `failed` events, never as stream errors, so one bad device cannot abort the
/// sweep.
class DeviceConnectProgress {
  /// Friendly device category being connected, e.g. `'camera'`, `'mount'`.
  final String deviceType;

  /// Device id that was passed to the connect call.
  final String deviceId;

  /// Current status of this device's connect attempt.
  final DeviceConnectProgressStatus status;

  /// Raw error object thrown by the backend, when [status] is `failed`.
  final Object? error;

  /// Stringified error for UI display, when [status] is `failed`.
  final String? errorMessage;

  const DeviceConnectProgress({
    required this.deviceType,
    required this.deviceId,
    required this.status,
    this.error,
    this.errorMessage,
  });

  @override
  String toString() =>
      'DeviceConnectProgress($deviceType=$deviceId, '
      'status=$status${errorMessage != null ? ", error=$errorMessage" : ""})';
}
