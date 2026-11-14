/// What an error's text says went wrong, for an error that carries no
/// category of its own: a Dart exception, or a plain message from the native
/// side or a host. A typed error is read by its type, never by this.
enum ErrorTextKind {
  timeout,
  notFound,
  connection,
  permission,
  busy,
  hardware,
  invalid,
  unsupported,
  imaging,
  driver,
  unknown,
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
