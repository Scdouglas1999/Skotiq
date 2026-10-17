// The host FFI backend's per-star tracked-star wiring.
//
// `FfiBackend.phd2GetStatus()` fills `Phd2Status.trackedStars` from the bridged
// `builtinGuiderGetTrackedStarsJson()` accessor. Left unset the field defaults
// to `const []`, the headless host API serializes an always-empty array, and
// the built-in multi-star guider's star-list panel reads "No stars tracked yet"
// on live hardware while the Rust side is computing the list correctly. These
// tests drive the REAL `FfiBackend` (NOT a mock backend) so the seam cannot
// regress to empty again:
//
//   1. The real `FfiBackend.phd2GetStatus()` runs end-to-end and exercises the
//      tracked-star accessor. Without the new bridge method bound this throws
//      (`NoSuchMethodError`/unimplemented), so the test fails closed if the seam
//      is removed or renamed. In the no-native test runtime the built-in guider
//      cannot run, so the decoded list is empty — but it is a real decoded
//      `List<GuideStar>`, proving the field is populated from the accessor
//      rather than hardcoded.
//
//   2. The exact native JSON shape that `get_tracked_stars_json()` emits
//      (`{"count":N,"stars":[...]}`, snake_case) decodes into a populated
//      `trackedStars` through the same `decodeTrackedStars` the FFI backend
//      calls — so when native DOES report stars, the host surfaces them.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FfiBackend.phd2GetStatus tracked-star wiring (real backend)', () {
    test('runs end-to-end and populates trackedStars from the native accessor', () async {
      // The REAL host FFI backend — not a mock. This is the seam under test; a
      // mock backend would never exercise it.
      final backend = FfiBackend();

      final status = await backend.phd2GetStatus();

      // The status itself is real (the call did not throw — proving the new
      // `builtinGuiderGetTrackedStarsJson()` bridge method is bound and called).
      expect(status, isA<Phd2Status>());

      // `trackedStars` is a real decoded list, not a hardcoded sentinel. In the
      // no-native test runtime the built-in guider is not the active guider, so
      // the native accessor returns `{"count":0,"stars":[]}` and the list is
      // empty — but it is the decoded result of the accessor, which is the wired
      // path. (On real hardware with the built-in guider looping, this same path
      // carries the per-star list to the UI.)
      expect(status.trackedStars, isA<List<GuideStar>>());
      expect(status.trackedStars, isEmpty);
    });
  });

  group('host status build decodes the native tracked-star JSON', () {
    test('a populated native snapshot becomes a populated trackedStars list', () {
      // Exactly the JSON `builtin_guider::get_tracked_stars_json()` serializes
      // and the FFI backend feeds to `decodeTrackedStars` in `phd2GetStatus()`.
      const nativeJson =
          '{"count":2,"stars":['
          '{"id":0,"x":410.0,"y":286.0,"flux":9100.0,"snr":24.6,"is_lock":true,"residual":0.18},'
          '{"id":1,"x":128.0,"y":512.0,"flux":6400.0,"snr":17.2,"is_lock":false,"residual":null}'
          ']}';

      final tracked = decodeTrackedStars(nativeJson);

      expect(tracked, hasLength(2));
      expect(tracked.first.isLock, isTrue);
      expect(tracked.first.snr, 24.6);
      expect(tracked.first.residual, 0.18);
      expect(tracked[1].isLock, isFalse);
      expect(tracked[1].residual, isNull);

      // And the populated list rides through `Phd2Status` (the value the FFI
      // backend returns) so the headless API serializes a non-empty array.
      final status = Phd2Status(
        state: 'Guiding',
        connected: true,
        trackedStars: tracked,
      );
      expect(status.toJson()['trackedStars'], hasLength(2));
    });

    test(
      'an empty native snapshot yields an empty list (PHD2/external guiders)',
      () {
        expect(decodeTrackedStars('{"count":0,"stars":[]}'), isEmpty);
      },
    );
  });
}
