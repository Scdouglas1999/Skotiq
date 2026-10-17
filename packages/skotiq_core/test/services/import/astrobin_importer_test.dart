import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/import/import_result.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/services/import/astrobin_importer.dart';
import 'package:skotiq_core/src/services/import/canonical_node_mapper.dart';

void main() {
  // Minimal in-memory catalog covering the M-objects in the fixture.
  final catalog = InMemoryCatalogLookup([
    const MapEntry(
      'M42',
      CatalogLookupResult(
        canonicalName: 'M42 (Orion Nebula)',
        raHours: 5.5881,
        decDegrees: -5.391,
      ),
    ),
    const MapEntry(
      'M31',
      CatalogLookupResult(
        canonicalName: 'M31 (Andromeda)',
        raHours: 0.7122,
        decDegrees: 41.269,
      ),
    ),
    const MapEntry(
      'M81',
      CatalogLookupResult(
        canonicalName: 'M81 (Bode\'s Galaxy)',
        raHours: 9.9258,
        decDegrees: 69.0653,
      ),
    ),
    const MapEntry(
      'M51',
      CatalogLookupResult(
        canonicalName: 'M51 (Whirlpool)',
        raHours: 13.4979,
        decDegrees: 47.1953,
      ),
    ),
  ]);

  group('AstrobinImporter sniff', () {
    test('detects astrobin headers', () async {
      final content = await File(
        'test/services/import/fixtures/astrobin_basic.csv',
      ).readAsString();
      expect(AstrobinImporter.sniff(content), isTrue);
    });

    test('does not mis-detect Telescopius CSV as Astrobin', () async {
      final content = await File(
        'test/services/import/fixtures/telescopius_single.csv',
      ).readAsString();
      expect(AstrobinImporter.sniff(content), isFalse);
    });
  });

  group('AstrobinImporter integration parsing', () {
    test('parses plain decimal hours', () async {
      const csv =
          'Title,Subject,Integration\n'
          '"Test","M42","6.5"\n';
      final summary = await AstrobinImporter(catalog: catalog).parse(csv);
      expect(summary.totalRows, 1);
      expect(summary.resolvedRows, 1);
      expect(summary.root.children, hasLength(1));
      final attrs = summary.root.children.first.attributes;
      expect(attrs['astrobinIntegrationHours'], closeTo(6.5, 1e-6));
    });

    test('parses "Nh Mm" format', () async {
      const csv =
          'Title,Subject,Integration\n'
          '"Test","M42","6h 30m"\n';
      final summary = await AstrobinImporter(catalog: catalog).parse(csv);
      final attrs = summary.root.children.first.attributes;
      expect(attrs['astrobinIntegrationHours'], closeTo(6.5, 1e-6));
    });

    test('parses Hh:MM format', () async {
      const csv =
          'Title,Subject,Integration\n'
          '"Test","M42","6:30"\n';
      final summary = await AstrobinImporter(catalog: catalog).parse(csv);
      final attrs = summary.root.children.first.attributes;
      expect(attrs['astrobinIntegrationHours'], closeTo(6.5, 1e-6));
    });
  });

  group('CatalogSearchLookup', () {
    test(
      'prefers an exact catalog id over an earlier partial result',
      () async {
        final lookup = CatalogSearchLookup(
          (_) async => const [
            CatalogLookupResult(
              canonicalName: 'M31 satellite field',
              raHours: 0.5,
              decDegrees: 40,
            ),
            CatalogLookupResult(
              canonicalName: 'Andromeda Galaxy',
              raHours: 0.7122,
              decDegrees: 41.269,
              identifiers: ['NGC 224', 'M 31'],
            ),
          ],
        );

        final result = await lookup.resolve('M31');
        expect(result?.canonicalName, 'Andromeda Galaxy');
        expect(result?.raHours, closeTo(0.7122, 1e-6));
      },
    );

    test('rejects invalid catalog coordinates before fallback', () async {
      final lookup = CatalogSearchLookup(
        (_) async => const [
          CatalogLookupResult(
            canonicalName: 'Broken result',
            raHours: 25,
            decDegrees: 0,
            identifiers: ['M31'],
          ),
          CatalogLookupResult(
            canonicalName: 'Andromeda Galaxy',
            raHours: 0.7122,
            decDegrees: 41.269,
          ),
        ],
      );

      expect((await lookup.resolve('M31'))?.canonicalName, 'Andromeda Galaxy');
    });
  });

  group('AstrobinImporter parse', () {
    test(
      'resolves matching designations and emits one target per row',
      () async {
        final content = await File(
          'test/services/import/fixtures/astrobin_basic.csv',
        ).readAsString();
        final summary = await AstrobinImporter(catalog: catalog).parse(content);
        expect(summary.totalRows, 5);
        expect(summary.resolvedRows, 4);
        expect(summary.unresolved, hasLength(1));
        expect(summary.unresolved.first.designation, 'NGC 99999');

        final mapped = CanonicalNodeMapper().map(
          summary.root,
          sequenceName: 'Astrobin',
          forceUnsupported: false,
        );
        final targets = mapped.sequence.nodes.values
            .whereType<TargetHeaderNode>()
            .toList();
        expect(targets, hasLength(5)); // includes unresolved placeholder
        // Resolved targets use the catalog's canonical name.
        final names = targets.map((t) => t.targetName).toSet();
        expect(names, contains('M42 (Orion Nebula)'));
        expect(names, contains('M31 (Andromeda)'));
        // Unresolved target gets RA=0/Dec=0 placeholder.
        final unresolvedTarget = targets.firstWhere(
          (t) => t.targetName == 'NGC 99999',
        );
        expect(unresolvedTarget.raHours, 0);
        expect(unresolvedTarget.decDegrees, 0);
      },
    );

    test(
      'aggregates integration hours when same designation appears twice',
      () async {
        const csv =
            'Title,Subject,Integration\n'
            '"A","M42","2.0"\n'
            '"B","M42","4.5"\n';
        final summary = await AstrobinImporter(catalog: catalog).parse(csv);
        // Same Subject is deduped.
        expect(summary.root.children, hasLength(1));
        final attrs = summary.root.children.first.attributes;
        expect(attrs['astrobinIntegrationHours'], closeTo(6.5, 1e-6));
      },
    );

    test('throws MalformedSourceError when Subject column is missing', () {
      const csv =
          'Title,Integration\n'
          '"x","2.0"\n';
      expect(
        () => AstrobinImporter().parse(csv),
        throwsA(isA<MalformedSourceError>()),
      );
    });

    test('NullCatalogLookup leaves everything unresolved', () async {
      final content = await File(
        'test/services/import/fixtures/astrobin_basic.csv',
      ).readAsString();
      final summary = await AstrobinImporter().parse(content);
      expect(summary.resolvedRows, 0);
      expect(summary.unresolved, hasLength(5));
    });
  });
}
