import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/science/aperture_photometry.dart';

/// Write a 16-bit FITS (BZERO 32768, as ASI drivers save) of [w] x [h] with
/// a flat sky of [sky] ADU, Gaussian noise of [noise] ADU and Gaussian stars.
File _fits(
  Directory dir, {
  required int w,
  required int h,
  required double sky,
  required double noise,
  required List<({double x, double y, double flux, double fwhm})> stars,
}) {
  final random = math.Random(7);
  double gauss() =>
      math.sqrt(-2 * math.log(1 - random.nextDouble())) *
      math.cos(2 * math.pi * random.nextDouble());
  final header = StringBuffer();
  void card(String key, String value) =>
      header.write('${key.padRight(8)}= ${value.padLeft(20)}'.padRight(80));
  card('SIMPLE', 'T');
  card('BITPIX', '16');
  card('NAXIS', '2');
  card('NAXIS1', '$w');
  card('NAXIS2', '$h');
  card('BZERO', '32768');
  card('BSCALE', '1');
  header.write('END'.padRight(80));
  final headerBytes = header.toString().padRight(2880).codeUnits;
  final data = ByteData(((w * h * 2 + 2879) ~/ 2880) * 2880);
  for (var j = 0; j < h; j++) {
    for (var i = 0; i < w; i++) {
      var v = sky + noise * gauss();
      for (final s in stars) {
        final sigma = s.fwhm / 2.3548;
        final r2 = (i - s.x) * (i - s.x) + (j - s.y) * (j - s.y);
        v +=
            s.flux /
            (2 * math.pi * sigma * sigma) *
            math.exp(-r2 / (2 * sigma * sigma));
      }
      data.setInt16((j * w + i) * 2, (v.round() - 32768).clamp(-32768, 32767));
    }
  }
  final file = File('${dir.path}/frame.fits');
  file.writeAsBytesSync([...headerBytes, ...data.buffer.asUint8List()]);
  return file;
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('aperture-test'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('stars in one aperture keep their true flux ratio', () async {
    // A target and a comparison twice as bright, on a 2400 ADU sky with the
    // 140 ADU noise of an M67 G frame, FWHM 4.6 px.
    final file = _fits(
      dir,
      w: 160,
      h: 100,
      sky: 2400,
      noise: 140,
      stars: [
        (x: 40.3, y: 50.6, flux: 300000, fwhm: 4.6),
        (x: 115.7, y: 48.2, flux: 600000, fwhm: 4.6),
      ],
    );
    final result = (await measureApertures(
      file.path,
      [(x: 40.3, y: 50.6), (x: 115.7, y: 48.2)],
      radius: 7,
      innerSky: 14,
      outerSky: 21,
    ))!;
    final target = result[0]!, comparison = result[1]!;
    expect(target.sky, closeTo(2400, 10));
    expect(comparison.flux / target.flux, closeTo(2.0, 0.01));
    // Within 7 px (1.5 FWHM) a Gaussian holds 99.8% of its light.
    expect(target.flux, closeTo(300000 * 0.998, 300000 * 0.01));
    // Background error: 140 ADU pixel noise over the aperture, plus the
    // error of a median sky from the 770-pixel annulus.
    const area = math.pi * 49;
    const annulus = math.pi * (21 * 21 - 14 * 14);
    expect(
      target.backgroundSigma,
      closeTo(
        140 * math.sqrt(area * (1 + area * math.pi / (2 * annulus))),
        120,
      ),
    );
  });

  test('a star whose annulus leaves the image is not measured', () async {
    final file = _fits(
      dir,
      w: 60,
      h: 60,
      sky: 1000,
      noise: 30,
      stars: [(x: 5, y: 30, flux: 50000, fwhm: 4)],
    );
    final result = await measureApertures(
      file.path,
      [(x: 5, y: 30)],
      radius: 6,
      innerSky: 12,
      outerSky: 18,
    );
    expect(result, [null]);
  });
}
