import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_core/skotiq_core.dart';
import '../../harness/in_memory_database.dart';

/// Live MASTER -> SLAVE mirroring of the OPEN sequencer editor canvas via the
/// [HostMutationEntity.sequenceEditor] host-mutation and the slave-side
/// `_applySequenceEditorMirror` apply branch (reached through the public
/// [applyRemoteSyncEvent] entrypoint).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Sequence buildSequence({
    String id = 'seq-1',
    String name = 'Mirror Target',
    int? databaseId,
  }) {
    var seq = Sequence.create(
      id: id,
      name: name,
      rootNodeId: 'target-1',
      nodes: {
        'target-1': TargetHeaderNode(
          id: 'target-1',
          targetName: 'M31',
          raHours: 0.712,
          decDegrees: 41.269,
          childIds: const ['exposure-1'],
        ),
        'exposure-1': ExposureNode(
          id: 'exposure-1',
          parentId: 'target-1',
          durationSecs: 60,
          count: 5,
          frameType: FrameType.light,
        ),
      },
    );
    if (databaseId != null) {
      seq = seq.copyWith(databaseId: databaseId);
    }
    return seq;
  }

  SkotiqEvent editorMirrorEvent({
    required SequenceFileService fileService,
    required Sequence sequence,
    required bool isDirty,
  }) {
    return buildHostMutationEvent(
      entityType: HostMutationEntity.sequenceEditor,
      action: HostMutationAction.updated,
      entityId: sequence.databaseId?.toString(),
      extra: {
        'sequence': fileService.sequenceToMap(sequence),
        if (sequence.databaseId != null) 'databaseId': sequence.databaseId,
        'isDirty': isDirty,
      },
    );
  }

  test(
    'sequenceToMap -> parseFromMap round-trips the working sequence losslessly',
    () {
      final service = SequenceFileService();
      final original = buildSequence(databaseId: 42);
      final restored = service.parseFromMap(service.sequenceToMap(original));

      // The on-disk wire format does NOT persist the in-memory `id` (a fresh
      // uuid is minted on parse); slave identity travels via `databaseId` in
      // the mirror envelope (asserted in the apply tests below). Structural +
      // metadata fields must round-trip losslessly.
      expect(restored.name, original.name);
      expect(restored.nodes.length, original.nodes.length);
      final exposure = restored.nodes['exposure-1'];
      expect(exposure, isA<ExposureNode>());
      expect((exposure as ExposureNode).count, 5);
      expect(exposure.durationSecs, 60);
    },
  );

  test(
    'editor-mirror applies to a CLEAN slave canvas (loadSequence)',
    () async {
      final container = ProviderContainer(
        overrides: [inMemoryDatabaseOverride()],
      );
      addTearDown(container.dispose);

      final fileService = container.read(sequenceFileServiceProvider);
      final mirrored = buildSequence(name: 'From Master', databaseId: 7);

      await applyRemoteSyncEvent(
        container,
        editorMirrorEvent(
          fileService: fileService,
          sequence: mirrored,
          isDirty: true,
        ),
      );

      final applied = container.read(currentSequenceProvider);
      expect(applied, isNotNull);
      expect(applied!.name, 'From Master');
      expect(applied.databaseId, 7);
      expect(applied.nodes.containsKey('exposure-1'), isTrue);
      // A freshly applied mirror frame is clean (not dirty) on the slave.
      expect(container.read(currentSequenceProvider.notifier).isDirty, isFalse);
    },
  );

  test(
    'editor-mirror SKIPS a slave canvas with unsaved edits (isDirty guard)',
    () async {
      final container = ProviderContainer(
        overrides: [inMemoryDatabaseOverride()],
      );
      addTearDown(container.dispose);

      final editor = container.read(currentSequenceProvider.notifier);
      // Slave operator has their own dirty, unsaved sequence open.
      final slaveLocal = buildSequence(name: 'Slave Local Edits');
      editor.loadSequence(slaveLocal);
      editor.setName('Slave Local Edits (touched)');
      expect(editor.isDirty, isTrue);

      final fileService = container.read(sequenceFileServiceProvider);
      final masterPush = buildSequence(name: 'Master Push', databaseId: 99);

      await applyRemoteSyncEvent(
        container,
        editorMirrorEvent(
          fileService: fileService,
          sequence: masterPush,
          isDirty: false,
        ),
      );

      // The master push must NOT clobber the slave operator's unsaved work.
      final current = container.read(currentSequenceProvider);
      expect(current, isNotNull);
      expect(current!.name, 'Slave Local Edits (touched)');
    },
  );

  test('editor-mirror "cleared" empties a CLEAN slave canvas', () async {
    final container = ProviderContainer(
      overrides: [inMemoryDatabaseOverride()],
    );
    addTearDown(container.dispose);

    final editor = container.read(currentSequenceProvider.notifier);
    editor.loadSequence(buildSequence(name: 'Open On Slave'));
    expect(container.read(currentSequenceProvider), isNotNull);
    expect(editor.isDirty, isFalse);

    await applyRemoteSyncEvent(
      container,
      buildHostMutationEvent(
        entityType: HostMutationEntity.sequenceEditor,
        action: HostMutationAction.cleared,
      ),
    );

    expect(container.read(currentSequenceProvider), isNull);
  });

  test('editor-mirror "cleared" does NOT wipe a dirty slave canvas', () async {
    final container = ProviderContainer(
      overrides: [inMemoryDatabaseOverride()],
    );
    addTearDown(container.dispose);

    final editor = container.read(currentSequenceProvider.notifier);
    editor.loadSequence(buildSequence(name: 'Dirty On Slave'));
    editor.setName('Dirty On Slave (touched)');
    expect(editor.isDirty, isTrue);

    await applyRemoteSyncEvent(
      container,
      buildHostMutationEvent(
        entityType: HostMutationEntity.sequenceEditor,
        action: HostMutationAction.cleared,
      ),
    );

    final current = container.read(currentSequenceProvider);
    expect(current, isNotNull);
    expect(current!.name, 'Dirty On Slave (touched)');
  });
}
