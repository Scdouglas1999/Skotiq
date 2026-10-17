/// The branch graph over one linear master: every recipe written for the same
/// pixels, the lineage of the one that is open, and the four things an operator
/// does to a branch.
///
/// **Why this is a separate notifier.** [DarkroomController] owns one recipe —
/// its step list, its render loop, its journal. A branch bar is about the set of
/// recipes over one master, and A/B compare renders TWO of them at once, each
/// through its own [DarkroomController]. Keeping the set here means the compare
/// pane is an ordinary second family member rather than a second render loop
/// bolted onto the first.
///
/// **Delete is RESTRICT, and the refusal is the product.** [RecipesDao] refuses
/// to delete a recipe that still has branches, because re-parenting them would
/// leave each branch's `divergence_index` pointing into a step list it never
/// diverged from. This notifier turns that refusal into a sentence naming the
/// branches that block it, plus the one destructive alternative the DAO actually
/// offers — deleting the whole line. A "Delete" that silently did nothing, or
/// that quietly deleted the descendants too, are both the cry-wolf defect class.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Which branch graph a [DarkroomBranchController] describes.
///
/// The master path is the identity: [RecipesDao.listForMaster] keys on it, and
/// [RecipesDao.branchFrom] copies it onto every branch, so one path names the
/// whole family. [recipeId] is the recipe currently open, whose lineage the bar
/// draws; it is null before one is loaded and the bar then shows the family
/// without marking any member current.
@immutable
class DarkroomBranchScope {
  /// Absolute path of the linear master every recipe in this family replays
  /// over.
  final String masterPath;

  /// `recipes.id` of the open recipe, or null when none is open.
  final int? recipeId;

  const DarkroomBranchScope({required this.masterPath, this.recipeId});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DarkroomBranchScope &&
          other.masterPath == masterPath &&
          other.recipeId == recipeId;

  @override
  int get hashCode => Object.hash(masterPath, recipeId);

  @override
  String toString() => 'DarkroomBranchScope($masterPath, recipe=$recipeId)';
}

/// One recipe in the branch family, as the bar draws it.
@immutable
class DarkroomBranch {
  /// `recipes.id`.
  final int id;

  /// The operator-facing branch label as stored. Empty is kept empty here; the
  /// bar supplies a fallback label rather than this class inventing a name that
  /// would then be written back on a rename.
  final String name;

  /// Who authored the step list: the dawn autopilot's first interpretation, or
  /// a human's.
  final RecipeAuthor author;

  /// The recipe this one branched from, or null for a root.
  final int? parentRecipeId;

  /// The index into the PARENT's step list where this branch stops matching it.
  /// Null exactly when [parentRecipeId] is null.
  final int? divergenceIndex;

  /// How many steps the stored stack carries, or null when `steps_json` could
  /// not be read as a step array. Null is shown as "unreadable", never as zero:
  /// a corrupt row and an empty recipe are different facts.
  final int? stepCount;

  /// The ids of the branches pointing at this one, ascending. A non-empty list
  /// is exactly what makes [RecipesDao.deleteRecipe] refuse.
  final List<int> childIds;

  /// How many parents separate this recipe from its root, for the indent in the
  /// lineage list. 0 for a root.
  final int depth;

  /// When the row was created (UTC).
  final DateTime createdAt;

  /// When the step list was last written (UTC).
  final DateTime updatedAt;

  const DarkroomBranch({
    required this.id,
    required this.name,
    required this.author,
    required this.parentRecipeId,
    required this.divergenceIndex,
    required this.stepCount,
    required this.childIds,
    required this.depth,
    required this.createdAt,
    required this.updatedAt,
  });

  /// True when branches point at this recipe, so a plain delete is refused.
  bool get hasChildren => childIds.isNotEmpty;

  /// The label the bar prints: the stored name, or a fallback naming the row.
  String get label => name.trim().isEmpty ? 'Recipe $id' : name.trim();
}

/// A delete the recipe graph refused, and what can be done about it.
///
/// Carried as its own object rather than a bare message so the offer to delete
/// the whole line is attached to the id it applies to; a destructive button
/// wired to "whatever was last refused" is how the wrong subtree gets deleted.
@immutable
class DarkroomBranchDeleteRefusal {
  /// The recipe that could not be deleted.
  final int recipeId;

  /// Its label, so the sentence names it the way the bar does.
  final String label;

  /// The branches that block the delete, in the DAO's own ascending order.
  final List<int> childIds;

  /// The labels of [childIds], in the same order, so the refusal names branches
  /// rather than row numbers.
  final List<String> childLabels;

  const DarkroomBranchDeleteRefusal({
    required this.recipeId,
    required this.label,
    required this.childIds,
    required this.childLabels,
  });

  /// The refusal in the words the operator reads.
  String get explanation {
    final names = childLabels.isEmpty
        ? childIds.map((id) => 'recipe $id').join(', ')
        : childLabels.join(', ');
    final count = childIds.length;
    return '"$label" cannot be deleted while $count '
        '${count == 1 ? 'branch diverges' : 'branches diverge'} from it '
        '($names). Each of those branches records the step of "$label" it '
        'stopped matching, so re-pointing them at its parent would leave them '
        'rendering while describing a lineage that never happened. Delete '
        'those branches first, or delete this branch and everything descended '
        'from it.';
  }
}

/// The branch family over one master, and what the last action did.
@immutable
class DarkroomBranchState {
  /// True until the first read of the family settles.
  final bool loading;

  /// Why the family could not be read, in the words the bar prints.
  final String? loadError;

  /// Every recipe over the master, root-first and depth-first inside each root,
  /// so a branch always follows the recipe it diverged from.
  final List<DarkroomBranch> branches;

  /// The open recipe's ancestry, root first. Empty when no recipe is open.
  final List<DarkroomBranch> lineage;

  /// Why the lineage could not be walked — a parent chain that revisits a row
  /// is storage corruption, and saying so beats drawing a truncated ancestry.
  final String? lineageError;

  /// True while a create/rename/delete is in flight, so a second press cannot
  /// duplicate the same branch twice.
  final bool busy;

  /// Why the last action did not take effect. Null when none has failed.
  final String? actionError;

  /// The delete the graph refused, with the branches that blocked it.
  final DarkroomBranchDeleteRefusal? deleteRefusal;

  /// The id the last successful duplicate created, so the screen can open it.
  /// Cleared once the screen has acted on it.
  final int? createdBranchId;

  const DarkroomBranchState({
    this.loading = true,
    this.loadError,
    this.branches = const [],
    this.lineage = const [],
    this.lineageError,
    this.busy = false,
    this.actionError,
    this.deleteRefusal,
    this.createdBranchId,
  });

  /// True when more than one recipe interprets these pixels, which is the only
  /// case where an A/B compare has two sides.
  bool get hasVariants => branches.length > 1;

  /// The entry for [id], or null when the family holds no such recipe.
  DarkroomBranch? branchFor(int id) {
    for (final branch in branches) {
      if (branch.id == id) return branch;
    }
    return null;
  }

  DarkroomBranchState copyWith({
    bool? loading,
    String? loadError,
    bool clearLoadError = false,
    List<DarkroomBranch>? branches,
    List<DarkroomBranch>? lineage,
    String? lineageError,
    bool clearLineageError = false,
    bool? busy,
    String? actionError,
    bool clearActionError = false,
    DarkroomBranchDeleteRefusal? deleteRefusal,
    bool clearDeleteRefusal = false,
    int? createdBranchId,
    bool clearCreatedBranchId = false,
  }) {
    return DarkroomBranchState(
      loading: loading ?? this.loading,
      loadError: clearLoadError ? null : (loadError ?? this.loadError),
      branches: branches ?? this.branches,
      lineage: lineage ?? this.lineage,
      lineageError:
          clearLineageError ? null : (lineageError ?? this.lineageError),
      busy: busy ?? this.busy,
      actionError: clearActionError ? null : (actionError ?? this.actionError),
      deleteRefusal:
          clearDeleteRefusal ? null : (deleteRefusal ?? this.deleteRefusal),
      createdBranchId: clearCreatedBranchId
          ? null
          : (createdBranchId ?? this.createdBranchId),
    );
  }
}

/// Drives the branch bar over one master.
class DarkroomBranchController extends StateNotifier<DarkroomBranchState> {
  DarkroomBranchController(Ref ref, this._scope)
      : _recipes = ref.read(recipesDaoProvider),
        super(const DarkroomBranchState()) {
    unawaited(refresh());
  }

  final DarkroomBranchScope _scope;
  final RecipesDao _recipes;

  /// Re-read the family and the open recipe's lineage.
  Future<void> refresh() async {
    if (_scope.masterPath.isEmpty) {
      state = state.copyWith(
        loading: false,
        loadError:
            'This recipe names no linear master, so the branches written over '
            'those pixels cannot be found.',
        branches: const [],
        lineage: const [],
      );
      return;
    }

    final List<DarkroomRecipe> rows;
    try {
      rows = await _recipes.listForMaster(_scope.masterPath);
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        loading: false,
        loadError: 'The recipes written over this master could not be read: '
            '$error',
      );
      return;
    }
    if (!mounted) return;

    final branches = _order(rows);
    state = state.copyWith(
      loading: false,
      clearLoadError: true,
      branches: branches,
    );
    await _loadLineage(branches);
  }

  /// Walk the open recipe's ancestry through the DAO rather than the list read
  /// above.
  ///
  /// The walk is the DAO's own, so a parent pointer that outlived its row or a
  /// cycle in the graph is reported here with the exception's own words instead
  /// of quietly producing a shorter ancestry than the one on disk.
  Future<void> _loadLineage(List<DarkroomBranch> branches) async {
    final recipeId = _scope.recipeId;
    if (recipeId == null) {
      state = state.copyWith(lineage: const [], clearLineageError: true);
      return;
    }
    try {
      final chain = await _recipes.chainToRoot(recipeId);
      if (!mounted) return;
      // chainToRoot answers self-first; the bar reads a lineage root-first.
      final ordered = chain.reversed
          .map((recipe) => _entryFor(recipe.id, branches, recipe))
          .toList(growable: false);
      state = state.copyWith(lineage: ordered, clearLineageError: true);
    } on RecipeMissingException catch (error) {
      if (!mounted) return;
      // The DAO's sentence names the row and stops there. On this bar it is
      // read by an operator looking at an editor that is still showing that
      // recipe's steps, so it says what to do about that as well — every other
      // failure on this screen names a next step and this one did not.
      state = state.copyWith(
        lineage: const [],
        lineageError: '$error, so its ancestry could not be walked. Press '
            'Reload to re-read this master: a recipe deleted while it was open '
            'leaves the editor showing a stack that is no longer stored.',
      );
    } on RecipeGraphCycleException catch (error) {
      if (!mounted) return;
      state = state.copyWith(lineage: const [], lineageError: '$error');
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        lineage: const [],
        lineageError: 'This recipe\'s ancestry could not be read: $error',
      );
    }
  }

  /// Copy [sourceRecipeId] into a new branch of it and return the new id, or
  /// null when nothing was created.
  ///
  /// The variant diverges at the END of the parent's step list: it starts as the
  /// same stack, so every step is shared until the operator changes one. Writing
  /// any other divergence index would claim a disagreement that has not happened
  /// yet.
  Future<int?> duplicateAsVariant({
    required int sourceRecipeId,
    required String name,
  }) async {
    if (state.busy) return null;
    final label = name.trim();
    if (label.isEmpty) {
      state = state.copyWith(
        actionError: 'A variant needs a name, so it can be told apart from the '
            'branch it was copied from.',
      );
      return null;
    }
    state = state.copyWith(
      busy: true,
      clearActionError: true,
      clearDeleteRefusal: true,
    );
    try {
      final source = await _recipes.getById(sourceRecipeId);
      if (source == null) {
        if (!mounted) return null;
        state = state.copyWith(
          busy: false,
          actionError:
              'Recipe $sourceRecipeId no longer has a row, so there is nothing '
              'to copy into a variant.',
        );
        return null;
      }
      final parentSteps = _stepCount(source.stepsJson);
      if (parentSteps == null) {
        if (!mounted) return null;
        state = state.copyWith(
          busy: false,
          actionError:
              'Recipe $sourceRecipeId stores a step list this build cannot '
              'read, so how many of its steps a variant would share is '
              'unknown. A branch written with a made-up divergence index would '
              'describe a lineage that never happened.',
        );
        return null;
      }
      final id = await _recipes.branchFrom(
        parentRecipeId: sourceRecipeId,
        divergenceIndex: parentSteps,
        name: label,
        createdBy: RecipeAuthor.user,
      );
      if (!mounted) return null;
      state = state.copyWith(busy: false, createdBranchId: id);
      await refresh();
      return id;
    } catch (error) {
      if (!mounted) return null;
      state = state.copyWith(
        busy: false,
        actionError: 'The variant could not be created: $error',
      );
      return null;
    }
  }

  /// Rename one branch. Answers whether the row was changed.
  Future<bool> renameBranch(int recipeId, String name) async {
    if (state.busy) return false;
    final label = name.trim();
    if (label.isEmpty) {
      state = state.copyWith(
        actionError: 'A branch name cannot be empty — the bar would have '
            'nothing to label it with.',
      );
      return false;
    }
    state = state.copyWith(
      busy: true,
      clearActionError: true,
      clearDeleteRefusal: true,
    );
    try {
      final rows = await _recipes.rename(recipeId, label);
      if (!mounted) return false;
      if (rows == 0) {
        state = state.copyWith(
          busy: false,
          actionError:
              'Recipe $recipeId no longer has a row, so the new name was not '
              'stored.',
        );
        return false;
      }
      state = state.copyWith(busy: false);
      await refresh();
      return true;
    } catch (error) {
      if (!mounted) return false;
      state = state.copyWith(
        busy: false,
        actionError: 'The branch could not be renamed: $error',
      );
      return false;
    }
  }

  /// Delete one branch, or explain why the graph refuses.
  ///
  /// Answers true only when a row was actually removed. A refusal leaves
  /// [DarkroomBranchState.deleteRefusal] set with the branches that blocked it.
  Future<bool> deleteBranch(int recipeId) async {
    if (state.busy) return false;
    state = state.copyWith(
      busy: true,
      clearActionError: true,
      clearDeleteRefusal: true,
    );
    try {
      final rows = await _recipes.deleteRecipe(recipeId);
      if (!mounted) return false;
      if (rows == 0) {
        state = state.copyWith(
          busy: false,
          actionError:
              'Recipe $recipeId no longer has a row, so there was nothing to '
              'delete.',
        );
        await refresh();
        return false;
      }
      state = state.copyWith(busy: false);
      await refresh();
      return true;
    } on RecipeHasChildrenException catch (error) {
      if (!mounted) return false;
      state = state.copyWith(
        busy: false,
        deleteRefusal: DarkroomBranchDeleteRefusal(
          recipeId: recipeId,
          label: state.branchFor(recipeId)?.label ?? 'Recipe $recipeId',
          childIds: error.childIds,
          childLabels: [
            for (final id in error.childIds)
              state.branchFor(id)?.label ?? 'Recipe $id',
          ],
        ),
      );
      return false;
    } catch (error) {
      if (!mounted) return false;
      state = state.copyWith(
        busy: false,
        actionError: 'The branch could not be deleted: $error',
      );
      return false;
    }
  }

  /// Delete [recipeId] and every branch descended from it. Answers how many
  /// rows went, or null when the delete failed.
  ///
  /// The explicitly destructive alternative the RESTRICT refusal offers: it says
  /// what it destroys before it runs, and it is never what a plain "Delete"
  /// does.
  Future<int?> deleteBranchLine(int recipeId) async {
    if (state.busy) return null;
    state = state.copyWith(
      busy: true,
      clearActionError: true,
      clearDeleteRefusal: true,
    );
    try {
      final deleted = await _recipes.deleteRecipeSubtree(recipeId);
      if (!mounted) return null;
      state = state.copyWith(busy: false);
      await refresh();
      return deleted;
    } catch (error) {
      if (!mounted) return null;
      state = state.copyWith(
        busy: false,
        actionError: 'The branch line could not be deleted: $error',
      );
      return null;
    }
  }

  /// Put the refusal away without acting on it.
  void dismissRefusal() {
    state = state.copyWith(clearDeleteRefusal: true);
  }

  /// Acknowledge the id a duplicate created, so opening it happens once.
  void acknowledgeCreatedBranch() {
    state = state.copyWith(clearCreatedBranchId: true);
  }

  /// Order the family root-first and depth-first, and attach each row's
  /// children and depth.
  ///
  /// A recipe whose parent is not in this family (its parent renders a different
  /// master, which `branchFrom` cannot produce) is treated as a root here rather
  /// than dropped: a branch missing from the bar is a branch the operator cannot
  /// reach.
  static List<DarkroomBranch> _order(List<DarkroomRecipe> rows) {
    final byId = <int, DarkroomRecipe>{};
    for (final row in rows) {
      final id = row.id;
      if (id != null) byId[id] = row;
    }
    final children = <int, List<int>>{};
    final roots = <int>[];
    // listForMaster answers newest-first; the bar reads a family oldest-first,
    // so a parent is drawn before the branches taken off it.
    final ids = byId.keys.toList()..sort();
    for (final id in ids) {
      final parent = byId[id]!.parentRecipeId;
      if (parent == null || !byId.containsKey(parent)) {
        roots.add(id);
      } else {
        children.putIfAbsent(parent, () => <int>[]).add(id);
      }
    }

    final out = <DarkroomBranch>[];
    final seen = <int>{};
    void walk(int id, int depth) {
      // The graph is acyclic by construction (a new branch has no descendants),
      // but a corrupt row must not spin this walk forever.
      if (!seen.add(id)) return;
      final row = byId[id]!;
      final kids = children[id] ?? const <int>[];
      out.add(
        DarkroomBranch(
          id: id,
          name: row.name,
          author: row.createdBy,
          parentRecipeId: row.parentRecipeId,
          divergenceIndex: row.divergenceIndex,
          stepCount: _stepCount(row.stepsJson),
          childIds: List.unmodifiable(kids),
          depth: depth,
          createdAt: row.createdAt,
          updatedAt: row.updatedAt,
        ),
      );
      for (final kid in kids) {
        walk(kid, depth + 1);
      }
    }

    for (final root in roots) {
      walk(root, 0);
    }
    // Anything a cycle kept out of the walk is still a recipe over this master.
    for (final id in ids) {
      if (seen.contains(id)) continue;
      final row = byId[id]!;
      out.add(
        DarkroomBranch(
          id: id,
          name: row.name,
          author: row.createdBy,
          parentRecipeId: row.parentRecipeId,
          divergenceIndex: row.divergenceIndex,
          stepCount: _stepCount(row.stepsJson),
          childIds: List.unmodifiable(children[id] ?? const <int>[]),
          depth: 0,
          createdAt: row.createdAt,
          updatedAt: row.updatedAt,
        ),
      );
    }
    return List.unmodifiable(out);
  }

  /// The entry for [id] out of [branches], or one built from [fallback] when the
  /// family read did not carry it.
  static DarkroomBranch _entryFor(
    int? id,
    List<DarkroomBranch> branches,
    DarkroomRecipe fallback,
  ) {
    if (id != null) {
      for (final branch in branches) {
        if (branch.id == id) return branch;
      }
    }
    return DarkroomBranch(
      id: id ?? -1,
      name: fallback.name,
      author: fallback.createdBy,
      parentRecipeId: fallback.parentRecipeId,
      divergenceIndex: fallback.divergenceIndex,
      stepCount: _stepCount(fallback.stepsJson),
      childIds: const [],
      depth: 0,
      createdAt: fallback.createdAt,
      updatedAt: fallback.updatedAt,
    );
  }

  /// How many steps a stored `steps_json` carries, or null when it is not a step
  /// array.
  static int? _stepCount(String stepsJson) {
    final Object? decoded;
    try {
      decoded = jsonDecode(stepsJson);
    } on FormatException {
      return null;
    }
    return decoded is List ? decoded.length : null;
  }
}

/// Family provider keyed by the master path and the open recipe.
///
/// autoDispose for the same reason [darkroomControllerProvider] is: this
/// notifier reads the family once, in its constructor, so a member that outlives
/// its bar would keep drawing chips for recipes that have since been deleted and
/// keep omitting ones that have since been created.
final darkroomBranchControllerProvider = StateNotifierProvider.autoDispose
    .family<DarkroomBranchController, DarkroomBranchState, DarkroomBranchScope>(
        (ref, scope) => DarkroomBranchController(ref, scope));
