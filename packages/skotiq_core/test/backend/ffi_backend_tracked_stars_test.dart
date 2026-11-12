// The host FFI backend's per-star tracked-star wiring.
//
// `FfiBackend.guiderGetStatus()` fills `Phd2Status.trackedStars` for the
// built-in multi-star guider from the bridged
// `apiBuiltinGuiderGetTrackedStarsJson()` accessor; the host API serializes
// that list for linked clients. These tests pin the two ends of that seam:
//
//   1. The real `FfiBackend.guiderGetStatus()` answers a status poll with
//      "disconnected" when the native library is not loaded, rather than
//      failing the poll.
//
//   2. The exact native JSON shape that `get_tracked_stars_json()` emits
//      (`{"count":N,"stars":[...]}`, snake_case) decodes into a populated
//      `trackedStars` through the same `decodeTrackedStars` the FFI backend
//      calls, so when native reports stars the host surfaces them.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FfiBackend.guiderGetStatus (real backend)', () {
    test('with no native library the guider reads as disconnected', () async {
      final backend = FfiBackend();

      final status = await backend.guiderGetStatus(
        deviceId: builtinGuiderDeviceId,
      );

      expect(status.connected, isFalse);
      expect(status.trackedStars, isEmpty);
    });
  });

  group('host status build decodes the native tracked-star JSON', () {
    test('a populated native snapshot becomes a populated trackedStars list', () {
      // Exactly the JSON `builtin_guider::get_tracked_stars_json()` serializes
      // and the FFI backend feeds to `decodeTrackedStars` in `guiderGetStatus()`.
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
