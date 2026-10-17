/// The durable non-destructive recipe record — an ordered, parameterized
/// operation stack replayed over a linear master light.
///
/// A [DarkroomRecipe] maps 1:1 to a row of the raw-DDL `recipes` table (see
/// `SkotiqDatabase._createDarkroomTables`) and is read/written through the
/// plain [RecipesDao], mirroring `MosaicProjectsDao` / `CampaignsDao`.
///
/// Naming: `IntegrationSettings` is already called a "recipe" by the A/B
/// compare panel and the preview-integrate path. That is a DATA-half settings
/// bundle; this is the INTERPRETATION-half op stack, so the type carries the
/// `Darkroom` prefix and the two never share a name.
library;

/// Who authored a [DarkroomRecipe].
///
/// Stored as the lowercase wire string in `recipes.created_by`, constrained by
/// a `CHECK` on the column so an unknown value cannot be written by this app.
enum RecipeAuthor {
  /// The dawn autopilot generated this recipe's first draft.
  autopilot,

  /// A human wrote or edited this recipe in the Darkroom editor.
  user;

  /// The lowercase wire string stored in the DB.
  String get wire => name;

  /// Parse a stored author string.
  ///
  /// Throws [DarkroomWireFormatException] on any value this app could not have
  /// written. The column carries a `CHECK` constraint, so an unrecognised value
  /// is storage corruption, not an older format — reporting it beats defaulting
  /// to `autopilot` and attributing a human's edits to the machine.
  static RecipeAuthor fromWire(String? value) {
    switch (value) {
      case 'autopilot':
        return RecipeAuthor.autopilot;
      case 'user':
        return RecipeAuthor.user;
      default:
        throw DarkroomWireFormatException('recipes.created_by', value);
    }
  }
}

/// A stored enum column holds a value outside its `CHECK` constraint.
class DarkroomWireFormatException implements Exception {
  /// `table.column` the unreadable value came from.
  final String column;

  /// The value as stored.
  final String? value;

  const DarkroomWireFormatException(this.column, this.value);

  @override
  String toString() =>
      'Unreadable $column value ${value == null ? '<null>' : '"$value"'}; '
      'the column is CHECK-constrained, so this row is corrupt.';
}

/// A branch field combination that cannot describe a real branch.
class RecipeBranchException implements Exception {
  final String message;

  const RecipeBranchException(this.message);

  @override
  String toString() => 'Invalid recipe branch: $message';
}

/// One recipe: the ordered op stack applied to one linear master.
///
/// A branch is a row pointing at [parentRecipeId] with the [divergenceIndex]
/// at which its steps stop matching the parent's. Both are null for a root
/// recipe and both are set for a branch; either alone is a
/// [RecipeBranchException].
class DarkroomRecipe {
  /// DB primary key (`recipes.id`). Null for an unsaved record.
  final int? id;

  /// The `targets.id` this recipe's master was integrated for, or null. The
  /// same target identity `integrated_masters.target_id` uses. `ON DELETE SET
  /// NULL` — a recipe outlives the target row it was framed from.
  final int? targetId;

  /// The `imaging_sessions.id` the dawn run read from
  /// `SequenceTerminalRunResult.dbSessionId`, or null for a recipe created
  /// outside a session (an imported or hand-opened master). `ON DELETE SET
  /// NULL`.
  final int? sessionId;

  /// The `integrated_masters.id` of the linear master this recipe renders, or
  /// null when the master was opened by path without a library row. `ON DELETE
  /// SET NULL`.
  final int? masterId;

  /// Absolute path of the linear master FITS this recipe replays over. The
  /// authoritative base reference: [masterId] may be null or may have been
  /// cleared by a target delete, but the pixels are addressed by path.
  final String baseMasterPath;

  /// Operator-facing branch label, e.g. `Draft` or `Warmer stars`.
  final String name;

  /// The serialized op stack: a JSON array of `{op_id, version, params,
  /// enabled}` objects, in replay order. Opaque here — the Rust recipe engine
  /// owns the op vocabulary and its validation.
  final String stepsJson;

  /// Who authored this recipe.
  final RecipeAuthor createdBy;

  /// The `recipes.id` this recipe branched from, or null for a root recipe.
  /// `ON DELETE RESTRICT`: a parent with children cannot be deleted out from
  /// under them (see [RecipesDao.deleteRecipe]).
  final int? parentRecipeId;

  /// The index into the PARENT's step list at which this branch diverges: steps
  /// `[0, divergenceIndex)` are shared with the parent. Null exactly when
  /// [parentRecipeId] is null.
  final int? divergenceIndex;

  /// Version of the `steps_json` format, NOT the database schema version. Op
  /// versions live per-step inside `steps_json`; this covers the envelope
  /// around them.
  final int schemaVersion;

  /// When the recipe row was created (UTC).
  final DateTime createdAt;

  /// When the recipe row was last updated (UTC).
  final DateTime updatedAt;

  const DarkroomRecipe({
    this.id,
    this.targetId,
    this.sessionId,
    this.masterId,
    required this.baseMasterPath,
    required this.name,
    required this.stepsJson,
    required this.createdBy,
    this.parentRecipeId,
    this.divergenceIndex,
    required this.schemaVersion,
    required this.createdAt,
    required this.updatedAt,
  });

  /// True when this recipe branched from another.
  bool get isBranch => parentRecipeId != null;

  DarkroomRecipe copyWith({
    int? id,
    int? targetId,
    int? sessionId,
    int? masterId,
    String? baseMasterPath,
    String? name,
    String? stepsJson,
    RecipeAuthor? createdBy,
    int? parentRecipeId,
    int? divergenceIndex,
    int? schemaVersion,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return DarkroomRecipe(
      id: id ?? this.id,
      targetId: targetId ?? this.targetId,
      sessionId: sessionId ?? this.sessionId,
      masterId: masterId ?? this.masterId,
      baseMasterPath: baseMasterPath ?? this.baseMasterPath,
      name: name ?? this.name,
      stepsJson: stepsJson ?? this.stepsJson,
      createdBy: createdBy ?? this.createdBy,
      parentRecipeId: parentRecipeId ?? this.parentRecipeId,
      divergenceIndex: divergenceIndex ?? this.divergenceIndex,
      schemaVersion: schemaVersion ?? this.schemaVersion,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  String toString() =>
      'DarkroomRecipe(id=$id, name=$name, by=${createdBy.wire}, '
      'parent=$parentRecipeId, divergeAt=$divergenceIndex)';
}
