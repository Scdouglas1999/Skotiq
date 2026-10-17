import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/darkroom/recipe.dart';
import '../../providers/database_provider.dart';
import '../database.dart';

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

/// Data-access object for the v58 `recipes` table — the non-destructive
/// operation stack replayed over a linear master, and the branch graph over it.
///
/// The table is managed with raw DDL (see
/// [SkotiqDatabase._createDarkroomTables]) rather than a drift `Table`
/// class, so this DAO is a plain class that reads/writes through the database's
/// `customSelect`/`customInsert`/`customStatement` APIs — mirroring
/// [MosaicProjectsDao] and [CampaignsDao]. It is deliberately NOT a
/// `@DriftAccessor`.
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
class RecipesDao {
  RecipesDao(this._db);

  final SkotiqDatabase _db;

  /// The columns a [DarkroomRecipe] is built from.
  ///
  /// `draft_notes_json` is deliberately absent: it is provenance about the pass
  /// that composed the stack, not part of the recipe every branch walk and
  /// sibling listing carries, and reading it on every row would decode a JSON
  /// array per recipe for the one screen that shows it. [draftNotesOf] reads it
  /// on its own.
  static const String _columns =
      'id, target_id, session_id, master_id, base_master_path, name, '
      'steps_json, created_by, parent_recipe_id, divergence_index, '
      'schema_version, created_at, updated_at';

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

    final created = _toEpochSeconds(createdAt ?? DateTime.now());
    final updated = updatedAt == null ? created : _toEpochSeconds(updatedAt);
    return _db.customInsert(
      'INSERT INTO recipes('
      'target_id, session_id, master_id, base_master_path, name, steps_json, '
      'created_by, draft_notes_json, parent_recipe_id, divergence_index, '
      'schema_version, created_at, updated_at'
      ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      variables: [
        Variable<int>(targetId),
        Variable<int>(sessionId),
        Variable<int>(masterId),
        Variable<String>(baseMasterPath),
        Variable<String>(name),
        Variable<String>(stepsJson),
        Variable<String>(createdBy.wire),
        Variable<String>(_encodeDraftNotes(draftNotes)),
        Variable<int>(parentRecipeId),
        Variable<int>(divergenceIndex),
        Variable<int>(schemaVersion),
        Variable<int>(created),
        Variable<int>(updated),
      ],
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

  /// Fetch a recipe by id, or null when absent.
  Future<DarkroomRecipe?> getById(int id) async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM recipes WHERE id = ? LIMIT 1',
          variables: [Variable<int>(id)],
        )
        .get();
    if (rows.isEmpty) return null;
    return _map(rows.first);
  }

  /// Every recipe over one linear master FITS, newest first.
  Future<List<DarkroomRecipe>> listForMaster(String baseMasterPath) async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM recipes WHERE base_master_path = ? '
          'ORDER BY created_at DESC, id DESC',
          variables: [Variable<String>(baseMasterPath)],
        )
        .get();
    return rows.map(_map).toList();
  }

  /// Every recipe produced from one imaging session, newest first.
  Future<List<DarkroomRecipe>> listForSession(int sessionId) async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM recipes WHERE session_id = ? '
          'ORDER BY created_at DESC, id DESC',
          variables: [Variable<int>(sessionId)],
        )
        .get();
    return rows.map(_map).toList();
  }

  /// Every recipe for one target, newest first.
  Future<List<DarkroomRecipe>> listForTarget(int targetId) async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM recipes WHERE target_id = ? '
          'ORDER BY created_at DESC, id DESC',
          variables: [Variable<int>(targetId)],
        )
        .get();
    return rows.map(_map).toList();
  }

  /// The direct branches of [id], oldest first. Empty when [id] is a leaf — and
  /// also when [id] has no row, which [getById] distinguishes.
  Future<List<DarkroomRecipe>> childrenOf(int id) async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM recipes WHERE parent_recipe_id = ? '
          'ORDER BY created_at ASC, id ASC',
          variables: [Variable<int>(id)],
        )
        .get();
    return rows.map(_map).toList();
  }

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
    final at = _toEpochSeconds(now ?? DateTime.now());
    return _db.customUpdate(
      'UPDATE recipes SET steps_json = ?, '
      'schema_version = COALESCE(?, schema_version), updated_at = ? '
      'WHERE id = ?',
      variables: [
        Variable<String>(stepsJson),
        Variable<int>(schemaVersion),
        Variable<int>(at),
        Variable<int>(id),
      ],
      updateKind: UpdateKind.update,
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
    final rows = await _db
        .customSelect(
          'SELECT draft_notes_json FROM recipes WHERE id = ? LIMIT 1',
          variables: [Variable<int>(id)],
        )
        .get();
    if (rows.isEmpty) throw RecipeMissingException(id);
    return _decodeDraftNotes(rows.first.read<String>('draft_notes_json'));
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
    final at = _toEpochSeconds(now ?? DateTime.now());
    return _db.customUpdate(
      'UPDATE recipes SET draft_notes_json = ?, updated_at = ? WHERE id = ?',
      variables: [
        Variable<String>(_encodeDraftNotes(notes)),
        Variable<int>(at),
        Variable<int>(id),
      ],
      updateKind: UpdateKind.update,
    );
  }

  /// Rename a recipe (the branch label), bumping `updated_at`. Returns the
  /// number of rows changed.
  Future<int> rename(int id, String name, {DateTime? now}) {
    final at = _toEpochSeconds(now ?? DateTime.now());
    return _db.customUpdate(
      'UPDATE recipes SET name = ?, updated_at = ? WHERE id = ?',
      variables: [Variable<String>(name), Variable<int>(at), Variable<int>(id)],
      updateKind: UpdateKind.update,
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
    return _db.customUpdate(
      'DELETE FROM recipes WHERE id = ?',
      variables: [Variable<int>(id)],
      updateKind: UpdateKind.delete,
    );
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
      deleted += await _db.customUpdate(
        'DELETE FROM recipes WHERE id = ?',
        variables: [Variable<int>(recipeId)],
        updateKind: UpdateKind.delete,
      );
    }
    deleted += await _db.customUpdate(
      'DELETE FROM recipes WHERE id = ?',
      variables: [Variable<int>(id)],
      updateKind: UpdateKind.delete,
    );
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

  DarkroomRecipe _map(QueryRow row) {
    return DarkroomRecipe(
      id: row.read<int>('id'),
      targetId: row.readNullable<int>('target_id'),
      sessionId: row.readNullable<int>('session_id'),
      masterId: row.readNullable<int>('master_id'),
      baseMasterPath: row.read<String>('base_master_path'),
      name: row.read<String>('name'),
      stepsJson: row.read<String>('steps_json'),
      createdBy: RecipeAuthor.fromWire(row.read<String>('created_by')),
      parentRecipeId: row.readNullable<int>('parent_recipe_id'),
      divergenceIndex: row.readNullable<int>('divergence_index'),
      schemaVersion: row.read<int>('schema_version'),
      createdAt: _fromEpochSeconds(row.read<int>('created_at')),
      updatedAt: _fromEpochSeconds(row.read<int>('updated_at')),
    );
  }

  static int _toEpochSeconds(DateTime when) =>
      when.toUtc().millisecondsSinceEpoch ~/ 1000;

  static DateTime _fromEpochSeconds(int seconds) =>
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}

/// Riverpod provider for [RecipesDao].
final recipesDaoProvider = Provider<RecipesDao>((ref) {
  return RecipesDao(ref.watch(databaseProvider));
});
