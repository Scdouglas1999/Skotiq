import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/darkroom/recipe.dart';
import '../../providers/database_provider.dart';
import '../database.dart';
import '../epoch_seconds.dart';

part 'recipes_dao.g.dart';

/// A recipe row was addressed by an id that has no row.
class RecipeMissingException implements Exception {
  final int recipeId;

  const RecipeMissingException(this.recipeId);

  @override
  String toString() => 'Recipe $recipeId does not exist';
}

/// A recipe with branches was asked to delete itself.
///
/// See [RecipesDao.deleteRecipe] for why the parent is restricted rather than
/// re-parented, and [RecipesDao.deleteRecipeSubtree] for the explicit
/// destructive alternative.
class RecipeHasChildrenException implements Exception {
  /// The recipe that cannot be deleted.
  final int recipeId;

  /// The ids of the branches that point at it, ascending.
  final List<int> childIds;

  const RecipeHasChildrenException(this.recipeId, this.childIds);

  @override
  String toString() =>
      'Recipe $recipeId still has ${childIds.length} branch(es) '
      '(${childIds.join(', ')}); delete or re-point them first.';
}

/// The `parent_recipe_id` graph contains a cycle, so no walk of it terminates.
///
/// Branch creation cannot produce one — a new row has no descendants — so this
/// is storage corruption, and reporting it beats looping forever or silently
/// truncating a lineage.
class RecipeGraphCycleException implements Exception {
  /// The recipe the walk started from.
  final int recipeId;

  /// The id the walk reached a second time.
  final int repeatedId;

  const RecipeGraphCycleException(this.recipeId, this.repeatedId);

  @override
  String toString() =>
      'Recipe parent chain from $recipeId revisits $repeatedId; '
      'the recipe graph is cyclic.';
}

/// One line of a draft's own account of how it was composed: what the operation
/// registry decided about one operation, and why.
///
/// The same three fields the dawn pass writes into its night report, stored in
/// `recipes.draft_notes_json` so the account survives the pass that made it.
/// The reasons an operation was left OUT are the part of a draft the step list
/// cannot carry — there is no card for a step that is not there — and they are
/// what turns "this mono master got no colour calibration" into a sentence.
class RecipeDraftNote {
  /// The operation the note is about, as the registry names it (`stretch`).
  final String opId;

  /// What the composition did with it: `included`, `retried`, `remeasured`, or
  /// `omitted`. Stored as written rather than parsed into an enum: the
  /// vocabulary belongs to the composing pass, and a word this build does not
  /// model is still a word the operator can read.
  final String outcome;

  /// Why, in the words the report and the editor both print.
  final String reason;

  const RecipeDraftNote({
    required this.opId,
    required this.outcome,
    required this.reason,
  });

  Map<String, dynamic> toJson() => {
    'opId': opId,
    'outcome': outcome,
    'reason': reason,
  };

  /// Read one stored note.
  ///
  /// Throws [DarkroomWireFormatException] rather than filling a missing field
  /// in: a note whose operation or reason is gone explains nothing, and an
  /// invented one would attribute a decision the composing pass never recorded.
  static RecipeDraftNote fromJson(Object? raw) {
    if (raw is! Map) {
      throw DarkroomWireFormatException(
        'recipes.draft_notes_json',
        raw?.toString(),
      );
    }
    final opId = raw['opId'];
    final outcome = raw['outcome'];
    final reason = raw['reason'];
    if (opId is! String || outcome is! String || reason is! String) {
      throw DarkroomWireFormatException(
        'recipes.draft_notes_json',
        raw.toString(),
      );
    }
    return RecipeDraftNote(opId: opId, outcome: outcome, reason: reason);
  }

  @override
  String toString() => '$opId: $outcome — $reason';
}

/// Reads and writes for `recipes`: the non-destructive operation stack
/// replayed over a linear master, and the branch graph over it.
///
/// BRANCHING. A branch is a row carrying both `parent_recipe_id` and the
/// `divergence_index` into that parent's step list; a root recipe carries
/// neither. The column pair is `CHECK`-constrained to move together, and
/// [create] / [branchFrom] reject a half-specified branch with
/// [RecipeBranchException] before SQLite is asked.
///
/// PARENT DELETE POLICY — RESTRICT, never re-parent. [deleteRecipe] refuses a
/// recipe that still has branches, and the `ON DELETE RESTRICT` foreign key is
/// the backstop underneath it. Re-parenting a branch to its grandparent would
/// keep `divergence_index` pointing into a step list the branch never diverged
/// from: the branch would go on rendering while describing a lineage that never
/// happened. A user who genuinely wants the whole line gone calls
/// [deleteRecipeSubtree], which is explicit about what it destroys.
@DriftAccessor(include: {'../schema/darkroom.drift'})
class RecipesDao extends DatabaseAccessor<SkotiqDatabase>
    with _$RecipesDaoMixin {
  RecipesDao(super.db);

  /// Insert a recipe row and return its id.
  ///
  /// [parentRecipeId] and [divergenceIndex] are both null for a root recipe and
  /// both set for a branch; either alone throws [RecipeBranchException].
  /// [createdAt]/[updatedAt] default to "now" (UTC seconds) when omitted.
  /// [draftNotes] is the composing pass's account (see [RecipeDraftNote]);
  /// empty for a recipe a human is writing step by step.
  Future<int> create({
    int? targetId,
    int? sessionId,
    int? masterId,
    required String baseMasterPath,
    String name = '',
    String stepsJson = '[]',
    RecipeAuthor createdBy = RecipeAuthor.autopilot,
    List<RecipeDraftNote> draftNotes = const [],
    int? parentRecipeId,
    int? divergenceIndex,
    int schemaVersion = 1,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    if (baseMasterPath.isEmpty) {
      throw ArgumentError.value(
        baseMasterPath,
        'baseMasterPath',
        'a recipe must name the linear master it replays over',
      );
    }
    if (schemaVersion < 1) {
      throw ArgumentError.value(
        schemaVersion,
        'schemaVersion',
        'the steps_json envelope format starts at 1',
      );
    }
    _assertBranchCoherent(parentRecipeId, divergenceIndex);

    final created = toEpochSeconds(createdAt ?? DateTime.now());
    final updated = updatedAt == null ? created : toEpochSeconds(updatedAt);
    return into(recipes).insert(
      RecipesCompanion.insert(
        targetId: Value(targetId),
        sessionId: Value(sessionId),
        masterId: Value(masterId),
        baseMasterPath: baseMasterPath,
        name: Value(name),
        stepsJson: Value(stepsJson),
        createdBy: Value(createdBy.wire),
        draftNotesJson: Value(_encodeDraftNotes(draftNotes)),
        parentRecipeId: Value(parentRecipeId),
        divergenceIndex: Value(divergenceIndex),
        schemaVersion: Value(schemaVersion),
        createdAt: created,
        updatedAt: updated,
      ),
    );
  }

  /// Create a branch of [parentRecipeId] that diverges at [divergenceIndex]
  /// (steps `[0, divergenceIndex)` are shared with the parent) and return its
  /// id.
  ///
  /// The branch inherits the parent's target/session/master identity and base
  /// master path — a branch renders the same pixels — and starts from the
  /// parent's steps unless [stepsJson] overrides them. Throws
  /// [RecipeMissingException] when the parent has no row.
  Future<int> branchFrom({
    required int parentRecipeId,
    required int divergenceIndex,
    required String name,
    String? stepsJson,
    RecipeAuthor createdBy = RecipeAuthor.user,
    DateTime? createdAt,
  }) async {
    final parent = await getById(parentRecipeId);
    if (parent == null) throw RecipeMissingException(parentRecipeId);
    return create(
      targetId: parent.targetId,
      sessionId: parent.sessionId,
      masterId: parent.masterId,
      baseMasterPath: parent.baseMasterPath,
      name: name,
      stepsJson: stepsJson ?? parent.stepsJson,
      createdBy: createdBy,
      parentRecipeId: parentRecipeId,
      divergenceIndex: divergenceIndex,
      schemaVersion: parent.schemaVersion,
      createdAt: createdAt,
    );
  }

  Future<DarkroomRecipe?> getById(int id) async {
    final row = await (select(
      recipes,
    )..where((r) => r.id.equals(id))).getSingleOrNull();
    return row == null ? null : _map(row);
  }

  /// Every recipe over one linear master FITS, newest first.
  Future<List<DarkroomRecipe>> listForMaster(String baseMasterPath) =>
      _list((r) => r.baseMasterPath.equals(baseMasterPath), newestFirst: true);

  /// Every recipe produced from one imaging session, newest first.
  Future<List<DarkroomRecipe>> listForSession(int sessionId) =>
      _list((r) => r.sessionId.equals(sessionId), newestFirst: true);

  /// Every recipe for one target, newest first.
  Future<List<DarkroomRecipe>> listForTarget(int targetId) =>
      _list((r) => r.targetId.equals(targetId), newestFirst: true);

  /// The direct branches of [id], oldest first. Empty when [id] is a leaf — and
  /// also when [id] has no row, which [getById] distinguishes.
  Future<List<DarkroomRecipe>> childrenOf(int id) =>
      _list((r) => r.parentRecipeId.equals(id), newestFirst: false);

  /// The lineage of [id]: the recipe itself, then its parent, up to the root.
  ///
  /// Throws [RecipeMissingException] when [id] has no row, and
  /// [RecipeGraphCycleException] when the parent chain revisits a row.
  Future<List<DarkroomRecipe>> chainToRoot(int id) async {
    final chain = <DarkroomRecipe>[];
    final seen = <int>{};
    int? cursor = id;
    while (cursor != null) {
      if (!seen.add(cursor)) {
        throw RecipeGraphCycleException(id, cursor);
      }
      final recipe = await getById(cursor);
      if (recipe == null) {
        // The first hop is the caller's own id; a later miss means a parent
        // pointer outlived its row, which the RESTRICT foreign key forbids.
        throw RecipeMissingException(cursor);
      }
      chain.add(recipe);
      cursor = recipe.parentRecipeId;
    }
    return chain;
  }

  /// Every recipe descended from [id], breadth-first from the nearest branches
  /// outward. [id] itself is not included.
  ///
  /// Throws [RecipeGraphCycleException] when the branch graph revisits a row.
  Future<List<DarkroomRecipe>> descendantsOf(int id) async {
    final found = <DarkroomRecipe>[];
    final seen = <int>{id};
    var frontier = <int>[id];
    while (frontier.isNotEmpty) {
      final next = <int>[];
      for (final parentId in frontier) {
        for (final child in await childrenOf(parentId)) {
          final childId = child.id;
          if (childId == null) continue;
          if (!seen.add(childId)) {
            throw RecipeGraphCycleException(id, childId);
          }
          found.add(child);
          next.add(childId);
        }
      }
      frontier = next;
    }
    return found;
  }

  /// Replace a recipe's op stack (and optionally its envelope
  /// [schemaVersion]), bumping `updated_at`. Returns the number of rows
  /// changed.
  Future<int> updateSteps(
    int id,
    String stepsJson, {
    int? schemaVersion,
    DateTime? now,
  }) {
    if (schemaVersion != null && schemaVersion < 1) {
      throw ArgumentError.value(
        schemaVersion,
        'schemaVersion',
        'the steps_json envelope format starts at 1',
      );
    }
    final at = toEpochSeconds(now ?? DateTime.now());
    return _write(
      id,
      RecipesCompanion(
        stepsJson: Value(stepsJson),
        schemaVersion: Value.absentIfNull(schemaVersion),
        updatedAt: Value(at),
      ),
    );
  }

  /// The composing pass's account of this recipe, in the order it was written.
  ///
  /// Empty for a recipe nobody drafted, and for every row written before v59 —
  /// the column defaults to `'[]'`, so "no account" and "an account of nothing"
  /// are the same answer, which is the truth in both cases.
  ///
  /// Throws [RecipeMissingException] when [id] has no row: an editor that
  /// silently read an absent recipe's notes as "none" would show a draft with
  /// its reasons stripped and no sign that anything was missing.
  /// [DarkroomWireFormatException] when the stored text is not an array of
  /// notes — this app is the only writer, so unreadable text is corruption.
  Future<List<RecipeDraftNote>> draftNotesOf(int id) async {
    final draftNotesJson = recipes.draftNotesJson;
    final raw =
        await (selectOnly(recipes)
              ..addColumns([draftNotesJson])
              ..where(recipes.id.equals(id))
              ..limit(1))
            .map((row) => row.read(draftNotesJson)!)
            .getSingleOrNull();
    if (raw == null) throw RecipeMissingException(id);
    return _decodeDraftNotes(raw);
  }

  /// Replace a recipe's draft account, bumping `updated_at`. Returns the number
  /// of rows changed.
  ///
  /// Replace, never append: the account describes ONE composing pass, and a
  /// second pass over the same master supersedes the first rather than adding
  /// to it — the same rule the dawn autopilot applies to the steps.
  Future<int> setDraftNotes(
    int id,
    List<RecipeDraftNote> notes, {
    DateTime? now,
  }) {
    final at = toEpochSeconds(now ?? DateTime.now());
    return _write(
      id,
      RecipesCompanion(
        draftNotesJson: Value(_encodeDraftNotes(notes)),
        updatedAt: Value(at),
      ),
    );
  }

  /// Rename a recipe (the branch label), bumping `updated_at`. Returns the
  /// number of rows changed.
  Future<int> rename(int id, String name, {DateTime? now}) {
    final at = toEpochSeconds(now ?? DateTime.now());
    return _write(
      id,
      RecipesCompanion(name: Value(name), updatedAt: Value(at)),
    );
  }

  /// Delete one recipe. Returns the number of rows changed.
  ///
  /// Throws [RecipeHasChildrenException] when branches still point at it — see
  /// the class doc for why the parent is restricted rather than re-parented.
  Future<int> deleteRecipe(int id) async {
    final children = await childrenOf(id);
    if (children.isNotEmpty) {
      final ids =
          children.map((c) => c.id).whereType<int>().toList(growable: false)
            ..sort();
      throw RecipeHasChildrenException(id, ids);
    }
    return _delete(id);
  }

  /// Delete [id] and every recipe descended from it, deepest branches first so
  /// no `ON DELETE RESTRICT` parent is removed before its children. Returns the
  /// total number of rows deleted.
  Future<int> deleteRecipeSubtree(int id) async {
    final descendants = await descendantsOf(id);
    var deleted = 0;
    for (final recipe in descendants.reversed) {
      final recipeId = recipe.id;
      if (recipeId == null) continue;
      deleted += await _delete(recipeId);
    }
    deleted += await _delete(id);
    return deleted;
  }

  static String _encodeDraftNotes(List<RecipeDraftNote> notes) =>
      jsonEncode([for (final note in notes) note.toJson()]);

  static List<RecipeDraftNote> _decodeDraftNotes(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (error) {
      throw DarkroomWireFormatException(
        'recipes.draft_notes_json',
        '${error.message}: $raw',
      );
    }
    if (decoded is! List) {
      throw DarkroomWireFormatException('recipes.draft_notes_json', raw);
    }
    return List.unmodifiable([
      for (final entry in decoded) RecipeDraftNote.fromJson(entry),
    ]);
  }

  static void _assertBranchCoherent(int? parentRecipeId, int? divergenceIndex) {
    if ((parentRecipeId == null) != (divergenceIndex == null)) {
      throw const RecipeBranchException(
        'parent_recipe_id and divergence_index are set together (a branch) or '
        'both null (a root)',
      );
    }
    if (divergenceIndex != null && divergenceIndex < 0) {
      throw const RecipeBranchException(
        'divergence_index is an index into the parent step list and cannot be '
        'negative',
      );
    }
  }

  /// The recipes [filter] selects, ordered by creation time then id.
  Future<List<DarkroomRecipe>> _list(
    Expression<bool> Function(Recipes r) filter, {
    required bool newestFirst,
  }) async {
    final mode = newestFirst ? OrderingMode.desc : OrderingMode.asc;
    final rows =
        await (select(recipes)
              ..where(filter)
              ..orderBy([
                (r) => OrderingTerm(expression: r.createdAt, mode: mode),
                (r) => OrderingTerm(expression: r.id, mode: mode),
              ]))
            .get();
    return rows.map(_map).toList();
  }

  Future<int> _write(int id, RecipesCompanion changes) =>
      (update(recipes)..where((r) => r.id.equals(id))).write(changes);

  Future<int> _delete(int id) =>
      (delete(recipes)..where((r) => r.id.equals(id))).go();

  /// Builds the [DarkroomRecipe]. `draft_notes_json` is not part of it: it is
  /// provenance about the pass that composed the stack, decoded only by
  /// [draftNotesOf] for the one screen that shows it.
  DarkroomRecipe _map(RecipeRow row) {
    return DarkroomRecipe(
      id: row.id,
      targetId: row.targetId,
      sessionId: row.sessionId,
      masterId: row.masterId,
      baseMasterPath: row.baseMasterPath,
      name: row.name,
      stepsJson: row.stepsJson,
      createdBy: RecipeAuthor.fromWire(row.createdBy),
      parentRecipeId: row.parentRecipeId,
      divergenceIndex: row.divergenceIndex,
      schemaVersion: row.schemaVersion,
      createdAt: fromEpochSeconds(row.createdAt),
      updatedAt: fromEpochSeconds(row.updatedAt),
    );
  }
}

final recipesDaoProvider = Provider<RecipesDao>((ref) {
  return RecipesDao(ref.watch(databaseProvider));
});
