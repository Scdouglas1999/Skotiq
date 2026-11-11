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
  final text = message != null && message.isNotEmpty
      ? message
      : error.toString().trim();
  if (text.isEmpty) return error.runtimeType.toString();
  final database = _databaseFailure.firstMatch(text);
  if (database != null) return 'database error: ${database.group(1)}';
  return _withoutErrorCode(text);
}

/// A failed database statement renders as the engine's exception class, its
/// result code, the reason, and then the statement and its parameters. Only
/// the reason is for the person: `SqliteException(1544): while executing
/// statement, attempt to write a readonly database, …`.
final RegExp _databaseFailure = RegExp(
  r'SqliteException\(\d+\): (?:while [^,\n]+, )?([^,\n]+)',
);

/// The imaging host words a refusal as `run_owns_cooler: <sentence>`; the
/// code is for programs, the sentence is for the person.
final RegExp _errorCodePrefix = RegExp(r'^[a-z][a-z0-9]*(?:_[a-z0-9]+)+: ');

String _withoutErrorCode(String text) {
  final match = _errorCodePrefix.firstMatch(text);
  if (match == null || match.end >= text.length) return text;
  return text.substring(match.end);
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
