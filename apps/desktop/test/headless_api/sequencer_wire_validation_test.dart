import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/sequencer_handlers.dart';
import 'package:skotiq_desktop/headless_api/sequence_wire_validation.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

class _MockSequencerBackend extends Mock implements SequencerBackend {}

class _MockSequenceExecutor extends Mock implements SequenceExecutor {}

/// The native `SequenceDefinition` wire shape produced by
/// `SequenceExecutor._sequenceToJson`/`SequenceSerializer._nodeToConfig` and
/// consumed by `sequencerLoadJson` (a plain
/// `serde_json::from_str::<SequenceDefinition>`).
///
/// The field lists below are the producer's, including the keys Rust requires
/// and the fixture previously omitted — `priority`, `duration_secs`, `count`
/// and `binning` are all non-defaulted on the Rust side, so a fixture without
/// them is a document the executor would reject outright (L8). The matching
/// canonical document is pinned on the Rust side by
/// `native/skotiq_native/sequencer/tests/dart_wire_contract.rs`; keep the
/// two in sync when the wire schema changes.
String wireSequence({
  required double raHours,
  required double decDegrees,
  bool exposureEnabled = true,
  bool targetEnabled = true,
}) => jsonEncode({
  'id': 'seq-1',
  'name': 'Remote run',
  'description': '',
  'root_node_id': 'root',
  'metadata': const <String, String>{},
  'nodes': [
    {
      'id': 'root',
      'name': 'Sequence',
      'node_type': const {
        'type': 'Loop',
        'iterations': 1,
        'condition': 'Count',
        'condition_value': 1,
      },
      'enabled': true,
      'children': ['target'],
    },
    {
      'id': 'target',
      'name': 'M31',
      'node_type': {
        'type': 'TargetHeader',
        'target_name': 'M31',
        'ra_hours': raHours,
        'dec_degrees': decDegrees,
        'rotation': null,
        'min_altitude': null,
        'max_altitude': null,
        'priority': 0,
        'start_after': null,
        'end_before': null,
        'mosaic_panel': null,
        'brightness_tier_hint': null,
        'start_when': null,
        'end_when': null,
        'trigger_poll_interval_secs': 30,
        'integration_budget': null,
      },
      'enabled': targetEnabled,
      'children': ['expose'],
    },
    {
      'id': 'expose',
      'name': 'Take Exposure',
      'node_type': const {
        'type': 'TakeExposure',
        'duration_secs': 60.0,
        'count': 1,
        'frame_type': 'Light',
        'filter': null,
        'filter_index': null,
        'gain': null,
        'offset': null,
        'binning': 'One',
        'dither_every': null,
        'dither_pixels': 5.0,
        'dither_settle_pixels': 1.5,
        'dither_settle_time': 10.0,
        'dither_settle_timeout': 60.0,
        'dither_ra_only': false,
        'save_to': null,
        'triggers': <Object>[],
        'adaptive_exposure': null,
      },
      'enabled': exposureEnabled,
      'children': const <String>[],
    },
  ],
});

Future<Response> postLoad(SequencerHandlers handlers, String wireJson) =>
    translateHandlerErrors(
      handlers.handleSequencerLoad(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sequencer/load'),
          body: jsonEncode({'json': wireJson}),
        ),
      ),
    );

Sequence placeholderTargetSequence() {
  final target = TargetHeaderNode(
    id: 'target',
    name: 'M31',
    targetName: 'M31',
    raHours: 0,
    decDegrees: 0,
    parentId: 'root',
    childIds: const ['expose'],
  );
  final expose = ExposureNode(
    id: 'expose',
    name: 'Take Exposure',
    parentId: 'target',
    durationSecs: 60,
  );
  final root = InstructionSetNode(
    id: 'root',
    name: 'Sequence',
    childIds: const ['target'],
  );
  return Sequence.create(
    name: 'Interrupted run',
    nodes: {'root': root, 'target': target, 'expose': expose},
    rootNodeId: 'root',
  );
}

void main() {
  group('POST /api/sequencer/load pre-flight', () {
    late ProviderContainer container;
    late _MockSequencerBackend backend;
    late SequencerHandlers handlers;

    setUp(() {
      backend = _MockSequencerBackend();
      when(() => backend.sequencerLoadJson(any())).thenAnswer((_) async {});
      container = createHeadlessTestContainer(
        overrides: [sequencerBackendProvider.overrideWithValue(backend)],
      );
      addTearDown(container.dispose);
      handlers = SequencerHandlers(container);
    });

    test('accepts a target with real coordinates', () async {
      final response = await postLoad(
        handlers,
        wireSequence(raHours: 0.712, decDegrees: 41.27),
      );

      expect(response.statusCode, HttpStatus.ok);
      verify(() => backend.sequencerLoadJson(any())).called(1);
    });

    test(
      'refuses a live target still on the RA 0h / Dec +0 placeholder and never '
      'loads it',
      () async {
        final response = await postLoad(
          handlers,
          wireSequence(raHours: 0, decDegrees: 0),
        );

        expect(response.statusCode, HttpStatus.badRequest);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], 'sequence_validation_failed');
        expect(body['errorCount'], 1);
        final issues = body['issues'] as List;
        expect(issues.single, containsPair('code', 'target_coordinates_unset'));
        expect(issues.single, containsPair('affectedNodeId', 'target'));
        // The whole point: the bad tree never reaches the native executor, so
        // the bare start path has nothing wrong to run.
        verifyNever(() => backend.sequencerLoadJson(any()));
      },
    );

    test(
      'a placeholder target nothing enabled consumes warns but still loads',
      () async {
        final response = await postLoad(
          handlers,
          wireSequence(raHours: 0, decDegrees: 0, exposureEnabled: false),
        );

        expect(response.statusCode, HttpStatus.ok);
        verify(() => backend.sequencerLoadJson(any())).called(1);
      },
    );

    test('refuses out-of-range and non-numeric coordinates', () async {
      for (final target in [
        {'ra_hours': 25.0, 'dec_degrees': 41.0},
        {'ra_hours': -1.0, 'dec_degrees': 41.0},
        {'ra_hours': 3.0, 'dec_degrees': 91.0},
        {'ra_hours': 3.0},
      ]) {
        final response = await postLoad(
          handlers,
          jsonEncode({
            'root_node_id': 'root',
            'nodes': [
              {
                'id': 'root',
                'name': 'Sequence',
                'node_type': const {'type': 'Loop', 'condition': 'Count'},
                'enabled': true,
                'children': ['target'],
              },
              {
                'id': 'target',
                'name': 'T',
                'node_type': {
                  'type': 'TargetHeader',
                  'target_name': 'T',
                  // Rust-required and non-defaulted; the cases above only
                  // vary the coordinate fields under test.
                  'priority': 0,
                  ...target,
                },
                'enabled': true,
                'children': const <String>[],
              },
            ],
          }),
        );
        expect(response.statusCode, HttpStatus.badRequest, reason: '$target');
      }
      verifyNever(() => backend.sequencerLoadJson(any()));
    });

    test('refuses a tree whose child ids or root do not resolve', () async {
      final dangling = jsonEncode({
        'root_node_id': 'root',
        'nodes': [
          {
            'id': 'root',
            'name': 'Sequence',
            // `condition` is non-defaulted on the Rust side; the tree is
            // wire-valid except for the dangling reference under test.
            'node_type': const {'type': 'Loop', 'condition': 'Count'},
            'enabled': true,
            'children': ['ghost'],
          },
        ],
      });
      final rootless = jsonEncode({
        'root_node_id': 'nowhere',
        'nodes': const <Object>[],
      });

      for (final payload in [dangling, rootless]) {
        final response = await postLoad(handlers, payload);
        expect(response.statusCode, HttpStatus.badRequest);
      }
      verifyNever(() => backend.sequencerLoadJson(any()));
    });
  });

  group('POST /api/sequencer/checkpoint/resume pre-flight', () {
    late _MockSequencerBackend backend;
    late _MockSequenceExecutor executor;

    setUp(() {
      backend = _MockSequencerBackend();
      executor = _MockSequenceExecutor();
      when(() => executor.resumeFromCheckpoint()).thenAnswer((_) async {});
      when(() => executor.restoreFromCheckpoint()).thenAnswer((_) async {});
      when(() => backend.getCheckpointInfo()).thenAnswer(
        (_) async => CheckpointInfo(
          sequenceName: 'Interrupted run',
          timestamp: DateTime.now(),
          completedExposures: 3,
          completedIntegrationSecs: 180,
          canResume: true,
          ageSeconds: 60,
        ),
      );
    });

    ProviderContainer containerFor() {
      final container = createHeadlessTestContainer(
        overrides: [
          sequencerBackendProvider.overrideWithValue(backend),
          sequenceExecutorProvider.overrideWithValue(executor),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    Future<Response> postResume(
      SequencerHandlers handlers, {
      Map<String, Object?>? body,
    }) => translateHandlerErrors(
      handlers.handleSequencerResumeFromCheckpoint(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sequencer/checkpoint/resume'),
          body: body == null ? null : jsonEncode(body),
        ),
      ),
    );

    test(
      'refuses to resume a stored checkpoint whose target has no coordinates',
      () async {
        final container = containerFor();
        final snapshot = jsonEncode(
          container
              .read(sequenceFileServiceProvider)
              .sequenceToMap(placeholderTargetSequence()),
        );
        await container
            .read(sequenceRunsDaoProvider)
            .startRun(
              sequenceId: null,
              sequenceName: 'Interrupted run',
              sequenceSnapshotJson: snapshot,
            );

        final response = await postResume(SequencerHandlers(container));

        expect(response.statusCode, HttpStatus.badRequest);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], 'sequence_validation_failed');
        expect(
          (body['issues'] as List).single,
          containsPair('code', 'target_coordinates_unset'),
        );
        verifyNever(() => executor.resumeFromCheckpoint());
        verifyNever(() => executor.restoreFromCheckpoint());
      },
    );

    test('restores a checkpoint whose target is pointed somewhere', () async {
      final container = containerFor();
      final good = placeholderTargetSequence().copyWith(
        nodes: {
          ...placeholderTargetSequence().nodes,
          'target':
              (placeholderTargetSequence().nodes['target'] as TargetHeaderNode)
                  .copyWith(raHours: 0.712, decDegrees: 41.27),
        },
      );
      final snapshot = jsonEncode(
        container.read(sequenceFileServiceProvider).sequenceToMap(good),
      );
      await container
          .read(sequenceRunsDaoProvider)
          .startRun(
            sequenceId: null,
            sequenceName: 'Interrupted run',
            sequenceSnapshotJson: snapshot,
          );

      final response = await postResume(SequencerHandlers(container));

      expect(response.statusCode, HttpStatus.ok);
      verify(() => executor.restoreFromCheckpoint()).called(1);
    });

    test(
      'restores when no snapshot survives — never blocks on bookkeeping',
      () async {
        final container = containerFor();

        final response = await postResume(SequencerHandlers(container));

        expect(response.statusCode, HttpStatus.ok);
        verify(() => executor.restoreFromCheckpoint()).called(1);
      },
    );

    // A restore at any hour must not move the rig: the run waits for an
    // explicit start, which a client asks for in the body.
    test('restores without starting unless the body asks to start', () async {
      final container = containerFor();

      final restored = await postResume(SequencerHandlers(container));
      expect(
        jsonDecode(await restored.readAsString()),
        containsPair('status', 'restored'),
      );
      verify(() => executor.restoreFromCheckpoint()).called(1);
      verifyNever(() => executor.resumeFromCheckpoint());
      verifyNever(() => executor.start());

      final started = await postResume(
        SequencerHandlers(container),
        body: {'start': true},
      );
      expect(
        jsonDecode(await started.readAsString()),
        containsPair('status', 'resumed'),
      );
      verify(() => executor.resumeFromCheckpoint()).called(1);
    });
  });

  group('SmartExposure depth-goal binding', () {
    late ProviderContainer container;
    late _MockSequencerBackend backend;
    late SequencerHandlers handlers;

    setUp(() {
      backend = _MockSequencerBackend();
      when(() => backend.sequencerLoadJson(any())).thenAnswer((_) async {});
      container = createHeadlessTestContainer(
        overrides: [sequencerBackendProvider.overrideWithValue(backend)],
      );
      addTearDown(container.dispose);
      handlers = SequencerHandlers(container);
    });

    Future<Map<String, dynamic>> issuesFrom(Response response) async =>
        jsonDecode(await response.readAsString()) as Map<String, dynamic>;

    test('a well-formed binding loads', () async {
      final response = await postLoad(
        handlers,
        smartExposureWireSequence(
          depthGoal: const {'goal_id': 'm42-ha', 'revision': 3},
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      verify(() => backend.sequencerLoadJson(any())).called(1);
    });

    test('an unbound plan is still a valid plan', () async {
      final response = await postLoad(
        handlers,
        smartExposureWireSequence(bound: false),
      );

      expect(response.statusCode, HttpStatus.ok);
      verify(() => backend.sequencerLoadJson(any())).called(1);
    });

    test(
      'a binding with no goal id is refused before the run starts',
      () async {
        final response = await postLoad(
          handlers,
          smartExposureWireSequence(depthGoal: const {'revision': 3}),
        );

        expect(response.statusCode, HttpStatus.badRequest);
        final body = await issuesFrom(response);
        final issues = body['issues'] as List;
        expect(
          issues.single,
          containsPair('code', 'depth_goal_binding_invalid'),
        );
        expect(issues.single, containsPair('affectedNodeId', 'smart'));
        // Serde would have read this as "unbound" and run the full count with
        // nobody told the goal was dropped.
        verifyNever(() => backend.sequencerLoadJson(any()));
      },
    );

    test('a negative revision is refused', () async {
      final response = await postLoad(
        handlers,
        smartExposureWireSequence(
          depthGoal: const {'goal_id': 'm42-ha', 'revision': -1},
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      final issues = (await issuesFrom(response))['issues'] as List;
      expect(issues.single, containsPair('code', 'depth_goal_binding_invalid'));
      verifyNever(() => backend.sequencerLoadJson(any()));
    });

    test('a binding that is not an object is refused', () async {
      final response = await postLoad(
        handlers,
        smartExposureWireSequence(depthGoal: 'm42-ha'),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      final issues = (await issuesFrom(response))['issues'] as List;
      expect(issues.single, containsPair('code', 'depth_goal_binding_invalid'));
    });

    test('what SequenceSerializer emits for a bound plan is accepted', () {
      // The producer and this validator are the two halves of the same seam:
      // a document the desktop builds must be one the host will run.
      final wire = container
          .read(_serializerProvider)
          .sequenceToJson(
            depthBoundSequence(
              const DepthGoalBinding(goalId: 'm42-ha', revision: 3),
            ),
          );

      expect(
        (jsonDecode(wire) as Map)['nodes'],
        contains(
          containsPair(
            'node_type',
            containsPair(
              'plans',
              contains(
                containsPair('depth_goal', {
                  'goal_id': 'm42-ha',
                  'revision': 3,
                }),
              ),
            ),
          ),
        ),
      );
      expect(
        validateSequenceWireJson(wire).where((issue) => issue.isError),
        isEmpty,
      );
    });

    test('an unbound plan emits no depth_goal key at all', () {
      // Not an explicit null: `#[serde(default)]` means a pre-feature document
      // and an unbound plan have to serialize identically.
      final wire = container
          .read(_serializerProvider)
          .sequenceToJson(depthBoundSequence(null));
      final plan =
          ((((jsonDecode(wire) as Map)['nodes'] as List).firstWhere(
                        (node) => (node as Map)['id'] == 'smart',
                      )
                      as Map)['node_type']
                  as Map)['plans']
              as List;
      expect((plan.single as Map).containsKey('depth_goal'), isFalse);
      expect(
        validateSequenceWireJson(wire).where((issue) => issue.isError),
        isEmpty,
      );
    });
  });
}

/// A SmartExposure document carrying one plan, optionally bound to a
/// DepthLock goal. `depth_goal` is `#[serde(default)]` on the Rust side, so a
/// malformed binding deserializes to "unbound" instead of failing the parse —
/// which is exactly why the host has to check it before the run starts.
String smartExposureWireSequence({Object? depthGoal, bool bound = true}) =>
    jsonEncode({
      'id': 'seq-depth',
      'name': 'Depth run',
      'description': '',
      'root_node_id': 'root',
      'metadata': const <String, String>{},
      'nodes': [
        {
          'id': 'root',
          'name': 'Sequence',
          'node_type': const {
            'type': 'Loop',
            'iterations': 1,
            'condition': 'Count',
            'condition_value': 1,
          },
          'enabled': true,
          'children': ['target'],
        },
        {
          'id': 'target',
          'name': 'M42',
          'node_type': const {
            'type': 'TargetHeader',
            'target_name': 'M42',
            'ra_hours': 5.588,
            'dec_degrees': -5.39,
            'rotation': null,
            'min_altitude': null,
            'max_altitude': null,
            'priority': 0,
            'start_after': null,
            'end_before': null,
            'mosaic_panel': null,
            'brightness_tier_hint': null,
            'start_when': null,
            'end_when': null,
            'trigger_poll_interval_secs': 30,
            'integration_budget': null,
          },
          'enabled': true,
          'children': ['smart'],
        },
        {
          'id': 'smart',
          'name': 'Smart Exposure',
          'node_type': {
            'type': 'SmartExposure',
            'plans': [
              {
                'filter_name': 'Ha',
                'filter_index': 2,
                'count': 30,
                'duration_secs': 300.0,
                'gain': null,
                'offset': null,
                'binning': 'One',
                'dither_every': null,
                if (bound) 'depth_goal': depthGoal,
              },
            ],
            'rotate_filters': true,
            'dither_on_filter_change': false,
            'integration_budget_secs': 0.0,
            'batch_size': 1,
            'loop_until_stopped': false,
          },
          'enabled': true,
          'children': const <String>[],
        },
      ],
    });

/// Builds the serializer through a provider so it gets a real [Ref], which is
/// the only way to exercise the production translation rather than a hand-
/// written copy of its output.
final _serializerProvider = Provider<SequenceSerializer>(
  (ref) => SequenceSerializer(ref: ref, warn: (_) {}),
);

Sequence depthBoundSequence(DepthGoalBinding? binding) {
  final smart = SmartExposureNode(
    id: 'smart',
    name: 'Smart Exposure',
    parentId: 'target',
    plans: [
      FilterPlan(
        filterName: 'Ha',
        filterIndex: 2,
        count: 30,
        durationSecs: 300,
        depthGoal: binding,
      ),
    ],
  );
  final target = TargetHeaderNode(
    id: 'target',
    name: 'M42',
    targetName: 'M42',
    raHours: 5.588,
    decDegrees: -5.39,
    parentId: 'root',
    childIds: const ['smart'],
  );
  final root = InstructionSetNode(
    id: 'root',
    name: 'Sequence',
    childIds: const ['target'],
  );
  return Sequence.create(
    name: 'Depth run',
    nodes: {'root': root, 'target': target, 'smart': smart},
    rootNodeId: 'root',
  );
}
