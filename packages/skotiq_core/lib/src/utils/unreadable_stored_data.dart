import 'logging_service.dart';

final Set<(String, int)> _reported = {};

/// Says once in the log that the stored [what] could not be read and that a
/// stand-in ([fallback], in words) is used instead.
///
/// Stored data is parsed again and again (each plan, each redraw); the same
/// unreadable [raw] is reported only the first time it is seen.
void reportUnreadableStoredData(
  String what,
  String raw,
  Object error, {
  required String fallback,
  required String source,
}) {
  if (!_reported.add((what, raw.hashCode))) return;
  Log.warning(
    'The stored $what could not be read, so $fallback is used: $error',
    source: source,
  );
}
