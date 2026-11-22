/// The bridge's error union read once, as the core [SkotiqError].
///
/// `SkotiqError` from the bridge is a flutter_rust_bridge freezed union, so
/// its `toString()` is the debug rendering — `SkotiqError.connectionFailed(
/// deviceId: localhost:11111, reason: …)`. Interpolating that into a status
/// line or a snackbar ships the Dart class name, the variant name and the
/// field names as product copy. [skotiqErrorFromBridge] is the one switch over
/// the union: a new Rust variant lands here and nowhere else in Dart.
///
/// UI packages reach this through `package:skotiq_core`; the bridge stays
/// an implementation detail of the backend layer (architecture §1).
library;

import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

import 'skotiq_error.dart';

/// [error] as the core error: its category, whether trying again or
/// reconnecting can help, the technical and the user message, and the
/// sentence the driver authored ([SkotiqError.reason]).
SkotiqError skotiqErrorFromBridge(bridge.SkotiqError error) {
  const connection = BackendErrorCategory.connection;
  const validation = BackendErrorCategory.validation;
  const imaging = BackendErrorCategory.imaging;
  const io = BackendErrorCategory.io;
  const driver = BackendErrorCategory.driver;
  const system = BackendErrorCategory.system;
  SkotiqError timedOut(String operation, String? deviceId, double? secs) =>
      SkotiqError(
        category: BackendErrorCategory.timeout,
        message:
            'Operation timed out: $operation'
            '${secs != null ? ' after ${secs.toStringAsFixed(1)}s' : ''}',
        userMessage: 'Operation timed out: $operation',
        isRecoverable: true,
        isTimeout: true,
        deviceId: deviceId,
        reason: deviceId == null ? operation : null,
      );
  const canceled = SkotiqError(
    category: system,
    message: 'Operation cancelled',
    userMessage: 'Operation canceled',
  );
  return error.when(
    deviceNotFound: (deviceId) => SkotiqError(
      category: connection,
      message: 'Device not found: $deviceId',
      userMessage: "Device '$deviceId' not found",
      deviceId: deviceId,
      reason: "Device '$deviceId' was not found",
    ),
    connectionFailed: (deviceId, reason) => SkotiqError(
      category: connection,
      message: 'Device connection failed: $deviceId - $reason',
      userMessage: "Could not connect to '$deviceId'",
      isRecoverable: true,
      shouldReconnect: true,
      deviceId: deviceId,
      reason: reason,
    ),
    alreadyConnected: (deviceId) => SkotiqError(
      category: connection,
      message: 'Device already connected: $deviceId',
      userMessage: "'$deviceId' is already connected",
      deviceId: deviceId,
      reason: "'$deviceId' is already connected",
    ),
    notConnected: (deviceId) => SkotiqError(
      category: connection,
      message: 'Device not connected: $deviceId',
      userMessage: "'$deviceId' is not connected",
      shouldReconnect: true,
      deviceId: deviceId,
      reason: "'$deviceId' is not connected",
    ),
    deviceDisconnected: (deviceId, reason) => SkotiqError(
      category: connection,
      message: 'Device disconnected unexpectedly: $deviceId - $reason',
      userMessage: "'$deviceId' disconnected unexpectedly",
      isRecoverable: true,
      shouldReconnect: true,
      deviceId: deviceId,
      reason: reason,
    ),
    hardwareError: (deviceId, message, errorCode) => SkotiqError(
      category: BackendErrorCategory.hardware,
      message: 'Hardware error: $deviceId - $message',
      userMessage: "Hardware error on '$deviceId': $message",
      isRecoverable: true,
      deviceId: deviceId,
      errorCode: errorCode,
      reason: message,
    ),
    communicationError: (deviceId, message) => SkotiqError(
      category: BackendErrorCategory.hardware,
      message: 'Communication error: $deviceId - $message',
      userMessage: "Communication error with '$deviceId'",
      isRecoverable: true,
      shouldReconnect: true,
      deviceId: deviceId,
      reason: message,
    ),
    timeout: (message) => timedOut(message, null, null),
    deviceTimeout: (deviceId, operation, timeoutSecs) =>
        timedOut(operation, deviceId, timeoutSecs),
    connectionTimeout: (deviceId, timeoutSecs) => SkotiqError(
      category: BackendErrorCategory.timeout,
      message:
          'Connection timeout: $deviceId after '
          '${timeoutSecs.toStringAsFixed(1)}s',
      userMessage: "Connection to '$deviceId' timed out",
      isRecoverable: true,
      isTimeout: true,
      shouldReconnect: true,
      deviceId: deviceId,
    ),
    invalidParameter: (message) => SkotiqError(
      category: validation,
      message: 'Invalid parameter: $message',
      reason: message,
    ),
    invalidInput: (message) => SkotiqError(
      category: validation,
      message: 'Invalid input: $message',
      reason: message,
    ),
    invalidDeviceId: (deviceId, reason) => SkotiqError(
      category: validation,
      message: 'Invalid device ID: $deviceId - $reason',
      deviceId: deviceId,
      reason: reason,
    ),
    parameterOutOfRange: (paramName, value, min, max) => SkotiqError(
      category: validation,
      message:
          'Parameter out of range: $paramName = $value (valid: $min to $max)',
      userMessage: '$paramName value $value is out of range ($min to $max)',
    ),
    operationFailed: (message) => SkotiqError(
      category: system,
      message: 'Operation failed: $message',
      isRecoverable: true,
      reason: message,
    ),
    notSupported: (deviceId, operation) => SkotiqError(
      category: BackendErrorCategory.unsupported,
      message: 'Operation not supported: $operation on device $deviceId',
      userMessage: "'$deviceId' does not support: $operation",
      deviceId: deviceId,
      reason: "'$deviceId' does not support $operation",
    ),
    // A refusal reads as the variant it was raised as before it had a kind.
    refused: (kind, message) => switch (kind) {
      bridge.Refusal.lightLeak => SkotiqError(
        category: validation,
        message: 'Invalid input: $message',
        reason: message,
      ),
      _ => SkotiqError(
        category: system,
        message: 'Operation failed: $message',
        isRecoverable: true,
        reason: message,
      ),
    },
    deviceBusy: (deviceId, currentOperation) => SkotiqError(
      category: BackendErrorCategory.busy,
      message: 'Device busy: $deviceId - $currentOperation',
      userMessage: "'$deviceId' is busy: $currentOperation",
      isRecoverable: true,
      deviceId: deviceId,
      reason: "'$deviceId' is busy with $currentOperation",
    ),
    invalidState: (message) => SkotiqError(
      category: BackendErrorCategory.busy,
      message: message,
      reason: message,
    ),
    imageError: (message) => SkotiqError(
      category: imaging,
      message: 'Image error: $message',
      reason: message,
    ),
    cameraError: (message) => SkotiqError(
      category: imaging,
      message: 'Camera error: $message',
      reason: message,
    ),
    noImageAvailable: () =>
        const SkotiqError(category: imaging, message: 'No image available'),
    exposureCancelled: () => canceled,
    exposureFailed: (cameraId, reason) => SkotiqError(
      category: imaging,
      message: 'Exposure failed: $cameraId - $reason',
      userMessage: "Exposure failed on '$cameraId'",
      deviceId: cameraId,
      reason: reason,
    ),
    downloadFailed: (cameraId, reason) => SkotiqError(
      category: imaging,
      message: 'Image download failed: $cameraId - $reason',
      deviceId: cameraId,
      reason: reason,
    ),
    ioError: (message) => SkotiqError(
      category: io,
      message: 'I/O error: $message',
      reason: message,
    ),
    serializationError: (message) => SkotiqError(
      category: io,
      message: 'Serialization error: $message',
      reason: message,
    ),
    plateSolveError: (message) => SkotiqError(
      category: io,
      message: 'Plate solve failed: $message',
      reason: message,
    ),
    sequenceError: (message) => SkotiqError(
      category: BackendErrorCategory.sequence,
      message: 'Sequence error: $message',
      reason: message,
    ),
    ascomError: (progId, message, errorCode) => SkotiqError(
      category: driver,
      message: 'ASCOM error: $progId - $message (code: $errorCode)',
      errorCode: errorCode,
      reason: message,
    ),
    alpacaError: (baseUrl, deviceNumber, message, errorCode) => SkotiqError(
      category: driver,
      message:
          'Alpaca error: $baseUrl device $deviceNumber - $message '
          '(code: $errorCode)',
      errorCode: errorCode,
      reason: message,
    ),
    indiError: (server, port, deviceName, message) => SkotiqError(
      category: driver,
      message: 'INDI error: $server:$port device $deviceName - $message',
      reason: message,
    ),
    nativeError: (vendor, message, errorCode) => SkotiqError(
      category: driver,
      message: 'Native SDK error: $vendor - $message (code: $errorCode)',
      errorCode: errorCode,
      reason: message,
    ),
    comError: (message, hresult) => SkotiqError(
      category: driver,
      message:
          'COM error: $message '
          '(HRESULT: 0x${hresult.toRadixString(16).padLeft(8, '0')})',
      errorCode: hresult,
      shouldReconnect: true,
      reason: message,
    ),
    internal: (message) => SkotiqError(
      category: system,
      message: 'Internal error: $message',
      reason: message,
    ),
    cancelled: () => canceled,
    runtimeInitFailed: (message) => SkotiqError(
      category: system,
      message: 'Runtime initialization failed: $message',
      reason: message,
    ),
    resourceExhausted: (resource, message) => SkotiqError(
      category: system,
      message: 'Resource exhausted: $resource - $message',
      isRecoverable: true,
      reason: message,
    ),
  );
}

/// The authored text inside a bridge `SkotiqError` ([SkotiqError.reason]).
///
/// Returns null when [error] is not a bridge error, and when the matched
/// variant's payload is only an identifier or a number (`cancelled`,
/// `parameterOutOfRange`, the device timeouts, …) — those carry their meaning
/// in values the caller must keep, so the caller renders them itself rather
/// than receiving a sentence with the numbers dropped.
String? bridgeErrorMessage(Object error) =>
    error is bridge.SkotiqError ? skotiqErrorFromBridge(error).reason : null;
