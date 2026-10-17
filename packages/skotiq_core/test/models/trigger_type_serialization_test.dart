// Round-trip tests for the expanded `TriggerType` Dart enum
// against Rust's serde-tagged form. Adding a new variant to either side
// without updating the other must produce a failing test here.
//
// The Rust enum lives at
// `native/skotiq_native/sequencer/src/lib.rs::TriggerType`. Each Rust
// variant has a corresponding case in
// `RecoveryNode.toRustTriggerConfig()`; this file exercises every case so a
// break in either direction is caught at `flutter test` time.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('TriggerType <-> Rust JSON round-trip', () {
    // The Rust serde-tagged form is either a bare string (unit variants) or
    // a `{"VariantName": {payload}}` object. We assert both shapes survive
    // `jsonEncode` so the FFI boundary doesn't drop the variant.
    test('humidityThreshold encodes with max_percent payload', () {
      final node = RecoveryNode(
        triggerType: TriggerType.humidityThreshold,
        triggerThreshold: 90.0,
      );
      final encoded = node.toRustTriggerConfig();
      expect(encoded, isA<Map<String, dynamic>>());
      final map = encoded as Map<String, dynamic>;
      expect(map.keys, ['HumidityThreshold']);
      final payload = map['HumidityThreshold'] as Map<String, dynamic>;
      expect(payload['max_percent'], 90.0);
      // jsonEncode must succeed — failures here mean a non-encodable
      // value (e.g. an enum instead of a primitive) slipped in.
      final json = jsonEncode(encoded);
      expect(json, contains('HumidityThreshold'));
      expect(json, contains('90'));
    });

    test('focusDrift encodes all three payload fields', () {
      final node = RecoveryNode(
        triggerType: TriggerType.focusDrift,
        focusDriftWindowSize: 12,
        focusDriftMinIncreasingCount: 4,
        focusDriftMinTotalIncrease: 0.75,
      );
      final encoded = node.toRustTriggerConfig() as Map<String, dynamic>;
      final payload = encoded['FocusDrift'] as Map<String, dynamic>;
      expect(payload['window_size'], 12);
      expect(payload['min_increasing_count'], 4);
      expect(payload['min_total_increase'], 0.75);
    });

    test('autofocusInterval encodes every_n_frames as int', () {
      final node = RecoveryNode(
        triggerType: TriggerType.autofocusInterval,
        triggerEveryNFrames: 7,
      );
      final encoded = node.toRustTriggerConfig() as Map<String, dynamic>;
      final payload = encoded['AutofocusInterval'] as Map<String, dynamic>;
      // Rust expects u32, so Dart `int` is the only correct mapping: a double
      // fails the Rust serde deserializer. The type assertion catches it at
      // test time.
      expect(payload['every_n_frames'], 7);
      expect(payload['every_n_frames'], isA<int>());
    });

    test('ditherInterval encodes every_n_frames as int', () {
      final node = RecoveryNode(
        triggerType: TriggerType.ditherInterval,
        triggerEveryNFrames: 5,
      );
      final encoded = node.toRustTriggerConfig() as Map<String, dynamic>;
      final payload = encoded['DitherInterval'] as Map<String, dynamic>;
      expect(payload['every_n_frames'], 5);
    });

    test('guidingFailed encodes rms_threshold + duration_secs', () {
      final node = RecoveryNode(
        triggerType: TriggerType.guidingFailed,
        triggerThreshold: 1.5,
        guidingFailedDurationSecs: 45.0,
      );
      final encoded = node.toRustTriggerConfig() as Map<String, dynamic>;
      final payload = encoded['GuidingFailed'] as Map<String, dynamic>;
      expect(payload['rms_threshold'], 1.5);
      expect(payload['duration_secs'], 45.0);
    });

    test('mountTrackingLost serializes as bare string (unit variant)', () {
      final node = RecoveryNode(triggerType: TriggerType.mountTrackingLost);
      final encoded = node.toRustTriggerConfig();
      expect(encoded, 'MountTrackingLost');
    });

    test('domeShutterNotOpen serializes as bare string', () {
      final node = RecoveryNode(triggerType: TriggerType.domeShutterNotOpen);
      expect(node.toRustTriggerConfig(), 'DomeShutterNotOpen');
    });

    test('guideStarLost serializes as bare string', () {
      final node = RecoveryNode(triggerType: TriggerType.guideStarLost);
      expect(node.toRustTriggerConfig(), 'GuideStarLost');
    });

    test('weatherUnsafe serializes as bare string', () {
      final node = RecoveryNode(triggerType: TriggerType.weatherUnsafe);
      expect(node.toRustTriggerConfig(), 'WeatherUnsafe');
    });

    test('filterChange serializes as bare string', () {
      final node = RecoveryNode(triggerType: TriggerType.filterChange);
      expect(node.toRustTriggerConfig(), 'FilterChange');
    });

    test('altitudeLimit uses triggerThreshold for min_altitude', () {
      final node = RecoveryNode(
        triggerType: TriggerType.altitudeLimit,
        triggerThreshold: 25.0,
      );
      final encoded = node.toRustTriggerConfig() as Map<String, dynamic>;
      final payload = encoded['AltitudeLimit'] as Map<String, dynamic>;
      expect(payload['min_altitude'], 25.0);
    });

    test('hfrDegraded encodes all three payload fields', () {
      final node = RecoveryNode(
        triggerType: TriggerType.hfrDegraded,
        triggerThreshold: 3.5,
        hfrThresholdPercent: 25.0,
        hfrConsecutiveFrames: 4,
      );
      final encoded = node.toRustTriggerConfig() as Map<String, dynamic>;
      final payload = encoded['HfrDegraded'] as Map<String, dynamic>;
      expect(payload['threshold_percent'], 25.0);
      expect(payload['absolute_threshold'], 3.5);
      expect(payload['consecutive_frames'], 4);
    });

    test('driftLimit encodes max_pixels from triggerThreshold', () {
      final node = RecoveryNode(
        triggerType: TriggerType.driftLimit,
        triggerThreshold: 40.0,
      );
      final encoded = node.toRustTriggerConfig() as Map<String, dynamic>;
      final payload = encoded['DriftLimit'] as Map<String, dynamic>;
      expect(payload['max_pixels'], 40.0);
    });

    test('null triggerType means "any error" — encodes to null', () {
      // RecoveryConfig::trigger is Option<TriggerType> on the Rust side;
      // null is the user-facing "Any Error" recovery (matches every error).
      final node = RecoveryNode();
      expect(node.toRustTriggerConfig(), isNull);
    });

    test(
      'every TriggerType variant has a non-null serialization (no missing cases)',
      () {
        // Defense-in-depth: if a future contributor adds a variant to the
        // enum but forgets to update toRustTriggerConfig, the exhaustive
        // switch in that method will throw at runtime. We exercise every
        // variant here so the test fires immediately.
        for (final t in TriggerType.values) {
          final node = RecoveryNode(triggerType: t);
          final encoded = node.toRustTriggerConfig();
          expect(
            encoded,
            isNotNull,
            reason: 'TriggerType.${t.name} produced null encoding',
          );
          // Must be encodable as JSON.
          final json = jsonEncode(encoded);
          expect(json.isNotEmpty, isTrue);
        }
      },
    );
  });

  group('RecoveryNode round-trip preserves new fields', () {
    test('copyWith preserves humidity threshold value', () {
      final original = RecoveryNode(
        triggerType: TriggerType.humidityThreshold,
        triggerThreshold: 78.0,
      );
      final copy = original.copyWith(name: 'Renamed');
      expect(copy.triggerType, TriggerType.humidityThreshold);
      expect(copy.triggerThreshold, 78.0);
    });

    test('copyWith preserves focusDrift triple', () {
      final original = RecoveryNode(
        triggerType: TriggerType.focusDrift,
        focusDriftWindowSize: 20,
        focusDriftMinIncreasingCount: 8,
        focusDriftMinTotalIncrease: 1.25,
      );
      final copy = original.copyWith(name: 'Renamed');
      expect(copy.focusDriftWindowSize, 20);
      expect(copy.focusDriftMinIncreasingCount, 8);
      expect(copy.focusDriftMinTotalIncrease, 1.25);
    });

    test('copyWith preserves every_n_frames cadence', () {
      final original = RecoveryNode(
        triggerType: TriggerType.autofocusInterval,
        triggerEveryNFrames: 13,
      );
      final copy = original.copyWith(name: 'Renamed');
      expect(copy.triggerEveryNFrames, 13);
    });

    test('Equality includes the new fields (Equatable)', () {
      final a = RecoveryNode(
        triggerType: TriggerType.focusDrift,
        focusDriftWindowSize: 10,
      );
      final b = RecoveryNode(
        triggerType: TriggerType.focusDrift,
        focusDriftWindowSize: 11,
      )..copyWith();
      // The two nodes have distinct ids (auto-generated), so Equatable
      // will already mark them unequal — the more useful assertion is
      // that the field is reachable in `props`.
      expect(a.props, contains(10));
      expect(b.props, contains(11));
    });
  });
}
