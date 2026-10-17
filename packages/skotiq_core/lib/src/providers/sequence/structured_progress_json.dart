/// Decoding for `InstructionProgressStructured.detail_json`.
///
/// The native side stringifies the `ProgressDetail` payload before it crosses
/// the bridge — `api/sequencer/event_translation.rs` does `payload.to_string()`
/// into `SequencerEvent::InstructionProgressStructured { detail_json: String }`
/// — and `event_mapping.dart` puts that String on `event.data['detail_json']`
/// verbatim. The remote (JSON) transport carries the same String. So a
/// consumer that reads the field as a Map reads nothing, on every host.
///
/// Every consumer therefore goes through this one decode, and the tests feed
/// the String shape, so a reader cannot accept a shape production does not
/// send.
library;

import 'dart:convert';

/// Decode a `detail_json` payload into the structured value consumers expect.
///
/// - a JSON String is decoded (this is what production sends)
/// - an empty String is an empty payload rather than a parse error
/// - anything already decoded is passed through
/// - an unparseable String is returned wrapped as `{'raw': ...}` so a display
///   consumer can still show it and a numeric consumer reads no numbers from it
Object? decodeStructuredProgressJson(Object? raw) {
  if (raw is String) {
    if (raw.trim().isEmpty) return const <String, Object?>{};
    try {
      return jsonDecode(raw);
    } catch (_) {
      return {'raw': raw};
    }
  }
  return raw;
}
