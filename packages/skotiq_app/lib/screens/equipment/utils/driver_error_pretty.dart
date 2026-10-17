// Driver-agnostic pretty-printer for raw device error messages.
//
// The device error pipeline drops the raw driver error message
// into the device state's [DeviceError.message] field unchanged. That is
// the right thing to do for the audit trail, but the raw text is often
// hostile to the user — e.g. ASCOM hands back bare HRESULTs like
// `0x80040402`, INDI hands back `BLOB property "WEATHER" set state
// Alert`, Alpaca hands back `HTTP 500 InvalidValue`.
//
// This helper takes the raw driver string and, when it matches a pattern
// we can confidently identify, prepends a short human-readable label.
// Everything we cannot identify passes through unchanged — never mask the
// real message just because we could not pretty-print it.
//
// All transformations are conservative: we only prepend when we can
// recognize the structure with high confidence. The original message is
// always preserved verbatim in the output.

/// Pretty-prints a raw driver error message for display in a device card
/// subtitle.
///
/// Returns a record of `(short, full)`:
///   * `short` is suitable for the card subtitle (typically prefixed with
///     a human-readable label, truncated to [maxShortChars]).
///   * `full` is the full pretty-printed message, suitable for use as a
///     tooltip.
///
/// If the message cannot be recognized, both fields contain the raw
/// message (with `short` possibly truncated).
class PrettyError {
  /// The fully pretty-printed message — what to show in a tooltip.
  final String full;

  /// The pretty-printed message truncated to [maxShortChars] — what to
  /// show as the card subtitle.
  final String short;

  /// Whether [PrettyError.format] recognized the message and prepended a
  /// human-readable label. Useful for tests and for telemetry.
  final bool recognized;

  const PrettyError({
    required this.full,
    required this.short,
    required this.recognized,
  });

  /// Default truncation threshold (matches the audit spec).
  static const int maxShortChars = 80;

  /// Conservative mapping of well-known ASCOM HRESULT codes to their
  /// canonical exception/condition name. Only includes codes that show
  /// up in real-world driver bug reports; we deliberately do not invent
  /// names for codes we cannot verify.
  ///
  /// Sources:
  ///  * ASCOM Platform `ErrorCodes.cs`
  ///  * ASCOM Standards documentation
  ///  * COM `winerror.h` for the system-side codes drivers commonly raise
  ///
  /// Keys are stored lowercased so lookups are case-insensitive.
  static const Map<String, String> ascomHresultNames = {
    // ASCOM driver-specific HRESULTs (0x80040400 .. 0x80040FFF range).
    '0x80040400': 'NotImplementedException',
    '0x80040401': 'InvalidValueException',
    '0x80040402': 'ValueNotSetException',
    '0x80040403': 'NotConnectedException',
    '0x80040404': 'InvalidOperationException',
    '0x80040405': 'ActionNotImplementedException',
    '0x80040406': 'ParkedException',
    '0x80040407': 'SlavedException',
    '0x80040408': 'InvalidWhileParkedException',
    '0x80040409': 'InvalidWhileSlavedException',
    '0x8004040a': 'SettingsProviderException',
    // COM/Windows infrastructure HRESULTs ASCOM drivers commonly surface.
    '0x80040154': 'CoCreateInstance failed (class not registered)',
    '0x80004005': 'Unspecified COM error (E_FAIL)',
    '0x80020009': 'Driver raised an exception (DISP_E_EXCEPTION)',
    '0x800706ba': 'RPC server unavailable (driver process not running)',
    '0x80070005': 'Access denied (E_ACCESSDENIED)',
    '0x8007000e': 'Out of memory (E_OUTOFMEMORY)',
  };

  /// Compiled lazily so we don't re-allocate the regex on every render.
  static final RegExp _ascomHresultPattern = RegExp(
    r'(0x[0-9a-fA-F]{8})',
  );

  /// Matches a typical Alpaca HTTP error surface like:
  ///   "HTTP 500: InvalidValue"
  ///   "Alpaca returned 400 Bad Request"
  ///   "status 503"
  static final RegExp _alpacaStatusPattern = RegExp(
    r'\b(?:HTTP|status|Alpaca returned)\s*:?\s*(\d{3})\b',
    caseSensitive: false,
  );

  /// Matches INDI property/state notifications of the form:
  ///   "INDI property WEATHER set state Alert"
  ///   "indi: device CCD Simulator property CCD_EXPOSURE state Alert: ..."
  /// We do not require all fields — anything we cannot match is left
  /// untouched.
  static final RegExp _indiAlertPattern = RegExp(
    r'\b(?:INDI|indi)\b[^:]*?\bproperty\s+([A-Z0-9_]+)[^:]*?\bstate\s+(Alert|Busy)\b',
  );

  /// Format [raw] for display. See class doc for behavior.
  ///
  /// If [raw] is `null` or empty, the result wraps the literal string
  /// `"(no message)"` and is not marked as recognized.
  factory PrettyError.format(String? raw) {
    final source = (raw ?? '').trim();
    if (source.isEmpty) {
      const fallback = '(no message)';
      return const PrettyError(
        full: fallback,
        short: fallback,
        recognized: false,
      );
    }

    String? label = _classifyAscom(source);
    label ??= _classifyAlpaca(source);
    label ??= _classifyIndi(source);

    if (label == null) {
      return PrettyError(
        full: source,
        short: _truncate(source, maxShortChars),
        recognized: false,
      );
    }

    final full = '$label: $source';
    return PrettyError(
      full: full,
      short: _truncate(full, maxShortChars),
      recognized: true,
    );
  }

  static String? _classifyAscom(String source) {
    final match = _ascomHresultPattern.firstMatch(source);
    if (match == null) return null;
    final hex = match.group(1)!.toLowerCase();
    final name = ascomHresultNames[hex];
    if (name == null) return null;
    return 'ASCOM $hex $name';
  }

  static String? _classifyAlpaca(String source) {
    // Only treat as Alpaca if the source mentions Alpaca explicitly OR
    // the HTTP keyword is paired with a 3-digit status. This avoids
    // false positives on stray "500"s in vendor error text.
    if (!source.toLowerCase().contains('alpaca') &&
        !RegExp(r'\bHTTP\b', caseSensitive: false).hasMatch(source) &&
        !RegExp(r'\bstatus\s*:?\s*\d{3}\b', caseSensitive: false)
            .hasMatch(source)) {
      return null;
    }
    final match = _alpacaStatusPattern.firstMatch(source);
    if (match == null) return null;
    final code = match.group(1)!;
    final reason = _httpReason(int.parse(code));
    if (reason == null) {
      return 'Alpaca HTTP $code';
    }
    return 'Alpaca HTTP $code $reason';
  }

  static String? _classifyIndi(String source) {
    final match = _indiAlertPattern.firstMatch(source);
    if (match == null) {
      // Fall back to a generic INDI prefix only if the source clearly
      // self-identifies as INDI, so we don't claim non-INDI errors are
      // INDI errors.
      if (RegExp(r'^\s*INDI\b', caseSensitive: false).hasMatch(source)) {
        return 'INDI';
      }
      return null;
    }
    final property = match.group(1)!;
    final state = match.group(2)!;
    return 'INDI $property $state';
  }

  /// Subset of HTTP status texts we surface from Alpaca responses.
  /// Kept small and verifiable — we don't synthesize reasons we cannot
  /// confirm against the Alpaca / HTTP specs.
  static String? _httpReason(int code) {
    switch (code) {
      case 400:
        return 'Bad Request';
      case 401:
        return 'Unauthorized';
      case 403:
        return 'Forbidden';
      case 404:
        return 'Not Found';
      case 408:
        return 'Request Timeout';
      case 409:
        return 'Conflict';
      case 500:
        return 'Internal Server Error';
      case 502:
        return 'Bad Gateway';
      case 503:
        return 'Service Unavailable';
      case 504:
        return 'Gateway Timeout';
      default:
        return null;
    }
  }

  static String _truncate(String value, int max) {
    if (value.length <= max) return value;
    // Reserve room for an ellipsis so it's clear the message was cut.
    if (max <= 1) return value.substring(0, max);
    return '${value.substring(0, max - 1)}…';
  }
}
