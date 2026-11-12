import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

const _cluster = CelestialObjectAnnotation(
  id: 'dso_NGC7380',
  name: 'NGC7380',
  catalogId: 'NGC 7380',
  commonName: "Wizard Nebula, cluster",
  type: ObjectType.starCluster,
  ra: 341.82,
  dec: 58.1325,
  x: 500,
  y: 500,
  magnitude: 7.2,
  size: 25,
);

const _star = CelestialObjectAnnotation(
  id: 'star_1',
  name: 'HD 213930',
  type: ObjectType.star,
  ra: 15.0,
  dec: -1.5,
  x: 10,
  y: 20,
);

void main() {
  group('CSV', () {
    test('has one header row and one row per object, quoting commas', () {
      final lines = AnnotationExportFormat.csv
          .render([_cluster, _star])
          .trimRight()
          .split('\n');
      expect(lines, hasLength(3));
      expect(
        lines[0],
        'Name,Common name,Catalog ID,Type,RA J2000 (deg),Dec J2000 (deg),'
        'RA J2000,Dec J2000,Magnitude,Size (arcmin)',
      );
      expect(
        lines[1],
        'NGC7380,"Wizard Nebula, cluster",NGC 7380,Star cluster,341.820000,'
        '58.132500,22h 47m 16.8s,"+58° 07\' 57""",7.20,25.00',
      );
      expect(
        lines[2],
        'HD 213930,,,Star,15.000000,-1.500000,01h 00m 00.0s,'
        '"-01° 30\' 00""",,',
      );
    });
  });

  group('DS9 regions', () {
    test('writes FK5 circles sized from the catalog diameter', () {
      final lines = AnnotationExportFormat.ds9Region
          .render([_cluster, _star])
          .trimRight()
          .split('\n');
      expect(lines.first, '# Region file format: DS9 version 4.1');
      expect(lines[2], 'fk5');
      expect(
        lines[3],
        'circle(341.820000,58.132500,750.0") '
        '# color=green text={Wizard Nebula, cluster}',
      );
      expect(
        lines[4],
        'circle(15.000000,-1.500000,30.0") # color=white text={HD 213930}',
      );
    });

    test('drops braces that would end the label early', () {
      final region = AnnotationExportFormat.ds9Region.render([
        _star.copyWith(name: 'odd {name}'),
      ]);
      expect(region, contains('text={odd name}'));
    });
  });
}
