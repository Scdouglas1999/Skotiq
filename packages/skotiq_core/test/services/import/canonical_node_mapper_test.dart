import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart'
    show FrameType;
import 'package:skotiq_core/src/models/import/canonical_sequence_node.dart';
import 'package:skotiq_core/src/models/import/import_result.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/sequence/sequence_validation.dart'
    show ValidationCategory, ValidationSeverity;
import 'package:skotiq_core/src/services/import/canonical_node_mapper.dart';

// Test imports use direct file paths rather than the package barrel so the
// mapper unit tests don't transitively pull in providers that depend on
// generated bindings (which may not be regenerated in every workspace).

CanonicalSequenceNode _container(
  String type, {
  String name = 'root',
  CanonicalKind kind = CanonicalKind.sequential,
  Map<String, Object?> attrs = const {},
  List<CanonicalSequenceNode> children = const [],
}) {
  return CanonicalSequenceNode(
    kind: kind,
    name: name,
    sourceType: type,
    attributes: attrs,
    children: children,
  );
}

void main() {
  group('CanonicalNodeMapper', () {
    test('maps a basic target+exposure tree to Skotiq nodes', () {
      final root = _container(
        'Container',
        name: 'Root',
        children: [
          _container(
            'DeepSkyObjectContainer',
            name: 'M42',
            kind: CanonicalKind.targetHeader,
            attrs: {
              'targetName': 'M42 Orion Nebula',
              'raHours': 5.5882,
              'decDegrees': -5.391,
              'rotation': 0.0,
            },
            children: [
              _container(
                'TakeExposure',
                name: 'Light',
                kind: CanonicalKind.exposure,
                attrs: {
                  'exposureTime': 120.0,
                  'count': 30,
                  'filterName': 'Lum',
                  'gain': 100,
                  'offset': 10,
                  'binning': 1,
                  'imageType': 'LIGHT',
                },
              ),
            ],
          ),
        ],
      );

      final mapper = CanonicalNodeMapper();
      final res = mapper.map(
        root,
        sequenceName: 'Test Sequence',
        forceUnsupported: false,
      );

      expect(res.unsupported, isEmpty);
      expect(res.totalNodes, 3);
      expect(res.sequence.name, 'Test Sequence');

      final rootNode = res.sequence.nodes[res.sequence.rootNodeId];
      expect(rootNode, isA<InstructionSetNode>());

      final targetNode = res.sequence.nodes.values
          .whereType<TargetHeaderNode>()
          .single;
      expect(targetNode.targetName, 'M42 Orion Nebula');
      expect(targetNode.raHours, closeTo(5.5882, 1e-4));
      expect(targetNode.decDegrees, closeTo(-5.391, 1e-4));

      final exposure = res.sequence.nodes.values
          .whereType<ExposureNode>()
          .single;
      expect(exposure.durationSecs, 120.0);
      expect(exposure.count, 30);
      expect(exposure.gain, 100);
      expect(exposure.offset, 10);
      expect(exposure.filter, 'Lum');
      expect(exposure.binning, BinningMode.one);
      expect(exposure.frameType, FrameType.light);

      // Mapping table should record the source -> skotiq pairings.
      final mappingByType = {for (final m in res.mappingTable) m.sourceType: m};
      expect(mappingByType['TakeExposure']?.skotiqType, 'TakeExposure');
      expect(
        mappingByType['DeepSkyObjectContainer']?.skotiqType,
        'TargetHeader',
      );
    });

    test(
      'drops annotation nodes as decorative without surfacing as unsupported',
      () {
        final root = _container(
          'Container',
          children: [
            _container(
              'Annotation',
              name: 'Note',
              kind: CanonicalKind.annotation,
            ),
            _container(
              'TakeExposure',
              kind: CanonicalKind.exposure,
              attrs: {'exposureTime': 60.0, 'count': 1, 'imageType': 'LIGHT'},
            ),
          ],
        );
        final mapper = CanonicalNodeMapper();
        final res = mapper.map(
          root,
          sequenceName: 'x',
          forceUnsupported: false,
        );
        expect(res.unsupported, isEmpty);
        expect(res.dropped, hasLength(1));
        expect(res.dropped.single.reason, DropReason.decorative);
        // One annotation + one exposure + container.
        expect(res.totalNodes, 3);
        // Only the exposure becomes a real Skotiq node (plus the root).
        expect(
          res.sequence.nodes.values.whereType<ExposureNode>(),
          hasLength(1),
        );
      },
    );

    test(
      'records unsupported nodes in strict mode without inserting them into the tree',
      () {
        final root = _container(
          'Container',
          children: [
            _container(
              'TakeExposure',
              kind: CanonicalKind.exposure,
              attrs: {'exposureTime': 60.0, 'count': 1, 'imageType': 'LIGHT'},
            ),
            _container(
              'VendorVoodooNode',
              name: 'Custom',
              kind: CanonicalKind.unsupported,
            ),
          ],
        );
        final mapper = CanonicalNodeMapper();
        final res = mapper.map(
          root,
          sequenceName: 'x',
          forceUnsupported: false,
        );

        expect(res.unsupported, hasLength(1));
        expect(res.unsupported.single.sourceType, 'VendorVoodooNode');
        // Strict mode does not move the unsupported into the dropped list - the
        // importer is responsible for raising; mapper records only.
        expect(res.dropped, isEmpty);
        // Tree contains root + exposure only (unsupported was excluded).
        expect(
          res.sequence.nodes.values.whereType<ExposureNode>(),
          hasLength(1),
        );
      },
    );

    test(
      'force-import surfaces unsupported nodes and ALSO records them as dropped',
      () {
        final root = _container(
          'Container',
          children: [
            _container(
              'VendorVoodooNode',
              name: 'Custom',
              kind: CanonicalKind.unsupported,
            ),
          ],
        );
        final mapper = CanonicalNodeMapper();
        final res = mapper.map(root, sequenceName: 'x', forceUnsupported: true);

        expect(res.unsupported, hasLength(1));
        expect(res.dropped, hasLength(1));
        expect(res.dropped.single.reason, DropReason.unsupported);
      },
    );

    test('disabled nodes are dropped with DropReason.disabled', () {
      final root = _container(
        'Container',
        children: [
          _container(
            'TakeExposure',
            kind: CanonicalKind.exposure,
            attrs: {
              'exposureTime': 60.0,
              'count': 1,
              'imageType': 'LIGHT',
              '_disabled': true,
            },
          ),
        ],
      );
      final mapper = CanonicalNodeMapper();
      final res = mapper.map(root, sequenceName: 'x', forceUnsupported: false);

      expect(res.unsupported, isEmpty);
      expect(res.dropped, hasLength(1));
      expect(res.dropped.single.reason, DropReason.disabled);
      // Exposure is not realized.
      expect(res.sequence.nodes.values.whereType<ExposureNode>(), isEmpty);
    });

    test('loop with count attribute lands as count-based loop', () {
      final root = _container(
        'LoopContainer',
        kind: CanonicalKind.loop,
        attrs: {'iterations': 7},
        children: [
          _container(
            'TakeExposure',
            kind: CanonicalKind.exposure,
            attrs: {'exposureTime': 30.0, 'count': 1, 'imageType': 'LIGHT'},
          ),
        ],
      );
      final mapper = CanonicalNodeMapper();
      final res = mapper.map(
        root,
        sequenceName: 'loopy',
        forceUnsupported: false,
      );
      final loop = res.sequence.nodes.values.whereType<LoopNode>().single;
      expect(loop.conditionType, LoopConditionType.count);
      expect(loop.repeatCount, 7);
      expect(loop.childIds, hasLength(1));
    });

    test('loop with _loopForever flag becomes forever-loop', () {
      final root = _container(
        'LoopContainer',
        kind: CanonicalKind.loop,
        attrs: {'_loopForever': true},
        children: [
          _container(
            'TakeExposure',
            kind: CanonicalKind.exposure,
            attrs: {'exposureTime': 30.0, 'count': 1, 'imageType': 'LIGHT'},
          ),
        ],
      );
      final mapper = CanonicalNodeMapper();
      final res = mapper.map(
        root,
        sequenceName: 'forever',
        forceUnsupported: false,
      );
      final loop = res.sequence.nodes.values.whereType<LoopNode>().single;
      expect(loop.conditionType, LoopConditionType.forever);
    });

    test(
      'exposure with no count under a forever-loop emits an indeterminate-count warning',
      () {
        final root = _container(
          'LoopContainer',
          kind: CanonicalKind.loop,
          attrs: {'_loopForever': true},
          children: [
            _container(
              'TakeExposure',
              name: 'Light',
              kind: CanonicalKind.exposure,
              // No 'count' — the parser couldn't propagate one from an
              // unbounded loop.
              attrs: {'exposureTime': 30.0, 'imageType': 'LIGHT'},
            ),
          ],
        );
        final mapper = CanonicalNodeMapper();
        final res = mapper.map(
          root,
          sequenceName: 'x',
          forceUnsupported: false,
        );

        expect(res.validationIssues, hasLength(1));
        final issue = res.validationIssues.single;
        expect(issue.severity, ValidationSeverity.warning);
        expect(issue.category, ValidationCategory.exposures);
        expect(issue.code, 'import_indeterminate_exposure_count');
        // The warning targets the realised exposure node.
        final exposure = res.sequence.nodes.values
            .whereType<ExposureNode>()
            .single;
        expect(issue.affectedNodeId, exposure.id);
      },
    );

    test(
      'exposure with an explicit count under a forever-loop emits no warning',
      () {
        final root = _container(
          'LoopContainer',
          kind: CanonicalKind.loop,
          attrs: {'_loopForever': true},
          children: [
            _container(
              'TakeExposure',
              kind: CanonicalKind.exposure,
              attrs: {'exposureTime': 30.0, 'count': 5, 'imageType': 'LIGHT'},
            ),
          ],
        );
        final mapper = CanonicalNodeMapper();
        final res = mapper.map(
          root,
          sequenceName: 'x',
          forceUnsupported: false,
        );
        expect(res.validationIssues, isEmpty);
      },
    );

    test(
      'exposure with no count under a fixed-iteration loop emits no warning',
      () {
        final root = _container(
          'LoopContainer',
          kind: CanonicalKind.loop,
          attrs: {'iterations': 10},
          children: [
            _container(
              'TakeExposure',
              kind: CanonicalKind.exposure,
              // A determinate loop count is resolvable, so no warning even
              // though this exposure carries no count of its own.
              attrs: {'exposureTime': 30.0, 'imageType': 'LIGHT'},
            ),
          ],
        );
        final mapper = CanonicalNodeMapper();
        final res = mapper.map(
          root,
          sequenceName: 'x',
          forceUnsupported: false,
        );
        expect(res.validationIssues, isEmpty);
      },
    );

    test('filter-change without filterName surfaces as unsupported', () {
      final root = _container(
        'Container',
        children: [
          _container(
            'SwitchFilter',
            kind: CanonicalKind.filterChange,
            attrs: const <String, Object?>{},
          ),
        ],
      );
      final mapper = CanonicalNodeMapper();
      final res = mapper.map(root, sequenceName: 'x', forceUnsupported: false);
      // The mapper's _construct returns null for filter-change with no name;
      // that path surfaces the node as unsupported.
      expect(res.unsupported, hasLength(1));
    });
  });
}
