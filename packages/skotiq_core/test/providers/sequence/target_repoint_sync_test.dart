// Re-pointing a target in the builder has to reach the catalog. Moving only the
// builder's copy leaves the scheduler — which scores the `targets` table —
// evaluating the position the operator replaced: alt 86.3° for a target whose
// own card, at the same instant, reads Alt −19.4°, labelled "Live … what the
// rig would slew to next".
//
// Two halves are covered here: the catalog write itself, and the editor edit
// that has to trigger it.
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart'
    show SkotiqDatabase;
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/sequence/sequence_editor.dart';
import 'package:skotiq_core/src/providers/sequence/target_catalog_coordinate_sync.dart';

/// Records what the editor asked to sync, without touching a database.
class _RecordingSync extends TargetCatalogCoordinateSync {
  _RecordingSync(super.ref);

  final List<TargetHeaderNode> synced = [];

  @override
  Future<bool> syncHeader(TargetHeaderNode header) async {
    synced.add(header);
    return true;
  }
}

final _refProvider = Provider<Ref>((ref) => ref);

Sequence _sequenceWithTarget(TargetHeaderNode target) {
  const rootId = 'root';
  return Sequence.create(
    name: 'Plan',
    nodes: {
      rootId: InstructionSetNode(
        id: rootId,
        name: 'Sequence',
        childIds: [target.id],
      ),
      target.id: target,
    },
    rootNodeId: rootId,
  );
}

void main() {
  group('catalog write', () {
    late SkotiqDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('a re-pointed target moves the row the scheduler evaluates', () async {
      final dao = container.read(targetsDaoProvider);
      final id = await dao.findOrCreateByName(
        name: 'M42-TEST',
        raHours: 21.42,
        decDegrees: -35.0,
      );

      final moved = await container
          .read(targetCatalogCoordinateSyncProvider)
          .syncHeader(
            TargetHeaderNode(
              id: 'n1',
              name: 'M42-TEST',
              targetName: 'M42-TEST',
              raHours: 5.5885,
              decDegrees: -5.39,
            ),
          );

      expect(moved, isTrue);
      final row = await dao.getTargetById(id);
      expect(row!.ra, closeTo(5.5885, 1e-9));
      expect(row.dec, closeTo(-5.39, 1e-9));
    });

    test('a bound catalog id is followed instead of the name', () async {
      final dao = container.read(targetsDaoProvider);
      final id = await dao.findOrCreateByName(
        name: 'Library row',
        raHours: 1.0,
        decDegrees: 1.0,
      );

      await container
          .read(targetCatalogCoordinateSyncProvider)
          .syncHeader(
            TargetHeaderNode(
              id: 'n1',
              name: 'renamed in the builder',
              targetName: 'renamed in the builder',
              raHours: 12.0,
              decDegrees: 45.0,
              catalogTargetId: id,
            ),
          );

      final row = await dao.getTargetById(id);
      expect(row!.ra, closeTo(12.0, 1e-9));
      expect(row.dec, closeTo(45.0, 1e-9));
    });

    test('editing the builder never creates a library row', () async {
      final dao = container.read(targetsDaoProvider);
      final moved = await container
          .read(targetCatalogCoordinateSyncProvider)
          .syncHeader(
            TargetHeaderNode(
              id: 'n1',
              name: 'Never imaged',
              targetName: 'Never imaged',
              raHours: 3.0,
              decDegrees: 3.0,
            ),
          );

      expect(moved, isFalse);
      expect(await dao.getAllTargets(), isEmpty);
    });

    test('an unset (0, 0) target never blanks a stored position', () async {
      final dao = container.read(targetsDaoProvider);
      final id = await dao.findOrCreateByName(
        name: 'M42-TEST',
        raHours: 21.42,
        decDegrees: -35.0,
      );

      final moved = await container
          .read(targetCatalogCoordinateSyncProvider)
          .syncHeader(
            TargetHeaderNode(
              id: 'n1',
              name: 'M42-TEST',
              targetName: 'M42-TEST',
              raHours: 0.0,
              decDegrees: 0.0,
            ),
          );

      expect(moved, isFalse);
      final row = await dao.getTargetById(id);
      expect(row!.ra, closeTo(21.42, 1e-9));
    });

    test(
      'a sub-arcsecond difference is round-trip noise, not a re-point',
      () async {
        final dao = container.read(targetsDaoProvider);
        await dao.findOrCreateByName(
          name: 'M42-TEST',
          raHours: 21.42,
          decDegrees: -35.0,
        );

        final moved = await container
            .read(targetCatalogCoordinateSyncProvider)
            .syncHeader(
              TargetHeaderNode(
                id: 'n1',
                name: 'M42-TEST',
                targetName: 'M42-TEST',
                raHours: 21.42 + 1e-9,
                decDegrees: -35.0 - 1e-9,
              ),
            );

        expect(moved, isFalse);
      },
    );
  });

  group('the editor triggers it', () {
    late ProviderContainer container;
    late _RecordingSync sync;
    late CurrentSequenceNotifier editor;

    setUp(() {
      late ProviderContainer c;
      c = ProviderContainer(
        overrides: [
          targetCatalogCoordinateSyncProvider.overrideWith(
            (ref) => sync = _RecordingSync(ref),
          ),
        ],
      );
      container = c;
      // Force the override to build before the editor uses it.
      container.read(targetCatalogCoordinateSyncProvider);
      editor = CurrentSequenceNotifier(ref: container.read(_refProvider));
    });

    tearDown(() {
      editor.dispose();
      container.dispose();
    });

    test('changing a target\'s coordinates syncs the catalog', () {
      final target = TargetHeaderNode(
        id: 't1',
        name: 'M42-TEST',
        targetName: 'M42-TEST',
        raHours: 21.42,
        decDegrees: -35.0,
      );
      editor.loadSequence(_sequenceWithTarget(target));

      editor.updateNode(target.copyWith(raHours: 5.5885, decDegrees: -5.39));

      expect(sync.synced, hasLength(1));
      expect(sync.synced.single.raHours, closeTo(5.5885, 1e-9));
      expect(sync.synced.single.decDegrees, closeTo(-5.39, 1e-9));
    });

    test('an edit that leaves the coordinates alone syncs nothing', () {
      final target = TargetHeaderNode(
        id: 't1',
        name: 'M42-TEST',
        targetName: 'M42-TEST',
        raHours: 21.42,
        decDegrees: -35.0,
      );
      editor.loadSequence(_sequenceWithTarget(target));

      editor.updateNode(target.copyWith(priority: 9));

      expect(sync.synced, isEmpty);
    });
  });
}
