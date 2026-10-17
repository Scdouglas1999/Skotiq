import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/import/canonical_sequence_node.dart';
import 'package:skotiq_core/src/models/import/import_result.dart';
import 'package:skotiq_core/src/providers/sequence/sequence_validation.dart';
import 'package:skotiq_core/src/services/import/sequence_importer.dart';

void main() {
  group('SequenceImporter', () {
    test('detectFormat returns nina for NINA content', () async {
      final content = await File(
        'test/services/import/fixtures/nina_basic.json',
      ).readAsString();
      expect(SequenceImporter().detectFormat(content), SourceFormat.nina);
    });

    test('detectFormat returns sgp for SGP content', () async {
      final content = await File(
        'test/services/import/fixtures/sgp_basic.sgf',
      ).readAsString();
      expect(SequenceImporter().detectFormat(content), SourceFormat.sgp);
    });

    test('detectFormat throws UnknownFormatError for free-form text', () {
      expect(
        () => SequenceImporter().detectFormat('hello world'),
        throwsA(isA<UnknownFormatError>()),
      );
    });

    test('importFromString returns ImportResult for valid NINA file', () async {
      final content = await File(
        'test/services/import/fixtures/nina_basic.json',
      ).readAsString();
      final result = SequenceImporter().importFromString(
        content,
        forceUnsupported: false,
        sequenceName: 'M31 run',
      );
      expect(result.sourceFormat, SourceFormat.nina);
      expect(result.sequence.name, 'M31 run');
      expect(result.sequence.nodes, isNotEmpty);
      expect(result.unsupportedNodes, isEmpty);
      // Mapping table should include TakeExposure -> TakeExposure (the
      // sequence-models ExposureNode reports its nodeType as 'TakeExposure').
      final exposureRow = result.mappingTable.firstWhere(
        (r) => r.sourceType == 'TakeExposure',
      );
      expect(exposureRow.skotiqType, 'TakeExposure');
    });

    test(
      'importFromString throws UnsupportedNodeError in strict mode for files with unsupported nodes',
      () async {
        final content = await File(
          'test/services/import/fixtures/nina_unsupported.json',
        ).readAsString();
        expect(
          () => SequenceImporter().importFromString(
            content,
            forceUnsupported: false,
            sequenceName: 'x',
          ),
          throwsA(isA<UnsupportedNodeError>()),
        );
      },
    );

    test(
      'importFromString in force-import mode returns a result with forcedImport=true',
      () async {
        final content = await File(
          'test/services/import/fixtures/nina_unsupported.json',
        ).readAsString();
        final result = SequenceImporter().importFromString(
          content,
          forceUnsupported: true,
          sequenceName: 'forced',
        );
        expect(result.forcedImport, isTrue);
        expect(result.unsupportedNodes, isNotEmpty);
        expect(
          result.droppedNodes.any((d) => d.reason == DropReason.unsupported),
          isTrue,
        );
        // Supported nodes still made it into the tree.
        expect(result.sequence.nodes.isNotEmpty, isTrue);
      },
    );

    test('importFromString returns SGP result with mapping table', () async {
      final content = await File(
        'test/services/import/fixtures/sgp_basic.sgf',
      ).readAsString();
      final result = SequenceImporter().importFromString(
        content,
        forceUnsupported: false,
        sequenceName: 'sgp run',
      );
      expect(result.sourceFormat, SourceFormat.sgp);
      expect(result.unsupportedNodes, isEmpty);
      // Two targets in fixture; mapping table must report SgpTarget pairing.
      final targetRow = result.mappingTable.firstWhere(
        (r) => r.sourceType == 'SgpTarget',
      );
      expect(targetRow.skotiqType, 'TargetHeader');
      expect(targetRow.count, 2);
    });

    test('importFromString surfaces MalformedSourceError for invalid JSON', () {
      expect(
        () => SequenceImporter().importFromString(
          '{"\$type": "NINA.Sequencer.X", broken',
          forceUnsupported: false,
          sequenceName: 'bad',
        ),
        throwsA(isA<MalformedSourceError>()),
      );
    });

    test('importFromPath reads file from disk and produces a result', () async {
      final result = await SequenceImporter().importFromPath(
        'test/services/import/fixtures/nina_basic.json',
        forceUnsupported: false,
      );
      expect(result.sourceFormat, SourceFormat.nina);
      // Default sequence name comes from the filename stem.
      expect(result.sequence.name, 'nina_basic');
    });

    test(
      'importFromPath throws MalformedSourceError for nonexistent files',
      () async {
        await expectLater(
          SequenceImporter().importFromPath(
            'test/services/import/fixtures/__does_not_exist__.json',
            forceUnsupported: false,
          ),
          throwsA(isA<MalformedSourceError>()),
        );
      },
    );

    test('importFromString throws SequenceImportValidationFailedException '
        'when validator reports ERROR-severity issues', () async {
      final content = await File(
        'test/services/import/fixtures/nina_basic.json',
      ).readAsString();

      // Stub validator returns one fake ERROR — confirms wiring without
      // depending on which built-in rule the fixture would happen to fail.
      final importer = SequenceImporter(
        validateSequenceFn: (_) => const [
          ValidationIssue(
            severity: ValidationSeverity.error,
            category: ValidationCategory.structure,
            title: 'Stubbed error',
            description: 'Test-only',
          ),
        ],
      );

      expect(
        () => importer.importFromString(
          content,
          forceUnsupported: false,
          sequenceName: 'M31 run',
        ),
        throwsA(
          isA<SequenceImportValidationFailedException>()
              .having((e) => e.errors, 'errors', hasLength(1))
              .having(
                (e) => e.parsed.sequence.nodes,
                'parsed.nodes',
                isNotEmpty,
              ),
        ),
      );
    });

    test(
      'importFromString with forceImport=true bypasses the validation gate',
      () async {
        final content = await File(
          'test/services/import/fixtures/nina_basic.json',
        ).readAsString();

        final importer = SequenceImporter(
          validateSequenceFn: (_) => const [
            ValidationIssue(
              severity: ValidationSeverity.error,
              category: ValidationCategory.structure,
              title: 'Stubbed error',
              description: 'Test-only',
            ),
          ],
        );

        // forceImport: true must not throw, AND must surface the issue list
        // via ImportResult.validationIssues so the UI can show it.
        final result = importer.importFromString(
          content,
          forceUnsupported: false,
          forceImport: true,
          sequenceName: 'M31 run',
        );

        expect(result.validationIssues, hasLength(1));
        expect(result.hasValidationErrors, isTrue);
        expect(result.sequence.nodes, isNotEmpty);
      },
    );

    test('clean import attaches an empty validationIssues list', () async {
      final content = await File(
        'test/services/import/fixtures/nina_basic.json',
      ).readAsString();
      final importer = SequenceImporter(validateSequenceFn: (_) => const []);
      final result = importer.importFromString(
        content,
        forceUnsupported: false,
        sequenceName: 'M31 run',
      );
      expect(result.validationIssues, isEmpty);
      expect(result.hasValidationErrors, isFalse);
    });
  });
}
