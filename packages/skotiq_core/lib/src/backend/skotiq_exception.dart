/// Structured exception types for Skotiq backend operations.
///
/// This module provides a Dart exception hierarchy that mirrors the Rust
/// SkotiqError enum, enabling rich error handling across the FFI boundary.
library;

/// Base exception for all Skotiq backend errors.
///
/// This provides a structured error with:
/// - Category classification for error handling strategies
/// - User-friendly messages for UI display
/// - Recovery hints (retryable, needs reconnection, etc.)
/// - Optional device and error code context
class SkotiqException implements Exception {
  /// Error category (timeout, connection, hardware, validation, etc.)
  final String category;

  /// Technical error message
  final String message;

  /// User-friendly message for UI display
  final String userMessage;

  /// Whether the operation can be retried
  final bool isRecoverable;

  /// Whether reconnection should be attempted before retry
  final bool shouldReconnect;

  final bool isTimeout;

  /// Device ID if this is a device-related error
  final String? deviceId;

  /// Vendor-specific error code if available
  final int? errorCode;

  const SkotiqException({
    required this.category,
    required this.message,
    required this.userMessage,
    this.isRecoverable = false,
    this.shouldReconnect = false,
    this.isTimeout = false,
    this.deviceId,
    this.errorCode,
  });

  @override
  String toString() => 'SkotiqException($category): $message';

  /// Check if this is a cancellation (not really an error)
  bool get isCancellation =>
      message.toLowerCase().contains('cancelled') ||
      message.toLowerCase().contains('canceled');

  /// Check if this is a hardware error requiring user attention
  bool get isHardwareError => category == 'hardware' || category == 'driver';

  bool get isValidationError => category == 'validation';
}

/// Connection-related exceptions (device not found, disconnected, etc.)
class ConnectionException extends SkotiqException {
  const ConnectionException({
    required super.message,
    required super.userMessage,
    super.isRecoverable = true,
    super.shouldReconnect = true,
    super.deviceId,
  }) : super(category: 'connection', isTimeout: false);

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

class HardwareException extends SkotiqException {
  const HardwareException({
    required super.message,
    required super.userMessage,
    super.isRecoverable = true,
    super.deviceId,
    super.errorCode,
  }) : super(category: 'hardware', shouldReconnect: false, isTimeout: false);
}

class TimeoutException extends SkotiqException {
  const TimeoutException({
    required super.message,
    required super.userMessage,
    super.deviceId,
  }) : super(
         category: 'timeout',
         isRecoverable: true,
         shouldReconnect: false,
         isTimeout: true,
       );

  factory TimeoutException.device(String deviceId, String operation) {
    return TimeoutException(
      message: 'Device timeout: $deviceId operation "$operation"',
      userMessage: 'Operation "$operation" timed out',
      deviceId: deviceId,
    );
  }
}

class ValidationException extends SkotiqException {
  const ValidationException({
    required super.message,
    required super.userMessage,
  }) : super(
         category: 'validation',
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

class UnsupportedOperationException extends SkotiqException {
  const UnsupportedOperationException({
    required super.message,
    required super.userMessage,
    super.deviceId,
  }) : super(
         category: 'unsupported',
         isRecoverable: false,
         shouldReconnect: false,
         isTimeout: false,
       );
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
         category: 'busy',
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
  }) : super(category: 'imaging', shouldReconnect: false, isTimeout: false);

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
        category: 'io',
        isRecoverable: false,
        shouldReconnect: false,
        isTimeout: false,
      );
}

class SequenceException extends SkotiqException {
  const SequenceException({required super.message, required super.userMessage})
    : super(
        category: 'sequence',
        isRecoverable: false,
        shouldReconnect: false,
        isTimeout: false,
      );
}

/// Driver-specific exceptions (ASCOM, Alpaca, INDI, Native SDK)
class DriverException extends SkotiqException {
  /// Driver type (ascom, alpaca, indi, native)
  final String? driverType;

  const DriverException({
    required super.message,
    required super.userMessage,
    super.isRecoverable = false,
    super.deviceId,
    super.errorCode,
    this.driverType,
  }) : super(category: 'driver', shouldReconnect: false, isTimeout: false);
}
