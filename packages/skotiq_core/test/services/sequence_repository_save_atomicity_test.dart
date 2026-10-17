// A multi-node sequence save used to issue one `updateNode` / `createNode` /
// `deleteNode` per node in a bare loop, with no enclosing transaction. An
// exception (or an app kill) part-way through saving left the library row
// updated and the node set half-migrated — some nodes renamed, some of the
// to-delete set still present — with no recovery path: the next load rebuilt a
// corrupted tree from whatever survived.
//
// The failure is injected at the database, not at the repository, so the test
// exercises the real save path: a BEFORE INSERT trigger aborts the insert of
// one specific node, exactly as a constraint violation or a disk error would.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  late SkotiqDatabase db;
  late SequencesDao dao;
  late SequenceRepository repository;

  setUp(() async {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    dao = SequencesDao(db);
    repository = SequenceRepository(dao);
  });

  tearDown(() async {
    await db.close();
  });

  ExposureNode exposure(String id, String name) => ExposureNode(
    id: id,
    name: name,
    parentId: null,
    orderIndex: 0,
    durationSecs: 60,
    count: 1,
  );

  Sequence sequenceOf(List<SequenceNode> nodes, {int? databaseId}) =>
      Sequence.create(
        id: 'seq',
        databaseId: databaseId,
        name: 'Night run',
        nodes: {for (final n in nodes) n.id: n},
        rootNodeId: nodes.first.id,
      );

  test(
    'a save that fails part-way leaves the persisted node set untouched',
    () async {
      final id = await repository.saveSequence(
        sequenceOf([
          exposure('a', 'A'),
          exposure('b', 'B'),
          exposure('c', 'C'),
        ]),
      );

      // Reject one specific insert, the way a constraint violation would.
      await db.customStatement(
        "CREATE TRIGGER reject_poison BEFORE INSERT ON sequence_nodes "
        "WHEN NEW.name = 'POISON' "
        "BEGIN SELECT RAISE(ABORT, 'poison node rejected'); END;",
      );

      // One edit that renames a node, deletes a node and adds the poisoned node,
      // so every arm of the diff is exercised before the failure.
      await expectLater(
        repository.saveSequence(
          sequenceOf([
            exposure('a', 'A renamed'),
            exposure('b', 'B'),
            exposure('d', 'POISON'),
          ], databaseId: id),
        ),
        throwsA(anything),
      );

      final persisted = await dao.getNodesForSequence(id);
      expect(
        {for (final n in persisted) n.nodeId: n.name},
        {'a': 'A', 'b': 'B', 'c': 'C'},
        reason:
            'the whole node diff must apply as one unit — a partial apply leaves '
            'a tree no later load can repair',
      );
    },
  );

  test(
    'a successful multi-node save still applies every arm of the diff',
    () async {
      final id = await repository.saveSequence(
        sequenceOf([
          exposure('a', 'A'),
          exposure('b', 'B'),
          exposure('c', 'C'),
        ]),
      );

      await repository.saveSequence(
        sequenceOf([
          exposure('a', 'A renamed'),
          exposure('b', 'B'),
          exposure('d', 'D'),
        ], databaseId: id),
      );

      final persisted = await dao.getNodesForSequence(id);
      expect(
        {for (final n in persisted) n.nodeId: n.name},
        {'a': 'A renamed', 'b': 'B', 'd': 'D'},
      );
    },
  );

  test(
    'an update preserves the database row id of an unchanged node',
    () async {
      final id = await repository.saveSequence(
        sequenceOf([exposure('a', 'A'), exposure('b', 'B')]),
      );
      final before = {
        for (final n in await dao.getNodesForSequence(id)) n.nodeId: n.id,
      };

      await repository.saveSequence(
        sequenceOf([
          exposure('a', 'A renamed'),
          exposure('b', 'B'),
        ], databaseId: id),
      );

      final after = {
        for (final n in await dao.getNodesForSequence(id)) n.nodeId: n.id,
      };
      expect(after, before);
    },
  );
}
