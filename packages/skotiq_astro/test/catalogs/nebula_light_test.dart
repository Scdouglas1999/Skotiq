// The nebula light table refines the OpenNGC type of each nebula it lists:
// a nebula published catalogs class as reflection reads as a reflection
// nebula wherever the app shows or reasons about its type.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:test/test.dart';

const _header =
    'Name;Type;RA;Dec;Const;MajAx;MinAx;PosAng;B-Mag;V-Mag;J-Mag;H-Mag;K-Mag;'
    'SurfBr;Hubble;Pax;Pm-RA;Pm-Dec;RadVel;Redshift;Cstar U-Mag;Cstar B-Mag;'
    'Cstar V-Mag;M;NGC;IC;Cstar Names;Identifiers;Common names;NED notes;'
    'OpenNGC notes;Sources';

String _row(String name, String type) => [
  name,
  type,
  '01:00:00.00',
  '+30:00:00.0',
  'Per',
  '4',
  ...List.filled(26, ''),
].join(';');

void main() {
  group('dsoTypeFromOpenNgcCode with a nebula light', () {
    test('a generic nebula becomes emission or reflection', () {
      expect(
        dsoTypeFromOpenNgcCode('Neb', light: NebulaLight.emission),
        DsoType.emissionNebula,
      );
      expect(
        dsoTypeFromOpenNgcCode('Neb', light: NebulaLight.reflection),
        DsoType.reflectionNebula,
      );
    });

    test('a cluster with nebula keeps the cluster', () {
      expect(
        dsoTypeFromOpenNgcCode('Cl+N', light: NebulaLight.emission),
        DsoType.clusterWithEmissionNebula,
      );
      expect(
        dsoTypeFromOpenNgcCode('Cl+N', light: NebulaLight.reflection),
        DsoType.clusterWithReflectionNebula,
      );
      expect(DsoType.clusterWithReflectionNebula.isCluster, isTrue);
    });

    test('an HII region with emission stays an HII region', () {
      expect(
        dsoTypeFromOpenNgcCode('HII', light: NebulaLight.emission),
        DsoType.hiiRegion,
      );
    });

    test('a typed nebula takes the class the catalogs give', () {
      expect(
        dsoTypeFromOpenNgcCode('HII', light: NebulaLight.reflection),
        DsoType.reflectionNebula,
      );
      expect(
        dsoTypeFromOpenNgcCode('RfN', light: NebulaLight.emission),
        DsoType.emissionNebula,
      );
    });

    test(
      'no light, or a type that is not a nebula, keeps the OpenNGC type',
      () {
        expect(dsoTypeFromOpenNgcCode('Neb'), DsoType.nebula);
        expect(dsoTypeFromOpenNgcCode('Cl+N'), DsoType.clusterWithNebulosity);
        expect(
          dsoTypeFromOpenNgcCode('PN', light: NebulaLight.reflection),
          DsoType.planetaryNebula,
        );
        expect(
          dsoTypeFromOpenNgcCode('G', light: NebulaLight.emission),
          DsoType.galaxy,
        );
      },
    );
  });

  group('parseNebulaLightTable', () {
    test('reads the rows and skips comments and the header', () {
      final table = parseNebulaLightTable(
        '# Generated\n'
        'Name;Light;Emission;Reflection\n'
        'NGC0001;reflection;;Magakian 1\n'
        'IC0002;emission;Sh2-1;Ced 1\n',
      );
      expect(table, {
        'NGC0001': NebulaLight.reflection,
        'IC0002': NebulaLight.emission,
      });
    });

    test('a damaged row is an error, not a quiet fallback', () {
      expect(
        () => parseNebulaLightTable('NGC0001;bright;;\n'),
        throwsFormatException,
      );
    });
  });

  test(
    'the OpenNGC reader applies the table to the objects it lists',
    () async {
      final dir = await Directory.systemTemp.createTemp('sk_nebula_light_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File(p.join(dir.path, 'NGC.csv'));
      await file.writeAsString(
        [
          _header,
          _row('NGC0001', 'Neb'),
          _row('NGC0002', 'Cl+N'),
          _row('NGC0003', 'Neb'),
        ].join('\n'),
      );

      final objects = await OpenNgcDsoCatalog(
        file.path,
        nebulaLight: const {
          'NGC0001': NebulaLight.reflection,
          'NGC0002': NebulaLight.emission,
        },
      ).load();
      final types = {for (final o in objects) o.id: o.type};

      expect(types, {
        'NGC1': DsoType.reflectionNebula,
        'NGC2': DsoType.clusterWithEmissionNebula,
        'NGC3': DsoType.nebula,
      });
    },
  );
}
