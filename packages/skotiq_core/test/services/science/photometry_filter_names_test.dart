// Photometry reads a filter's band by the filter-name rule the wheel moves
// by, so a broadband filter named with its maker ("ZWO R", "Baader B") keeps
// its standard band and AAVSO code, and narrowband frames are found under any
// spelling of their filter.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/services/science/narrowband_frames.dart';
import 'package:skotiq_core/src/services/science/photometric_bands.dart';

DbCapturedImage _light(int id, String filter) => DbCapturedImage(
  id: id,
  filePath: '/f$id.fits',
  fileName: 'f$id.fits',
  fileFormat: 'fits',
  frameType: 'light',
  exposureDuration: 120,
  binX: 1,
  binY: 1,
  filter: filter,
  capturedAt: DateTime.utc(2026, 11, 20, 22, id),
  isPlateSolved: false,
  createdAt: DateTime.utc(2026, 11, 20, 22, id),
  isAccepted: true,
);

void main() {
  test('a broadband filter named with its maker keeps its standard band', () {
    for (final (name, code, band) in [
      ('ZWO R', 'TR', PhotometricBand.sloanR),
      ('Baader B', 'TB', PhotometricBand.johnsonB),
      ('Astronomik G', 'TG', PhotometricBand.johnsonV),
      ('Red', 'TR', PhotometricBand.sloanR),
    ]) {
      final mapping = filterBandFor(name);
      expect(mapping.isStandard, isTrue, reason: name);
      expect(mapping.aavsoFilterCode, code, reason: name);
      expect(mapping.band, band, reason: name);
    }
    expect(normalizeFilterKey('ZWO R'), normalizeFilterKey('R'));
    expect(normalizeFilterKey('Baader Ha 7nm'), 'Ha');
  });

  test('the photometric spellings the rule has no band for stay', () {
    expect(normalizeFilterKey('V'), 'V');
    expect(normalizeFilterKey('Johnson V'), 'V');
    expect(normalizeFilterKey('Johnson B'), 'B');
    expect(normalizeFilterKey('Rc'), 'R');
    expect(normalizeFilterKey('CLR'), 'L');
    expect(normalizeFilterKey('None'), '');
    expect(normalizeFilterKey(''), '');
    expect(normalizeFilterKey('UV/IR Cut'), 'UV/IR Cut');
    expect(filterBandFor('L').aavsoFilterCode, 'CV');
    expect(filterBandFor('Ha').isStandard, isFalse);
  });

  test('narrowband frames are found under any spelling of their filter', () {
    final frames = latestNarrowbandFrames([
      _light(1, 'Hydrogen alpha'),
      _light(2, 'Optolong OIII 6.5nm'),
      _light(3, 'Sulfur II'),
      _light(4, 'Ha/OIII'),
    ]);
    expect(frames, isNotNull);
    expect(frames!.hAlpha.id, 1);
    expect(frames.oiii.id, 2);
    expect(frames.sii.id, 3);
  });
}
