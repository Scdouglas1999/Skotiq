// The branch graph behind the Darkroom's branch bar.
//
// These assert the things a reader of the code cannot see: that a variant
// records where it diverged, that the family is ordered so a branch follows the
// recipe it came from, and — the one that matters — that deleting a recipe with
// branches is REFUSED with the branches named, never silently done and never
// silently ignored.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/darkroom/darkroom_branch_controller.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/mock_database.dart';

const String _masterPath = '/tmp/skotiq-test/m31_L.fits';

String _steps(int count) => jsonEncode([
      for (var i = 0; i < count; i++)
        {
          'opId': 'background_extract',
          'opVersion': 1,
          'params': <String, dynamic>{},
          'enabled': true,
        },
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late RecipesDao dao;
  late ProviderContainer container;

  setUp(() {
    db = mockDatabase();
    dao = RecipesDao(db);
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  /// Hold one scope open for the length of the test.
  ///
  /// The provider is autoDispose — a bar that outlives its screen keeps drawing
  /// a family it read once — so a bare `container.read` builds a controller and
  /// tears it down again while its first read of the family is still in flight.
  /// This subscription is what a mounted bar's `ref.watch` does; the container's
  /// own teardown closes it.
  void open(int? recipeId) {
    container.listen<DarkroomBranchState>(
      darkroomBranchControllerProvider(
        DarkroomBranchScope(masterPath: _masterPath, recipeId: recipeId),
      ),
      (_, __) {},
      fireImmediately: true,
    );
  }

  DarkroomBranchController controllerFor(int? recipeId) {
    open(recipeId);
    return container.read(
      darkroomBranchControllerProvider(
        DarkroomBranchScope(masterPath: _masterPath, recipeId: recipeId),
      ).notifier,
    );
  }

  DarkroomBranchState stateFor(int? recipeId) {
    open(recipeId);
    return container.read(
      darkroomBranchControllerProvider(
        DarkroomBranchScope(masterPath: _masterPath, recipeId: recipeId),
      ),
    );
  }

  Future<int> seedRoot({
    String name = 'Draft',
    RecipeAuthor by = RecipeAuthor.autopilot,
    int steps = 3,
  }) {
    return dao.create(
      baseMasterPath: _masterPath,
      name: name,
      stepsJson: _steps(steps),
      createdBy: by,
    );
  }

  test('the family reads root-first with the author of every branch', () async {
    final root = await seedRoot();
    final variant = await dao.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 3,
      name: 'Warmer',
    );

    final controller = controllerFor(root);
    await controller.refresh();

    final state = stateFor(root);
    expect(state.loading, isFalse);
    expect(state.branches.map((b) => b.id), [root, variant]);
    expect(state.branches.first.author, RecipeAuthor.autopilot);
    expect(state.branches.last.author, RecipeAuthor.user);
    expect(state.branches.last.depth, 1);
    expect(state.branches.first.childIds, [variant]);
    expect(state.hasVariants, isTrue);
  });

  test('a duplicate diverges at the end of the parent stack', () async {
    final root = await seedRoot(steps: 4);
    final controller = controllerFor(root);
    await controller.refresh();

    final id = await controller.duplicateAsVariant(
      sourceRecipeId: root,
      name: '  Softer stars  ',
    );
    expect(id, isNotNull);

    final created = await dao.getById(id!);
    expect(created!.parentRecipeId, root);
    // Every step is shared until the operator changes one.
    expect(created.divergenceIndex, 4);
    expect(created.name, 'Softer stars');
    expect(created.createdBy, RecipeAuthor.user);
    expect(created.stepsJson, _steps(4));
    expect(stateFor(root).createdBranchId, id);
  });

  test('a variant with no name is refused, and nothing is written', () async {
    final root = await seedRoot();
    final controller = controllerFor(root);
    await controller.refresh();

    final id = await controller.duplicateAsVariant(
      sourceRecipeId: root,
      name: '   ',
    );
    expect(id, isNull);
    expect(stateFor(root).actionError, contains('needs a name'));
    expect(await dao.listForMaster(_masterPath), hasLength(1));
  });

  test('rename writes the label and nothing else', () async {
    final root = await seedRoot(name: 'Draft', steps: 2);
    final controller = controllerFor(root);
    await controller.refresh();

    expect(await controller.renameBranch(root, 'Night one'), isTrue);
    final row = await dao.getById(root);
    expect(row!.name, 'Night one');
    expect(row.stepsJson, _steps(2));
    expect(stateFor(root).branches.single.label, 'Night one');
  });

  test('renaming a row that is gone says so instead of reporting success',
      () async {
    final root = await seedRoot();
    final controller = controllerFor(root);
    await controller.refresh();
    await dao.deleteRecipe(root);

    expect(await controller.renameBranch(root, 'Ghost'), isFalse);
    expect(stateFor(root).actionError, contains('no longer has a row'));
  });

  test('a leaf branch deletes', () async {
    final root = await seedRoot();
    final variant = await dao.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 3,
      name: 'Warmer',
    );
    final controller = controllerFor(variant);
    await controller.refresh();

    expect(await controller.deleteBranch(variant), isTrue);
    expect(await dao.getById(variant), isNull);
    expect(await dao.getById(root), isNotNull);
    expect(stateFor(variant).deleteRefusal, isNull);
  });

  test('a parent with branches is REFUSED, and the refusal names them',
      () async {
    final root = await seedRoot(name: 'Draft');
    final warmer = await dao.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 3,
      name: 'Warmer',
    );
    final starless = await dao.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 2,
      name: 'Starless',
    );
    final controller = controllerFor(root);
    await controller.refresh();

    expect(await controller.deleteBranch(root), isFalse);

    final refusal = stateFor(root).deleteRefusal;
    expect(refusal, isNotNull);
    expect(refusal!.recipeId, root);
    expect(refusal.childIds, [warmer, starless]..sort());
    expect(refusal.childLabels, containsAll(['Warmer', 'Starless']));
    expect(refusal.explanation, contains('Warmer'));
    expect(refusal.explanation, contains('Starless'));
    expect(refusal.explanation, contains('cannot be deleted'));
    // The row survived: a refusal that had already deleted something would be
    // the defect this test exists for.
    expect(await dao.getById(root), isNotNull);
  });

  test('the whole line can be deleted explicitly', () async {
    final root = await seedRoot();
    final warmer = await dao.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 3,
      name: 'Warmer',
    );
    final deeper = await dao.branchFrom(
      parentRecipeId: warmer,
      divergenceIndex: 1,
      name: 'Warmer, less blue',
    );
    final controller = controllerFor(root);
    await controller.refresh();

    expect(await controller.deleteBranchLine(root), 3);
    expect(await dao.getById(root), isNull);
    expect(await dao.getById(warmer), isNull);
    expect(await dao.getById(deeper), isNull);
  });

  test('the lineage is walked through the DAO, root first', () async {
    final root = await seedRoot(name: 'Draft');
    final warmer = await dao.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 3,
      name: 'Warmer',
    );
    final deeper = await dao.branchFrom(
      parentRecipeId: warmer,
      divergenceIndex: 1,
      name: 'Warmer, less blue',
    );

    final controller = controllerFor(deeper);
    await controller.refresh();

    final state = stateFor(deeper);
    expect(state.lineage.map((b) => b.label), [
      'Draft',
      'Warmer',
      'Warmer, less blue',
    ]);
    expect(state.lineage.last.divergenceIndex, 1);
    expect(state.lineageError, isNull);
  });

  test('an unreadable step list is reported as unreadable, not as zero',
      () async {
    final root = await dao.create(
      baseMasterPath: _masterPath,
      name: 'Corrupt',
      stepsJson: 'not json at all',
      createdBy: RecipeAuthor.user,
    );
    final controller = controllerFor(root);
    await controller.refresh();

    expect(stateFor(root).branches.single.stepCount, isNull);
  });

  test('a lineage over a deleted recipe names the way back', () async {
    final root = await dao.create(
      baseMasterPath: _masterPath,
      name: 'Draft',
      stepsJson: _steps(2),
      createdBy: RecipeAuthor.autopilot,
    );
    final controller = controllerFor(root);
    await controller.refresh();
    expect(stateFor(root).lineageError, isNull);

    // The row goes while the editor is still open on it — the shape a delete
    // from another surface takes.
    await dao.deleteRecipe(root);
    await controller.refresh();

    final error = stateFor(root).lineageError!;
    // The DAO's own sentence, kept verbatim…
    expect(error, contains('Recipe $root does not exist'));
    // …and the next step it does not carry, which every other failure on this
    // screen states.
    expect(error, contains('Press Reload'));
  });

  test('a recipe with no master path explains why it has no family', () async {
    final controller = container.read(
      darkroomBranchControllerProvider(
        const DarkroomBranchScope(masterPath: ''),
      ).notifier,
    );
    await controller.refresh();

    final state = container.read(
      darkroomBranchControllerProvider(
        const DarkroomBranchScope(masterPath: ''),
      ),
    );
    expect(state.loading, isFalse);
    expect(state.loadError, contains('names no linear master'));
  });
}
