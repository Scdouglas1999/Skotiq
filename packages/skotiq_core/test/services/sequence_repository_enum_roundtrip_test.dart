// The DB codec for `sequence_nodes.properties` wrote each enum with
// `.name` but read it back through a hand-listed switch. Any value the switch
// had not been updated for decoded to the switch's default — silently, on the
// next load, with no error anywhere.
//
// THE BUG that shape produced: `MeridianTriggerMethod.onTrackingLimitHit` is
// written as 'onTrackingLimitHit' by the encoder, and the reader listed only
// 'minutesBeforeLimit' and 'hourAngleThreshold'. An operator who chose "flip
// when the mount hits its tracking limit" got "5 minutes past meridian" back
// every time the sequence was reloaded — a different flip, on a mount that was
// configured that way precisely because the meridian is not where it stops.
//
// The guard is exhaustive on purpose: it round-trips EVERY value of every enum
// the encoder emits, so adding a case to an enum without teaching the reader
// fails here rather than at 2am.

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  late SkotiqDatabase db;
  late SequenceRepository repository;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    repository = SequenceRepository(SequencesDao(db));
  });

  tearDown(() async {
    await db.close();
  });

  /// Save a one-node sequence and read the node back off the database.
  Future<SequenceNode> roundTrip(SequenceNode node) async {
    final id = await repository.saveSequence(
      Sequence.create(
        id: 'seq',
        name: 'Round trip',
        nodes: {node.id: node},
        rootNodeId: node.id,
      ),
    );
    final loaded = await repository.loadSequence(id);
    return loaded!.nodes[node.id]!;
  }

  test('every meridian trigger method survives a save/load', () async {
    for (final method in MeridianTriggerMethod.values) {
      final node = await roundTrip(
        MeridianFlipNode(id: 'flip', triggerMethod: method),
      );
      expect(
        (node as MeridianFlipNode).triggerMethod,
        method,
        reason:
            'the encoder writes ${method.name}; a reader that does not know '
            'the token rewrites the operator\'s flip trigger on reload',
      );
    }
  });

  test('every flip failure action survives a save/load', () async {
    for (final action in FlipFailureAction.values) {
      final node = await roundTrip(
        MeridianFlipNode(id: 'flip', failureAction: action),
      );
      expect((node as MeridianFlipNode).failureAction, action);
    }
  });

  test('every recovery action survives a save/load', () async {
    for (final action in RecoveryActionType.values) {
      final node = await roundTrip(
        RecoveryNode(id: 'recovery', recoveryAction: action),
      );
      expect((node as RecoveryNode).recoveryAction, action);
    }
  });

  test('every recovery trigger type survives a save/load', () async {
    for (final trigger in TriggerType.values) {
      final node = await roundTrip(
        RecoveryNode(id: 'recovery', triggerType: trigger),
      );
      expect((node as RecoveryNode).triggerType, trigger);
    }
  });

  test('the file reader accepts the DB spelling of continue', () {
    // The DB format writes 'continue' where the file format writes
    // 'continueExecution'. A reader that falls back to `retry` on anything it
    // does not recognise turns a node that crossed from the DB side into
    // "retry the failed step" instead of "carry on".
    final node = SequenceFileService().nodeFromMap(const {
      'id': 'recovery',
      'nodeType': 'recovery',
      'name': 'Recovery',
      'recoveryAction': 'continue',
    });

    expect(
      (node as RecoveryNode).recoveryAction,
      RecoveryActionType.continueExecution,
    );
  });

  test('the DB reader accepts the file spelling of continue', () async {
    final dao = SequencesDao(db);
    final sequenceId = await dao.createSequence(
      SequencesCompanion.insert(
        name: 'Cross format',
        rootNodeId: const Value('r'),
      ),
    );
    await dao.createNode(
      SequenceNodesCompanion.insert(
        nodeId: 'r',
        sequenceId: sequenceId,
        nodeType: 'container',
        specificType: 'recovery',
        name: 'Recovery',
        properties: const Value('{"recoveryAction":"continueExecution"}'),
      ),
    );

    final loaded = await repository.loadSequence(sequenceId);

    expect(
      (loaded!.nodes['r']! as RecoveryNode).recoveryAction,
      RecoveryActionType.continueExecution,
    );
  });

  test('every binning mode and frame type survives a save/load', () async {
    for (final binning in BinningMode.values) {
      for (final frameType in FrameType.values) {
        final node = await roundTrip(
          ExposureNode(
            id: 'exposure',
            durationSecs: 60,
            count: 1,
            binning: binning,
            frameType: frameType,
          ),
        );
        expect((node as ExposureNode).binning, binning);
        expect(node.frameType, frameType);
      }
    }
  });
}
