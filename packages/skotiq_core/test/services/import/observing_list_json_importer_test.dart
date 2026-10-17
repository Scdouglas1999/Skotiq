import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/import/import_result.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/services/import/canonical_node_mapper.dart';
import 'package:skotiq_core/src/services/import/observing_list_json_importer.dart';

void main() {
  group('ObservingListJsonImporter sniff', () {
    test('detects format marker', () {
      expect(
        ObservingListJsonImporter.sniff(
          '{"_format": "observing_list_v1", "items": []}',
        ),
        isTrue,
      );
    });

    test('detects heuristic (items + version)', () {
      expect(
        ObservingListJsonImporter.sniff(
          '{"name":"x","version":1,"items":[{"target":{"name":"M1"}}]}',
        ),
        isTrue,
      );
    });

    test('rejects NINA-shaped JSON (capital Items)', () {
      // NINA uses "Items" not "items".
      expect(
        ObservingListJsonImporter.sniff(
          '{"\$type": "NINA.Sequencer.Container", "Items": []}',
        ),
        isFalse,
      );
    });

    test('rejects non-JSON', () {
      expect(ObservingListJsonImporter.sniff('hello'), isFalse);
      expect(ObservingListJsonImporter.sniff(''), isFalse);
    });
  });

  group('ObservingListJsonImporter parse', () {
    test('produces TargetHeaderNodes for each item', () async {
      final content = await File(
        'test/services/import/fixtures/observing_list_basic.json',
      ).readAsString();
      final root = ObservingListJsonImporter().parse(content);
      final mapped = CanonicalNodeMapper().map(
        root,
        sequenceName: 'Spring DSO Tour',
        forceUnsupported: false,
      );
      final targets = mapped.sequence.nodes.values
          .whereType<TargetHeaderNode>()
          .toList();
      expect(targets, hasLength(3));
      final names = targets.map((t) => t.targetName).toSet();
      expect(names, containsAll(['M51', 'M81', 'M101']));
      // M51 had two exposures attached.
      final exposures = mapped.sequence.nodes.values
          .whereType<ExposureNode>()
          .toList();
      expect(exposures, hasLength(2));
    });

    test(
      'sorts higher priorities first and preserves source order for ties',
      () {
        const json =
            '{"name":"L","version":1,"items":['
            '{"target":{"name":"C","ra":5,"dec":0},"priority":3},'
            '{"target":{"name":"A","ra":5,"dec":0},"priority":3},'
            '{"target":{"name":"B","ra":5,"dec":0},"priority":2}'
            ']}';
        final root = ObservingListJsonImporter().parse(json);
        expect(root.children, hasLength(3));
        expect(root.children[0].attributes['targetName'], 'C');
        expect(root.children[1].attributes['targetName'], 'A');
        expect(root.children[2].attributes['targetName'], 'B');
      },
    );

    test('throws MalformedSourceError on invalid JSON', () {
      expect(
        () => ObservingListJsonImporter().parse('{not json'),
        throwsA(isA<MalformedSourceError>()),
      );
    });

    test('throws on missing items array', () {
      expect(
        () => ObservingListJsonImporter().parse('{"name":"x","version":1}'),
        throwsA(isA<MalformedSourceError>()),
      );
    });

    test('throws on missing target.ra', () {
      expect(
        () => ObservingListJsonImporter().parse(
          '{"name":"x","version":1,"items":[{"target":{"name":"M1"}}]}',
        ),
        throwsA(isA<MalformedSourceError>()),
      );
    });

    test('rejects future schema versions', () {
      expect(
        () => ObservingListJsonImporter().parse(
          '{"name":"x","version":999,"items":[]}',
        ),
        throwsA(isA<MalformedSourceError>()),
      );
    });
  });

  group('ObservingListJsonImporter export + round-trip', () {
    test('round-trips a hand-built sequence', () {
      // Build a sequence with two TargetHeaderNodes, one with exposures.
      final m31 = TargetHeaderNode(
        id: 't1',
        name: 'M31',
        targetName: 'M31',
        raHours: 0.7122,
        decDegrees: 41.269,
        rotation: 12.0,
        priority: 1,
        comment: 'Andromeda — wide-field',
      );
      final m31Exposure = ExposureNode(
        id: 'e1',
        name: 'Light',
        parentId: 't1',
        durationSecs: 300,
        count: 60,
        filter: 'L',
      );
      final m51 = TargetHeaderNode(
        id: 't2',
        name: 'M51',
        targetName: 'M51',
        raHours: 13.4979,
        decDegrees: 47.1953,
        priority: 2,
      );
      final seq = Sequence.create(
        id: 's1',
        name: 'Test Export',
        description: 'export test',
        nodes: {
          't1': m31.copyWith(childIds: ['e1']),
          'e1': m31Exposure,
          't2': m51,
        },
        rootNodeId: 't1',
      );

      final json = ObservingListJsonImporter.export(seq);
      // Decode + re-import.
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      expect(decoded['_format'], 'observing_list_v1');
      expect(decoded['name'], 'Test Export');
      expect((decoded['items'] as List).length, 2);

      final reroot = ObservingListJsonImporter().parse(json);
      final mapped = CanonicalNodeMapper().map(
        reroot,
        sequenceName: 'Re-imported',
        forceUnsupported: false,
      );
      final targets = mapped.sequence.nodes.values
          .whereType<TargetHeaderNode>()
          .toList();
      expect(targets, hasLength(2));
      final reM31 = targets.firstWhere((t) => t.targetName == 'M31');
      expect(reM31.raHours, closeTo(0.7122, 1e-4));
      expect(reM31.decDegrees, closeTo(41.269, 1e-3));
      expect(reM31.rotation, closeTo(12.0, 1e-3));
      // Round-tripped exposure: one ExposureNode child of M31.
      final exposures = mapped.sequence.nodes.values
          .whereType<ExposureNode>()
          .toList();
      expect(exposures, hasLength(1));
      expect(exposures.first.durationSecs, 300);
      expect(exposures.first.count, 60);
      expect(exposures.first.filter, 'L');
    });

    test('round-trips mosaic metadata', () {
      final panel = TargetHeaderNode(
        id: 't1',
        name: 'Big Mosaic',
        targetName: 'Big Mosaic',
        raHours: 5.0,
        decDegrees: 20.0,
        mosaicPanel: const MosaicPanelInfo(
          mosaicName: 'Big Mosaic',
          panelIndex: 3,
          totalPanels: 9,
          row: 1,
          column: 0,
        ),
      );
      final seq = Sequence.create(
        id: 's1',
        name: 'Mosaic Round Trip',
        nodes: {'t1': panel},
        rootNodeId: 't1',
      );
      final json = ObservingListJsonImporter.export(seq);
      final root = ObservingListJsonImporter().parse(json);
      final mapped = CanonicalNodeMapper().map(
        root,
        sequenceName: 'r',
        forceUnsupported: false,
      );
      final target = mapped.sequence.nodes.values
          .whereType<TargetHeaderNode>()
          .single;
      expect(target.mosaicPanel, isNotNull);
      expect(target.mosaicPanel!.mosaicName, 'Big Mosaic');
      expect(target.mosaicPanel!.panelIndex, 3);
      expect(target.mosaicPanel!.totalPanels, 9);
    });
  });
}
