// Serde cover for the `TargetTrigger` sealed family.
//
// `TargetTrigger` lives in
// `lib/src/models/sequence/sequence_models.dart` and is a hand-rolled
// sealed class hierarchy. The Rust side
// (`native/skotiq_native/sequencer/src/scheduling/target_trigger.rs`)
// uses serde's `#[serde(tag = "kind", content = "value")]` encoding, so
// the Dart `toJson()` shape is a byte-for-byte contract.
//
// Every leaf trigger gets:
//   * a JSON shape pin (the snake_case-free wire format is significant
//     because Rust's `TargetTrigger` uses PascalCase tag names rather
//     than the snake_case used for the rest of the sequencer types),
//   * a `fromJson(toJson(x)) == x` round-trip,
//   * an equality / hashCode check (two trigger instances with the same
//     payload must be `==`, mutating any field breaks equality),
//   * a `referencesAltitude` / `hasEmptyCompound` sanity check.
//
// Compound triggers (And, Or) additionally get nested-payload tests so
// the recursive JSON encoder/decoder stays symmetric.
//
// Trigger JSON keys are PascalCase ("AltitudeAbove"), NOT snake_case, which
// mirrors Rust's serde externally-tagged enum encoding.
//
// Compound triggers (And/Or) carry the children list inside the `value` slot
// (a JSON array). HourAngleBetweenTrigger carries a JSON object with two
// double fields `minHa` / `maxHa` — camelCase, NOT snake_case (matching the
// Rust struct's field names).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('AltitudeAboveTrigger', () {
    test('json_shape_matches_rust_serde_tag_content_pascal_case', () {
      const t = AltitudeAboveTrigger(35.5);
      expect(t.toJson(), equals({'kind': 'AltitudeAbove', 'value': 35.5}));
    });

    test('json_round_trip_preserves_altitude', () {
      const t = AltitudeAboveTrigger(28.75);
      final back = TargetTrigger.fromJson(
        jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>,
      );
      expect(back, isA<AltitudeAboveTrigger>());
      expect(back, equals(t));
    });

    test('references_altitude_returns_true', () {
      expect(const AltitudeAboveTrigger(30.0).referencesAltitude, isTrue);
      expect(const AltitudeAboveTrigger(30.0).hasEmptyCompound, isFalse);
    });

    test('equality_breaks_when_altitude_differs', () {
      expect(
        const AltitudeAboveTrigger(30.0),
        equals(const AltitudeAboveTrigger(30.0)),
      );
      expect(
        const AltitudeAboveTrigger(30.0).hashCode,
        equals(const AltitudeAboveTrigger(30.0).hashCode),
      );
      expect(
        const AltitudeAboveTrigger(30.0),
        isNot(equals(const AltitudeAboveTrigger(35.0))),
      );
    });
  });

  group('AltitudeBelowTrigger', () {
    test('json_shape_matches_rust_serde_tag_content_pascal_case', () {
      const t = AltitudeBelowTrigger(60.0);
      expect(t.toJson(), equals({'kind': 'AltitudeBelow', 'value': 60.0}));
    });

    test('json_round_trip_preserves_altitude', () {
      const t = AltitudeBelowTrigger(45.5);
      final back = TargetTrigger.fromJson(
        jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>,
      );
      expect(back, isA<AltitudeBelowTrigger>());
      expect(back, equals(t));
    });

    test('references_altitude_true_has_empty_compound_false', () {
      expect(const AltitudeBelowTrigger(60.0).referencesAltitude, isTrue);
      expect(const AltitudeBelowTrigger(60.0).hasEmptyCompound, isFalse);
    });

    test('equality_and_hash_distinguish_altitude_below_from_above', () {
      // Each trigger subclass mixes the discriminator into hashCode
      // (`Object.hash('AltitudeAbove', altitudeDeg)`), so two triggers with
      // the same numeric payload but different kinds are NOT equal.
      expect(
        const AltitudeAboveTrigger(30.0),
        isNot(equals(const AltitudeBelowTrigger(30.0))),
      );
    });
  });

  group('TimeAfterTrigger', () {
    test('json_shape_uses_int_unix_secs_in_value', () {
      // 2026-05-25T00:00:00Z = 1779840000 (approx)
      const t = TimeAfterTrigger(1779840000);
      expect(t.toJson(), equals({'kind': 'TimeAfter', 'value': 1779840000}));
      // TimeAfter / TimeBefore carry an integer wire value (Unix seconds).
      // fromJson uses `(raw as num).toInt()`, so a double on the wire is
      // accepted, but the canonical form is int.
    });

    test('json_round_trip_preserves_unix_seconds', () {
      const t = TimeAfterTrigger(1779840000);
      final back = TargetTrigger.fromJson(
        jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>,
      );
      expect(back, isA<TimeAfterTrigger>());
      expect(back, equals(t));
    });

    test('references_altitude_false', () {
      expect(const TimeAfterTrigger(0).referencesAltitude, isFalse);
      expect(const TimeAfterTrigger(0).hasEmptyCompound, isFalse);
    });

    test('equality_and_hash_match_for_same_payload', () {
      expect(const TimeAfterTrigger(42), equals(const TimeAfterTrigger(42)));
      expect(
        const TimeAfterTrigger(42).hashCode,
        equals(const TimeAfterTrigger(42).hashCode),
      );
      expect(
        const TimeAfterTrigger(42),
        isNot(equals(const TimeAfterTrigger(43))),
      );
    });
  });

  group('TimeBeforeTrigger', () {
    test('json_shape_pin', () {
      const t = TimeBeforeTrigger(1779840000);
      expect(t.toJson(), equals({'kind': 'TimeBefore', 'value': 1779840000}));
    });

    test('json_round_trip', () {
      const t = TimeBeforeTrigger(1234567890);
      final back = TargetTrigger.fromJson(
        jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>,
      );
      expect(back, isA<TimeBeforeTrigger>());
      expect(back, equals(t));
    });

    test('not_equal_to_time_after_with_same_unix_seconds', () {
      // Discriminator in hashCode must distinguish the variants.
      expect(
        const TimeBeforeTrigger(42),
        isNot(equals(const TimeAfterTrigger(42))),
      );
    });
  });

  group('HourAngleBetweenTrigger', () {
    test('json_shape_uses_nested_object_value_with_camelCase_keys', () {
      // HourAngleBetween is the only trigger whose `value` is a JSON OBJECT
      // rather than a scalar. Its keys are camelCase (`minHa` / `maxHa`), NOT
      // snake_case, matching the Rust struct's field names.
      const t = HourAngleBetweenTrigger(minHa: -2.0, maxHa: 2.0);
      expect(
        t.toJson(),
        equals({
          'kind': 'HourAngleBetween',
          'value': {'minHa': -2.0, 'maxHa': 2.0},
        }),
      );
    });

    test('json_round_trip_preserves_both_endpoints', () {
      const t = HourAngleBetweenTrigger(minHa: -3.5, maxHa: 3.5);
      final back = TargetTrigger.fromJson(
        jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>,
      );
      expect(back, isA<HourAngleBetweenTrigger>());
      expect(back, equals(t));
    });

    test('references_altitude_false_has_empty_compound_false', () {
      const t = HourAngleBetweenTrigger(minHa: -1.0, maxHa: 1.0);
      expect(t.referencesAltitude, isFalse);
      expect(t.hasEmptyCompound, isFalse);
    });

    test('equality_distinguishes_min_and_max', () {
      const a = HourAngleBetweenTrigger(minHa: -1.0, maxHa: 1.0);
      const b = HourAngleBetweenTrigger(minHa: -1.0, maxHa: 1.0);
      const c = HourAngleBetweenTrigger(minHa: -1.5, maxHa: 1.0);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });
  });

  group('AndTrigger', () {
    test('json_shape_uses_value_array_of_nested_triggers', () {
      const t = AndTrigger([
        AltitudeAboveTrigger(35.0),
        TimeAfterTrigger(1779840000),
      ]);
      expect(
        t.toJson(),
        equals({
          'kind': 'And',
          'value': [
            {'kind': 'AltitudeAbove', 'value': 35.0},
            {'kind': 'TimeAfter', 'value': 1779840000},
          ],
        }),
      );
    });

    test('json_round_trip_preserves_child_order_and_kinds', () {
      const t = AndTrigger([
        AltitudeAboveTrigger(30.0),
        HourAngleBetweenTrigger(minHa: -2.0, maxHa: 2.0),
        TimeAfterTrigger(100),
      ]);
      final back = TargetTrigger.fromJson(
        jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>,
      );
      expect(back, isA<AndTrigger>());
      expect(back, equals(t));
    });

    test('references_altitude_true_when_any_child_does', () {
      expect(
        const AndTrigger([
          TimeAfterTrigger(0),
          AltitudeAboveTrigger(30.0),
        ]).referencesAltitude,
        isTrue,
      );
      expect(
        const AndTrigger([
          TimeAfterTrigger(0),
          TimeBeforeTrigger(100),
        ]).referencesAltitude,
        isFalse,
      );
    });

    test('has_empty_compound_true_when_children_empty', () {
      expect(const AndTrigger([]).hasEmptyCompound, isTrue);
    });

    test('has_empty_compound_propagates_from_nested_compound', () {
      expect(const AndTrigger([AndTrigger([])]).hasEmptyCompound, isTrue);
    });

    test('equality_requires_same_child_order', () {
      const a = AndTrigger([AltitudeAboveTrigger(30.0), TimeAfterTrigger(0)]);
      const b = AndTrigger([AltitudeAboveTrigger(30.0), TimeAfterTrigger(0)]);
      const c = AndTrigger([TimeAfterTrigger(0), AltitudeAboveTrigger(30.0)]);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      // Child order is significant for equality: list equality is
      // order-sensitive.
      expect(a, isNot(equals(c)));
    });
  });

  group('OrTrigger', () {
    test('json_shape_mirrors_and_trigger_but_with_or_tag', () {
      const t = OrTrigger([AltitudeAboveTrigger(35.0), TimeBeforeTrigger(200)]);
      expect(
        t.toJson(),
        equals({
          'kind': 'Or',
          'value': [
            {'kind': 'AltitudeAbove', 'value': 35.0},
            {'kind': 'TimeBefore', 'value': 200},
          ],
        }),
      );
    });

    test('json_round_trip_preserves_nested_compound_structures', () {
      const t = OrTrigger([
        AndTrigger([AltitudeAboveTrigger(30.0), TimeAfterTrigger(0)]),
        HourAngleBetweenTrigger(minHa: -1.0, maxHa: 1.0),
      ]);
      final back = TargetTrigger.fromJson(
        jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>,
      );
      expect(back, isA<OrTrigger>());
      expect(back, equals(t));
    });

    test('has_empty_compound_true_for_empty_or', () {
      expect(const OrTrigger([]).hasEmptyCompound, isTrue);
    });

    test('or_and_with_same_children_are_not_equal', () {
      const a = OrTrigger([AltitudeAboveTrigger(30.0)]);
      const b = AndTrigger([AltitudeAboveTrigger(30.0)]);
      expect(a, isNot(equals(b)));
    });
  });

  group('TargetTrigger.fromJson error handling', () {
    test('unknown_kind_throws_format_exception', () {
      expect(
        () => TargetTrigger.fromJson({'kind': 'Bogus', 'value': 0.0}),
        throwsA(isA<FormatException>()),
      );
    });

    test('missing_kind_throws_format_exception', () {
      expect(
        () => TargetTrigger.fromJson({'value': 0.0}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('evaluateTargetTrigger sanity (data-shape behaviour)', () {
    // `evaluateTargetTrigger` is a free function that switches on the sealed
    // family, not a virtual method on the class, so the dispatch lives outside
    // the class. A representative input per leaf keeps the evaluator's parity
    // with the wire protocol pinned.
    test('altitude_above_satisfied_when_altitude_meets_threshold', () {
      expect(
        evaluateTargetTrigger(
          const AltitudeAboveTrigger(30.0),
          altitudeDeg: 35.0,
          hourAngleHours: 0.0,
          nowUnix: 0,
        ),
        isTrue,
      );
    });

    test('and_with_empty_children_is_false', () {
      // Empty And/Or returns false: the fall-through case in
      // `evaluateTargetTrigger` early-returns rather than letting
      // `[].every(...)` return `true`. This differs from a Rust "all of
      // empty is true" reading, deliberately.
      expect(
        evaluateTargetTrigger(
          const AndTrigger([]),
          altitudeDeg: 90,
          hourAngleHours: 0,
          nowUnix: 0,
        ),
        isFalse,
      );
    });
  });
}
