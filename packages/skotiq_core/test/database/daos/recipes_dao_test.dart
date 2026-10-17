// Behaviour tests for the v58 RecipesDao — the non-destructive op stack and
// the branch graph over it. Covers creation + identity columns, the branch
// coherence rule, the branching queries (children-of, chain-to-root,
// descendants), the RESTRICT parent-delete policy plus the explicit subtree
// delete, and the cycle guard that keeps a corrupt graph from looping a walk
// forever.

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/recipes_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/darkroom/recipe.dart';

void main() {
  late SkotiqDatabase db;
  late RecipesDao dao;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    dao = RecipesDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> seedTarget(String name) {
    return db.customInsert(
      'INSERT INTO targets (name, ra, dec) VALUES (?, ?, ?)',
      variables: [
        Variable.withString(name),
        Variable.withReal(0.71),
        Variable.withReal(41.27),
      ],
    );
  }

  Future<int> seedSession() {
    return db.customInsert(
      'INSERT INTO imaging_sessions (start_time) VALUES (?)',
      variables: [Variable.withInt(1770000000)],
    );
  }

  test('create stores the post-session identity columns', () async {
    final targetId = await seedTarget('M31');
    final sessionId = await seedSession();

    final id = await dao.create(
      targetId: targetId,
      sessionId: sessionId,
      baseMasterPath: '/data/masters/M31_Ha_master.fits',
      name: 'Draft',
      stepsJson: '[{"op_id":"stretch","version":1,"enabled":true}]',
      createdAt: DateTime.utc(2026, 8, 16, 5, 30),
    );

    final recipe = await dao.getById(id);
    expect(recipe, isNotNull);
    expect(recipe!.targetId, targetId);
    expect(recipe.sessionId, sessionId);
    expect(recipe.masterId, isNull);
    expect(recipe.baseMasterPath, '/data/masters/M31_Ha_master.fits');
    expect(recipe.createdBy, RecipeAuthor.autopilot);
    expect(recipe.parentRecipeId, isNull);
    expect(recipe.divergenceIndex, isNull);
    expect(recipe.isBranch, isFalse);
    expect(recipe.schemaVersion, 1);
    expect(recipe.createdAt, DateTime.utc(2026, 8, 16, 5, 30));
  });

  test('create rejects a half-specified branch and a negative index', () async {
    expect(
      () => dao.create(baseMasterPath: '/m.fits', parentRecipeId: 1),
      throwsA(isA<RecipeBranchException>()),
    );
    expect(
      () => dao.create(baseMasterPath: '/m.fits', divergenceIndex: 3),
      throwsA(isA<RecipeBranchException>()),
    );
    expect(
      () => dao.create(
        baseMasterPath: '/m.fits',
        parentRecipeId: 1,
        divergenceIndex: -1,
      ),
      throwsA(isA<RecipeBranchException>()),
    );
    expect(() => dao.create(baseMasterPath: ''), throwsA(isA<ArgumentError>()));
    expect(
      () => dao.create(baseMasterPath: '/m.fits', schemaVersion: 0),
      throwsA(isA<ArgumentError>()),
    );
  });

  test(
    'branchFrom inherits the parent identity and diverges at an index',
    () async {
      final targetId = await seedTarget('M31');
      final rootId = await dao.create(
        targetId: targetId,
        baseMasterPath: '/data/masters/M31_Ha_master.fits',
        name: 'Draft',
        stepsJson: '["a","b","c"]',
      );

      final branchId = await dao.branchFrom(
        parentRecipeId: rootId,
        divergenceIndex: 2,
        name: 'Warmer stars',
      );

      final branch = await dao.getById(branchId);
      expect(branch!.parentRecipeId, rootId);
      expect(branch.divergenceIndex, 2);
      expect(branch.isBranch, isTrue);
      expect(branch.createdBy, RecipeAuthor.user);
      expect(
        branch.baseMasterPath,
        '/data/masters/M31_Ha_master.fits',
        reason: 'a branch renders the same pixels as its parent',
      );
      expect(branch.targetId, targetId);
      expect(
        branch.stepsJson,
        '["a","b","c"]',
        reason: 'a branch starts from the parent steps unless told otherwise',
      );

      expect(
        () => dao.branchFrom(
          parentRecipeId: rootId + 9999,
          divergenceIndex: 0,
          name: 'orphan',
        ),
        throwsA(isA<RecipeMissingException>()),
      );
    },
  );

  test('childrenOf returns the direct branches, oldest first', () async {
    final rootId = await dao.create(baseMasterPath: '/m.fits', name: 'root');
    final first = await dao.branchFrom(
      parentRecipeId: rootId,
      divergenceIndex: 0,
      name: 'first',
      createdAt: DateTime.utc(2026, 8, 16, 5),
    );
    final second = await dao.branchFrom(
      parentRecipeId: rootId,
      divergenceIndex: 1,
      name: 'second',
      createdAt: DateTime.utc(2026, 8, 16, 6),
    );
    // A grandchild is NOT a direct child.
    await dao.branchFrom(
      parentRecipeId: first,
      divergenceIndex: 0,
      name: 'grandchild',
    );

    final children = await dao.childrenOf(rootId);
    expect(children.map((r) => r.id).toList(), <int>[first, second]);
    expect(await dao.childrenOf(second), isEmpty);
  });

  test('chainToRoot walks a branch back to its root', () async {
    final rootId = await dao.create(baseMasterPath: '/m.fits', name: 'root');
    final midId = await dao.branchFrom(
      parentRecipeId: rootId,
      divergenceIndex: 1,
      name: 'mid',
    );
    final leafId = await dao.branchFrom(
      parentRecipeId: midId,
      divergenceIndex: 2,
      name: 'leaf',
    );

    final chain = await dao.chainToRoot(leafId);
    expect(chain.map((r) => r.id).toList(), <int>[leafId, midId, rootId]);
    expect(chain.map((r) => r.name).toList(), <String>['leaf', 'mid', 'root']);

    expect((await dao.chainToRoot(rootId)).map((r) => r.id).toList(), <int>[
      rootId,
    ]);
    expect(
      () => dao.chainToRoot(rootId + 9999),
      throwsA(isA<RecipeMissingException>()),
    );
  });

  test('chainToRoot reports a cyclic graph instead of looping', () async {
    final aId = await dao.create(baseMasterPath: '/m.fits', name: 'a');
    final bId = await dao.branchFrom(
      parentRecipeId: aId,
      divergenceIndex: 0,
      name: 'b',
    );
    // Close the loop behind the DAO's back: both rows exist, so the foreign key
    // is satisfied and only the walk can catch it.
    await db.customStatement(
      'UPDATE recipes SET parent_recipe_id = ?, divergence_index = 0 '
      'WHERE id = ?',
      [bId, aId],
    );

    expect(
      () => dao.chainToRoot(aId),
      throwsA(isA<RecipeGraphCycleException>()),
    );
    expect(
      () => dao.descendantsOf(aId),
      throwsA(isA<RecipeGraphCycleException>()),
    );
  });

  test('descendantsOf collects the whole subtree, breadth-first', () async {
    final rootId = await dao.create(baseMasterPath: '/m.fits', name: 'root');
    final childA = await dao.branchFrom(
      parentRecipeId: rootId,
      divergenceIndex: 0,
      name: 'a',
    );
    final childB = await dao.branchFrom(
      parentRecipeId: rootId,
      divergenceIndex: 1,
      name: 'b',
    );
    final grandchild = await dao.branchFrom(
      parentRecipeId: childA,
      divergenceIndex: 2,
      name: 'a1',
    );

    final descendants = await dao.descendantsOf(rootId);
    expect(descendants.map((r) => r.id).toList(), <int>[
      childA,
      childB,
      grandchild,
    ]);
    expect(await dao.descendantsOf(grandchild), isEmpty);
  });

  test(
    'deleting a parent is restricted, and the subtree delete is explicit',
    () async {
      final rootId = await dao.create(baseMasterPath: '/m.fits', name: 'root');
      final branchId = await dao.branchFrom(
        parentRecipeId: rootId,
        divergenceIndex: 0,
        name: 'branch',
      );
      final leafId = await dao.branchFrom(
        parentRecipeId: branchId,
        divergenceIndex: 1,
        name: 'leaf',
      );

      await expectLater(
        dao.deleteRecipe(rootId),
        throwsA(
          isA<RecipeHasChildrenException>().having(
            (e) => e.childIds,
            'childIds',
            <int>[branchId],
          ),
        ),
      );
      expect(
        await dao.getById(rootId),
        isNotNull,
        reason: 'the refused delete must leave the parent in place',
      );

      // A leaf deletes on its own.
      expect(await dao.deleteRecipe(leafId), 1);
      expect(await dao.getById(leafId), isNull);

      // The whole line goes only when the caller asks for exactly that.
      expect(await dao.deleteRecipeSubtree(rootId), 2);
      expect(await dao.getById(rootId), isNull);
      expect(await dao.getById(branchId), isNull);
    },
  );

  test(
    'updateSteps and rename bump updated_at without touching lineage',
    () async {
      final rootId = await dao.create(
        baseMasterPath: '/m.fits',
        name: 'Draft',
        createdAt: DateTime.utc(2026, 8, 16, 5),
      );
      final branchId = await dao.branchFrom(
        parentRecipeId: rootId,
        divergenceIndex: 3,
        name: 'Variant',
      );

      expect(
        await dao.updateSteps(
          branchId,
          '["a","b"]',
          schemaVersion: 2,
          now: DateTime.utc(2026, 8, 16, 7),
        ),
        1,
      );
      var branch = await dao.getById(branchId);
      expect(branch!.stepsJson, '["a","b"]');
      expect(branch.schemaVersion, 2);
      expect(branch.updatedAt, DateTime.utc(2026, 8, 16, 7));
      expect(branch.parentRecipeId, rootId);
      expect(branch.divergenceIndex, 3);

      // An omitted schema version leaves the envelope format alone.
      await dao.updateSteps(branchId, '["a"]');
      branch = await dao.getById(branchId);
      expect(branch!.schemaVersion, 2);

      expect(await dao.rename(branchId, 'Warmer stars'), 1);
      expect((await dao.getById(branchId))!.name, 'Warmer stars');

      expect(
        () => dao.updateSteps(branchId, '[]', schemaVersion: 0),
        throwsA(isA<ArgumentError>()),
      );
    },
  );

  test('list queries scope by master, session and target', () async {
    final targetId = await seedTarget('M31');
    final otherTarget = await seedTarget('M42');
    final sessionId = await seedSession();

    final mine = await dao.create(
      targetId: targetId,
      sessionId: sessionId,
      baseMasterPath: '/data/M31.fits',
      name: 'mine',
    );
    await dao.create(
      targetId: otherTarget,
      baseMasterPath: '/data/M42.fits',
      name: 'other',
    );

    expect(
      (await dao.listForMaster('/data/M31.fits')).map((r) => r.id).toList(),
      <int>[mine],
    );
    expect(
      (await dao.listForSession(sessionId)).map((r) => r.id).toList(),
      <int>[mine],
    );
    expect((await dao.listForTarget(targetId)).map((r) => r.id).toList(), <int>[
      mine,
    ]);
    expect(await dao.listForMaster('/data/nothing.fits'), isEmpty);
  });

  test(
    'deleting the target clears the reference and keeps the recipe',
    () async {
      final targetId = await seedTarget('M31');
      final id = await dao.create(
        targetId: targetId,
        baseMasterPath: '/data/M31.fits',
        name: 'Draft',
      );

      await db.customStatement('DELETE FROM targets WHERE id = ?', [targetId]);

      final recipe = await dao.getById(id);
      expect(recipe, isNotNull, reason: 'the recipe outlives its target row');
      expect(recipe!.targetId, isNull);
      expect(recipe.baseMasterPath, '/data/M31.fits');
    },
  );
}
