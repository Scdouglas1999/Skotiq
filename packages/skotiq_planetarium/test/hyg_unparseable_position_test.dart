// A HYG row whose ra/dec column will not parse must be SKIPPED, never loaded
// at RA 0h / Dec 0.
//
// The parser used to coerce an unparseable coordinate to 0, which is a real
// place on the sky in Pisces — the very position the id-0 Sun row is dropped
// for (see hyg_sun_row_test.dart). A truncated export, an encoding glitch or an
// upstream column reorder therefore did not lose a star, it INVENTED one: a
// named entry with a real magnitude sitting at 0h/0°, answering
// brightest-object-in-view queries over that region and offering itself as a
// slew target.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

const _header =
    '"id","hip","hd","hr","gl","bf","proper","ra","dec","dist","pmra",'
    '"pmdec","rv","mag","absmag","spect","ci","x","y","z","vx","vy","vz",'
    '"rarad","decrad","pmrarad","pmdecrad","bayer","flam","con","comp",'
    '"comp_primary","base","lum","var","var_min","var_max"';

/// A genuine row (Sirius), used as the control: the load must still work.
const _realStar =
    '32263,32349,48915,2491,"Gl 244A","Alp CMa",Sirius,6.752481,-16.716116,'
    '2.6371,-546.01,-1223.07,-9.4,-1.44,1.45,A0m...,0.009,-0.494,1.998,'
    '-1.548,0.0,0.0,0.0,1.767794,-0.291752,0.0,0.0,"Alp","9","CMa",1,32263,'
    '"",25.4,"",,';

/// Same shape as [_realStar] but with the named columns replaced.
String _rowWithPosition(String id, String name, String ra, String dec) =>
    '$id,,,,"","",$name,$ra,$dec,'
    '2.6371,0.0,0.0,-9.4,2.10,1.45,A0V,0.009,0.0,0.0,'
    '0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,"","","CMa",1,$id,'
    '"",25.4,"",,';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hyg_position_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Future<List<Star>> loadFrom(List<String> rows) async {
    final file = File('${tempDir.path}/hyg.csv');
    await file.writeAsString([_header, ...rows].join('\n'));
    return HygStarCatalog(
      catalogPath: file.path,
      magnitudeLimit: 15,
    ).loadObjects();
  }

  test('a row with an unparseable RA is skipped, not placed at 0h', () async {
    final stars = await loadFrom([
      _rowWithPosition('90001', 'BadRa', 'abc', '12.5'),
      _realStar,
    ]);

    expect(
      stars.any((s) => s.name == 'BadRa'),
      isFalse,
      reason: 'a star with no readable RA has no position to draw it at',
    );
    expect(stars.single.name, 'Sirius');
  });

  test('a row with an empty Dec column is skipped', () async {
    final stars = await loadFrom([
      _rowWithPosition('90002', 'NoDec', '5.5', ''),
      _realStar,
    ]);

    expect(stars.any((s) => s.name == 'NoDec'), isFalse);
    expect(stars.single.name, 'Sirius');
  });

  test('a NaN coordinate is skipped rather than drawn nowhere', () async {
    final stars = await loadFrom([
      _rowWithPosition('90003', 'NanStar', 'NaN', 'NaN'),
      _realStar,
    ]);

    expect(
      stars.any((s) => s.name == 'NanStar'),
      isFalse,
      reason:
          'double.tryParse accepts the literal "NaN"; a NaN coordinate '
          'survives every projection as a star that matches nothing',
    );
    expect(stars.single.name, 'Sirius');
  });

  test(
    'no loaded star sits at exactly RA 0h / Dec 0 after a malformed row',
    () async {
      final stars = await loadFrom([
        _rowWithPosition('90004', 'BadBoth', 'x', 'y'),
        _realStar,
      ]);

      expect(
        stars.any((s) => s.coordinates.ra == 0.0 && s.coordinates.dec == 0.0),
        isFalse,
        reason:
            'RA 0h / Dec 0 is a real place in Pisces; a phantom there wins '
            'brightest-in-view queries over that region',
      );
    },
  );

  test('a genuine row at RA 0h is still loaded', () async {
    // The fix must reject unreadable columns, not legitimate zeros: HYG carries
    // real stars within an arcminute of 0h, and Dec 0 is the celestial equator.
    final stars = await loadFrom([
      _rowWithPosition('90005', 'ZeroPoint', '0.0', '0.0'),
    ]);

    expect(stars, hasLength(1));
    expect(stars.single.name, 'ZeroPoint');
    expect(stars.single.coordinates.ra, 0.0);
    expect(stars.single.coordinates.dec, 0.0);
  });
}
