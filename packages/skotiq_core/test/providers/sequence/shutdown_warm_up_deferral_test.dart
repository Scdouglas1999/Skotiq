// With end-of-night calibration to follow, the run's closing Warm Camera
// waits for the darks. Which steps close the plan is the native sequencer's
// rule (it also reads inside a wizard plan's one container and passes
// recovery and flip watchers by), so the app only asks for the deferral and
// marks no step itself.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../harness/in_memory_database.dart';

/// A wizard plan: one target holding the whole night, its warm-up last,
/// followed by a meridian flip watcher.
Sequence _wizardPlan() => Sequence.create(
  id: 'seq',
  name: 'M31',
  rootNodeId: 'root',
  nodes: {
    'root': InstructionSetNode(id: 'root', childIds: const ['target', 'flip']),
    'target': InstructionSetNode(
      id: 'target',
      parentId: 'root',
      childIds: const ['lights', 'warm'],
    ),
    'lights': ExposureNode(id: 'lights', parentId: 'target', count: 2),
    'warm': WarmCameraNode(id: 'warm', parentId: 'target'),
    'flip': MeridianFlipNode(id: 'flip', parentId: 'root'),
  },
);

Future<Map<String, dynamic>> _wire({required bool defer}) async {
  final container = ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
  addTearDown(container.dispose);
  final serializer = container.read(
    Provider((ref) => SequenceSerializer(ref: ref, warn: (_) {})),
  );
  final json = serializer.sequenceToJson(
    _wizardPlan(),
    deferShutdownWarmUp: defer,
  );
  // The settings the serializer's providers load land before teardown.
  await pumpEventQueue();
  return jsonDecode(json) as Map<String, dynamic>;
}

bool _nodeDefers(Map<String, dynamic> wire, String id) {
  final node = (wire['nodes'] as List).cast<Map<String, dynamic>>().firstWhere(
    (n) => n['id'] == id,
  );
  return (node['node_type'] as Map)['defer_to_calibration'] == true;
}

/// The metadata key the native sequencer reads, as a Rust test writes it.
String _nativeDeferKey() =>
    (jsonDecode(
              File(
                '../../test_fixtures/wire_words/sequence_metadata.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>)['deferShutdownWarmUp']
        as String;

void main() {
  test('the deferral is asked for under the key the sequencer reads', () async {
    expect(
      (await _wire(defer: true))['metadata'],
      containsPair(_nativeDeferKey(), 'true'),
    );
  });

  test('a run before end-of-night calibration asks the sequencer to defer '
      'its shutdown warm-up', () async {
    final wire = await _wire(defer: true);
    expect(wire['metadata'], containsPair('defer_shutdown_warm_up', 'true'));
    expect(_nodeDefers(wire, 'warm'), isFalse);
  });

  test('a run with no calibration after it asks for nothing', () async {
    final wire = await _wire(defer: false);
    expect(
      (wire['metadata'] as Map).containsKey('defer_shutdown_warm_up'),
      isFalse,
    );
    expect(_nodeDefers(wire, 'warm'), isFalse);
  });
}
