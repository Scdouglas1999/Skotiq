/// Single Dart seam for reading the authored sentence out of a bridge error.
///
/// `SkotiqError` is a flutter_rust_bridge freezed union, so its
/// `toString()` is the debug rendering — `SkotiqError.connectionFailed(
/// deviceId: localhost:11111, reason: …)`. Interpolating that into a status
/// line or a snackbar ships the Dart class name, the variant name and the
/// field names as product copy. Every variant carries the sentence the operator
/// needs in one of its fields, so read the field instead.
///
/// UI packages reach this through `package:skotiq_core`; the bridge stays
/// an implementation detail of the backend layer (architecture §1).
library;

import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

/// The authored text inside a bridge `SkotiqError`.
///
/// Returns null when [error] is not a bridge error, and when the matched
/// variant's payload is only an identifier or a number (`cancelled`,
/// `parameterOutOfRange`, the timeout family, …) — those carry their meaning in
/// values the caller must keep, so the caller renders them itself rather than
/// receiving a sentence with the numbers dropped.
String? bridgeErrorMessage(Object error) {
  if (error is! bridge.SkotiqError) return null;
  return error.maybeWhen(
    deviceNotFound: (deviceId) => "Device '$deviceId' was not found",
    connectionFailed: (_, reason) => reason,
    alreadyConnected: (deviceId) => "'$deviceId' is already connected",
    notConnected: (deviceId) => "'$deviceId' is not connected",
    deviceDisconnected: (_, reason) => reason,
    hardwareError: (_, message, __) => message,
    communicationError: (_, message) => message,
    timeout: (message) => message,
    invalidParameter: (message) => message,
    invalidInput: (message) => message,
    invalidDeviceId: (_, reason) => reason,
    operationFailed: (message) => message,
    notSupported: (deviceId, operation) =>
        "'$deviceId' does not support $operation",
    deviceBusy: (deviceId, currentOperation) =>
        "'$deviceId' is busy with $currentOperation",
    imageError: (message) => message,
    cameraError: (message) => message,
    exposureFailed: (_, reason) => reason,
    downloadFailed: (_, reason) => reason,
    ioError: (message) => message,
    serializationError: (message) => message,
    plateSolveError: (message) => message,
    sequenceError: (message) => message,
    ascomError: (_, message, __) => message,
    alpacaError: (_, __, message, ___) => message,
    indiError: (_, __, ___, message) => message,
    nativeError: (_, message, __) => message,
    comError: (message, _) => message,
    internal: (message) => message,
    runtimeInitFailed: (message) => message,
    resourceExhausted: (_, message) => message,
    orElse: () => null,
  );
}
