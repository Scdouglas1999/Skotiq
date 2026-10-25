// How the Darkroom shows a color composite: the measured parameters of its
// channel combination as readable lines, and the per-channel histogram of a
// color preview.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/darkroom/darkroom_measured_values.dart';
import 'package:skotiq_app/screens/darkroom/edit/darkroom_editor.dart';

void main() {
  test('the combination inputs read as filters, registration and files', () {
    final lines = darkroomMeasuredValueLines('inputs', [
      {
        'role': 'luminance',
        'filter': 'L',
        'path': r'C:\Users\me\masters\NGC0891_L_master.fits',
        'width': 4656,
        'height': 3520,
        'reference': true,
      },
      {
        'role': 'red',
        'filter': 'R',
        'path': '/masters/NGC0891_R_master.fits',
        'width': 4656,
        'height': 3520,
        'transform': [1.0, 0.0, 70.55, 0.0, 1.0, 19.91],
      },
    ]);
    expect(lines, [
      'L (luminance): the reference, NGC0891_L_master.fits',
      'R (red): shifted 70.5, 19.9 px, rotated 0.000°, NGC0891_R_master.fits',
    ]);
  });

  test('the crop, the fits and the star profiles read as sentences', () {
    expect(
      darkroomMeasuredValueLines('crop', {
        'x': 96,
        'y': 32,
        'width': 4544,
        'height': 3456,
      }),
      ['4544 x 3456 px, starting at (96, 32) on the reference master'],
    );
    expect(
      darkroomMeasuredValueLines('fits', {
        'luminanceToRgb': {'scale': 0.48177, 'offset': 358.16},
      }),
      ['Luminance matched to the RGB: scale 0.4818, offset 358.2'],
    );
    expect(
      darkroomMeasuredValueLines('starSigma', {'red': 2.5}),
      ['red stars: half-flux radius 2.94 px'],
    );
    expect(darkroomMeasuredValueLines('fits', <String, dynamic>{}), [
      'measured on every render',
    ]);
  });

  test('a color preview histograms each channel separately', () {
    // Two pixels: one pure red at full scale, one mid gray.
    final rgba = Uint8List.fromList([255, 0, 0, 255, 128, 128, 128, 255]);
    final histogram = DarkroomHistogram.of(rgba, isColor: true);
    expect(histogram.channels, hasLength(3));
    expect(histogram.channels[0].last, 0.5);
    expect(histogram.channels[0][32], 0.5);
    expect(histogram.channels[1].first, 0.5);
    expect(histogram.clipped, [0.5, 0.0, 0.0]);
    expect(histogram.peak, 0.5);

    final mono = DarkroomHistogram.of(rgba, isColor: false);
    expect(mono.channels, hasLength(1));
  });
}
