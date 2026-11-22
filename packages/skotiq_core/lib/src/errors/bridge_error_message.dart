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
/// reconnecting can help, the technical message, the sentence a person reads
/// ([SkotiqError.userMessage]) and the sentence the driver authored
/// ([SkotiqError.reason]).
SkotiqError skotiqErrorFromBridge(bridge.SkotiqError error) {
  final (:core, :shown, sentence: _) = _bridgeErrorTexts(error);
  return SkotiqError(
    category: core.category,
    message: core.message,
    userMessage: shown,
    isRecoverable: core.isRecoverable,
    shouldReconnect: core.shouldReconnect,
    isTimeout: core.isTimeout,
    deviceId: core.deviceId,
    errorCode: core.errorCode,
    reason: core.reason,
  );
}

/// The sentence the imaging host puts in its reply to a remote client for
/// [error].
String bridgeErrorSentence(bridge.SkotiqError error) =>
    _bridgeErrorTexts(error).sentence;

/// A bridge error as the core error ([core]), the sentence the host sends a
/// remote client ([sentence]) and the one this app shows ([shown]).
typedef _BridgeErrorTexts = ({SkotiqError core, String sentence, String shown});

/// The one table over the bridge's error union: each variant as the core
/// error and the sentence it is told in. A rewording lands here.
_BridgeErrorTexts _bridgeErrorTexts(bridge.SkotiqError error) {
  _BridgeErrorTexts told(SkotiqError core, String sentence) =>
      (core: core, sentence: sentence, shown: sentence);
  // `deviceId` is empty on the arms where the driver did not scope the
  // failure to one device; appending "(device )" there would be noise.
  String scoped(String sentence, String deviceId) =>
      deviceId.isEmpty ? sentence : '$sentence (device $deviceId)';
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
        isRecoverable: true,
        isTimeout: true,
        deviceId: deviceId,
        reason: deviceId == null ? operation : null,
      );
  const canceled = SkotiqError(
    category: system,
    message: 'Operation cancelled',
  );
  return error.when(
    deviceNotFound: (deviceId) => told(
      SkotiqError(
        category: connection,
        message: 'Device not found: $deviceId',
        deviceId: deviceId,
        reason: "Device '$deviceId' was not found",
      ),
      'Device not found: $deviceId',
    ),
    connectionFailed: (deviceId, reason) => told(
      SkotiqError(
        category: connection,
        message: 'Device connection failed: $deviceId - $reason',
        isRecoverable: true,
        shouldReconnect: true,
        deviceId: deviceId,
        reason: reason,
      ),
      'Could not connect to $deviceId: $reason',
    ),
    alreadyConnected: (deviceId) => told(
      SkotiqError(
        category: connection,
        message: 'Device already connected: $deviceId',
        deviceId: deviceId,
        reason: "'$deviceId' is already connected",
      ),
      'Device already connected: $deviceId',
    ),
    notConnected: (deviceId) => told(
      SkotiqError(
        category: connection,
        message: 'Device not connected: $deviceId',
        shouldReconnect: true,
        deviceId: deviceId,
        reason: "'$deviceId' is not connected",
      ),
      'Device not connected: $deviceId',
    ),
    deviceDisconnected: (deviceId, reason) => told(
      SkotiqError(
        category: connection,
        message: 'Device disconnected unexpectedly: $deviceId - $reason',
        isRecoverable: true,
        shouldReconnect: true,
        deviceId: deviceId,
        reason: reason,
      ),
      'Device $deviceId disconnected: $reason',
    ),
    hardwareError: (deviceId, message, errorCode) => told(
      SkotiqError(
        category: BackendErrorCategory.hardware,
        message: 'Hardware error: $deviceId - $message',
        isRecoverable: true,
        deviceId: deviceId,
        errorCode: errorCode,
        reason: message,
      ),
      'Hardware error on $deviceId: $message',
    ),
    communicationError: (deviceId, message) => told(
      SkotiqError(
        category: BackendErrorCategory.hardware,
        message: 'Communication error: $deviceId - $message',
        isRecoverable: true,
        shouldReconnect: true,
        deviceId: deviceId,
        reason: message,
      ),
      'Communication error with $deviceId: $message',
    ),
    timeout: (message) => told(timedOut(message, null, null), message),
    deviceTimeout: (deviceId, operation, timeoutSecs) => told(
      timedOut(operation, deviceId, timeoutSecs),
      '$deviceId timed out after ${timeoutSecs}s during $operation',
    ),
    connectionTimeout: (deviceId, timeoutSecs) => told(
      SkotiqError(
        category: BackendErrorCategory.timeout,
        message:
            'Connection timeout: $deviceId after '
            '${timeoutSecs.toStringAsFixed(1)}s',
        isRecoverable: true,
        isTimeout: true,
        shouldReconnect: true,
        deviceId: deviceId,
      ),
      'Connecting to $deviceId timed out after ${timeoutSecs}s',
    ),
    invalidParameter: (message) => told(
      SkotiqError(
        category: validation,
        message: 'Invalid parameter: $message',
        reason: message,
      ),
      message,
    ),
    invalidInput: (message) => told(
      SkotiqError(
        category: validation,
        message: 'Invalid input: $message',
        reason: message,
      ),
      message,
    ),
    invalidDeviceId: (deviceId, reason) => told(
      SkotiqError(
        category: validation,
        message: 'Invalid device ID: $deviceId - $reason',
        deviceId: deviceId,
        reason: reason,
      ),
      scoped(reason, deviceId),
    ),
    parameterOutOfRange: (paramName, value, min, max) => told(
      SkotiqError(
        category: validation,
        message:
            'Parameter out of range: $paramName = $value (valid: $min to $max)',
      ),
      '$paramName $value is outside the valid range $min to $max',
    ),
    operationFailed: (message) => told(
      SkotiqError(
        category: system,
        message: 'Operation failed: $message',
        isRecoverable: true,
        reason: message,
      ),
      message,
    ),
    notSupported: (deviceId, operation) => told(
      SkotiqError(
        category: BackendErrorCategory.unsupported,
        message: 'Operation not supported: $operation on device $deviceId',
        deviceId: deviceId,
        reason: "'$deviceId' does not support $operation",
      ),
      scoped(operation, deviceId),
    ),
    // A refusal reads as the variant it was raised as before it had a kind.
    refused: (kind, message) => told(switch (kind) {
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
    }, message),
    deviceBusy: (deviceId, currentOperation) => told(
      SkotiqError(
        category: BackendErrorCategory.busy,
        message: 'Device busy: $deviceId - $currentOperation',
        isRecoverable: true,
        deviceId: deviceId,
        reason: "'$deviceId' is busy with $currentOperation",
      ),
      '$deviceId is busy: $currentOperation',
    ),
    invalidState: (message) => told(
      SkotiqError(
        category: BackendErrorCategory.busy,
        message: message,
        reason: message,
      ),
      message,
    ),
    imageError: (message) => told(
      SkotiqError(
        category: imaging,
        message: 'Image error: $message',
        reason: message,
      ),
      message,
    ),
    cameraError: (message) => told(
      SkotiqError(
        category: imaging,
        message: 'Camera error: $message',
        reason: message,
      ),
      message,
    ),
    noImageAvailable: () => told(
      const SkotiqError(category: imaging, message: 'No image available'),
      'No image is available yet — capture an exposure first',
    ),
    exposureCancelled: () => told(canceled, 'Exposure canceled'),
    exposureFailed: (cameraId, reason) => told(
      SkotiqError(
        category: imaging,
        message: 'Exposure failed: $cameraId - $reason',
        deviceId: cameraId,
        reason: reason,
      ),
      reason,
    ),
    downloadFailed: (cameraId, reason) => told(
      SkotiqError(
        category: imaging,
        message: 'Image download failed: $cameraId - $reason',
        deviceId: cameraId,
        reason: reason,
      ),
      'Image download failed: $cameraId - $reason',
    ),
    ioError: (message) => told(
      SkotiqError(
        category: io,
        message: 'I/O error: $message',
        reason: message,
      ),
      message,
    ),
    serializationError: (message) => told(
      SkotiqError(
        category: io,
        message: 'Serialization error: $message',
        reason: message,
      ),
      message,
    ),
    plateSolveError: (message) => told(
      SkotiqError(
        category: io,
        message: 'Plate solve failed: $message',
        reason: message,
      ),
      message,
    ),
    sequenceError: (message) => told(
      SkotiqError(
        category: BackendErrorCategory.sequence,
        message: 'Sequence error: $message',
        reason: message,
      ),
      message,
    ),
    ascomError: (progId, message, errorCode) => told(
      SkotiqError(
        category: driver,
        message: 'ASCOM error: $progId - $message (code: $errorCode)',
        errorCode: errorCode,
        reason: message,
      ),
      'ASCOM driver $progId reported: $message (code $errorCode)',
    ),
    alpacaError: (baseUrl, deviceNumber, message, errorCode) => told(
      SkotiqError(
        category: driver,
        message:
            'Alpaca error: $baseUrl device $deviceNumber - $message '
            '(code: $errorCode)',
        errorCode: errorCode,
        reason: message,
      ),

      'Alpaca device $deviceNumber at $baseUrl reported: $message (code $errorCode)',
    ),
    indiError: (server, port, deviceName, message) => told(
      SkotiqError(
        category: driver,
        message: 'INDI error: $server:$port device $deviceName - $message',
        reason: message,
      ),
      'INDI device $deviceName on $server:$port reported: $message',
    ),
    nativeError: (vendor, message, errorCode) => told(
      SkotiqError(
        category: driver,
        message: 'Native SDK error: $vendor - $message (code: $errorCode)',
        errorCode: errorCode,
        reason: message,
      ),
      '$vendor SDK reported: $message (code $errorCode)',
    ),
    comError: (message, hresult) => told(
      SkotiqError(
        category: driver,
        message:
            'COM error: $message '
            '(HRESULT: 0x${hresult.toRadixString(16).padLeft(8, '0')})',
        errorCode: hresult,
        shouldReconnect: true,
        reason: message,
      ),

      'Windows COM call failed: $message (HRESULT 0x${hresult.toUnsigned(32).toRadixString(16)})',
    ),
    internal: (message) => told(
      SkotiqError(
        category: system,
        message: 'Internal error: $message',
        reason: message,
      ),
      message,
    ),
    cancelled: () => told(canceled, 'Operation canceled'),
    runtimeInitFailed: (message) => told(
      SkotiqError(
        category: system,
        message: 'Runtime initialization failed: $message',
        reason: message,
      ),
      message,
    ),
    resourceExhausted: (resource, message) => told(
      SkotiqError(
        category: system,
        message: 'Resource exhausted: $resource - $message',
        isRecoverable: true,
        reason: message,
      ),
      '$resource exhausted: $message',
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
