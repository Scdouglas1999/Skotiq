/// The one form an instant takes on the wire between a host and its clients.
library;

/// Writes an instant for the wire.
extension WireTime on DateTime {
  /// This instant as UTC ISO 8601 with a `Z`, whatever zone the value is in.
  ///
  /// A host and the client reading it are not always in one time zone, and a
  /// local time sent without an offset reads as the reader's own local time.
  String toWireTime() => toUtc().toIso8601String();
}

/// Reads a wire time as the reader's local time, or null when [raw] is not a
/// timestamp.
///
/// A host from before [WireTime] sent its local wall-clock time with no
/// offset. That form still parses, as the same wall-clock time here: right
/// when host and reader share a zone, which is all such a host could ever
/// show correctly.
DateTime? tryParseWireTime(String raw) => DateTime.tryParse(raw)?.toLocal();

/// [tryParseWireTime] for a field that must hold a timestamp.
DateTime parseWireTime(String raw) => DateTime.parse(raw).toLocal();
