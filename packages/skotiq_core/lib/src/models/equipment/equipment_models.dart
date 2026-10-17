import 'package:equatable/equatable.dart';

import '../backend/device_capabilities.dart' show TrackingRate;
import '../errors/skotiq_error.dart';

// Re-export TrackingRate from device_capabilities as the canonical source
export '../backend/device_capabilities.dart' show TrackingRate;

part 'equipment_models/camera_and_mount_states.dart';
part 'equipment_models/focus_filter_and_guider_states.dart';
part 'equipment_models/rotator_and_dome_states.dart';
part 'equipment_models/environment_and_safety_states.dart';
part 'equipment_models/switch_and_cover_calibrator_states.dart';

/// Base device state
enum DeviceConnectionState { disconnected, connecting, connected, error }

/// Device error types for categorized error handling
enum DeviceErrorType {
  /// Connection to device failed
  connectionFailed,

  /// Device was not found
  deviceNotFound,

  /// Operation timed out
  timeout,

  /// Device driver error
  driverError,

  /// Invalid parameter passed
  invalidParameter,

  /// Device is busy
  busy,

  /// Permission denied
  permissionDenied,

  /// Communication error
  communicationError,

  /// Unknown error
  unknown,
}

/// Represents an error from a device operation
class DeviceError extends Equatable {
  /// Type of error
  final DeviceErrorType type;

  /// Human-readable error message
  final String message;

  /// Optional error code from the device/driver
  final String? code;

  /// When the error occurred
  final DateTime timestamp;

  /// Device ID that caused the error
  final String? deviceId;

  /// Number of retry attempts made
  final int retryAttempts;

  /// Whether this error is recoverable (can retry)
  final bool recoverable;

  const DeviceError({
    required this.type,
    required this.message,
    this.code,
    required this.timestamp,
    this.deviceId,
    this.retryAttempts = 0,
    this.recoverable = true,
  });

  /// Create a DeviceError from an exception
  ///
  /// If the exception is a [SkotiqError], the structured error information
  /// is extracted directly. Otherwise, the error message is parsed to determine
  /// the error category.
  factory DeviceError.fromException(
    Object error, {
    String? deviceId,
    int retryAttempts = 0,
  }) {
    // If it's already a SkotiqError, convert directly
    if (error is SkotiqError) {
      return DeviceError.fromSkotiqError(
        error,
        deviceId: deviceId,
        retryAttempts: retryAttempts,
      );
    }

    final message = error.toString();
    final normalized = message.toLowerCase();

    // Try to categorize the error from the message
    DeviceErrorType type = DeviceErrorType.unknown;
    bool recoverable = true;

    if (normalized.contains('timeout') || normalized.contains('timed out')) {
      type = DeviceErrorType.timeout;
    } else if (normalized.contains('not found') ||
        normalized.contains('notfound')) {
      type = DeviceErrorType.deviceNotFound;
      recoverable = false;
    } else if (normalized.contains('connection') ||
        normalized.contains('connect')) {
      type = DeviceErrorType.connectionFailed;
    } else if (normalized.contains('driver')) {
      type = DeviceErrorType.driverError;
    } else if (normalized.contains('busy')) {
      type = DeviceErrorType.busy;
    } else if (normalized.contains('permission') ||
        normalized.contains('denied')) {
      type = DeviceErrorType.permissionDenied;
      recoverable = false;
    }

    return DeviceError(
      type: type,
      message: message,
      timestamp: DateTime.now(),
      deviceId: deviceId,
      retryAttempts: retryAttempts,
      recoverable: recoverable,
    );
  }

  /// Create a DeviceError from a structured [SkotiqError]
  ///
  /// This provides a more accurate conversion using the structured error
  /// information from the native backend.
  factory DeviceError.fromSkotiqError(
    SkotiqError error, {
    String? deviceId,
    int retryAttempts = 0,
  }) {
    // Map BackendErrorCategory to DeviceErrorType
    final type = switch (error.category) {
      BackendErrorCategory.connection => DeviceErrorType.connectionFailed,
      BackendErrorCategory.hardware => DeviceErrorType.communicationError,
      BackendErrorCategory.timeout => DeviceErrorType.timeout,
      BackendErrorCategory.validation => DeviceErrorType.invalidParameter,
      BackendErrorCategory.unsupported => DeviceErrorType.invalidParameter,
      BackendErrorCategory.busy => DeviceErrorType.busy,
      BackendErrorCategory.imaging => DeviceErrorType.driverError,
      BackendErrorCategory.io => DeviceErrorType.driverError,
      BackendErrorCategory.sequence => DeviceErrorType.driverError,
      BackendErrorCategory.driver => DeviceErrorType.driverError,
      BackendErrorCategory.system => DeviceErrorType.unknown,
      BackendErrorCategory.unknown => DeviceErrorType.unknown,
    };

    // Determine recoverability - prefer SkotiqError's assessment
    final recoverable = error.isRecoverable;

    return DeviceError(
      type: type,
      message: error.userMessage,
      code: error.errorCode?.toString(),
      timestamp: DateTime.now(),
      deviceId: deviceId ?? error.deviceId,
      retryAttempts: retryAttempts,
      recoverable: recoverable,
    );
  }

  /// Get a user-friendly description of the error
  String get userMessage {
    switch (type) {
      case DeviceErrorType.connectionFailed:
        return 'Failed to connect to device. Please check the device is powered on and connected.';
      case DeviceErrorType.deviceNotFound:
        return 'Device not found. The device may have been disconnected or is not available.';
      case DeviceErrorType.timeout:
        return 'Operation timed out. The device may be unresponsive.';
      case DeviceErrorType.driverError:
        return 'Device driver error. Try restarting the device or reinstalling drivers.';
      case DeviceErrorType.invalidParameter:
        return 'Invalid parameter. The requested operation is not supported.';
      case DeviceErrorType.busy:
        return 'Device is busy. Please wait and try again.';
      case DeviceErrorType.permissionDenied:
        return 'Permission denied. The device may be in use by another application.';
      case DeviceErrorType.communicationError:
        return 'Communication error. Check the connection to the device.';
      case DeviceErrorType.unknown:
        return message.isNotEmpty ? message : 'An unknown error occurred.';
    }
  }

  /// Get a suggested recovery action
  String? get suggestedAction {
    switch (type) {
      case DeviceErrorType.connectionFailed:
        return 'Try reconnecting or restart the device.';
      case DeviceErrorType.deviceNotFound:
        return 'Check device connections and refresh the device list.';
      case DeviceErrorType.timeout:
        return 'Wait a moment and try again. Consider increasing timeout settings.';
      case DeviceErrorType.driverError:
        return 'Update or reinstall device drivers.';
      case DeviceErrorType.busy:
        return 'Wait for the current operation to complete.';
      case DeviceErrorType.permissionDenied:
        return 'Close other applications using this device.';
      case DeviceErrorType.communicationError:
        return 'Check cables and connections.';
      default:
        return null;
    }
  }

  @override
  List<Object?> get props => [
    type,
    message,
    code,
    timestamp,
    deviceId,
    retryAttempts,
    recoverable,
  ];

  @override
  String toString() =>
      'DeviceError(type: $type, message: $message, deviceId: $deviceId)';
}
