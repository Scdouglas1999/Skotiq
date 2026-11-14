// The node-type table every codec, the diff, the palette and the tree read.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

import '../services/node_codec_goldens/node_fixtures.dart';

void main() {
  test('every node type has exactly one kind, and its nodes report it', () {
    final kinds = NodeKind.all;
    expect(kinds.toSet(), hasLength(kinds.length));
    for (final node in fullNodes()) {
      expect(kinds, contains(node.kind), reason: '${node.runtimeType}');
      expect(node.kind.create().runtimeType, node.runtimeType);
    }
    expect(kinds, hasLength(fullNodes().length));
  });

  test('no two kinds answer to the same stored name', () {
    final seen = <String, String>{};
    for (final kind in NodeKind.all) {
      for (final name in [kind.wireName, ...kind.legacyNames]) {
        final loose = normalizeNodeTypeName(name);
        expect(
          seen[loose],
          anyOf(isNull, kind.wireName),
          reason: '"$name" names ${seen[loose]} and ${kind.wireName}',
        );
        seen[loose] = kind.wireName;
      }
    }
  });

  test('what a store writes reads back to the same stored fields', () {
    for (final store in NodeStore.values) {
      for (final node in fullNodes()) {
        final kind = node.kind;
        final stored = kind.encodeFields(node, store);
        expect(
          kind.encodeFields(kind.decodeFields(stored, store), store),
          stored,
          reason: '${node.runtimeType} through ${store.name}',
        );
      }
    }
  });

  test('a new node is named after its kind', () {
    expect(NodeKinds.exposure.displayName, 'Take Exposures');
    expect(NodeKinds.targetHeader.displayName, 'Target');
    expect(NodeKinds.homeMount.displayName, 'Home mount');
  });

  test('the tree lets exactly the container kinds hold children', () {
    expect(
      {
        for (final kind in NodeKind.all)
          if (kind.isContainer) kind.wireName,
      },
      {
        'TargetHeader',
        'Loop',
        'Parallel',
        'Conditional',
        'Recovery',
        'InstructionSet',
        'TargetScheduler',
      },
    );
  });
}
