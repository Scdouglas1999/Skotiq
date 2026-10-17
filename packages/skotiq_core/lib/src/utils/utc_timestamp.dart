/// Parsing helpers for ISO-8601 timestamps that cross a language or wire
/// boundary.
///
/// The native bridge stamps frames with `chrono::Utc::now()` and remote hosts
/// serialise UTC instants, so these strings always denote UTC. `DateTime.parse`
/// reads an offset-less string as *local* time, which silently shifts the
/// instant by the host's timezone offset — a frame then claims a `DATE-OBS` it
/// was not taken at. Treat the offset-less form as UTC and preserve any
/// explicit designator.
library;

final RegExp _explicitUtcOffset = RegExp(r'(?:[zZ]|[+-]\d{2}:?\d{2})$');

/// Parse [value] as the UTC instant it denotes.
///
/// Throws a [FormatException] when [value] is not ISO-8601.
DateTime parseUtcTimestamp(String value) {
  final trimmed = value.trim();
  return DateTime.parse(
    _explicitUtcOffset.hasMatch(trimmed) ? trimmed : '${trimmed}Z',
  ).toUtc();
}

/// Parse [value] as the UTC instant it denotes, or `null` when [value] is
/// `null` or not ISO-8601.
DateTime? tryParseUtcTimestamp(String? value) {
  if (value == null) return null;
  try {
    return parseUtcTimestamp(value);
  } on FormatException {
    return null;
  }
}

/// Rewrite [value] as an explicitly-UTC ISO-8601 string.
///
/// Returns [value] unchanged when it is empty or unparseable.
String normalizeUtcTimestamp(String value) {
  if (value.trim().isEmpty) return value;
  try {
    return parseUtcTimestamp(value).toIso8601String();
  } on FormatException {
    return value;
  }
}
