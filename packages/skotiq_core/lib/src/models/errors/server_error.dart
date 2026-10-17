//
// Structured representation of the headless server's error envelope.
//
// From the start the headless API returns errors as JSON like:
//
//     { "code": "pairing_required",
//       "message": "No paired token presented",
//       "details": { "deviceId": "ascom:camera:foo" } }
//
// Old client code (and the existing `SkotiqError.fromString`) flattened
// those into a single string and the UI lost the machine-readable `code`.
// [ServerError] preserves both halves so mobile SnackBars can render
// "<message> (<code>)" and severity-tinted callsites can branch on the
// HTTP status without parsing the message text.
//
// This type lives alongside [SkotiqError] rather than replacing it:
// [SkotiqError] is the richer cross-FFI model used by Rust-originated
// failures; [ServerError] is the thin wire-envelope shape that comes back
// over HTTP from the headless API. Treating them separately keeps each
// faithful to its source of truth.

class ServerError implements Exception {
  /// Machine-readable error code (e.g. 'pairing_required',
  /// 'rate_limited', 'device_busy'). Lower-snake_case by convention.
  final String code;

  /// Human-readable message intended for direct display.
  final String message;

  /// HTTP status code the response carried. Null when [ServerError] was
  /// constructed from a non-HTTP source (e.g. a WebSocket error frame
  /// that uses the same envelope shape).
  final int? httpStatus;

  /// Optional structured details map. Free-form per-endpoint, but always
  /// JSON-serializable so it can be logged and round-tripped over the
  /// wire intact.
  final Map<String, dynamic>? details;

  const ServerError({
    required this.code,
    required this.message,
    this.httpStatus,
    this.details,
  });

  /// Decode the headless server's error envelope. Returns null when the
  /// JSON doesn't look like the envelope shape at all (no human message
  /// under either the canonical `message` key or the legacy `error` key),
  /// so callers can fall through to a less-structured parser (e.g.
  /// [SkotiqError.fromString]).
  ///
  /// Three wire shapes converge onto one [ServerError] here:
  ///
  ///   1. Canonical `{code, message, details?}` — the original envelope.
  ///   2. Unified `{error, code, message, ...}` — the backward-compatible
  ///      transition envelope emitted by `jsonError`, where `error`
  ///      mirrors `message` for legacy display-only clients. The
  ///      machine `code` always wins over the legacy `error` field.
  ///   3. Legacy prose-only `{error: '...'}` — the historical bodies that
  ///      carried a human string but no machine code AND no `message`. The
  ///      prose is taken as the [message] and a stable non-empty [code] is
  ///      synthesized from the HTTP status so machine-readable callsites
  ///      still get a code instead of null.
  ///
  /// Deliberately NOT matched here (returns null, falls through to the
  /// caller's status-based / `SkotiqError.fromString` fallback):
  /// the older two-field `{error, message}` shape where `error` is a
  /// category label and `message` is the detail, and the bare `{message}`
  /// shape. Those have no machine `code` and pre-date the envelope, so
  /// converging them would change their long-standing surfaced type.
  static ServerError? tryFromJson(
    Map<String, dynamic> json, {
    int? httpStatus,
  }) {
    final explicitCode = _firstNonEmptyString(json['code']);
    final messageField = _firstNonEmptyString(json['message']);
    final errorField = _firstNonEmptyString(json['error']);

    // The human message: prefer the canonical `message`, fall back to the
    // legacy prose `error`. Without either, this isn't an error envelope.
    final message = messageField ?? errorField;
    if (message == null) return null;

    final String code;
    if (explicitCode != null) {
      // Shapes (1) and (2): an explicit machine code is authoritative.
      code = explicitCode;
    } else if (messageField == null) {
      // Shape (3): prose-only `{error}` with no `message` and no `code`.
      // Synthesize a stable, non-empty code from the HTTP status so the
      // ~225 legacy prose bodies still converge on a machine-readable code.
      code = _synthesizeCode(httpStatus);
    } else {
      // `{error, message}` two-field or bare `{message}` with no code:
      // not the envelope. Let the caller's fallback build a SkotiqError
      // so we don't change those callsites' long-standing surfaced type.
      return null;
    }

    Map<String, dynamic>? details;
    final rawDetails = json['details'];
    if (rawDetails is Map<String, dynamic>) {
      details = rawDetails;
    } else if (rawDetails is Map) {
      details = rawDetails.cast<String, dynamic>();
    }

    return ServerError(
      code: code,
      message: message,
      httpStatus: httpStatus,
      details: details,
    );
  }

  /// Returns [value] when it is a non-empty [String], else null.
  static String? _firstNonEmptyString(Object? value) {
    if (value is String && value.isNotEmpty) return value;
    return null;
  }

  /// Synthesize a machine-readable code for legacy prose-only bodies that
  /// carried no `code`. Derived from the HTTP status so callers still get a
  /// meaningful, branchable code; falls back to the generic `error` when no
  /// status is available (e.g. a WebSocket error frame).
  static String _synthesizeCode(int? httpStatus) {
    switch (httpStatus) {
      case 400:
        return 'bad_request';
      case 401:
        return 'unauthorized';
      case 403:
        return 'forbidden';
      case 404:
        return 'not_found';
      case 409:
        return 'conflict';
      case 413:
        return 'payload_too_large';
      case 426:
        return 'upgrade_required';
      case 429:
        return 'rate_limited';
      case 500:
        return 'internal_error';
      case 501:
        return 'not_implemented';
      case 503:
        return 'service_unavailable';
      default:
        return 'error';
    }
  }

  /// True if the underlying status code indicates a client-side problem
  /// (auth, validation, rate limit, etc.). Used by the mobile SnackBar
  /// helper to choose an amber tint over the harsher red.
  bool get isClientError {
    final status = httpStatus;
    return status != null && status >= 400 && status < 500;
  }

  /// True if the underlying status code indicates a server-side failure.
  bool get isServerError {
    final status = httpStatus;
    return status != null && status >= 500;
  }

  Map<String, dynamic> toJson() => {
    'code': code,
    'message': message,
    if (httpStatus != null) 'httpStatus': httpStatus,
    if (details != null) 'details': details,
  };

  @override
  String toString() {
    final statusSuffix = httpStatus != null ? ' [HTTP $httpStatus]' : '';
    return '$message ($code)$statusSuffix';
  }
}
