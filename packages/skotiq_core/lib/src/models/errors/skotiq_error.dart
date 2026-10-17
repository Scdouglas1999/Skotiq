/// Structured error types for Skotiq.
///
/// These types mirror the Rust error types from `native/bridge/src/error.rs`,
/// providing structured error information across FFI and network boundaries.
library;

/// Backend error category classifications.
///
/// These categories match the Rust `SkotiqError::error_category()` values.
enum BackendErrorCategory {
  /// Connection/discovery errors
  connection,

  /// Hardware-level errors
  hardware,

  /// Timeout errors
  timeout,

  /// Input validation errors
  validation,

  /// Unsupported operation errors
  unsupported,

  /// Device busy errors
  busy,

  /// Imaging/camera errors
  imaging,

  /// File I/O errors
  io,

  /// Sequence execution errors
  sequence,

  /// Driver-specific errors (ASCOM, Alpaca, INDI, native)
  driver,

  /// System/internal errors
  system,

  /// Unknown error category
  unknown,
}

/// Extension for parsing backend error category from strings
extension BackendErrorCategoryParsing on BackendErrorCategory {
  static BackendErrorCategory fromString(String value) {
    return switch (value.toLowerCase()) {
      'connection' => BackendErrorCategory.connection,
      'hardware' => BackendErrorCategory.hardware,
      'timeout' => BackendErrorCategory.timeout,
      'validation' => BackendErrorCategory.validation,
      'unsupported' => BackendErrorCategory.unsupported,
      'busy' => BackendErrorCategory.busy,
      'imaging' => BackendErrorCategory.imaging,
      'io' => BackendErrorCategory.io,
      'sequence' => BackendErrorCategory.sequence,
      'driver' => BackendErrorCategory.driver,
      'system' => BackendErrorCategory.system,
      _ => BackendErrorCategory.unknown,
    };
  }
}

/// Structured error information from the Skotiq native library.
///
/// This class mirrors the Rust `ErrorInfo` struct and provides all the
/// context needed to:
/// - Display appropriate error messages to users
/// - Decide whether to retry operations
/// - Determine if reconnection is needed
/// - Log errors with full context
class SkotiqError implements Exception {
  /// Error category (timeout, connection, hardware, validation, etc.)
  final BackendErrorCategory category;

  /// Human-readable error message (technical details)
  final String message;

  /// User-friendly message for UI display
  final String userMessage;

  /// Whether the operation can be retried with the same parameters
  final bool isRecoverable;

  /// Whether reconnection to the device should be attempted
  final bool shouldReconnect;

  /// Whether this was a timeout error
  final bool isTimeout;

  /// Device ID if error is device-related
  final String? deviceId;

  /// Vendor-specific error code if available (ASCOM, Alpaca, native SDK)
  final int? errorCode;

  const SkotiqError({
    required this.category,
    required this.message,
    String? userMessage,
    this.isRecoverable = false,
    this.shouldReconnect = false,
    this.isTimeout = false,
    this.deviceId,
    this.errorCode,
  }) : userMessage = userMessage ?? message;

  /// Create from JSON (for network transport and FRB bridge)
  factory SkotiqError.fromJson(Map<String, dynamic> json) {
    return SkotiqError(
      category: BackendErrorCategoryParsing.fromString(
        json['category'] as String? ?? 'unknown',
      ),
      message: json['message'] as String? ?? 'Unknown error',
      userMessage:
          json['user_message'] as String? ?? json['userMessage'] as String?,
      isRecoverable:
          json['is_recoverable'] as bool? ??
          json['isRecoverable'] as bool? ??
          false,
      shouldReconnect:
          json['should_reconnect'] as bool? ??
          json['shouldReconnect'] as bool? ??
          false,
      isTimeout:
          json['is_timeout'] as bool? ?? json['isTimeout'] as bool? ?? false,
      deviceId: json['device_id'] as String? ?? json['deviceId'] as String?,
      errorCode: json['error_code'] as int? ?? json['errorCode'] as int?,
    );
  }

  /// Convert to JSON (for network transport)
  Map<String, dynamic> toJson() => {
    'category': category.name,
    'message': message,
    'user_message': userMessage,
    'is_recoverable': isRecoverable,
    'should_reconnect': shouldReconnect,
    'is_timeout': isTimeout,
    'device_id': deviceId,
    'error_code': errorCode,
  };

  /// Parse error from a string message (for backward compatibility)
  ///
  /// This attempts to extract structure from legacy string-based errors.
  /// Prefer using [fromJson] when structured error data is available.
  factory SkotiqError.fromString(String message) {
    // Try to detect category from common patterns
    final lowerMessage = message.toLowerCase();

    BackendErrorCategory category = BackendErrorCategory.unknown;
    bool isRecoverable = false;
    bool shouldReconnect = false;
    bool isTimeout = false;
    String? deviceId;

    // Detect timeout errors
    if (lowerMessage.contains('timeout') ||
        lowerMessage.contains('timed out')) {
      category = BackendErrorCategory.timeout;
      isTimeout = true;
      isRecoverable = true;
    }
    // Detect connection errors
    else if (lowerMessage.contains('not connected') ||
        lowerMessage.contains('connection failed') ||
        lowerMessage.contains('disconnected')) {
      category = BackendErrorCategory.connection;
      shouldReconnect = true;
      isRecoverable = true;
    }
    // Detect hardware errors
    else if (lowerMessage.contains('hardware') ||
        lowerMessage.contains('communication error')) {
      category = BackendErrorCategory.hardware;
      isRecoverable = true;
    }
    // Detect busy errors
    else if (lowerMessage.contains('busy')) {
      category = BackendErrorCategory.busy;
      isRecoverable = true;
    }
    // Detect validation errors
    else if (lowerMessage.contains('invalid') ||
        lowerMessage.contains('out of range')) {
      category = BackendErrorCategory.validation;
    }
    // Detect unsupported operations
    else if (lowerMessage.contains('not supported') ||
        lowerMessage.contains('unsupported')) {
      category = BackendErrorCategory.unsupported;
    }
    // Detect imaging errors
    else if (lowerMessage.contains('exposure') ||
        lowerMessage.contains('camera') ||
        lowerMessage.contains('image')) {
      category = BackendErrorCategory.imaging;
    }
    // Detect driver errors
    else if (lowerMessage.contains('ascom') ||
        lowerMessage.contains('alpaca') ||
        lowerMessage.contains('indi')) {
      category = BackendErrorCategory.driver;
    }

    // Try to extract device ID from common patterns (simplified regex)
    final deviceRegex = RegExp(r'device:\s*(\S+)', caseSensitive: false);
    final deviceMatch = deviceRegex.firstMatch(message);
    if (deviceMatch != null) {
      deviceId = deviceMatch.group(1);
    }

    return SkotiqError(
      category: category,
      message: message,
      isRecoverable: isRecoverable,
      shouldReconnect: shouldReconnect,
      isTimeout: isTimeout,
      deviceId: deviceId,
    );
  }

  /// Create from a generic exception
  factory SkotiqError.fromException(
    Object exception, [
    StackTrace? stackTrace,
  ]) {
    if (exception is SkotiqError) {
      return exception;
    }
    return SkotiqError.fromString(exception.toString());
  }

  // Convenience constructors

  /// Create a device not found error
  factory SkotiqError.deviceNotFound(String deviceId) {
    return SkotiqError(
      category: BackendErrorCategory.connection,
      message: 'Device not found: $deviceId',
      userMessage: "Device '$deviceId' not found",
      deviceId: deviceId,
    );
  }

  /// Create a connection failed error
  factory SkotiqError.connectionFailed(String deviceId, String reason) {
    return SkotiqError(
      category: BackendErrorCategory.connection,
      message: 'Device connection failed: $deviceId - $reason',
      userMessage: "Could not connect to '$deviceId'",
      isRecoverable: true,
      shouldReconnect: true,
      deviceId: deviceId,
    );
  }

  /// Create a device not connected error
  factory SkotiqError.notConnected(String deviceId) {
    return SkotiqError(
      category: BackendErrorCategory.connection,
      message: 'Device not connected: $deviceId',
      userMessage: "'$deviceId' is not connected",
      shouldReconnect: true,
      deviceId: deviceId,
    );
  }

  /// Create a device disconnected error
  factory SkotiqError.deviceDisconnected(String deviceId, String reason) {
    return SkotiqError(
      category: BackendErrorCategory.connection,
      message: 'Device disconnected unexpectedly: $deviceId - $reason',
      userMessage: "'$deviceId' disconnected unexpectedly",
      isRecoverable: true,
      shouldReconnect: true,
      deviceId: deviceId,
    );
  }

  /// Create a timeout error
  factory SkotiqError.timeout(
    String operation, {
    String? deviceId,
    double? timeoutSecs,
  }) {
    final timeoutMsg = timeoutSecs != null
        ? ' after ${timeoutSecs.toStringAsFixed(1)}s'
        : '';
    return SkotiqError(
      category: BackendErrorCategory.timeout,
      message: 'Operation timed out: $operation$timeoutMsg',
      userMessage: 'Operation timed out: $operation',
      isRecoverable: true,
      isTimeout: true,
      deviceId: deviceId,
    );
  }

  /// Create an operation not supported error
  factory SkotiqError.notSupported(String deviceId, String operation) {
    return SkotiqError(
      category: BackendErrorCategory.unsupported,
      message: 'Operation not supported: $operation on device $deviceId',
      userMessage: "'$deviceId' does not support: $operation",
      deviceId: deviceId,
    );
  }

  /// Create a device busy error
  factory SkotiqError.deviceBusy(String deviceId, String currentOperation) {
    return SkotiqError(
      category: BackendErrorCategory.busy,
      message: 'Device busy: $deviceId - $currentOperation',
      userMessage: "'$deviceId' is busy: $currentOperation",
      isRecoverable: true,
      deviceId: deviceId,
    );
  }

  /// Create a hardware error
  factory SkotiqError.hardwareError(
    String deviceId,
    String message, {
    int? errorCode,
  }) {
    return SkotiqError(
      category: BackendErrorCategory.hardware,
      message: 'Hardware error: $deviceId - $message',
      userMessage: "Hardware error on '$deviceId': $message",
      isRecoverable: true,
      deviceId: deviceId,
      errorCode: errorCode,
    );
  }

  /// Create a cancelled operation error
  factory SkotiqError.cancelled() {
    return const SkotiqError(
      category: BackendErrorCategory.system,
      message: 'Operation cancelled',
      userMessage: 'Operation cancelled',
    );
  }

  /// Create an internal error
  factory SkotiqError.internal(String message) {
    return SkotiqError(
      category: BackendErrorCategory.system,
      message: 'Internal error: $message',
    );
  }

  // Classification methods

  /// Whether this is a hardware-level error
  bool get isHardwareError => category == BackendErrorCategory.hardware;

  /// Whether this is an unsupported operation error
  bool get isNotSupported => category == BackendErrorCategory.unsupported;

  /// Whether this is a validation/input error
  bool get isValidationError => category == BackendErrorCategory.validation;

  /// Whether this is a cancellation (not really an error)
  bool get isCancellation =>
      message.toLowerCase().contains('cancelled') ||
      message.toLowerCase().contains('canceled');

  @override
  String toString() => message;
}

/// A fail-closed, terminal server-identity error: the host we connected to
/// advertised a fingerprint that does not match the one the client pinned
/// (or advertised none while a pin was required).
///
/// This is deliberately a distinct type so the network backend can treat it
/// as *terminal* — unlike an ordinary [BackendErrorCategory.connection]
/// failure, a mismatched identity must NOT trigger the exponential-backoff
/// reconnect loop (that would keep re-contacting a host whose identity we
/// cannot verify — a potential man-in-the-middle). The connection is refused
/// and surfaced to the operator as an unrecoverable identity error so they can
/// re-pair if they intentionally changed servers. See the `pinnedFingerprint`
/// contract on `NetworkBackend`.
class ServerIdentityMismatchError extends SkotiqError {
  /// The fingerprint the client pinned (the one the operator paired with).
  final String expectedFingerprint;

  /// The fingerprint the live server advertised, or `null` when the server
  /// advertised none at all (also a fail-closed rejection — an attacker could
  /// otherwise downgrade by simply omitting the field).
  final String? actualFingerprint;

  const ServerIdentityMismatchError({
    required super.message,
    required this.expectedFingerprint,
    required this.actualFingerprint,
    super.userMessage,
  }) : super(
         category: BackendErrorCategory.connection,
         // Identity mismatch is terminal: never auto-retry/reconnect to a host
         // we cannot positively identify.
         isRecoverable: false,
         shouldReconnect: false,
       );
}
