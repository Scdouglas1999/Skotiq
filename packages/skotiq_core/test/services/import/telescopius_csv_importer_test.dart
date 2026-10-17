import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart'
    show FrameType;
import 'package:skotiq_core/src/models/import/canonical_sequence_node.dart';
import 'package:skotiq_core/src/models/import/import_result.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/services/import/canonical_node_mapper.dart';
import 'package:skotiq_core/src/services/import/telescopius_csv_importer.dart';

// Direct-file imports (mirroring canonical_node_mapper_test.dart) keep the
// transitive compile graph small enough to avoid pulling sibling-agent
// work-in-progress into this test's build.

void main() {
  group('TelescopiusCsvImporter sniff', () {
    test('detects valid Telescopius CSV', () async {
      final content = await File(
        'test/services/import/fixtures/telescopius_single.csv',
      ).readAsString();
      expect(TelescopiusCsvImporter.sniff(content), isTrue);
    });

    test('does not sniff non-CSV content', () {
      expect(TelescopiusCsvImporter.sniff('hello world'), isFalse);
      expect(TelescopiusCsvImporter.sniff(''), isFalse);
      expect(TelescopiusCsvImporter.sniff('{"foo": 1}'), isFalse);
    });
  });

  group('TelescopiusCsvImporter RA/Dec parsing', () {
    test('parses canonical HMS RA', () {
      expect(
        TelescopiusCsvImporter.parseRaToHours('05h35m17.3s'),
        closeTo(5.5881, 1e-3),
      );
      expect(
        TelescopiusCsvImporter.parseRaToHours('05h35mZZ'),
        closeTo(5.5833, 1e-3),
      );
    });

    test('parses negative dec DMS', () {
      expect(
        TelescopiusCsvImporter.parseDecToDegrees("-05°23'28\""),
        closeTo(-5.391, 1e-3),
      );
    });

    test('parses positive dec DMS', () {
      expect(
        TelescopiusCsvImporter.parseDecToDegrees("+41°16'09\""),
        closeTo(41.269, 1e-3),
      );
    });

    test('parses decimal hours / degrees', () {
      expect(
        TelescopiusCsvImporter.parseRaToHours('5.5881'),
        closeTo(5.5881, 1e-3),
      );
      expect(
        TelescopiusCsvImporter.parseDecToDegrees('-5.391'),
        closeTo(-5.391, 1e-3),
      );
    });

    test('rejects out-of-range RA instead of redirecting the target', () {
      expect(TelescopiusCsvImporter.parseRaToHours('-1.0'), isNull);
      expect(TelescopiusCsvImporter.parseRaToHours('24.1'), isNull);
    });

    test('rejects invalid Dec instead of clamping it to a pole', () {
      expect(TelescopiusCsvImporter.parseDecToDegrees('95.0'), isNull);
      expect(TelescopiusCsvImporter.parseDecToDegrees('-95.0'), isNull);
      expect(TelescopiusCsvImporter.parseDecToDegrees('+90:00:01'), isNull);
    });

    test('rejects overflowing sexagesimal components', () {
      expect(TelescopiusCsvImporter.parseRaToHours('12h99m00s'), isNull);
      expect(TelescopiusCsvImporter.parseRaToHours('12h00m60s'), isNull);
      expect(TelescopiusCsvImporter.parseDecToDegrees('+12°99\'00"'), isNull);
      expect(TelescopiusCsvImporter.parseDecToDegrees('+12°00\'60"'), isNull);
    });

    test('returns null for unparseable', () {
      expect(TelescopiusCsvImporter.parseRaToHours('not a coord'), isNull);
      expect(TelescopiusCsvImporter.parseDecToDegrees('also not'), isNull);
    });
  });

  group('TelescopiusCsvImporter parse', () {
    test('produces one TargetHeaderNode per single-target row', () async {
      final content = await File(
        'test/services/import/fixtures/telescopius_single.csv',
      ).readAsString();
      final root = TelescopiusCsvImporter().parse(content);
      final mapped = CanonicalNodeMapper().map(
        root,
        sequenceName: 'Telescopius Test',
        forceUnsupported: false,
      );
      expect(mapped.unsupported, isEmpty);
      final targets = mapped.sequence.nodes.values
          .whereType<TargetHeaderNode>()
          .toList();
      expect(targets, hasLength(3));
      final names = targets.map((t) => t.targetName).toSet();
      expect(names, containsAll(['M42', 'M31', 'NGC 7000']));
      final m42 = targets.firstWhere((t) => t.targetName == 'M42');
      expect(m42.rotation, closeTo(37.5, 1e-3));
      final ngc = targets.firstWhere((t) => t.targetName == 'NGC 7000');
      expect(ngc.rotation, closeTo(-15.2, 1e-3));
    });

    test('groups same-Designation rows into a mosaic', () async {
      final content = await File(
        'test/services/import/fixtures/telescopius_mosaic_5x5.csv',
      ).readAsString();
      final root = TelescopiusCsvImporter().parse(content);
      final mapped = CanonicalNodeMapper().map(
        root,
        sequenceName: 'Andromeda Mosaic',
        forceUnsupported: false,
      );
      final panels = mapped.sequence.nodes.values
          .whereType<TargetHeaderNode>()
          .where((t) => t.mosaicPanel != null)
          .toList();
      expect(panels, hasLength(25));
      for (final p in panels) {
        expect(p.mosaicPanel!.mosaicName, 'Andromeda Mosaic');
        expect(p.mosaicPanel!.totalPanels, 25);
        expect(p.targetName, 'Andromeda Mosaic');
        expect(p.rotation, closeTo(12.0, 1e-3));
      }
      final indices = panels.map((p) => p.mosaicPanel!.panelIndex).toSet();
      expect(indices, hasLength(25));
      expect(indices.reduce((a, b) => a < b ? a : b), 0);
      expect(indices.reduce((a, b) => a > b ? a : b), 24);
    });

    test('honors per-panel rotation independently of other panels', () {
      // Use decimal degrees in the inline CSV to dodge inner-quote escaping
      // hell. Production paths exercise the full HMS/DMS parsing via the
      // file-fixture tests above.
      const csv =
          'Pane,Designation,Right Ascension,Declination,Rotation\n'
          '1,TestMosaic,10.0,20.0,0\n'
          '2,TestMosaic,10.08,20.0,45\n'
          '3,TestMosaic,10.17,20.0,90\n';
      final root = TelescopiusCsvImporter().parse(csv);
      final group = root.children.firstWhere(
        (c) => c.sourceType == 'TelescopiusMosaicGroup',
      );
      expect(group.children, hasLength(3));
      expect(group.children[0].attributes['rotation'], 0.0);
      expect(group.children[1].attributes['rotation'], 45.0);
      expect(group.children[2].attributes['rotation'], 90.0);
    });

    test('reads Sub Length / Count / Filter extension columns', () async {
      final content = await File(
        'test/services/import/fixtures/telescopius_extended.csv',
      ).readAsString();
      final root = TelescopiusCsvImporter().parse(content);
      final mapped = CanonicalNodeMapper().map(
        root,
        sequenceName: 'Extended',
        forceUnsupported: false,
      );
      final exposures = mapped.sequence.nodes.values
          .whereType<ExposureNode>()
          .toList();
      expect(exposures, hasLength(3));
      // Each of M51, M81, NGC 6960 had one exposure block.
      final m51Exp = exposures.firstWhere((e) => e.filter == 'L');
      expect(m51Exp.durationSecs, 300.0);
      expect(m51Exp.count, 60);
      expect(m51Exp.frameType, FrameType.light);
    });

    test(
      'throws MalformedSourceError when required columns are missing',
      () async {
        final content = await File(
          'test/services/import/fixtures/telescopius_missing_columns.csv',
        ).readAsString();
        expect(
          () => TelescopiusCsvImporter().parse(content),
          throwsA(isA<MalformedSourceError>()),
        );
      },
    );

    test('throws MalformedSourceError on empty input', () {
      expect(
        () => TelescopiusCsvImporter().parse(''),
        throwsA(isA<MalformedSourceError>()),
      );
    });

    test('preserves unknown extra columns in attributes', () {
      // Avoid inline escaped quotes — those make the Dart source hard to
      // reason about. Use decimal coordinates so we can drop the quoting
      // of cells entirely.
      const csv =
          'Designation,Right Ascension,Declination,Foo,Bar\n'
          'M42,5.5881,-5.391,unknown1,unknown2\n';
      final root = TelescopiusCsvImporter().parse(csv);
      expect(root.children, hasLength(1));
      final target = root.children.first;
      expect(target.attributes['targetName'], 'M42');
      final unknown =
          target.attributes['unknownColumns'] as Map<String, Object?>;
      expect(unknown.keys, containsAll(['foo', 'bar']));
    });

    test('mosaic source type group emits sequential container', () async {
      final content = await File(
        'test/services/import/fixtures/telescopius_mosaic_5x5.csv',
      ).readAsString();
      final root = TelescopiusCsvImporter().parse(content);
      expect(root.children, hasLength(1));
      final group = root.children.first;
      expect(group.sourceType, 'TelescopiusMosaicGroup');
      expect(group.kind, CanonicalKind.sequential);
      expect(group.children, hasLength(25));
    });
  });
}
