// Reusable JsonConverters for the sequence-models freezed migration.
//
// The Rust side (`native/skotiq_native/sequencer/`) uses serde with
// non-standard encodings for two field types that freezed/json_serializable
// don't handle out of the box:
//
//   * `BinningMode` is serialised as a PascalCase string ("One" .. "Four")
//     to match Rust's `#[serde(rename_all = "PascalCase")]` on the
//     `BinningMode` enum. The default `json_serializable` enum encoder would
//     emit the lowercase Dart enum name ("one" .. "four"), which is wire-
//     incompatible.
//
//   * `DateTime` fields like `ConditionsScore.generatedAt` and
//     `AdaptiveSwapRuntimeState.lastSwapAt` are serialised as unix epoch
//     seconds (i64 on the Rust side via `serde_with`). The default
//     `json_serializable` `DateTime` encoder emits ISO-8601 strings, which
//     is also wire-incompatible.
//
// These converters preserve the wire format byte-for-byte. They live in a
// sibling file so any future model in this directory can reuse them by
// annotating its freezed class with `@BinningModeConverter()` /
// `@UnixSecsDateTimeConverter()`.

import 'package:freezed_annotation/freezed_annotation.dart';

import 'sequence_models.dart' show BinningMode;

/// PascalCase string ↔ [BinningMode] converter.
///
/// Wire format: `"One"` / `"Two"` / `"Three"` / `"Four"` (matches Rust's
/// `#[serde(rename_all = "PascalCase")]` `BinningMode`).
///
/// Behaviour:
///   * `toJson(BinningMode.two)` → `"Two"`.
///   * `fromJson("Two")` → `BinningMode.two`.
///   * `fromJson(null)` or any unrecognised string → [BinningMode.one]
///     (matches the pre-freezed `_rustStringToBinningMode` fall-through
///     default — Phase 2 contract test pins this behaviour).
class BinningModeJsonConverter implements JsonConverter<BinningMode, String?> {
  const BinningModeJsonConverter();

  @override
  BinningMode fromJson(String? value) {
    switch (value) {
      case 'One':
        return BinningMode.one;
      case 'Two':
        return BinningMode.two;
      case 'Three':
        return BinningMode.three;
      case 'Four':
        return BinningMode.four;
      default:
        // Mirrors the pre-freezed `_rustStringToBinningMode` default
        // branch. The default-to-1x1 behaviour is pinned by the Phase 1
        // `FilterPlan` missing-field-default contract test.
        return BinningMode.one;
    }
  }

  @override
  String toJson(BinningMode mode) {
    switch (mode) {
      case BinningMode.one:
        return 'One';
      case BinningMode.two:
        return 'Two';
      case BinningMode.three:
        return 'Three';
      case BinningMode.four:
        return 'Four';
    }
  }
}

/// Unix-epoch-seconds (int) ↔ UTC [DateTime] converter.
///
/// Wire format: integer seconds since 1970-01-01T00:00:00Z. Matches the
/// Rust side's `serde_with::TimestampSeconds<i64>` encoding used for
/// `ConditionsScore.generated_unix_secs`, `AdaptiveSwapRuntimeState
/// .last_swap_unix_secs`, etc.
///
/// Behaviour:
///   * `toJson(DateTime)` → integer seconds, always normalised to UTC
///     before division so a local-time `DateTime` round-trips the same
///     instant. Sub-second precision is lost (intentional — the wire
///     format is i64 seconds).
///   * `fromJson(int)` → `DateTime.fromMillisecondsSinceEpoch(... ,
///     isUtc: true)`. The resulting `DateTime` has `isUtc == true`, which
///     the Phase 1 `ConditionsScore.from_json_parses_unix_secs_as_utc`
///     contract test pins.
class UnixSecsDateTimeConverter implements JsonConverter<DateTime, int> {
  const UnixSecsDateTimeConverter();

  @override
  DateTime fromJson(int unixSecs) =>
      DateTime.fromMillisecondsSinceEpoch(unixSecs * 1000, isUtc: true);

  @override
  int toJson(DateTime instant) =>
      instant.toUtc().millisecondsSinceEpoch ~/ 1000;
}

/// Nullable variant of [UnixSecsDateTimeConverter].
///
/// Wire format: integer seconds, or `null`. Mirrors
/// `AdaptiveSwapRuntimeState.lastSwapAt` semantics — when null, the JSON
/// field is present with value `null` (not omitted). Phase 1's
/// `null_last_swap_serialises_as_null_field` contract test pins this.
class NullableUnixSecsDateTimeConverter
    implements JsonConverter<DateTime?, int?> {
  const NullableUnixSecsDateTimeConverter();

  @override
  DateTime? fromJson(int? unixSecs) {
    if (unixSecs == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(unixSecs * 1000, isUtc: true);
  }

  @override
  int? toJson(DateTime? instant) {
    if (instant == null) return null;
    return instant.toUtc().millisecondsSinceEpoch ~/ 1000;
  }
}
