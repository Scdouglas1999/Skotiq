import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

void main() {
  test('line figures expose the complete constellation catalog', () {
    expect(Constellations.all, hasLength(88));
    expect(Constellations.findByAbbreviation('ori')?.name, 'Orion');
    expect(Constellations.findByName('ORION')?.abbreviation, 'Ori');
  });

  test('boundary lookup exposes the complete catalog and resolves Orion', () {
    expect(ConstellationBoundaries.all, hasLength(88));
    expect(ConstellationBoundaries.getBoundary('Ori'), isNotEmpty);
    expect(ConstellationBoundaries.getConstellationAtCoordinate(5.5, 0), 'Ori');
  });
}
