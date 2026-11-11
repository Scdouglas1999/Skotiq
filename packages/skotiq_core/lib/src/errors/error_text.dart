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
  final rendered = error.toString().trim();
  if (rendered.isEmpty) return error.runtimeType.toString();
  return _clean(rendered);
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
  final raw = error?.toString() ?? '';
  final known = _knownFailure(raw, domain);
  if (known != null) return known;
  return ErrorText(
    _sentence(userFacingError(error)),
    suggestion:
        'If it keeps happening, the log has the details '
        '(Settings > Diagnostics).',
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
  r'Unsupported operation|Failed assertion): ',
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
    final prefix =
        _classPrefix.firstMatch(out) ?? _errorCodePrefix.firstMatch(out);
    if (prefix == null || prefix.end >= out.length) break;
    out = out.substring(prefix.end).trim();
  }
  return out;
}

/// [text] with a capital first letter and a full stop.
String _sentence(String text) {
  if (text.isEmpty) return text;
  final capitalized = text[0].toUpperCase() + text.substring(1);
  return RegExp(r'[.!?]$').hasMatch(capitalized)
      ? capitalized
      : '$capitalized.';
}

ErrorText? _knownFailure(String raw, ErrorDomain? domain) {
  ErrorText? search(Iterable<(ErrorDomain, String, ErrorText)> rows) {
    for (final (_, pattern, text) in rows) {
      if (RegExp(pattern, caseSensitive: false).hasMatch(raw)) return text;
    }
    return null;
  }

  if (domain != null) {
    final inDomain = search(_knownFailures.where((row) => row.$1 == domain));
    if (inDomain != null) return inDomain;
  }
  return search(_knownFailures);
}

/// Native failures recognized by their wording, with what to do about each.
///
/// Matching on English text is what typed native errors replace: each row
/// here becomes a case on an error kind. Until then this table is the only
/// place that reads a native message for meaning. Patterns are regular
/// expressions, matched without regard to case and tried in order, the
/// asked-for domain first. Short words are anchored: a bare `com` or `limit`
/// also matches "command" and "rate limit", and turned unrelated failures
/// into "Windows COM interface error".
const List<(ErrorDomain, String, ErrorText)>
_knownFailures = <(ErrorDomain, String, ErrorText)>[
  (
    ErrorDomain.device,
    'device not found',
    ErrorText(
      'The device could not be found.',
      suggestion:
          'Check that the device is powered on, connected, and the '
          'driver is installed.',
    ),
  ),
  (
    ErrorDomain.device,
    'connection refused',
    ErrorText(
      'Could not connect to the device.',
      suggestion:
          'Verify the device is on, connected via USB/network, and no '
          'other software is using it.',
    ),
  ),
  (
    ErrorDomain.device,
    'connection timed out',
    ErrorText(
      'Connection to the device timed out.',
      suggestion: 'Check network settings and that the device is responding.',
    ),
  ),
  (
    ErrorDomain.device,
    'device already connected',
    ErrorText('This device is already connected.'),
  ),
  (
    ErrorDomain.device,
    'device not connected',
    ErrorText(
      'The device is not connected.',
      suggestion: 'Connect to the device before performing this operation.',
    ),
  ),
  (
    ErrorDomain.device,
    r'\bascom\b',
    ErrorText(
      'ASCOM driver error occurred.',
      suggestion:
          'Check that the ASCOM driver is installed and configured '
          'correctly.',
    ),
  ),
  (
    ErrorDomain.device,
    r'HRESULT|0x800[0-9a-f]{5}|\bCOM (interface|object|exception)\b',
    ErrorText(
      'Windows COM interface error.',
      suggestion: 'Try restarting the application or reconnecting the device.',
    ),
  ),
  (
    ErrorDomain.imaging,
    'exposure cancelled',
    ErrorText('The exposure was canceled.'),
  ),
  (
    ErrorDomain.imaging,
    'exposure failed',
    ErrorText(
      'The exposure failed.',
      suggestion: 'Check camera connection and settings, then try again.',
    ),
  ),
  (
    ErrorDomain.imaging,
    'download failed',
    ErrorText(
      'Failed to download image from camera.',
      suggestion: 'Check USB connection and try again.',
    ),
  ),
  (
    ErrorDomain.imaging,
    'no image available',
    ErrorText('No image is available.', suggestion: 'Take an exposure first.'),
  ),
  (
    ErrorDomain.imaging,
    'file write',
    ErrorText(
      'Failed to save the image file.',
      suggestion:
          'Check that the save location is accessible and has '
          'sufficient disk space.',
    ),
  ),
  (
    ErrorDomain.imaging,
    'disk space',
    ErrorText(
      'Insufficient disk space.',
      suggestion: 'Free up disk space or choose a different save location.',
    ),
  ),
  (
    ErrorDomain.mount,
    'slew failed',
    ErrorText(
      'Mount slew failed.',
      suggestion: 'Check that the mount is unparked and tracking is enabled.',
    ),
  ),
  (
    ErrorDomain.mount,
    'target below horizon',
    ErrorText(
      'The target is below the horizon.',
      suggestion: 'Wait until the target rises above the horizon.',
      isRecoverable: false,
    ),
  ),
  (
    ErrorDomain.mount,
    'mount parked',
    ErrorText(
      'The mount is parked.',
      suggestion: 'Unpark the mount before slewing.',
    ),
  ),
  (
    ErrorDomain.mount,
    'park failed',
    ErrorText(
      'Failed to park the mount.',
      suggestion: 'Manually park the mount using the hand controller.',
    ),
  ),
  (
    ErrorDomain.mount,
    r'(slew|tracking|axis|travel|meridian|horizon) limit|limit (reached|exceeded)|(at|beyond|outside|past)( \w+){0,2} limits?\b',
    ErrorText(
      'Mount has reached a limit.',
      suggestion:
          'The mount has reached its movement limits. Perform a meridian '
          'flip or reconfigure limits.',
    ),
  ),
  (
    ErrorDomain.guiding,
    'guide star lost',
    ErrorText(
      'Guide star was lost.',
      suggestion: 'Check guider focus and try selecting a brighter star.',
    ),
  ),
  (
    ErrorDomain.guiding,
    r'\bphd2\b',
    ErrorText(
      'PHD2 guiding error.',
      suggestion: 'Check PHD2 connection and guide camera settings.',
    ),
  ),
  (
    ErrorDomain.guiding,
    'settle timeout',
    ErrorText(
      'Guiding failed to settle in time.',
      suggestion: 'Increase settle timeout or check for tracking issues.',
    ),
  ),
  (
    ErrorDomain.guiding,
    r'calibration (failed|error|was lost|lost)',
    ErrorText(
      'Guiding calibration failed.',
      suggestion: 'Recalibrate guiding near the celestial equator.',
    ),
  ),
  (
    ErrorDomain.plateSolve,
    'plate solve failed',
    ErrorText(
      'Plate solving failed.',
      suggestion:
          'Ensure the mount is roughly pointed at the target. Try using '
          'a longer exposure or wider field hint.',
    ),
  ),
  (
    ErrorDomain.plateSolve,
    'no solution',
    ErrorText(
      'Could not determine image location.',
      suggestion:
          'The image may be out of focus or pointing far from expected. '
          'Check focus and alignment.',
    ),
  ),
  (
    ErrorDomain.plateSolve,
    r'\bastap\b',
    ErrorText(
      'ASTAP plate solver error.',
      suggestion:
          'Verify ASTAP is installed and the star database is downloaded.',
    ),
  ),
];
