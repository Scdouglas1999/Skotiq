// Unit tests for the per-star tracked-star DTO decode (Phase F, guider-ui).
//
// The built-in multi-star guider exports its tracked stars as a JSON payload
// that rides through the guiding status path (no flutter_rust_bridge regen).
// These tests pin the decode of that payload — across the native serde shape
// (snake_case, JSON string) and the network re-serialized shape (camelCase,
// parsed list) — plus the `Phd2Status.trackedStars` integration. A break in
// any of these silently empties the guider UI star list.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('GuideStar.fromJson', () {
    test('decodes native snake_case shape including lock + residual', () {
      final star = GuideStar.fromJson(const {
        'id': 2,
        'x': 123.5,
        'y': 64.25,
        'flux': 5000.0,
        'snr': 18.4,
        'is_lock': true,
        'residual': 0.42,
      });

      expect(star.id, 2);
      expect(star.x, 123.5);
      expect(star.y, 64.25);
      expect(star.flux, 5000.0);
      expect(star.snr, 18.4);
      expect(star.isLock, isTrue);
      expect(star.residual, 0.42);
    });

    test('accepts camelCase isLock from network re-serialization', () {
      final star = GuideStar.fromJson(const {
        'id': 0,
        'x': 1.0,
        'y': 2.0,
        'isLock': true,
      });
      expect(star.isLock, isTrue);
    });

    test('null residual stays null (unmatched star) and defaults are safe', () {
      final star = GuideStar.fromJson(const {
        'id': 1,
        'x': 10.0,
        'y': 11.0,
        'residual': null,
      });
      expect(star.residual, isNull);
      expect(star.flux, 0.0);
      expect(star.snr, 0.0);
      expect(star.isLock, isFalse);
    });

    test('round-trips through toJson', () {
      const star = GuideStar(
        id: 3,
        x: 5.0,
        y: 6.0,
        flux: 100.0,
        snr: 9.0,
        isLock: true,
        residual: 1.25,
      );
      final decoded = GuideStar.fromJson(star.toJson());
      expect(decoded, equals(star));
    });
  });

  group('decodeTrackedStars', () {
    test('decodes a JSON string in the BuiltinGuideTrackedStars shape', () {
      // Exactly the shape `get_tracked_stars_json()` emits in Rust.
      const raw =
          '{"count":2,"stars":['
          '{"id":0,"x":10.0,"y":12.0,"flux":5000.0,"snr":18.0,"is_lock":false,"residual":0.5},'
          '{"id":1,"x":60.0,"y":64.0,"flux":2000.0,"snr":9.0,"is_lock":true,"residual":null}'
          ']}';

      final stars = decodeTrackedStars(raw);
      expect(stars, hasLength(2));
      expect(stars[0].id, 0);
      expect(stars[0].residual, 0.5);
      expect(stars[0].isLock, isFalse);
      expect(stars[1].isLock, isTrue);
      expect(stars[1].residual, isNull);
    });

    test('decodes an already-parsed list of star maps', () {
      final raw = jsonDecode('[{"id":0,"x":1.0,"y":2.0,"snr":7.0}]');
      final stars = decodeTrackedStars(raw);
      expect(stars, hasLength(1));
      expect(stars.single.snr, 7.0);
    });

    test('decodes an already-parsed wrapper map', () {
      final raw = jsonDecode('{"count":1,"stars":[{"id":0,"x":1.0,"y":2.0}]}');
      final stars = decodeTrackedStars(raw);
      expect(stars, hasLength(1));
      expect(stars.single.id, 0);
    });

    test('empty / null / malformed inputs decode to an empty list', () {
      expect(decodeTrackedStars(null), isEmpty);
      expect(decodeTrackedStars(''), isEmpty);
      expect(decodeTrackedStars('not json {{{'), isEmpty);
      expect(decodeTrackedStars(42), isEmpty);
      expect(
        decodeTrackedStars(const {'count': 0, 'stars': <dynamic>[]}),
        isEmpty,
      );
    });
  });

  group('Phd2Status.trackedStars', () {
    test(
      'defaults to empty (PHD2 / external guiders report no per-star list)',
      () {
        const status = Phd2Status(state: 'Guiding', connected: true);
        expect(status.trackedStars, isEmpty);
      },
    );

    test(
      'fromJson decodes a trackedStars array from the network status JSON',
      () {
        final status = Phd2Status.fromJson(const {
          'state': 'Guiding',
          'connected': true,
          'rmsRa': 0.4,
          'rmsDec': 0.3,
          'rmsTotal': 0.5,
          'trackedStars': [
            {'id': 0, 'x': 10.0, 'y': 12.0, 'snr': 18.0, 'is_lock': true},
            {'id': 1, 'x': 60.0, 'y': 64.0, 'snr': 9.0, 'is_lock': false},
          ],
        });

        expect(status.trackedStars, hasLength(2));
        expect(status.trackedStars.first.isLock, isTrue);
        expect(status.rmsTotal, 0.5);
      },
    );

    test('toJson emits trackedStars so the network transport carries them', () {
      const status = Phd2Status(
        state: 'Guiding',
        connected: true,
        trackedStars: [
          GuideStar(id: 0, x: 1.0, y: 2.0, snr: 5.0, isLock: true),
        ],
      );
      final json = status.toJson();
      final tracked = json['trackedStars'] as List;
      expect(tracked, hasLength(1));
      expect((tracked.first as Map)['is_lock'], isTrue);

      // And the emitted JSON decodes back into the same list.
      final reDecoded = Phd2Status.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
      );
      expect(reDecoded.trackedStars.single.snr, 5.0);
    });
  });
}
