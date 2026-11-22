import 'package:equatable/equatable.dart';

import '../backend/device_capabilities.dart' show TrackingRate;
import '../../errors/device_connect_exception.dart';
import '../../errors/error_text.dart';
import '../../errors/error_text_kind.dart';
import '../../errors/skotiq_error.dart';
import '../../errors/skotiq_exception.dart';

// Re-export TrackingRate from device_capabilities as the canonical source
export '../backend/device_capabilities.dart' show TrackingRate;
export 'guider_for_move.dart';

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

  /// [error] as a device error. A typed error is read by its category; one
  /// with no category of its own is classified from its text by
  /// [classifyErrorText]. The message is the sentence a person reads.
  ///
  /// An error Skotiq's Dart code raised ([SkotiqException]) takes its type
  /// from its category but whether it is recoverable from its text, as a
  /// device slot has always read it.
  factory DeviceError.fromException(
    Object error, {
    String? deviceId,
    int retryAttempts = 0,
  }) {
    if (error is DeviceError) return error;
    // A failed connect carries the native failure typed; the driver's own
    // sentence stays the message.
    if (error is DeviceConnectException) {
      final native = error.nativeError;
      if (native != null) {
        return DeviceError.fromSkotiqError(
          native,
          deviceId: deviceId ?? error.deviceId,
          retryAttempts: retryAttempts,
          message: userFacingError(error),
        );
      }
    }
    if (error is SkotiqError && error is! SkotiqException) {
      return DeviceError.fromSkotiqError(
        error,
        deviceId: deviceId,
        retryAttempts: retryAttempts,
      );
    }
    final message = userFacingError(error);
    final kind = classifyErrorText(message);
    final type = error is SkotiqException
        ? _typeOfCategory(error.category)
        : switch (kind) {
            ErrorTextKind.timeout => DeviceErrorType.timeout,
            ErrorTextKind.notFound => DeviceErrorType.deviceNotFound,
            ErrorTextKind.connection => DeviceErrorType.connectionFailed,
            ErrorTextKind.permission => DeviceErrorType.permissionDenied,
            ErrorTextKind.busy => DeviceErrorType.busy,
            ErrorTextKind.hardware => DeviceErrorType.communicationError,
            ErrorTextKind.invalid ||
            ErrorTextKind.unsupported => DeviceErrorType.invalidParameter,
            ErrorTextKind.imaging ||
            ErrorTextKind.driver => DeviceErrorType.driverError,
            ErrorTextKind.unknown => DeviceErrorType.unknown,
          };
    return DeviceError(
      type: type,
      message: message,
      timestamp: DateTime.now(),
      deviceId: deviceId ?? (error is SkotiqError ? error.deviceId : null),
      retryAttempts: retryAttempts,
      recoverable: kind.recoverable,
    );
  }

  factory DeviceError.fromSkotiqError(
    SkotiqError error, {
    String? deviceId,
    int retryAttempts = 0,
    String? message,
  }) {
    return DeviceError(
      type: _typeOfCategory(error.category),
      message: message ?? error.userMessage,
      code: error.errorCode?.toString(),
      timestamp: DateTime.now(),
      deviceId: deviceId ?? error.deviceId,
      retryAttempts: retryAttempts,
      recoverable: error.isRecoverable,
    );
  }

  static DeviceErrorType _typeOfCategory(BackendErrorCategory category) =>
      switch (category) {
        BackendErrorCategory.connection => DeviceErrorType.connectionFailed,
        BackendErrorCategory.hardware => DeviceErrorType.communicationError,
        BackendErrorCategory.timeout => DeviceErrorType.timeout,
        BackendErrorCategory.validation ||
        BackendErrorCategory.unsupported => DeviceErrorType.invalidParameter,
        BackendErrorCategory.busy => DeviceErrorType.busy,
        BackendErrorCategory.imaging ||
        BackendErrorCategory.io ||
        BackendErrorCategory.sequence ||
        BackendErrorCategory.driver => DeviceErrorType.driverError,
        BackendErrorCategory.system ||
        BackendErrorCategory.unknown => DeviceErrorType.unknown,
      };

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
