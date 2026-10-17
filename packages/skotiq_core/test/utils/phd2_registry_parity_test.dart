// Parity tests for the PHD2 registry split (Wave C2).
//
// The PHD2 guider id is checked by two entry points that used to carry their
// own copy of the four-spelling token list:
//
//   * `isPhd2DeviceId`        (utils/device_id.dart)      — trims + lower-cases
//   * `isPhd2GuiderDeviceId`  (services/phd2_status_poll) — exact match, null-safe
//
// They now share `isPhd2WireToken` but keep their own normalization, because
// the two are NOT interchangeable. These tests pin the exact outputs both
// copies produced before the merge, including the cases where they disagree —
// so a later "cleanup" that collapses them fails here instead of in the field.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/phd2_status_poll.dart';
import 'package:skotiq_core/src/utils/device_id.dart';

void main() {
  group('isPhd2WireToken — the shared token list', () {
    test('accepts exactly the four canonical spellings', () {
      expect(isPhd2WireToken('phd2_guider'), isTrue);
      expect(isPhd2WireToken('phd2'), isTrue);
      expect(isPhd2WireToken('phd2:localhost:4400'), isTrue);
      expect(isPhd2WireToken('phd2://localhost:4400'), isTrue);
      // Degenerate prefix forms still match — `startsWith`, as before.
      expect(isPhd2WireToken('phd2:'), isTrue);
      expect(isPhd2WireToken('phd2://'), isTrue);
    });

    test('normalizes nothing', () {
      expect(isPhd2WireToken(''), isFalse);
      expect(isPhd2WireToken('PHD2'), isFalse);
      expect(isPhd2WireToken('PHD2_GUIDER'), isFalse);
      expect(isPhd2WireToken(' phd2'), isFalse);
      expect(isPhd2WireToken('phd2 '), isFalse);
    });

    test('rejects near-misses', () {
      expect(isPhd2WireToken('phd2x-not-really-phd2'), isFalse);
      expect(isPhd2WireToken('phd 2'), isFalse);
      expect(isPhd2WireToken('native:zwo:0'), isFalse);
      expect(isPhd2WireToken('builtin_guider'), isFalse);
    });

    test('agrees with the canonical id constant', () {
      expect(kPhd2CanonicalId, 'phd2_guider');
      expect(isPhd2WireToken(kPhd2CanonicalId), isTrue);
    });
  });

  group('the two wrappers keep their pre-merge behaviour', () {
    const shared = <String>[
      'phd2_guider',
      'phd2',
      'phd2:localhost:4400',
      'phd2://localhost:4400',
    ];

    test('both accept every canonical spelling', () {
      for (final id in shared) {
        expect(isPhd2DeviceId(id), isTrue, reason: 'isPhd2DeviceId($id)');
        expect(
          isPhd2GuiderDeviceId(id),
          isTrue,
          reason: 'isPhd2GuiderDeviceId($id)',
        );
      }
    });

    test('both reject non-PHD2 ids', () {
      for (final id in <String>[
        '',
        'native:zwo:0',
        'builtin_guider',
        'phd 2',
        'phd2x-not-really-phd2',
      ]) {
        expect(isPhd2DeviceId(id), isFalse, reason: 'isPhd2DeviceId($id)');
        expect(
          isPhd2GuiderDeviceId(id),
          isFalse,
          reason: 'isPhd2GuiderDeviceId($id)',
        );
      }
    });

    test('they DISAGREE on un-normalized input, on purpose', () {
      // isPhd2DeviceId trims + lower-cases; isPhd2GuiderDeviceId does not.
      // This divergence is load-bearing: collapsing the two would widen the
      // remote-sync PHD2 short-circuit to ids the host never emits.
      for (final id in <String>['  PHD2  ', 'PHD2_GUIDER', ' phd2', 'Phd2']) {
        expect(isPhd2DeviceId(id), isTrue, reason: 'isPhd2DeviceId($id)');
        expect(
          isPhd2GuiderDeviceId(id),
          isFalse,
          reason: 'isPhd2GuiderDeviceId($id)',
        );
      }
    });

    test('only the guider-state wrapper tolerates null', () {
      expect(isPhd2GuiderDeviceId(null), isFalse);
    });
  });

  group('canonicalGuiderId still collapses onto the shared token list', () {
    test('every PHD2 spelling collapses to the canonical id', () {
      for (final id in <String>[
        'phd2',
        'phd2_guider',
        'phd2:localhost:4400',
        'phd2://localhost:4400',
        'PHD2',
      ]) {
        expect(canonicalGuiderId(id), kPhd2CanonicalId, reason: id);
      }
    });

    test('non-PHD2 ids pass through untouched, original case preserved', () {
      expect(canonicalGuiderId('native:ZWO:0'), 'native:ZWO:0');
      expect(canonicalGuiderId('builtin_guider'), 'builtin_guider');
      expect(canonicalGuiderId(''), '');
    });
  });
}
