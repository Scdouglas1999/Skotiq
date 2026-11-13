import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' show FrameWcs;
import 'package:skotiq_core/src/services/frame_header.dart';

FrameWcs _wcs({
  double crpix1 = 50.5,
  double crpix2 = 40.5,
  double cd11 = -2.8e-4,
  double cd22 = 2.8e-4,
  int aOrder = 0,
  List<double> aCoeffs = const [],
}) => FrameWcs(
  crval1: 83.8,
  crval2: -5.4,
  crpix1: crpix1,
  crpix2: crpix2,
  cd11: cd11,
  cd12: 0,
  cd21: 0,
  cd22: cd22,
  aOrder: aOrder,
  bOrder: aOrder,
  aCoeffs: Float64List.fromList(aCoeffs),
  bCoeffs: Float64List.fromList(aCoeffs),
  apOrder: 0,
  bpOrder: 0,
  apCoeffs: Float64List(0),
  bpCoeffs: Float64List(0),
);

void main() {
  test('cards read as text and as numbers', () {
    final header = FrameHeader({
      'INSTRUME': ' ZWO ASI2600MM Pro ',
      'GAIN': 100,
      'CCD-TEMP': -9.6,
      'OBJECT': '',
    });
    expect(header.string('INSTRUME'), 'ZWO ASI2600MM Pro');
    expect(header.string('GAIN'), '100');
    expect(header.integer('GAIN'), 100);
    expect(header.integer('CCD-TEMP'), -10);
    expect(header.number('INSTRUME'), isNull);
    expect(header.string('OBJECT'), isNull);
    expect(header.firstNumber(const ['CCD_TEMP', 'CCD-TEMP']), -9.6);
  });

  test('the image size is NAXIS1 by NAXIS2, with NAXIS3 planes', () {
    expect(FrameHeader({'NAXIS1': 4, 'NAXIS2': 3}).imageSize, (
      width: 4,
      height: 3,
    ));
    expect(FrameHeader({'NAXIS1': 4, 'NAXIS2': 3}).channels, 1);
    expect(FrameHeader({'NAXIS1': 4, 'NAXIS2': 3, 'NAXIS3': 3}).channels, 3);
    expect(FrameHeader({'NAXIS1': 4}).imageSize, isNull);
    expect(FrameHeader({'NAXIS1': 0, 'NAXIS2': 3}).imageSize, isNull);
  });

  test('the stated astrometry projects over the frame from its own '
      'reference pixel, with its SIP terms', () {
    final header = FrameHeader(
      {'NAXIS1': 100, 'NAXIS2': 80},
      astrometry: _wcs(
        crpix1: 20.0,
        crpix2: 10.0,
        aOrder: 1,
        aCoeffs: [0, 0, 1e-6, 0],
      ),
    );
    final wcs = header.solvedWcs!;
    expect((wcs.imageWidth, wcs.imageHeight), (100, 80));
    expect(wcs.raHours, closeTo(83.8 / 15, 1e-12));
    expect(wcs.referencePixel, (x: 19.0, y: 9.0));
    expect(wcs.sip.aOrder, 1);
    expect(wcs.sip.aCoeffs, [0, 0, 1e-6, 0]);
  });

  test('no astrometry, no size, or a singular matrix gives no WCS', () {
    expect(FrameHeader({'NAXIS1': 100, 'NAXIS2': 80}).solvedWcs, isNull);
    expect(FrameHeader(const {}, astrometry: _wcs()).solvedWcs, isNull);
    expect(
      FrameHeader({
        'NAXIS1': 100,
        'NAXIS2': 80,
      }, astrometry: _wcs(cd11: 0, cd22: 0)).solvedWcs,
      isNull,
    );
  });
}
