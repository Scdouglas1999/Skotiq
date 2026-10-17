import 'dart:async';

import 'package:skotiq_core/skotiq_core.dart' as core;

/// Renders a caught error as copy a person can read.
///
/// Dart's built-in `Error`/`Exception` types stamp their class name onto
/// `toString()` — `StateError` becomes `"Bad state: <message>"`,
/// `UnsupportedError` becomes `"Unsupported operation: <message>"`,
/// `Exception('x')` becomes `"Exception: x"`. Those prefixes are diagnostics
/// for someone reading a stack trace. Interpolating the error object straight
/// into a snackbar (`'Failed to send: $e'`) ships them as product copy, so the
/// operator reads "Failed to send test notification: Bad state: No push
/// transport is listening."
///
/// Each of those types carries the authored message in a separate field, so
/// this reads the message rather than string-stripping the rendered form —
/// prefix-stripping would also eat a message that legitimately begins with the
/// same words.
///
/// Anything whose authored message is not reachable falls through to
/// `toString()` untouched: dropping detail from an unrecognised error type
/// would be a worse failure than an awkward prefix.
String userFacingError(Object? error) {
  if (error == null) return 'Unknown error';
  final message = _authoredMessage(error)?.trim();
  if (message != null && message.isNotEmpty) return message;
  final rendered = error.toString().trim();
  return rendered.isEmpty ? error.runtimeType.toString() : rendered;
}

String? _authoredMessage(Object error) {
  final bridgeMessage = core.bridgeErrorMessage(error);
  if (bridgeMessage != null) return bridgeMessage;
  if (error is StateError) return error.message;
  // The unsupported-operation family shares this authored-message field.
  if (error is UnsupportedError) return error.message;
  if (error is FormatException) return error.message;
  if (error is TimeoutException) return error.message;
  if (error is ArgumentError) {
    // `ArgumentError.value` / `.notNull` put the offending name and value in
    // `toString()` only. Keep those verbatim; collapse just the plain form.
    if (error.name != null || error.invalidValue != null) return null;
    final message = error.message;
    return message is String ? message : null;
  }
  // `Exception('...')` is a private class with no message accessor, and its
  // `toString()` is exactly 'Exception: <message>'.
  const exceptionPrefix = 'Exception: ';
  final rendered = error.toString();
  if (error is Exception && rendered.startsWith(exceptionPrefix)) {
    return rendered.substring(exceptionPrefix.length);
  }
  return null;
}
