import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// The HYG catalogue's first data row (id 0) is the SUN, carried as a
/// placeholder at RA 0h / Dec 0 with magnitude -26.7 because the catalogue's
/// cartesian coordinates are heliocentric. It is not a sky position.
///
/// Left in the loaded set it drew a huge blob labelled "Sol" in the middle of
/// Pisces, and — being by far the brightest entry in a magnitude-sorted index —
/// it was the first result of every brightest-in-view query whose region
/// touched RA 0h / Dec 0. The real Sun is drawn separately from its ephemeris.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hyg_sun_row_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Future<List<Star>> loadFrom(String csv) async {
    final file = File('${tempDir.path}/hyg.csv');
    await file.writeAsString(csv);
    return HygStarCatalog(
      catalogPath: file.path,
      magnitudeLimit: 15,
    ).loadObjects();
  }

  // Header plus the real HYG id-0 Sun row, then a genuine star (Sirius-like).
  const header =
      '"id","hip","hd","hr","gl","bf","proper","ra","dec","dist","pmra",'
      '"pmdec","rv","mag","absmag","spect","ci","x","y","z","vx","vy","vz",'
      '"rarad","decrad","pmrarad","pmdecrad","bayer","flam","con","comp",'
      '"comp_primary","base","lum","var","var_min","var_max"';
  const sunRow =
      '0,,,,"","",Sol,0.0,0.0,0.0,0.0,0.0,0.0,-26.7,4.85,G2V,0.656,0.000005,'
      '0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,"","","",1,0,"",1.0,"",,';
  const realStar =
      '32263,32349,48915,2491,"Gl 244A","Alp CMa",Sirius,6.752481,-16.716116,'
      '2.6371,-546.01,-1223.07,-9.4,-1.44,1.45,A0m...,0.009,-0.494,1.998,'
      '-1.548,0.0,0.0,0.0,1.767794,-0.291752,0.0,0.0,"Alp","9","CMa",1,32263,'
      '"",25.4,"",,';

  test('the HYG id-0 Sun placeholder row is not loaded as a star', () async {
    final stars = await loadFrom('$header\n$sunRow\n$realStar');

    expect(
      stars.any((s) => s.name.toLowerCase() == 'sol'),
      isFalse,
      reason: 'the Sun placeholder row must be filtered out',
    );
    expect(
      stars.any((s) => (s.magnitude ?? 0) < -20),
      isFalse,
      reason: 'no real catalogue star is anywhere near magnitude -26',
    );
  });

  test('filtering the Sun row does not drop genuine stars', () async {
    final stars = await loadFrom('$header\n$sunRow\n$realStar');

    expect(stars, hasLength(1));
    expect(stars.single.name, 'Sirius');
    expect(stars.single.magnitude, closeTo(-1.44, 0.001));
    // RA is carried in hours by CelestialCoordinate.
    expect(stars.single.coordinates.ra, closeTo(6.752, 0.01));
    expect(stars.single.coordinates.dec, closeTo(-16.716, 0.01));
  });
}
