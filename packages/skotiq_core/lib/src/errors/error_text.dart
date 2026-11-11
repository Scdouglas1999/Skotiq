/// The one place an error becomes text a person reads.
///
/// Three kinds of thing reach the UI as "an error": a typed error (the bridge
/// union, [SkotiqError], [ServerError]), a Dart exception, and a string that
/// crossed a process boundary (a native error, a remote API body). Each used
/// to be cleaned up where it was shown, by a different rule every time, so the
/// same failure read differently on two screens and `Exception:` prefixes,
/// freezed class names and stack frames reached the operator.
///
/// - [userFacingError] is the sentence: what happened, with nothing but the
///   authored message in it.
/// - [describeError] adds what the operator can do about it.
/// - [failureText] puts the sentence after the action that failed.
///
/// When the native side sends typed errors, [_typedMessage] and
/// [_knownFailures] are the two things that change; no screen does.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:http/http.dart' as http;

import '../backend/bridge_error_message.dart';
import '../backend/skotiq_exception.dart' as backend;
import '../models/errors/server_error.dart';
import '../models/errors/skotiq_error.dart';

/// What a person reads about a failure.
class ErrorText {
  const ErrorText(this.message, {this.suggestion, this.isRecoverable = true});

  /// What happened.
  final String message;

  /// What the operator can do about it, when that is known.
  final String? suggestion;

  /// Whether trying again can work.
  final bool isRecoverable;

  /// The message with the suggestion under it.
  String get full => suggestion == null ? message : '$message\n\n$suggestion';

  @override
  String toString() => message;
}

/// Which part of the rig a failure came from, to prefer that part's known
/// failures when a native string matches more than one.
enum ErrorDomain { device, imaging, mount, guiding, plateSolve }

/// [error] as one sentence a person can read: the authored message, without
/// the exception class, an error code, a wrapper's name or a stack trace.
///
/// An error whose authored message cannot be reached is rendered as it is;
/// dropping detail from an unrecognized error is worse than an awkward word.
String userFacingError(Object? error) {
  if (error == null) return 'Unknown error';
  final typed = _typedMessage(error)?.trim();
  if (typed != null && typed.isNotEmpty) return _clean(typed);
  final rendered = _clean(error.toString().trim());
  return rendered.isEmpty ? 'Unknown error' : rendered;
}

/// `Could not save the profile: <what happened>`.
///
/// [action] is the whole lead-in, written by the caller in the words of its
/// screen: `'Could not save the profile'`, `'Slew failed'`.
String failureText(String action, Object? error) =>
    '$action: ${userFacingError(error)}';

/// [error] as a message plus, when the failure is a known one, what to do
/// about it.
ErrorText describeError(Object? error, {ErrorDomain? domain}) {
  if (error is SkotiqError) {
    return ErrorText(
      _clean(error.userMessage),
      suggestion: error.shouldReconnect
          ? 'Reconnect the device, then try again.'
          : null,
      isRecoverable: error.isRecoverable,
    );
  }
  // The driver's own sentence says what happened more exactly than any
  // table could ("ASCOM is only available on Windows" is not "ASCOM driver
  // error"); the table only knows what to do about it.
  final known = _knownFailure(error?.toString() ?? '', domain);
  return ErrorText(
    _sentence(userFacingError(error)),
    suggestion:
        known?.suggestion ??
        'If it keeps happening, the log has the details (Settings > Logs).',
    isRecoverable: known?.recoverable ?? true,
  );
}

/// The authored message of an error type that carries one.
///
/// This is the seam for typed native errors: a new typed error gets a line
/// here and every screen shows it correctly.
String? _typedMessage(Object error) {
  final bridged = bridgeErrorMessage(error);
  if (bridged != null) return bridged;
  if (error is SkotiqError) return error.userMessage;
  if (error is backend.SkotiqException) return error.userMessage;
  if (error is ServerError) return error.message;
  if (error is StateError) return error.message;
  // The unsupported-operation family shares this authored-message field.
  if (error is UnsupportedError) return error.message;
  if (error is FormatException) return error.message;
  if (error is TimeoutException) {
    final message = error.message;
    if (message != null && message.isNotEmpty) return message;
    final after = error.duration;
    return after == null
        ? 'The operation timed out'
        : 'No answer after ${after.inSeconds} s';
  }
  if (error is ArgumentError) {
    // `ArgumentError.value` / `.notNull` put the offending name and value in
    // `toString()` only. Keep those; collapse just the plain form.
    if (error.name != null || error.invalidValue != null) return null;
    final message = error.message;
    return message is String ? message : null;
  }
  if (error is PlatformException) return error.message ?? error.code;
  // A refused or unreachable request: the socket's own port is this side's
  // ephemeral one, so the host is named by the address that was asked for.
  if (error is http.ClientException && error is SocketException) {
    final uri = error.uri;
    final where = uri == null
        ? ''
        : uri.hasPort
        ? ' ${uri.host}:${uri.port}'
        : ' ${uri.host}';
    final why = (error as SocketException).osError?.message;
    return 'Could not reach$where${why == null || why.isEmpty ? '' : ' ($why)'}';
  }
  if (error is SocketException) {
    final host = error.address?.host;
    final port = error.port;
    final where = host == null
        ? ''
        : port == null
        ? ' $host'
        : ' $host:$port';
    final why = error.osError?.message ?? error.message;
    return 'Could not reach$where${why.isEmpty ? '' : ' ($why)'}';
  }
  if (error is FileSystemException) {
    final why = error.osError?.message ?? error.message;
    final path = error.path;
    return path == null ? why : '$why: $path';
  }
  if (error is HttpException) return error.message;
  return null;
}

/// A code the imaging host puts before a refusal, `run_owns_cooler: <text>`.
/// The code is for programs; the text is for the person.
final RegExp _errorCodePrefix = RegExp(r'^[a-z][a-z0-9]*(?:_[a-z0-9]+)+: ');

/// Class names Dart and the bridge stamp in front of a message.
final RegExp _classPrefix = RegExp(
  r'^(?:(?:[A-Za-z_]\w*)?(?:Exception|Error|Failure)(?:\([^)]*\))?|Bad state|Operation failed|Invalid argument\(s\)|'
  r'Unsupported operation|Failed assertion):(?: |$)',
);

/// `AnyhowException(text)`, `PanicException(text)`: the bridge's wrappers
/// around a native error string. And the bridge union's debug rendering,
/// `SkotiqError.operationFailed(field0: text)`, which is what a typed error
/// looks like after something has turned it into a string.
final RegExp _wrapper = RegExp(
  r'^(?:(?:AnyhowException|PanicException|FrbException)\(|'
  r'[A-Za-z_]\w*\.\w+\((?:.*?\b(?:field0|reason|message): )?)(.*)\)$',
  dotAll: true,
);

/// The first stack frame, in Dart's or Rust's rendering.
final RegExp _stackStart = RegExp(
  r'\n\s*(?:#0\s|Stack backtrace:|stack backtrace:|   0: )',
);

String _clean(String text) {
  var out = text;
  final database = _databaseFailure.firstMatch(out);
  if (database != null) return 'database error: ${database.group(1)!.trim()}';
  final stack = _stackStart.firstMatch(out);
  if (stack != null) out = out.substring(0, stack.start);
  out = out.trim();
  // A message can be wrapped more than once on its way up
  // ("Exception: StateError: ...").
  for (var i = 0; i < 4; i++) {
    final wrapped = _wrapper.firstMatch(out);
    if (wrapped != null) {
      out = wrapped.group(1)!.trim();
      continue;
    }
    // A class name with nothing after it ("Exception:") is an empty message.
    final classPrefix = _classPrefix.firstMatch(out);
    if (classPrefix != null) {
      out = out.substring(classPrefix.end).trim();
      continue;
    }
    final code = _errorCodePrefix.firstMatch(out);
    if (code == null || code.end >= out.length) break;
    out = out.substring(code.end).trim();
  }
  return out;
}

/// A failed database statement renders as the engine's exception class, its
/// result code, the reason, and then the statement and its parameters. Only
/// the reason is for the person: `SqliteException(1544): while executing
/// statement, attempt to write a readonly database, …`.
final RegExp _databaseFailure = RegExp(
  r'SqliteException\(\d+\): (?:while [^,\n]+, )?([^,\n]+)',
);

/// [text] with a capital first letter and a full stop.
String _sentence(String text) {
  if (text.isEmpty) return text;
  final capitalized = text[0].toUpperCase() + text.substring(1);
  return RegExp(r'[.!?]$').hasMatch(capitalized)
      ? capitalized
      : '$capitalized.';
}

_KnownFailure? _knownFailure(String raw, ErrorDomain? domain) {
  _KnownFailure? search(Iterable<_KnownFailure> rows) {
    for (final row in rows) {
      if (RegExp(row.pattern, caseSensitive: false).hasMatch(raw)) return row;
    }
    return null;
  }

  if (domain != null) {
    final inDomain = search(
      _knownFailures.where((row) => row.domain == domain),
    );
    if (inDomain != null) return inDomain;
  }
  return search(_knownFailures);
}

/// Native failures recognized by their wording, and what to do about each.
///
/// Matching on English text is what typed native errors replace: each row
/// here becomes a case on an error kind. Until then this table is the only
/// place that reads a native message for meaning. Patterns are regular
/// expressions, matched without regard to case and tried in order, the
/// asked-for domain first. Short words are anchored: a bare `com` or `limit`
/// also matches "command" and "rate limit", and turned unrelated failures
/// into "Windows COM interface error".
const List<_KnownFailure> _knownFailures = <_KnownFailure>[
  _KnownFailure(
    ErrorDomain.device,
    'device not found',
    'Check that the device is powered on, connected, and the '
        'driver is installed.',
  ),
  _KnownFailure(
    ErrorDomain.device,
    'connection refused',
    'Verify the device is on, connected via USB/network, and no '
        'other software is using it.',
  ),
  _KnownFailure(
    ErrorDomain.device,
    'connection timed out',
    'Check network settings and that the device is responding.',
  ),
  _KnownFailure(
    ErrorDomain.device,
    'device not connected',
    'Connect to the device before performing this operation.',
  ),
  _KnownFailure(
    ErrorDomain.device,
    r'\bascom\b',
    'Check that the ASCOM driver is installed and configured '
        'correctly.',
  ),
  _KnownFailure(
    ErrorDomain.device,
    r'HRESULT|0x800[0-9a-f]{5}|\bCOM (interface|object|exception)\b',
    'Try restarting the application or reconnecting the device.',
  ),
  _KnownFailure(
    ErrorDomain.imaging,
    'exposure failed',
    'Check camera connection and settings, then try again.',
  ),
  _KnownFailure(
    ErrorDomain.imaging,
    'download failed',
    'Check USB connection and try again.',
  ),
  _KnownFailure(
    ErrorDomain.imaging,
    'no image available',
    'Take an exposure first.',
  ),
  _KnownFailure(
    ErrorDomain.imaging,
    'file write',
    'Check that the save location is accessible and has '
        'sufficient disk space.',
  ),
  _KnownFailure(
    ErrorDomain.imaging,
    'disk space',
    'Free up disk space or choose a different save location.',
  ),
  _KnownFailure(
    ErrorDomain.mount,
    'slew failed',
    'Check that the mount is unparked and tracking is enabled.',
  ),
  _KnownFailure(
    ErrorDomain.mount,
    'target below horizon',
    'Wait until the target rises above the horizon.',
    recoverable: false,
  ),
  _KnownFailure(
    ErrorDomain.mount,
    'mount parked',
    'Unpark the mount before slewing.',
  ),
  _KnownFailure(
    ErrorDomain.mount,
    'park failed',
    'Manually park the mount using the hand controller.',
  ),
  _KnownFailure(
    ErrorDomain.mount,
    r'(slew|tracking|axis|travel|meridian|horizon) limit|limit (reached|exceeded)|(at|beyond|outside|past)( \w+){0,2} limits?\b',
    'The mount has reached its movement limits. Perform a meridian '
        'flip or reconfigure limits.',
  ),
  _KnownFailure(
    ErrorDomain.guiding,
    'guide star lost',
    'Check guider focus and try selecting a brighter star.',
  ),
  _KnownFailure(
    ErrorDomain.guiding,
    r'\bphd2\b',
    'Check PHD2 connection and guide camera settings.',
  ),
  _KnownFailure(
    ErrorDomain.guiding,
    'settle timeout',
    'Increase settle timeout or check for tracking issues.',
  ),
  _KnownFailure(
    ErrorDomain.guiding,
    r'calibration (failed|error|was lost|lost)',
    'Recalibrate guiding near the celestial equator.',
  ),
  _KnownFailure(
    ErrorDomain.plateSolve,
    'plate solve failed',
    'Ensure the mount is roughly pointed at the target. Try using '
        'a longer exposure or wider field hint.',
  ),
  _KnownFailure(
    ErrorDomain.plateSolve,
    'no solution',
    'The image may be out of focus or pointing far from expected. '
        'Check focus and alignment.',
  ),
  _KnownFailure(
    ErrorDomain.plateSolve,
    r'\bastap\b',
    'Verify ASTAP is installed and the star database is downloaded.',
  ),
];

class _KnownFailure {
  const _KnownFailure(
    this.domain,
    this.pattern,
    this.suggestion, {
    this.recoverable = true,
  });

  final ErrorDomain domain;
  final String pattern;
  final String suggestion;
  final bool recoverable;
}
