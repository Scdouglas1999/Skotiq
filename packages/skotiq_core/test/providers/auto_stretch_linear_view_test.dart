// The Stretch toggle: on shows the frame stretched, off shows it linear.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('linear view', () {
    test('scales darkest to black and brightest to white', () {
      final rgba = linearDisplayRgba(
        LinearDisplayParams(
          Uint16List.fromList([1000, 3000, 5000, 1000]),
          2,
          2,
        ),
      );
      expect(rgba.sublist(0, 4), [0, 0, 0, 255]);
      expect(rgba.sublist(4, 8), [127, 127, 127, 255]);
      expect(rgba.sublist(8, 12), [255, 255, 255, 255]);
    });

    test('reads raw pixels as values or as little-endian bytes', () {
      expect(
        rawPixelsFromBackend(Uint16List.fromList([1, 2, 3, 4]), pixelCount: 4),
        [1, 2, 3, 4],
      );
      expect(
        rawPixelsFromBackend(<int>[1, 0, 2, 0, 0, 1, 255, 255], pixelCount: 4),
        [1, 2, 256, 65535],
      );
      expect(rawPixelsFromBackend(<int>[1, 2, 3], pixelCount: 4), isNull);
    });

    test('the default stretch is the one every frame already carries', () {
      expect(isDefaultScreenStretch(AutoStretchSettings.defaults()), isTrue);
      expect(
        isDefaultScreenStretch(
          AutoStretchSettings.defaults().copyWith(
            method: AutoStretchMethod.asinh,
          ),
        ),
        isFalse,
      );
      expect(AutoStretchSettings.defaults().enabled, isTrue);
      expect(
        AutoStretchSettings.fromJson(const <String, dynamic>{}).enabled,
        isTrue,
      );
    });
  });
}
