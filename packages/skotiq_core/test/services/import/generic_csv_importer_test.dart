import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/import/import_result.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/services/import/canonical_node_mapper.dart';
import 'package:skotiq_core/src/services/import/generic_csv_importer.dart';

void main() {
  group('GenericCsvImporter preview', () {
    test('extracts headers + sample rows from CSV with header', () {
      const csv =
          'name,ra,dec,filter\n'
          'M42,5.5881,-5.391,L\n'
          'M31,0.7122,41.269,L\n'
          'M51,13.498,47.195,L\n';
      final preview = GenericCsvImporter.preview(csv);
      expect(preview.hasHeader, isTrue);
      expect(preview.columnCount, 4);
      expect(preview.headers, ['name', 'ra', 'dec', 'filter']);
      expect(preview.sampleRows, hasLength(3));
      expect(preview.totalRows, 4);
    });

    test('handles CSV without header', () {
      const csv = '5,1.0,2.0\n6,3.0,4.0\n';
      final preview = GenericCsvImporter.preview(csv);
      expect(preview.hasHeader, isFalse);
      expect(preview.headers, isNull);
      expect(preview.sampleRows, hasLength(2));
    });

    test('signature key is stable for same headers', () {
      const csv1 = 'name,ra,dec\nM42,5,-5\n';
      const csv2 = 'name,ra,dec\nM31,0.7,41\n';
      final p1 = GenericCsvImporter.preview(csv1);
      final p2 = GenericCsvImporter.preview(csv2);
      expect(p1.signatureKey, p2.signatureKey);
    });
  });

  group('GenericCsvImporter parse with mapping', () {
    test('produces TargetHeaderNodes using explicit column mapping', () {
      const csv =
          'name,ra,dec,filter,exposure,count\n'
          'M42,5.5881,-5.391,L,300,30\n'
          'M31,0.7122,41.269,Ha,600,20\n';
      const mapping = CsvColumnMapping(
        nameColumn: 0,
        raColumn: 1,
        decColumn: 2,
        filterColumn: 3,
        exposureTimeColumn: 4,
        countColumn: 5,
      );
      final root = GenericCsvImporter().parse(csv, mapping: mapping);
      final mapped = CanonicalNodeMapper().map(
        root,
        sequenceName: 'Generic',
        forceUnsupported: false,
      );
      final targets = mapped.sequence.nodes.values
          .whereType<TargetHeaderNode>()
          .toList();
      expect(targets, hasLength(2));
      final exposures = mapped.sequence.nodes.values
          .whereType<ExposureNode>()
          .toList();
      expect(exposures, hasLength(2));
      final m42Exp = exposures.firstWhere((e) => e.filter == 'L');
      expect(m42Exp.durationSecs, 300);
      expect(m42Exp.count, 30);
    });

    test('throws when required cell is missing', () {
      const csv = 'name,ra,dec\nM42,,-5.391\n';
      const mapping = CsvColumnMapping(
        nameColumn: 0,
        raColumn: 1,
        decColumn: 2,
      );
      expect(
        () => GenericCsvImporter().parse(csv, mapping: mapping),
        throwsA(isA<MalformedSourceError>()),
      );
    });

    test('throws when coordinate is unparseable', () {
      const csv = 'name,ra,dec\nM42,not_a_ra,not_a_dec\n';
      const mapping = CsvColumnMapping(
        nameColumn: 0,
        raColumn: 1,
        decColumn: 2,
      );
      expect(
        () => GenericCsvImporter().parse(csv, mapping: mapping),
        throwsA(isA<MalformedSourceError>()),
      );
    });

    test('round-trips CsvColumnMapping via JSON', () {
      const original = CsvColumnMapping(
        nameColumn: 0,
        raColumn: 1,
        decColumn: 2,
        filterColumn: 3,
        exposureTimeColumn: 4,
        countColumn: 5,
      );
      final json = original.toJson();
      final restored = CsvColumnMapping.fromJson(json);
      expect(restored.nameColumn, 0);
      expect(restored.filterColumn, 3);
      expect(restored.countColumn, 5);
    });
  });
}
