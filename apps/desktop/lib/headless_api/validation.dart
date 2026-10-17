import 'dart:convert';

import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_error;
import 'package:shelf/shelf.dart';

import 'response_helpers.dart';

/// Operator-readable sentence for an arbitrary thrown object, for handlers
/// that build their own error body instead of letting
/// [errorTranslationMiddleware] do it.
///
/// `$e` on a bridge error is the freezed constructor form, and remote clients
/// render `message` verbatim — so any handler interpolating a caught backend
/// error into a user-facing string must route it through here.
String describeBackendError(Object error) => error is bridge_error.SkotiqError
    ? _cleanBackendErrorMessage(error)
    : error.toString();

/// Extract a human-readable message from a flutter_rust_bridge
/// [bridge_error.SkotiqError]. Its `toString()` leaks the freezed wrapper
/// (`SkotiqError.operationFailed(field0: <msg>)`); unwrap to just `<msg>`
/// so the wire response carries the actionable text a remote client should
/// show, not the Dart class plumbing.
///
/// An EXHAUSTIVE `map` with no `orElse`, never `maybeMap` plus a regex
/// fallback: a regex over `e.toString()` can only unwrap a variant with one
/// positional `field0`, so every zero-arg and named-field variant would leak
/// the constructor form. Without `orElse`, a variant added to the bridge union
/// stops this function compiling instead of silently leaking again. Do not
/// reintroduce a catch-all.
String _cleanBackendErrorMessage(bridge_error.SkotiqError e) {
  // `deviceId` is empty on the arms where the driver did not scope the
  // failure to one device; appending "(device )" there would be noise.
  String scoped(String sentence, String deviceId) =>
      deviceId.isEmpty ? sentence : '$sentence (device $deviceId)';

  final message = e.map(
    // Connection / presence
    deviceNotFound: (v) => 'Device not found: ${v.field0}',
    connectionFailed: (v) => 'Could not connect to ${v.deviceId}: ${v.reason}',
    alreadyConnected: (v) => 'Device already connected: ${v.field0}',
    notConnected: (v) => 'Device not connected: ${v.field0}',
    deviceDisconnected: (v) => 'Device ${v.deviceId} disconnected: ${v.reason}',
    // Hardware / transport
    hardwareError: (v) => 'Hardware error on ${v.deviceId}: ${v.message}',
    communicationError: (v) =>
        'Communication error with ${v.deviceId}: ${v.message}',
    timeout: (v) => v.field0,
    deviceTimeout: (v) =>
        '${v.deviceId} timed out after ${v.timeoutSecs}s during ${v.operation}',
    connectionTimeout: (v) =>
        'Connecting to ${v.deviceId} timed out after ${v.timeoutSecs}s',
    // Caller input
    invalidParameter: (v) => v.field0,
    invalidInput: (v) => v.field0,
    invalidDeviceId: (v) => scoped(v.reason, v.deviceId),
    parameterOutOfRange: (v) =>
        '${v.paramName} ${v.value} is outside the valid range '
        '${v.min} to ${v.max}',
    // Operation
    operationFailed: (v) => v.field0,
    notSupported: (v) => scoped(v.operation, v.deviceId),
    deviceBusy: (v) => '${v.deviceId} is busy: ${v.currentOperation}',
    // Imaging
    imageError: (v) => v.field0,
    cameraError: (v) => v.field0,
    noImageAvailable: (_) =>
        'No image is available yet — capture an exposure first',
    exposureCancelled: (_) => 'Exposure cancelled',
    // `reason` is already the complete operator-actionable sentence.
    exposureFailed: (v) => v.reason,
    downloadFailed: (v) => 'Image download failed: ${v.cameraId} - ${v.reason}',
    // Host
    ioError: (v) => v.field0,
    serializationError: (v) => v.field0,
    plateSolveError: (v) => v.field0,
    sequenceError: (v) => v.field0,
    // Driver-stack specific
    ascomError: (v) =>
        'ASCOM driver ${v.progId} reported: ${v.message} (code ${v.errorCode})',
    alpacaError: (v) =>
        'Alpaca device ${v.deviceNumber} at ${v.baseUrl} reported: '
        '${v.message} (code ${v.errorCode})',
    indiError: (v) =>
        'INDI device ${v.deviceName} on ${v.server}:${v.port} reported: '
        '${v.message}',
    nativeError: (v) =>
        '${v.vendor} SDK reported: ${v.message} (code ${v.errorCode})',
    comError: (v) =>
        'Windows COM call failed: ${v.message} '
        '(HRESULT 0x${v.hresult.toUnsigned(32).toRadixString(16)})',
    // Process
    internal: (v) => v.field0,
    cancelled: (_) => 'Operation cancelled',
    runtimeInitFailed: (v) => v.field0,
    resourceExhausted: (v) => '${v.resource} exhausted: ${v.message}',
  );

  // Belt and braces: a variant whose payload string is empty would otherwise
  // put an empty `message` on the wire. Never fall back to `e.toString()` —
  // that is the constructor form this function exists to keep off the wire.
  final trimmed = message.trim();
  return trimmed.isEmpty ? 'The device reported an unspecified error' : trimmed;
}

/// Produce a short, single-line message from an arbitrary thrown object for the
/// generic-500 wire body. Strips the `Exception:`/`StateError:` prefixes, keeps
/// only the first line (so a multi-line message can't smuggle a stack trace),
/// and caps the length.
String _sanitizeErrorDetail(Object e) {
  var msg = e.toString().trim();
  for (final prefix in const ['Exception: ', 'StateError: ', 'Bad state: ']) {
    if (msg.startsWith(prefix)) {
      msg = msg.substring(prefix.length).trim();
    }
  }
  final firstLine = msg.split('\n').first.trim();
  const maxLen = 300;
  return firstLine.length > maxLen
      ? '${firstLine.substring(0, maxLen)}…'
      : firstLine;
}

/// The wire `error` code for a mapped backend status.
///
/// Only a genuine 500 is `internal_error`. 501, 502 and 504 name the real
/// condition instead: a capability the camera does not have, a driver that is
/// unreachable, a driver that is slow. None of those is a fault of the host,
/// and labelling them one sends a client looking in the wrong place.
String _backendErrorCode(int statusCode) => switch (statusCode) {
  501 => 'not_supported',
  502 => 'device_unreachable',
  504 => 'device_timeout',
  >= 500 => 'internal_error',
  _ => 'device_error',
};

/// Map a flutter_rust_bridge [bridge_error.SkotiqError] to the HTTP status
/// that best describes it. Without this, every device-operation error reaching
/// the headless error translator collapses to an opaque 500; a remote tablet
/// needs "not supported", "not connected", "bad request" so it can react.
/// Genuinely internal/driver faults stay 500.
int _httpStatusForBackendError(bridge_error.SkotiqError e) {
  return e.maybeMap(
    notSupported: (_) => 501,
    notConnected: (_) => 409,
    deviceDisconnected: (_) => 409,
    deviceNotFound: (_) => 404,
    invalidParameter: (_) => 400,
    invalidInput: (_) => 400,
    invalidDeviceId: (_) => 400,
    parameterOutOfRange: (_) => 400,
    deviceBusy: (_) => 409,
    resourceExhausted: (_) => 409,
    timeout: (_) => 504,
    deviceTimeout: (_) => 504,
    connectionTimeout: (_) => 504,
    connectionFailed: (_) => 502,
    noImageAvailable: (_) => 404,
    exposureCancelled: (_) => 409,
    // A frame the camera delivered but image validation rejected (completely
    // saturated, all-zero, wrong pixel count). The request was well-formed and
    // the driver worked, so this is not an internal fault: 422 tells the client
    // the exposure itself is unusable and names the reason, instead of the
    // `500 internal_error` a real ASI1600MM produced for an overexposed
    // daylight frame — which also invited retry-on-5xx clients to retry a
    // request that cannot succeed until the exposure or gain changes.
    exposureFailed: (_) => 422,
    cancelled: (_) => 409,
    orElse: () => 500,
  );
}

/// Validation helpers for headless API request payloads.
///
/// A missing or wrong-type field must become a structured 400 naming the
/// field, never a [TypeError] the trap formats into a 500 body — that leaks
/// stack traces and internal Dart type names to the wire. These helpers raise
/// one [BadRequestError] type that [errorMiddleware] (or per-handler glue)
/// translates. A genuine internal error becomes a 500 carrying a request-id
/// reference and never echoes `e.toString()`.

class BadRequestError implements Exception {
  final String field;
  final String expected;
  final String? message;

  BadRequestError({required this.field, required this.expected, this.message});

  @override
  String toString() => 'BadRequestError(field=$field, expected=$expected)';

  String get displayMessage {
    if (message != null) return message!;
    return switch (expected) {
      'string' => '$field is required',
      'number' => '$field is required',
      'integer' => '$field is required',
      'boolean' => '$field is required',
      'object' => '$field is required',
      _ => 'Invalid request',
    };
  }

  Map<String, Object?> toJsonBody() => {
    'error': displayMessage,
    'code': 'invalid_request',
    'field': field,
    'expected': expected,
    if (message != null) 'message': message,
  };
}

/// Handler-level structured failure for fail-closed responses.
///
/// Why: handlers must not return `{'status': 'failed', 'error': e.toString()}`
/// — that ships HTTP 200/500 bodies with leaked Dart type names and stack
/// traces, and confuses clients about whether the operation succeeded. The
/// `errorTranslationMiddleware` catches this exception and renders a
/// non-2xx response with a stable machine-readable `code`, a sanitized
/// human `message`, and an optional `details` map. Full exception detail
/// (if any) goes to the structured log via [cause]/[stackTrace].
class HandlerFailure implements Exception {
  /// Stable machine-readable identifier, e.g. `backup_create_failed`.
  final String code;

  /// Sanitized human-readable summary safe to ship to the caller.
  ///
  /// MUST NOT include `e.toString()` output, stack traces, or internal
  /// Dart type names. Producer-supplied service messages (e.g. a
  /// BackupResult.errorMessage) are acceptable here because they are
  /// curated by the service layer for caller display.
  final String message;

  /// HTTP status code. Defaults to 500 (server-side failure). Use 4xx
  /// only when the caller can fix the request by itself.
  final int statusCode;

  /// Optional caller-visible additional fields (counts, ids, paths, etc.).
  /// Must not contain stack traces or Dart type names.
  final Map<String, Object?>? details;

  /// Underlying cause for log-side diagnostics. NEVER serialized.
  final Object? cause;

  /// Stack trace for log-side diagnostics. NEVER serialized.
  final StackTrace? stackTrace;

  HandlerFailure({
    required this.code,
    required this.message,
    this.statusCode = 500,
    this.details,
    this.cause,
    this.stackTrace,
  });

  @override
  String toString() => 'HandlerFailure(code=$code, status=$statusCode)';

  Map<String, Object?> toJsonBody({String? requestId}) => {
    'error': code,
    'message': message,
    if (requestId != null) 'requestId': requestId,
    if (details != null) ...details!,
  };
}

/// Reads the request body as a JSON object.
///
/// Throws [BadRequestError] if the body is not valid JSON or not a
/// [Map<String, dynamic>] at the top level.
Future<Map<String, dynamic>> readJsonObject(Request request) async {
  final raw = await request.readAsString();
  if (raw.isEmpty) {
    throw BadRequestError(
      field: 'body',
      expected: 'json_object',
      message: 'Request body is empty',
    );
  }
  return _decodeJsonObject(raw);
}

/// Name the keys of [payload] this endpoint understood and the keys it did
/// not, so a caller can see that a misspelled field had no effect.
///
/// Without it, `POST /api/sequencer/update-observer-profile` carrying
/// `focalLengthMm` — the obvious spelling of `telescopeFocalLengthMm` —
/// answers `200 {"status":"ok"}` and drops the value, and the only way to
/// discover that is a later FITS header missing `FOCALLEN`.
///
/// Reporting rather than rejecting is deliberate. A 400 on an unknown key would
/// be the stricter contract, but it turns a forward-compatible client — a phone
/// that auto-updated ahead of its appliance — into a hard failure. Naming the
/// ignored keys costs nothing, breaks nobody, and is enough: the response stops
/// claiming it did something it did not.
///
/// Use it as the body of a settings-style POST:
/// `return jsonOk({'status': 'ok', ...fieldReport(payload, const {...})});`
Map<String, Object?> fieldReport(
  Map<String, dynamic> payload,
  Set<String> understood,
) {
  final applied = payload.keys.where(understood.contains).toList()..sort();
  final ignored = payload.keys.where((k) => !understood.contains(k)).toList()
    ..sort();
  return {
    'applied': applied,
    if (ignored.isNotEmpty) ...{
      'ignored': ignored,
      'warning':
          'These fields are not part of this endpoint and were not applied: '
          '${ignored.join(', ')}. Accepted fields: '
          '${(understood.toList()..sort()).join(', ')}.',
    },
  };
}

/// The settings object a settings POST should read, from either shape a client
/// can reasonably send.
///
/// Several settings GETs on this API answer `{"settings": {...}}`. Reading one
/// and posting it straight back is the obvious client move — and a handler that
/// only reads the top level stores nothing from that body while answering 200.
/// `POST /api/weather/settings` did exactly that: the round trip of its own GET
/// silently disarmed weather safety for a whole night.
///
/// So both shapes are accepted: the envelope its own GET emits, and the flat
/// body older clients send. A body carrying BOTH — a `settings` object AND a
/// top-level key this endpoint understands — is refused, because it holds two
/// answers for one field and no rule picks between them honestly.
///
/// Throws [BadRequestError] naming `settings` when the envelope is present but
/// is not a JSON object.
Map<String, dynamic> settingsBody(
  Map<String, dynamic> payload,
  Set<String> understood,
) {
  if (!payload.containsKey('settings')) return payload;
  final nested = payload['settings'];
  if (nested is! Map<String, dynamic>) {
    throw BadRequestError(
      field: 'settings',
      expected: 'json_object',
      message: 'The settings envelope must be a JSON object',
    );
  }
  final alsoAtTopLevel = payload.keys.where(understood.contains).toList()
    ..sort();
  if (alsoAtTopLevel.isNotEmpty) {
    throw BadRequestError(
      field: 'settings',
      expected: 'json_object',
      message:
          'This body carries a settings envelope and the top-level fields '
          '${alsoAtTopLevel.join(', ')}. Send one or the other, not both.',
    );
  }
  return nested;
}

/// Refuse a settings write that would store nothing, naming what was sent.
///
/// A write that changed nothing must never answer "updated". Call this after
/// [settingsBody] and before touching the store; [readOnly] names keys a GET
/// echoes back that are not settings (a row `id`), so round-tripping a GET
/// document is not mistaken for a misspelling.
///
/// Returns the understood keys, sorted — the honest `applied` list for the
/// response.
List<String> requireSettingsFields(
  Map<String, dynamic> body,
  Set<String> understood, {
  Set<String> readOnly = const {},
}) {
  final applied = body.keys.where(understood.contains).toList()..sort();
  if (applied.isNotEmpty) return applied;
  final sent = body.keys.where((k) => !readOnly.contains(k)).toList()..sort();
  throw BadRequestError(
    field: 'settings',
    expected: understood.isEmpty
        ? 'settings_field'
        : (understood.toList()..sort()).join('|'),
    message: sent.isEmpty
        ? 'This request names no setting to change. Accepted fields: '
              '${(understood.toList()..sort()).join(', ')}.'
        : 'None of the fields sent is a setting this endpoint stores: '
              '${sent.join(', ')}. Accepted fields: '
              '${(understood.toList()..sort()).join(', ')}.',
  );
}

/// Reads an optional JSON-object body. An absent or whitespace-only body maps
/// to an empty object; a supplied body is held to the same strict contract as
/// [readJsonObject]. This is for POST endpoints whose entire payload is
/// optional—it must not turn malformed JSON into a plausible default request.
Future<Map<String, dynamic>> readJsonObjectOrEmpty(Request request) async {
  final raw = await request.readAsString();
  if (raw.trim().isEmpty) return <String, dynamic>{};
  return _decodeJsonObject(raw);
}

Map<String, dynamic> _decodeJsonObject(String raw) {
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (e) {
    throw BadRequestError(
      field: 'body',
      expected: 'valid_json',
      message: 'Malformed JSON: ${e.message}',
    );
  }
  if (decoded is! Map<String, dynamic>) {
    throw BadRequestError(
      field: 'body',
      expected: 'json_object',
      message: 'Top-level JSON value must be an object',
    );
  }
  return decoded;
}

/// Required string. Empty strings throw unless [allowEmpty] is true.
String requireString(
  Map<String, dynamic> payload,
  String field, {
  bool allowEmpty = false,
  int? maxLength,
}) {
  final value = payload[field];
  if (value == null) {
    throw BadRequestError(field: field, expected: 'string');
  }
  if (value is! String) {
    throw BadRequestError(field: field, expected: 'string');
  }
  if (!allowEmpty && value.isEmpty) {
    throw BadRequestError(
      field: field,
      expected: 'string',
      message: 'Value must not be empty',
    );
  }
  if (maxLength != null && value.length > maxLength) {
    throw BadRequestError(
      field: field,
      expected: 'string',
      message: 'Value exceeds maximum length of $maxLength',
    );
  }
  return value;
}

String? optionalString(
  Map<String, dynamic> payload,
  String field, {
  bool allowEmpty = false,
  int? maxLength,
}) {
  final value = payload[field];
  if (value == null) return null;
  if (value is! String) {
    throw BadRequestError(field: field, expected: 'string');
  }
  if (!allowEmpty && value.isEmpty) {
    return null;
  }
  if (maxLength != null && value.length > maxLength) {
    throw BadRequestError(
      field: field,
      expected: 'string',
      message: 'Value exceeds maximum length of $maxLength',
    );
  }
  return value;
}

int requireInt(
  Map<String, dynamic> payload,
  String field, {
  int? min,
  int? max,
}) {
  final value = payload[field];
  if (value == null) {
    throw BadRequestError(field: field, expected: 'integer');
  }
  int parsed;
  if (value is int) {
    parsed = value;
  } else if (value is double && value == value.toInt().toDouble()) {
    parsed = value.toInt();
  } else if (value is String) {
    final maybe = int.tryParse(value);
    if (maybe == null) {
      throw BadRequestError(field: field, expected: 'integer');
    }
    parsed = maybe;
  } else {
    throw BadRequestError(field: field, expected: 'integer');
  }
  _checkRange(field, parsed.toDouble(), min?.toDouble(), max?.toDouble());
  return parsed;
}

int? optionalInt(
  Map<String, dynamic> payload,
  String field, {
  int? min,
  int? max,
}) {
  final value = payload[field];
  if (value == null) return null;
  return requireInt(payload, field, min: min, max: max);
}

double requireDouble(
  Map<String, dynamic> payload,
  String field, {
  double? min,
  double? max,
}) {
  final value = payload[field];
  if (value == null) {
    throw BadRequestError(field: field, expected: 'number');
  }
  double parsed;
  if (value is num) {
    parsed = value.toDouble();
  } else if (value is String) {
    final maybe = double.tryParse(value);
    if (maybe == null) {
      throw BadRequestError(field: field, expected: 'number');
    }
    parsed = maybe;
  } else {
    throw BadRequestError(field: field, expected: 'number');
  }
  if (!parsed.isFinite) {
    throw BadRequestError(
      field: field,
      expected: 'number',
      message: 'Value must be finite',
    );
  }
  _checkRange(field, parsed, min, max);
  return parsed;
}

double? optionalDouble(
  Map<String, dynamic> payload,
  String field, {
  double? min,
  double? max,
}) {
  final value = payload[field];
  if (value == null) return null;
  return requireDouble(payload, field, min: min, max: max);
}

bool requireBool(Map<String, dynamic> payload, String field) {
  final value = payload[field];
  if (value == null) {
    throw BadRequestError(field: field, expected: 'boolean');
  }
  if (value is bool) return value;
  if (value is String) {
    final lower = value.toLowerCase();
    if (lower == 'true' || lower == '1' || lower == 'yes') return true;
    if (lower == 'false' || lower == '0' || lower == 'no') return false;
  }
  throw BadRequestError(field: field, expected: 'boolean');
}

bool? optionalBool(Map<String, dynamic> payload, String field) {
  final value = payload[field];
  if (value == null) return null;
  return requireBool(payload, field);
}

Map<String, dynamic> requireObject(Map<String, dynamic> payload, String field) {
  final value = payload[field];
  if (value == null) {
    throw BadRequestError(field: field, expected: 'object');
  }
  if (value is! Map<String, dynamic>) {
    throw BadRequestError(field: field, expected: 'object');
  }
  return value;
}

Map<String, dynamic>? optionalObject(
  Map<String, dynamic> payload,
  String field,
) {
  final value = payload[field];
  if (value == null) return null;
  if (value is! Map<String, dynamic>) {
    throw BadRequestError(field: field, expected: 'object');
  }
  return value;
}

List<T> requireList<T>(Map<String, dynamic> payload, String field) {
  final value = payload[field];
  if (value == null) {
    throw BadRequestError(field: field, expected: 'array');
  }
  if (value is! List) {
    throw BadRequestError(field: field, expected: 'array');
  }
  for (final element in value) {
    if (element is! T) {
      throw BadRequestError(field: field, expected: 'array<${T.toString()}>');
    }
  }
  return value.cast<T>();
}

List<T>? optionalList<T>(Map<String, dynamic> payload, String field) {
  if (payload[field] == null) return null;
  return requireList<T>(payload, field);
}

/// Optional `{ "<key>": <number> }` object — e.g. a per-filter exposure floor.
/// Absent or null yields an empty map. A bad entry names its own path
/// (`perFilterMinSecs.L`) so the client knows which key to fix.
Map<String, double> optionalStringDoubleMap(
  Map<String, dynamic> payload,
  String field,
) {
  final value = payload[field];
  if (value == null) return const {};
  if (value is! Map) {
    throw BadRequestError(field: field, expected: 'object');
  }
  final parsed = <String, double>{};
  value.forEach((key, entry) {
    if (entry is! num) {
      throw BadRequestError(field: '$field.$key', expected: 'number');
    }
    parsed[key.toString()] = entry.toDouble();
  });
  return parsed;
}

/// Optional `{ "<key>": <bool> }` object — e.g. a per-filter enable flag.
Map<String, bool> optionalStringBoolMap(
  Map<String, dynamic> payload,
  String field,
) {
  final value = payload[field];
  if (value == null) return const {};
  if (value is! Map) {
    throw BadRequestError(field: field, expected: 'object');
  }
  final parsed = <String, bool>{};
  value.forEach((key, entry) {
    if (entry is! bool) {
      throw BadRequestError(field: '$field.$key', expected: 'boolean');
    }
    parsed[key.toString()] = entry;
  });
  return parsed;
}

/// Optional `{ "<outer>": { "<inner>": <number> } }` object — e.g. carried-over
/// integration keyed by target and then by filter.
Map<String, Map<String, double>> optionalNestedDoubleMap(
  Map<String, dynamic> payload,
  String field,
) {
  final value = payload[field];
  if (value == null) return const {};
  if (value is! Map) {
    throw BadRequestError(field: field, expected: 'object');
  }
  final parsed = <String, Map<String, double>>{};
  value.forEach((outerKey, inner) {
    if (inner is! Map) {
      throw BadRequestError(field: '$field.$outerKey', expected: 'object');
    }
    final entries = <String, double>{};
    inner.forEach((innerKey, entry) {
      if (entry is! num) {
        throw BadRequestError(
          field: '$field.$outerKey.$innerKey',
          expected: 'number',
        );
      }
      entries[innerKey.toString()] = entry.toDouble();
    });
    parsed[outerKey.toString()] = entries;
  });
  return parsed;
}

// Query-string parameter helpers (GET / query endpoints).
//
// Why a separate family from the JSON-body helpers above: query values arrive
// as a `Map<String, String>` where a MISSING key and an EMPTY value both read
// as "not supplied" for endpoints that document a default. These helpers fail
// closed — a value that IS supplied but is malformed (unparseable, NaN /
// Infinity, out of range, or non-whole for an int) raises [BadRequestError]
// BEFORE any DAO / backend / service call, rather than mapping garbage onto
// the default or forwarding a NaN downstream. Absence (or empty) still yields
// the documented default via the `optional*` variants returning null.

/// Required finite [double] query parameter. Throws [BadRequestError] when the
/// key is absent/empty, unparseable, non-finite (NaN/Infinity), or outside
/// the inclusive [min]/[max] bounds.
double requireQueryDouble(
  Map<String, String> query,
  String field, {
  double? min,
  double? max,
}) {
  final raw = query[field];
  if (raw == null || raw.isEmpty) {
    throw BadRequestError(field: field, expected: 'number');
  }
  final parsed = double.tryParse(raw);
  if (parsed == null) {
    throw BadRequestError(field: field, expected: 'number');
  }
  if (!parsed.isFinite) {
    throw BadRequestError(
      field: field,
      expected: 'number',
      message: '$field must be a finite number',
    );
  }
  _checkRange(field, parsed, min, max);
  return parsed;
}

/// Optional finite [double] query parameter. Returns null when the key is
/// absent or empty (the caller then applies the documented default);
/// otherwise validates exactly as [requireQueryDouble].
double? optionalQueryDouble(
  Map<String, String> query,
  String field, {
  double? min,
  double? max,
}) {
  final raw = query[field];
  if (raw == null || raw.isEmpty) return null;
  return requireQueryDouble(query, field, min: min, max: max);
}

/// Required whole [int] query parameter. Throws [BadRequestError] when the key
/// is absent/empty, not a whole integer (e.g. `5.0`, `3e2`, `abc`), or outside
/// the inclusive [min]/[max] bounds.
int requireQueryInt(
  Map<String, String> query,
  String field, {
  int? min,
  int? max,
}) {
  final raw = query[field];
  if (raw == null || raw.isEmpty) {
    throw BadRequestError(field: field, expected: 'integer');
  }
  final parsed = int.tryParse(raw);
  if (parsed == null) {
    throw BadRequestError(field: field, expected: 'integer');
  }
  _checkRange(field, parsed.toDouble(), min?.toDouble(), max?.toDouble());
  return parsed;
}

/// Optional whole [int] query parameter. Returns null when the key is absent or
/// empty (the caller then applies the documented default); otherwise validates
/// exactly as [requireQueryInt].
int? optionalQueryInt(
  Map<String, String> query,
  String field, {
  int? min,
  int? max,
}) {
  final raw = query[field];
  if (raw == null || raw.isEmpty) return null;
  return requireQueryInt(query, field, min: min, max: max);
}

/// Optional strict-boolean query parameter. Returns null when the key is absent
/// or empty. Accepts the same tokens as [requireBool] (`true`/`1`/`yes`,
/// `false`/`0`/`no`, case-insensitive); any other supplied value throws
/// [BadRequestError] rather than silently collapsing to false.
bool? optionalQueryBool(Map<String, String> query, String field) {
  final raw = query[field];
  if (raw == null || raw.isEmpty) return null;
  final lower = raw.toLowerCase();
  if (lower == 'true' || lower == '1' || lower == 'yes') return true;
  if (lower == 'false' || lower == '0' || lower == 'no') return false;
  throw BadRequestError(field: field, expected: 'boolean');
}

void _checkRange(String field, double value, double? min, double? max) {
  if (min != null && value < min) {
    throw BadRequestError(
      field: field,
      expected: 'number',
      message: 'Value must be >= $min',
    );
  }
  if (max != null && value > max) {
    throw BadRequestError(
      field: field,
      expected: 'number',
      message: 'Value must be <= $max',
    );
  }
}

/// Translates uncaught exceptions into structured error responses.
///
/// No handler may ship `e.toString()` to the wire — that leaks stack traces
/// and Dart type names. This middleware catches [BadRequestError] (-> 400 with
/// a structured body) and any other exception (-> 500 with `internal_error` +
/// `requestId`). Full exception detail goes to the structured log only.
Middleware errorTranslationMiddleware({
  required void Function(String message, {Map<String, Object?>? fields})
  logError,
  required String Function(Request request) requestIdFor,
  bool Function(Request request)? shouldBypass,
}) {
  return (innerHandler) {
    return (request) async {
      if (shouldBypass?.call(request) ?? false) {
        return innerHandler(request);
      }
      try {
        return await innerHandler(request);
      } on BadRequestError catch (e) {
        return jsonBadRequest(e.toJsonBody());
      } on HandlerFailure catch (e, stackTrace) {
        final requestId = requestIdFor(request);
        // Log the full detail (cause + stack) on the server side; the wire
        // body only carries the curated code/message/details. Why two logs:
        // a HandlerFailure is an explicit handler decision and is logged
        // at warning (not error) unless the underlying cause is unexpected.
        logError(
          '[HANDLER-FAIL][$requestId] ${e.code}: ${e.message}',
          fields: {
            'requestId': requestId,
            'code': e.code,
            'statusCode': e.statusCode,
            if (e.cause != null) 'cause': e.cause.toString(),
            if (e.stackTrace != null) 'cause_stack': e.stackTrace.toString(),
            'handler_stack': stackTrace.toString(),
          },
        );
        return jsonResponse(
          e.toJsonBody(requestId: requestId),
          statusCode: e.statusCode,
        );
      } on bridge_error.SkotiqError catch (e, stackTrace) {
        // Device-operation errors from the native bridge: map the structured
        // category to a meaningful HTTP status (501 not-supported, 409
        // not-connected/busy, 404 not-found, 400 bad-params, 504 timeout, 502
        // unreachable) so a remote client gets an actionable response instead
        // of an opaque 500. Genuinely internal/driver faults fall through to
        // 500 via the mapper's orElse.
        final requestId = requestIdFor(request);
        final statusCode = _httpStatusForBackendError(e);
        final message = _cleanBackendErrorMessage(e);
        if (statusCode >= 500) {
          logError(
            '[ERR][$requestId] Backend error: $message',
            fields: {
              'requestId': requestId,
              'error': message,
              'stack': stackTrace.toString(),
            },
          );
        }
        return jsonResponse({
          'error': _backendErrorCode(statusCode),
          'message': message,
          'requestId': requestId,
        }, statusCode: statusCode);
      } catch (e, stackTrace) {
        final requestId = requestIdFor(request);
        logError(
          '[ERR][$requestId] Unhandled error: $e',
          fields: {
            'requestId': requestId,
            'error': e.toString(),
            'stack': stackTrace.toString(),
          },
        );
        // Surface a sanitized, truncated message even for unanticipated
        // exceptions. This is a self-hosted appliance accessed by its owner, so
        // "PHD2 launch failed: ..." / "session 1 not found" is far more useful
        // than a bare `internal_error` — and it turns the many precondition /
        // environment failures (a guider not running, no report data, a feature
        // not configured) into something a remote client can actually act on.
        // The full cause + stack stay server-side (logged above). Auth failures
        // never reach here (they're BadRequestError / HandlerFailure above).
        final detail = _sanitizeErrorDetail(e);
        return jsonInternalServerError({
          'error': 'internal_error',
          if (detail.isNotEmpty) 'message': detail,
          'requestId': requestId,
        });
      }
    };
  };
}
