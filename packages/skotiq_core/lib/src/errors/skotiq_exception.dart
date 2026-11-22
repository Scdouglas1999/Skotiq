/// The errors Skotiq's own Dart code raises, as kinds of [SkotiqError].
library;

import 'skotiq_error.dart';

/// A [SkotiqError] raised by Skotiq's Dart code rather than read from the
/// native side or a host. Its text names the category.
class SkotiqException extends SkotiqError {
  const SkotiqException({
    required super.category,
    required super.message,
    required String super.userMessage,
    super.isRecoverable,
    super.shouldReconnect,
    super.isTimeout,
    super.deviceId,
    super.errorCode,
  });

  @override
  String toString() => 'SkotiqException(${category.name}): $message';
}

/// Connection-related exceptions (device not found, disconnected, etc.)
class ConnectionException extends SkotiqException {
  const ConnectionException({
    required super.message,
    required super.userMessage,
    super.isRecoverable = true,
    super.shouldReconnect = true,
    super.deviceId,
  }) : super(category: BackendErrorCategory.connection, isTimeout: false);

  factory ConnectionException.notFound(String deviceId) {
    return ConnectionException(
      message: 'Device not found: $deviceId',
      userMessage: 'Device "$deviceId" not found',
      deviceId: deviceId,
      isRecoverable: false,
      shouldReconnect: false,
    );
  }

  factory ConnectionException.disconnected(String deviceId, [String? reason]) {
    return ConnectionException(
      message:
          'Device disconnected: $deviceId${reason != null ? ' - $reason' : ''}',
      userMessage: '"$deviceId" disconnected unexpectedly',
      deviceId: deviceId,
    );
  }
}

class ValidationException extends SkotiqException {
  const ValidationException({
    required super.message,
    required super.userMessage,
  }) : super(
         category: BackendErrorCategory.validation,
         isRecoverable: false,
         shouldReconnect: false,
         isTimeout: false,
       );

  factory ValidationException.outOfRange(
    String paramName,
    dynamic value,
    dynamic min,
    dynamic max,
  ) {
    return ValidationException(
      message:
          'Parameter out of range: $paramName = $value (valid: $min to $max)',
      userMessage: '$paramName value $value is out of range ($min to $max)',
    );
  }
}

class DeviceBusyException extends SkotiqException {
  /// Current operation the device is performing
  final String? currentOperation;

  const DeviceBusyException({
    required super.message,
    required super.userMessage,
    super.deviceId,
    this.currentOperation,
  }) : super(
         category: BackendErrorCategory.busy,
         isRecoverable: true,
         shouldReconnect: false,
         isTimeout: false,
       );
}

class ImagingException extends SkotiqException {
  const ImagingException({
    required super.message,
    required super.userMessage,
    super.isRecoverable = false,
    super.deviceId,
  }) : super(
         category: BackendErrorCategory.imaging,
         shouldReconnect: false,
         isTimeout: false,
       );

  /// Exposure cancelled (not really an error)
  factory ImagingException.cancelled() {
    return const ImagingException(
      message: 'Exposure cancelled',
      userMessage: 'Exposure was canceled',
    );
  }

  factory ImagingException.noImage() {
    return const ImagingException(
      message: 'No image available',
      userMessage: 'No image is available',
    );
  }
}

/// I/O exceptions (file operations, plate solving)
class IoException extends SkotiqException {
  const IoException({required super.message, required super.userMessage})
    : super(
        category: BackendErrorCategory.io,
        isRecoverable: false,
        shouldReconnect: false,
        isTimeout: false,
      );
}
