// A secondary component of a multiple star never enters the catalogue named
// after its raw row id.
//
// The chart draws the label "Capella"; clicking it must not open a panel headed
// "HYG118360" with the chip "HYG118360" and "mag 1.0". HYG carries the Capella
// system as two rows — id 24549 (hip 24608, proper "Capella", mag 0.08) and id
// 118360 (no hip, no proper name, no Bayer letter, mag 0.96, comp 2,
// comp_primary 24549), the Ab component 9 arcsec away. An unnamed row that
// falls through the name chain to its own id lets search and the object panel
// show a star called "HYG118360" that no chart ever labels.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

const _header =
    '"id","hip","hd","hr","gl","bf","proper","ra","dec","dist","pmra",'
    '"pmdec","rv","mag","absmag","spect","ci","x","y","z","vx","vy","vz",'
    '"rarad","decrad","pmrarad","pmdecrad","bayer","flam","con","comp",'
    '"comp_primary","base","lum","var","var_min","var_max"';

/// The real HYG v4.2 rows for the Capella system, trimmed of the columns the
/// parser does not read.
const _capellaAa =
    '24549,24608,34029,1708,Gl 194A,"13Alp Aur",Capella,5.27815,45.997991,'
    '13.1234,75.52,-427.13,22.2,0.08,-0.51,M1: comp,0.795,0,0,0,0,0,0,0,0,0,0,'
    'Alp,"13",Aur,1,24549,Gl 194,139.3,"",,';
const _capellaAb =
    '118360,,,,Gl 194B,"","",5.277926,46.000842,12.9383,80.57,-422.38,33.9,'
    '0.96,0.401,G0 III,,0,0,0,0,0,0,0,0,0,0,"","",Aur,2,24549,Gl 194,60.2,"",,';

/// An ordinary unnamed field star: comp 1, its own primary. Must keep the id
/// fallback — there is no system to name it after.
const _fieldStar =
    '90001,,,,,"","",12.0,10.0,100,0,0,0,8.4,4.0,G5,0.6,0,0,0,0,0,0,0,0,0,0,'
    '"","",Vir,1,90001,,1.0,"",,';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hyg_component_naming');
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

  test(
    'an unnamed secondary is named after its primary, not after its id',
    () async {
      final stars = await loadFrom([_capellaAa, _capellaAb]);

      expect(stars.map((s) => s.name), isNot(contains('HYG118360')));

      final secondary = stars.firstWhere((s) => s.id == 'HYG118360');
      expect(secondary.name, 'Capella B');
      expect(
        secondary.magnitude,
        closeTo(0.96, 1e-6),
        reason:
            'the component keeps its own brightness; only the name is derived',
      );

      final primary = stars.firstWhere((s) => s.name == 'Capella');
      expect(primary.id, 'HIP24608');
      expect(primary.magnitude, closeTo(0.08, 1e-6));
    },
  );

  test('a star that is nobody\'s component keeps the id fallback', () async {
    final stars = await loadFrom([_fieldStar]);
    expect(stars.single.name, 'HYG90001');
  });

  test('a component whose primary is unnamed is left alone', () async {
    // Same Ab row, but the primary row carries no designation of its own.
    const unnamedPrimary =
        '24549,,,,,"","",5.27815,45.997991,13.1234,0,0,0,0.08,-0.51,M1,0.795,'
        '0,0,0,0,0,0,0,0,0,0,"","",Aur,1,24549,,139.3,"",,';
    final stars = await loadFrom([unnamedPrimary, _capellaAb]);

    expect(
      stars.firstWhere((s) => s.id == 'HYG118360').name,
      'HYG118360',
      reason: 'nothing may be invented when the system itself has no name',
    );
  });
}
