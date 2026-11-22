/// The one Dart error type: what failed, in which category, and whether
/// trying again or reconnecting can help. A native error becomes one in
/// `skotiqErrorFromBridge`, text with no type of its own in
/// [SkotiqError.fromString], and Skotiq's own Dart code raises the kinds in
/// `skotiq_exception.dart`.
library;

import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart'
    show LinkVersion, LinkVersionMismatch;
import 'error_text_kind.dart';

/// Backend error category classifications.
///
/// These categories match the Rust `SkotiqError::error_category()` values.
enum BackendErrorCategory {
  connection,

  hardware,

  timeout,

  validation,

  unsupported,

  busy,

  imaging,

  io,

  sequence,

  /// Driver-specific errors (ASCOM, Alpaca, INDI, native)
  driver,

  system,

  unknown,
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

  final bool isTimeout;

  /// Device ID if error is device-related
  final String? deviceId;

  /// Vendor-specific error code if available (ASCOM, Alpaca, native SDK)
  final int? errorCode;

  /// The sentence the driver or host authored, when the error carries one
  /// that says more than [userMessage] ("No Alpaca server answered on port
  /// 11111"). Null when the error's meaning is in values only.
  final String? reason;

  const SkotiqError({
    required this.category,
    required this.message,
    String? userMessage,
    this.isRecoverable = false,
    this.shouldReconnect = false,
    this.isTimeout = false,
    this.deviceId,
    this.errorCode,
    this.reason,
  }) : userMessage = userMessage ?? message;

  /// An error that carries no category of its own (a Dart exception, a plain
  /// native or host message), classified from its text. The one reading of
  /// error text: `DeviceError.fromException` and the FFI backend's fallback
  /// both come here. Prefer [fromJson] when structured data is available.
  factory SkotiqError.fromString(String message) {
    final (category, recoverable, reconnect) = switch (classifyErrorText(
      message,
    )) {
      ErrorTextKind.timeout => (BackendErrorCategory.timeout, true, false),
      ErrorTextKind.connection => (BackendErrorCategory.connection, true, true),
      ErrorTextKind.notFound => (BackendErrorCategory.connection, false, false),
      ErrorTextKind.permission => (BackendErrorCategory.system, false, false),
      ErrorTextKind.busy => (BackendErrorCategory.busy, true, false),
      ErrorTextKind.hardware => (BackendErrorCategory.hardware, true, false),
      ErrorTextKind.invalid => (BackendErrorCategory.validation, false, false),
      ErrorTextKind.unsupported => (
        BackendErrorCategory.unsupported,
        false,
        false,
      ),
      ErrorTextKind.imaging => (BackendErrorCategory.imaging, false, false),
      ErrorTextKind.driver => (BackendErrorCategory.driver, false, false),
      ErrorTextKind.unknown => (BackendErrorCategory.unknown, false, false),
    };
    final deviceMatch = RegExp(
      r'device:\s*(\S+)',
      caseSensitive: false,
    ).firstMatch(message);
    return SkotiqError(
      category: category,
      message: message,
      isRecoverable: recoverable,
      shouldReconnect: reconnect,
      isTimeout: category == BackendErrorCategory.timeout,
      deviceId: deviceMatch?.group(1),
    );
  }

  /// Whether this is a cancellation (not really an error)
  bool get isCancellation => saysCanceled(message);

  @override
  String toString() => message;
}

/// True when [text] says an operation was canceled, in either spelling.
/// The one reading of a cancellation from text, for errors that arrive
/// without a type (a host's message, a native string).
bool saysCanceled(String text) {
  final lower = text.toLowerCase();
  return lower.contains('cancelled') || lower.contains('canceled');
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

/// The host runs another Skotiq release than this client, so the client does
/// not link ([LinkVersion]). Terminal until one side is updated: reconnecting
/// cannot help.
class HostVersionMismatchError extends SkotiqError {
  HostVersionMismatchError(this.mismatch)
    : super(
        category: BackendErrorCategory.connection,
        message: 'Host version mismatch: ${mismatch.message}',
        userMessage: mismatch.message,
        isRecoverable: false,
        shouldReconnect: false,
      );

  final LinkVersionMismatch mismatch;
}
