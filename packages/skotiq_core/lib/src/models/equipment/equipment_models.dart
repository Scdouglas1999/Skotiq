import 'package:equatable/equatable.dart';

import '../backend/device_capabilities.dart' show TrackingRate;
import '../../errors/error_text.dart';
import '../../errors/error_text_kind.dart';
import '../errors/skotiq_error.dart';

// Re-export TrackingRate from device_capabilities as the canonical source
export '../backend/device_capabilities.dart' show TrackingRate;

part 'equipment_models/camera_and_mount_states.dart';
part 'equipment_models/focus_filter_and_guider_states.dart';
part 'equipment_models/rotator_and_dome_states.dart';
part 'equipment_models/environment_and_safety_states.dart';
part 'equipment_models/switch_and_cover_calibrator_states.dart';

enum DeviceConnectionState { disconnected, connecting, connected, error }

/// The connection half that every device state carries, so one notifier base
/// and one device table can read and write it without knowing the device.
abstract interface class DeviceSlotState<S> {
  DeviceConnectionState get connectionState;
  String? get deviceId;
  String? get deviceName;
  DeviceError? get lastError;
  bool get autoReconnectEnabled;

  S copyWith({
    DeviceConnectionState? connectionState,
    String? deviceId,
    String? deviceName,
    DeviceError? lastError,
    bool? autoReconnectEnabled,
    bool clearError,
  });
}

extension DeviceSlotRetryTarget on DeviceSlotState<Object?> {
  /// The device a retry connects: the one the slot holds, or the one that
  /// last failed to connect there (a failed connect leaves the slot empty).
  String? get retryDeviceId => deviceId ?? lastError?.deviceId;
}

enum DeviceErrorType {
  connectionFailed,

  deviceNotFound,

  timeout,

  driverError,

  invalidParameter,

  busy,

  permissionDenied,

  communicationError,

  unknown,
}

class DeviceError extends Equatable {
  final DeviceErrorType type;

  final String message;

  /// Optional error code from the device/driver
  final String? code;

  final DateTime timestamp;

  final String? deviceId;

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
  /// [error] as a device error. An error with no category of its own is
  /// classified from its text by [classifyErrorText]; the message is the
  /// sentence a person reads.
  factory DeviceError.fromException(
    Object error, {
    String? deviceId,
    int retryAttempts = 0,
  }) {
    if (error is DeviceError) return error;
    if (error is SkotiqError) {
      return DeviceError.fromSkotiqError(
        error,
        deviceId: deviceId,
        retryAttempts: retryAttempts,
      );
    }
    final message = userFacingError(error);
    final (type, recoverable) = switch (classifyErrorText(message)) {
      ErrorTextKind.timeout => (DeviceErrorType.timeout, true),
      ErrorTextKind.notFound => (DeviceErrorType.deviceNotFound, false),
      ErrorTextKind.connection => (DeviceErrorType.connectionFailed, true),
      ErrorTextKind.permission => (DeviceErrorType.permissionDenied, false),
      ErrorTextKind.busy => (DeviceErrorType.busy, true),
      ErrorTextKind.hardware => (DeviceErrorType.communicationError, true),
      ErrorTextKind.invalid ||
      ErrorTextKind.unsupported => (DeviceErrorType.invalidParameter, true),
      ErrorTextKind.imaging ||
      ErrorTextKind.driver => (DeviceErrorType.driverError, true),
      ErrorTextKind.unknown => (DeviceErrorType.unknown, true),
    };
    return DeviceError(
      type: type,
      message: message,
      timestamp: DateTime.now(),
      deviceId: deviceId,
      retryAttempts: retryAttempts,
      recoverable: recoverable,
    );
  }

  factory DeviceError.fromSkotiqError(
    SkotiqError error, {
    String? deviceId,
    int retryAttempts = 0,
  }) {
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
