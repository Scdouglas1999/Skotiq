import 'skotiq_error.dart' show BackendErrorCategory, SkotiqError;

/// What an error's text says went wrong, for an error that carries no
/// category of its own: a Dart exception, or a plain message from the native
/// side or a host. A typed error is read by its type, never by this.
enum ErrorTextKind {
  timeout(BackendErrorCategory.timeout, retryable: true),
  notFound(BackendErrorCategory.connection, refusal: true),
  connection(BackendErrorCategory.connection, retryable: true, reconnect: true),
  permission(BackendErrorCategory.system, refusal: true),
  busy(BackendErrorCategory.busy, retryable: true),
  hardware(BackendErrorCategory.hardware, retryable: true),
  invalid(BackendErrorCategory.validation),
  unsupported(BackendErrorCategory.unsupported),
  imaging(BackendErrorCategory.imaging),
  driver(BackendErrorCategory.driver),
  unknown(BackendErrorCategory.unknown);

  const ErrorTextKind(
    this.category, {
    this.retryable = false,
    this.reconnect = false,
    this.refusal = false,
  });

  /// The category an error of this kind is filed under.
  final BackendErrorCategory category;

  /// Trying the same operation again can work ([SkotiqError.isRecoverable]).
  final bool retryable;

  /// Reconnecting the device can help ([SkotiqError.shouldReconnect]).
  final bool reconnect;

  /// The device or the system refused outright (not there, not allowed).
  /// A device slot counts every other kind as one it may recover from.
  final bool refusal;
}

/// The one reading of error text. A new kind or a reworded native message
/// changes here and nowhere else.
ErrorTextKind classifyErrorText(String text) {
  final lower = text.toLowerCase();
  bool says(List<String> words) => words.any(lower.contains);
  if (says(const ['timeout', 'timed out'])) return ErrorTextKind.timeout;
  if (says(const ['not found', 'notfound'])) return ErrorTextKind.notFound;
  if (says(const [
    'not connected',
    'disconnected',
    'connection',
    'failed to connect',
    'could not connect',
    'unable to connect',
    'cannot connect',
  ])) {
    return ErrorTextKind.connection;
  }
  if (says(const ['permission', 'denied'])) return ErrorTextKind.permission;
  if (says(const ['busy'])) return ErrorTextKind.busy;
  if (says(const ['hardware', 'communication error'])) {
    return ErrorTextKind.hardware;
  }
  if (says(const ['invalid', 'out of range'])) return ErrorTextKind.invalid;
  if (says(const ['not supported', 'unsupported'])) {
    return ErrorTextKind.unsupported;
  }
  if (says(const ['exposure', 'camera', 'image'])) return ErrorTextKind.imaging;
  if (says(const ['ascom', 'alpaca', 'indi', 'driver'])) {
    return ErrorTextKind.driver;
  }
  return ErrorTextKind.unknown;
}
