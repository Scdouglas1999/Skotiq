import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Sesame's answer for "M42", captured from the live service 2026-10-21.
const _m42Xml = '''<?xml version="1.0" encoding="UTF-8"?>
<Sesame xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
 xsi:noNamespaceSchemaLocation="https://vizier.cds.unistra.fr/xml/sesame_4x.xsd">
<Target option="S">
  <name>M42</name>
  <Resolver name="Sc=Simbad (CDS, via client/server)">
    <INFO>from cache</INFO>
    <oid>810146</oid>
    <otype>HII</otype>
    <jpos>05:35:16.82 -05:23:15.3</jpos>
    <jradeg>83.8201</jradeg>
    <jdedeg>-5.3876</jdedeg>
    <refPos>2022A&amp;A...661A..38P</refPos>
    <oname>M  42</oname>
    <nrefs>4516</nrefs>
  </Resolver>
</Target>
</Sesame>''';

const _notFoundXml = '''<?xml version="1.0" encoding="UTF-8"?>
<Sesame>
<Target option="S">
  <name>zzzz42</name>
  <INFO> *** NNNothing found *** </INFO>
</Target>
</Sesame>''';

String _sesameXml(String oname, double raDeg, double decDeg, String otype) =>
    '<Sesame><Target><Resolver><otype>$otype</otype>'
    '<jradeg>$raDeg</jradeg><jdedeg>$decDeg</jdedeg>'
    '<oname>$oname</oname></Resolver></Target></Sesame>';

void main() {
  group('SesameNameResolver', () {
    test('parses the object, coordinates and collapses SIMBAD padding', () {
      final r = SesameNameResolver.parseSesameXml(_m42Xml)!;
      expect(r.mainId, 'M 42');
      expect(r.raHours, closeTo(5.5880, 0.0001)); // 05h35m17s
      expect(r.decDegrees, closeTo(-5.3876, 0.0001)); // -05 23'
      expect(r.objectType, 'HII');
    });

    test('"Nothing found" is no object, not an error', () {
      expect(SesameNameResolver.parseSesameXml(_notFoundXml), isNull);
    });

    test('drops the NAME prefix SIMBAD puts on common names', () {
      expect(
        SesameNameResolver.displayIdentifier('NAME Heart Nebula'),
        'Heart Nebula',
      );
      expect(SesameNameResolver.displayIdentifier('NGC   891'), 'NGC 891');
    });

    test('spells catalogs the way SIMBAD knows them', () {
      expect(SesameNameResolver.simbadIdentifier('B33'), 'Barnard 33');
      expect(SesameNameResolver.simbadIdentifier('b 33'), 'Barnard 33');
      expect(SesameNameResolver.simbadIdentifier('Cr 399'), 'Collinder 399');
      expect(SesameNameResolver.simbadIdentifier('SH 2-129'), 'Sh2-129');
      expect(SesameNameResolver.simbadIdentifier('m42'), 'm42');
      expect(
        SesameNameResolver.simbadIdentifier('  Orion   Nebula '),
        'Orion Nebula',
      );
    });

    test('asks Sesame for the exact identifier, SIMBAD only', () async {
      Uri? asked;
      final resolver = SesameNameResolver(
        client: MockClient((request) async {
          asked = request.url;
          return http.Response(_m42Xml, 200);
        }),
      );
      final r = await resolver.resolve('M42');
      expect(r!.mainId, 'M 42');
      expect(asked.toString(), '${SesameNameResolver.endpoint}?M42');
    });

    test(
      'an unreachable SIMBAD throws instead of reading as "not found"',
      () async {
        final down = SesameNameResolver(
          client: MockClient(
            (_) async => throw http.ClientException('offline'),
          ),
        );
        await expectLater(
          down.resolve('M42'),
          throwsA(isA<TargetNameLookupUnavailable>()),
        );
        final error = SesameNameResolver(
          client: MockClient((_) async => http.Response('busy', 503)),
        );
        await expectLater(
          error.resolve('M42'),
          throwsA(isA<TargetNameLookupUnavailable>()),
        );
      },
    );
  });

  group('SimbadProvider.searchByName', () {
    // TAP rows shaped like the substring hits SIMBAD returns for "M42".
    final tapRows = jsonEncode({
      'data': [
        ['Cl* NGC 2516 HTR M42', 119.5, -60.8, '*', 'Cl* NGC 2516 HTR M42'],
        ['[SSP2021] M42', 10.0, 20.0, 'YSO', '[SSP2021] M42'],
        [
          '[CMR2006] J1107+7239 M42',
          166.64,
          72.63,
          'G',
          '[CMR2006] J1107+7239 M42',
        ],
      ],
    });

    http.Client fakeSimbad({bool sesameUp = true, bool tapUp = true}) =>
        MockClient((request) async {
          if (request.url.toString().startsWith(SesameNameResolver.endpoint)) {
            if (!sesameUp) throw http.ClientException('offline');
            return http.Response(_m42Xml, 200);
          }
          if (!tapUp) throw http.ClientException('offline');
          return http.Response(tapRows, 200);
        });

    test('the exact object comes first, substring hits after it', () async {
      final matches = await SimbadProvider(
        client: fakeSimbad(),
      ).searchByName('M42');
      expect(matches.first.mainId, 'M 42');
      expect(matches.first.exact, isTrue);
      expect(matches.first.raHours, closeTo(5.588, 0.001));
      expect(matches.skip(1).every((m) => !m.exact), isTrue);
      expect(matches.map((m) => m.mainId), contains('[SSP2021] M42'));
    });

    test(
      'the substring query is valid SIMBAD ADQL (no REPLACE/LOWER)',
      () async {
        String? adql;
        final client = MockClient((request) async {
          if (request.url.toString().startsWith(SesameNameResolver.endpoint)) {
            return http.Response(_notFoundXml, 200);
          }
          adql = request.bodyFields['query'];
          return http.Response(jsonEncode({'data': []}), 200);
        });
        await SimbadProvider(client: client).searchByName('m42');
        expect(adql, contains("ident.id LIKE '%m42%'"));
        expect(adql, contains("ident.id LIKE '%M42%'"));
        expect(adql!.toUpperCase(), isNot(contains('REPLACE(')));
        expect(adql!.toUpperCase(), isNot(contains('LOWER(')));
      },
    );

    test('SIMBAD unreachable is an error, not "no object named"', () async {
      await expectLater(
        SimbadProvider(
          client: fakeSimbad(sesameUp: false, tapUp: false),
        ).searchByName('M42'),
        throwsA(isA<TargetNameLookupUnavailable>()),
      );
    });

    test('a failed substring query still returns the exact object', () async {
      final matches = await SimbadProvider(
        client: fakeSimbad(tapUp: false),
      ).searchByName('M42');
      expect(matches.single.mainId, 'M 42');
    });
  });

  test('sesame resolver parses a generated answer', () {
    final r = SesameNameResolver.parseSesameXml(
      _sesameXml('NGC   891', 35.6371125, 42.34831944, 'H2G'),
    )!;
    expect(r.mainId, 'NGC 891');
    expect(r.raHours, closeTo(2.3758, 0.0001));
  });

  // Hits the real CDS services. Opt in with SKOTIQ_LIVE_SIMBAD=1; CI stays
  // offline.
  group(
    'live SIMBAD',
    () {
      const cases = <String, (String, double, double)>{
        'M42': ('M 42', 5.588, -5.388),
        'm 42': ('M 42', 5.588, -5.388),
        'NGC891': ('NGC 891', 2.376, 42.348),
        'IC 1805': ('IC 1805', 2.547, 61.471),
        'Sh2-129': ('SH 2-129', 21.197, 59.95),
        'B33': ('Horsehead Nebula', 5.683, -2.458),
        'Pleiades': ('Cl Melotte 22', 3.773, 24.114),
      };
      for (final entry in cases.entries) {
        test('${entry.key} -> ${entry.value.$1}', () async {
          final r = (await SesameNameResolver().resolve(entry.key))!;
          expect(r.mainId, entry.value.$1);
          expect(r.raHours, closeTo(entry.value.$2, 0.01));
          expect(r.decDegrees, closeTo(entry.value.$3, 0.01));
        });
      }
      test('M42 search lists M 42 first', () async {
        final matches = await SimbadProvider().searchByName('M42');
        expect(matches.first.mainId, 'M 42');
      });
    },
    skip: Platform.environment['SKOTIQ_LIVE_SIMBAD'] == '1'
        ? false
        : 'set SKOTIQ_LIVE_SIMBAD=1',
  );
}
