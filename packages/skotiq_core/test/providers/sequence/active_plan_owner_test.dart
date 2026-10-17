import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_core/skotiq_core.dart';

/// Coverage for the active-plan-owner concept: the autopilot (and the other
/// automated planners) must hand the editor slot back and forth with the human
/// operator instead of silently destroying unsaved manual work.
///
/// STEP 1/2: ownership transitions + stash/restore on the local notifier.
/// STEP 3: the master/slave editor mirror carries + applies the owner.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Sequence buildSequence({
    String id = 'seq-1',
    String name = 'Plan',
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

  ProviderContainer newContainer() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  group('ownership transitions + stash/restore', () {
    test('default owner is manual', () {
      final c = newContainer();
      expect(c.read(activePlanOwnerProvider), ActivePlanOwner.manual);
    });

    test(
      'autopilot takeOwnership preserves unsaved manual work and flips owner',
      () {
        final c = newContainer();
        final editor = c.read(currentSequenceProvider.notifier);

        // Operator has an unsaved, dirty sequence open.
        editor.loadSequence(buildSequence(name: 'Manual Work'));
        editor.setName('Manual Work (touched)');
        expect(editor.isDirty, isTrue);
        expect(c.read(activePlanOwnerProvider), ActivePlanOwner.manual);

        // Autopilot takes over without discarding the operator's unsaved work.
        final auto = buildSequence(name: 'Autopilot Plan', databaseId: 5);
        editor.takeOwnership(auto, ActivePlanOwner.autopilot);

        // Editor now shows the autopilot plan and owner flipped.
        expect(c.read(currentSequenceProvider)!.name, 'Autopilot Plan');
        expect(c.read(activePlanOwnerProvider), ActivePlanOwner.autopilot);
        expect(editor.activeOwner, ActivePlanOwner.autopilot);
        // The freshly-loaded autopilot plan is clean.
        expect(editor.isDirty, isFalse);
      },
    );

    test(
      'releaseOwnership restores the stashed manual sequence + dirty flag',
      () {
        final c = newContainer();
        final editor = c.read(currentSequenceProvider.notifier);

        editor.loadSequence(buildSequence(name: 'Manual Work'));
        editor.setName('Manual Work (touched)');
        expect(editor.isDirty, isTrue);

        editor.takeOwnership(
          buildSequence(name: 'Autopilot Plan'),
          ActivePlanOwner.autopilot,
        );
        expect(c.read(activePlanOwnerProvider), ActivePlanOwner.autopilot);

        // Autopilot stops -> manual ownership and the exact unsaved work return.
        editor.releaseOwnership();
        expect(c.read(activePlanOwnerProvider), ActivePlanOwner.manual);
        expect(c.read(currentSequenceProvider)!.name, 'Manual Work (touched)');
        expect(editor.isDirty, isTrue);
      },
    );

    test('re-dispatch while owned keeps the ORIGINAL manual stash', () {
      final c = newContainer();
      final editor = c.read(currentSequenceProvider.notifier);

      editor.loadSequence(buildSequence(name: 'Manual Work'));
      editor.setName('Manual Work (touched)');

      // First target.
      editor.takeOwnership(
        buildSequence(name: 'Autopilot A'),
        ActivePlanOwner.autopilot,
      );
      // Autopilot switches target (re-dispatch while it already owns the slot).
      editor.takeOwnership(
        buildSequence(name: 'Autopilot B'),
        ActivePlanOwner.autopilot,
      );
      expect(c.read(currentSequenceProvider)!.name, 'Autopilot B');

      // Releasing restores the ORIGINAL manual work, not "Autopilot A".
      editor.releaseOwnership();
      expect(c.read(currentSequenceProvider)!.name, 'Manual Work (touched)');
      expect(editor.isDirty, isTrue);
    });

    test('releaseOwnership with empty manual editor clears the canvas', () {
      final c = newContainer();
      final editor = c.read(currentSequenceProvider.notifier);

      // Operator started the autopilot from a blank editor (nothing stashed).
      expect(c.read(currentSequenceProvider), isNull);
      editor.takeOwnership(
        buildSequence(name: 'Autopilot Plan'),
        ActivePlanOwner.autopilot,
      );
      expect(c.read(currentSequenceProvider), isNotNull);

      editor.releaseOwnership();
      expect(c.read(currentSequenceProvider), isNull);
      expect(c.read(activePlanOwnerProvider), ActivePlanOwner.manual);
    });

    test('releaseOwnership is a no-op when manual already owns the slot', () {
      final c = newContainer();
      final editor = c.read(currentSequenceProvider.notifier);
      editor.loadSequence(buildSequence(name: 'Manual Work'));

      editor.releaseOwnership();
      expect(c.read(currentSequenceProvider)!.name, 'Manual Work');
      expect(c.read(activePlanOwnerProvider), ActivePlanOwner.manual);
    });

    test('a manual loadSequence reclaims the slot and drops the stash', () {
      final c = newContainer();
      final editor = c.read(currentSequenceProvider.notifier);

      editor.loadSequence(buildSequence(name: 'Manual A'));
      editor.takeOwnership(
        buildSequence(name: 'Autopilot Plan'),
        ActivePlanOwner.autopilot,
      );
      // Operator opens another sequence while autopilot owns the slot.
      editor.loadSequence(buildSequence(name: 'Manual B'));
      expect(c.read(activePlanOwnerProvider), ActivePlanOwner.manual);

      // Releasing now does nothing (manual owns) and does NOT resurrect "Manual A".
      editor.releaseOwnership();
      expect(c.read(currentSequenceProvider)!.name, 'Manual B');
    });
  });

  group('wire token round-trip (backward-compatible)', () {
    test('every owner round-trips through its wire value', () {
      for (final owner in ActivePlanOwner.values) {
        expect(ActivePlanOwnerWire.fromWire(owner.wireValue), owner);
      }
    });

    test('absent / unknown token resolves to manual', () {
      expect(ActivePlanOwnerWire.fromWire(null), ActivePlanOwner.manual);
      expect(ActivePlanOwnerWire.fromWire('legacy'), ActivePlanOwner.manual);
      expect(ActivePlanOwnerWire.fromWire(42), ActivePlanOwner.manual);
    });

    test('isAutomated is true for every planner and false for manual', () {
      expect(ActivePlanOwner.manual.isAutomated, isFalse);
      expect(ActivePlanOwner.autopilot.isAutomated, isTrue);
      expect(ActivePlanOwner.smartNight.isAutomated, isTrue);
      expect(ActivePlanOwner.mosaic.isAutomated, isTrue);
    });
  });

  group('master/slave mirror reflects the owner', () {
    test('slave adopts the host owner from an editor-mirror frame', () async {
      final c = newContainer();
      final fileService = c.read(sequenceFileServiceProvider);
      final hostPlan = buildSequence(name: 'Host Autopilot', databaseId: 11);

      await applyRemoteSyncEvent(
        c,
        buildHostMutationEvent(
          entityType: HostMutationEntity.sequenceEditor,
          action: HostMutationAction.updated,
          entityId: '11',
          extra: {
            'sequence': fileService.sequenceToMap(hostPlan),
            'databaseId': 11,
            'isDirty': false,
            'activePlanOwner': ActivePlanOwner.autopilot.wireValue,
          },
        ),
      );

      expect(c.read(currentSequenceProvider)!.name, 'Host Autopilot');
      expect(c.read(activePlanOwnerProvider), ActivePlanOwner.autopilot);
    });

    test('an older host (no owner field) is treated as manual', () async {
      final c = newContainer();
      final fileService = c.read(sequenceFileServiceProvider);
      final hostPlan = buildSequence(name: 'Legacy Host', databaseId: 12);

      await applyRemoteSyncEvent(
        c,
        buildHostMutationEvent(
          entityType: HostMutationEntity.sequenceEditor,
          action: HostMutationAction.updated,
          entityId: '12',
          extra: {
            'sequence': fileService.sequenceToMap(hostPlan),
            'databaseId': 12,
            'isDirty': false,
          },
        ),
      );

      expect(c.read(currentSequenceProvider)!.name, 'Legacy Host');
      expect(c.read(activePlanOwnerProvider), ActivePlanOwner.manual);
    });

    test('"cleared" frame returns the slave to manual ownership', () async {
      final c = newContainer();
      final fileService = c.read(sequenceFileServiceProvider);

      // Slave first mirrors a host autopilot plan.
      await applyRemoteSyncEvent(
        c,
        buildHostMutationEvent(
          entityType: HostMutationEntity.sequenceEditor,
          action: HostMutationAction.updated,
          extra: {
            'sequence': fileService.sequenceToMap(buildSequence()),
            'isDirty': false,
            'activePlanOwner': ActivePlanOwner.autopilot.wireValue,
          },
        ),
      );
      expect(c.read(activePlanOwnerProvider), ActivePlanOwner.autopilot);

      // Host closes its editor.
      await applyRemoteSyncEvent(
        c,
        buildHostMutationEvent(
          entityType: HostMutationEntity.sequenceEditor,
          action: HostMutationAction.cleared,
        ),
      );

      expect(c.read(currentSequenceProvider), isNull);
      expect(c.read(activePlanOwnerProvider), ActivePlanOwner.manual);
    });
  });
}
