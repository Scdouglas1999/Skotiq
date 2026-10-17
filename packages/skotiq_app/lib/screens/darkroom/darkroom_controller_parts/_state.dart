part of '../darkroom_controller.dart';

/// Another master from the same night, and the newest recipe written over it.
///
/// Every in-app "refine this night" entry point resolves ONE master and opens
/// it, so a four-filter night hands the editor one of four drafts and says
/// nothing about the other three. This is the statement that they exist: one
/// entry per sibling master, with the recipe that opens it when it has one.
@immutable
class DarkroomSiblingDraft {
  /// `integrated_masters.id` of the sibling.
  final int masterId;

  /// The sibling master's own library name.
  final String masterName;

  /// The filter it covers, or null for an unfiltered master.
  final String? filter;

  /// The newest recipe over those pixels, or null when the master carries none
  /// yet — in which case the link opens the master and offers a first one.
  final int? recipeId;

  /// That recipe's label, or null when there is no recipe.
  final String? recipeName;

  /// Who wrote that recipe, or null when there is none.
  final RecipeAuthor? author;

  /// True when the operation registry composed that recipe's steps — the same
  /// fact [DarkroomState.composedByRegistry] states for the open one, so a chip
  /// and the panel it leads to cannot disagree about who drafted a stack.
  final bool composedByRegistry;

  const DarkroomSiblingDraft({
    required this.masterId,
    required this.masterName,
    required this.filter,
    required this.recipeId,
    required this.recipeName,
    required this.author,
    this.composedByRegistry = false,
  });

  /// The words the branch bar prints on the link.
  ///
  /// The master name is not repeated when the recipe's own name already opens
  /// with it: the dawn autopilot names every draft after the master it was
  /// drafted over, so joining the two printed "Master · G · Master · G draft"
  /// on one chip — the same words twice, and wide enough to push the row off a
  /// phone.
  String get label {
    final name = recipeName?.trim();
    if (name == null || name.isEmpty) return masterName;
    if (name == masterName || name.startsWith('$masterName ')) return name;
    return '$masterName · $name';
  }
}

/// The step a failed render NAMED, and the fault it named for it.
///
/// A render that stops names its culprit exactly — "step 3 failed:
/// color_calibrate@1: unsupported channel layout…" — and the stack showed that
/// nowhere: the failing step's card carried the same "the last render did not
/// finish, so nothing is reported for this step" sentence as every step that
/// merely never ran, so nothing on screen said which one stopped the render.
///
/// It is only ever built from a message whose index AND operation both match
/// the step at that position in the recipe the engine was handed. A message
/// this build cannot join that way produces none, and every card keeps the
/// honest generic sentence — a guess about which step failed would be worse
/// than no attribution at all.
@immutable
class DarkroomRenderFailure {
  /// The [DarkroomStep.identity] of the named step.
  final Object stepIdentity;

  /// The operation's own fault, in the engine's words, without the "step N
  /// failed:" framing — the card this lands on IS that step.
  final String reason;

  const DarkroomRenderFailure({
    required this.stepIdentity,
    required this.reason,
  });
}

/// What the Darkroom is showing right now.
///
/// The state is rebuilt whole on every change; there is no in-place mutation,
/// so a widget that captured an earlier state keeps describing the frame it was
/// built for.
@immutable
class DarkroomState {
  /// True until the first load settles.
  final bool loading;

  /// Why nothing can be opened, in the words the empty state prints. Null when
  /// a recipe (or an offer to create one) is loaded.
  final String? loadError;

  /// A master with no recipe, and the two ways to give it one. Null once a
  /// recipe is open.
  final DarkroomStartOffer? offer;

  /// True while one of the offer's two actions is running, so a second tap
  /// cannot create a second recipe over the same master.
  final bool offerBusy;

  /// Why the last offer action produced no recipe. Null when none has failed.
  ///
  /// Named for the start offer because that is where it began, but `Import
  /// .nsrecipe` writes it from BOTH entry points — the offer and the branch bar
  /// over an open recipe — so every layout of this screen has to render it. A
  /// refusal composed into a field the current layout does not read is a
  /// refusal the operator never sees, which is the same thing as no refusal at
  /// all.
  final String? offerError;

  /// `recipes.id` of the open recipe, null while none is open.
  final int? recipeId;

  /// Operator-facing recipe (branch) label.
  final String recipeName;

  /// Absolute path of the linear master this recipe replays over.
  final String baseMasterPath;

  /// Who authored the step list as it stands.
  final RecipeAuthor author;

  /// `integrated_masters.id` the recipe was framed from, or null when the
  /// master was opened by path with no library row.
  final int? masterId;

  /// The edited op stack, in application order.
  final List<DarkroomStep> steps;

  /// The operation catalogue that drives the parameter controls. Null until the
  /// registry answers.
  final DarkroomCatalog? catalog;

  /// Why the catalogue is absent, in the engine's words. With no catalogue the
  /// step cards show what the recipe stores and say that the ranges behind the
  /// controls could not be read, rather than drawing controls over guessed
  /// bounds.
  final String? catalogError;

  /// The most recent render's pixels, or null before the first one lands.
  final DarkroomPreviewImage? preview;

  /// One entry per step the last render covered.
  final List<DarkroomStepReport> reports;

  /// The [DarkroomStep.identity] of every step the last render was ASKED
  /// about, in the order the engine indexed them.
  ///
  /// A report line names an index into the list the engine was handed, which
  /// is not the position of that step in the stack the operator is now looking
  /// at: a step can be inserted in front of it, and a step the render was not
  /// asked about is not in the engine's list at all. [reportFor] joins through
  /// this list, so an outcome only ever reaches the card of the step the engine
  /// actually produced it for.
  final List<Object> reportedSteps;

  /// One entry per step from the last `validate` call.
  final List<DarkroomStepIssue> issues;

  /// The step identities [issues] index, in the order they were validated.
  final List<Object> issuedSteps;

  /// The identities of the steps the last render was NOT asked about, because
  /// they are switched off and this build cannot run them.
  ///
  /// The engine validates the whole recipe before it touches a pixel, so one
  /// unregistered step refuses the render whether or not it would have been
  /// applied. A step that is switched off contributes nothing to the picture,
  /// so it is left out of the render request instead of stopping it — and the
  /// card says so rather than the operator having to infer it.
  final List<Object> omittedFromRender;

  /// The engine's verdict on the recipe as a whole, null when it validates.
  final String? recipeError;

  /// True while a render is in flight.
  final bool rendering;

  /// True once cancellation has been asked for and before the render answers.
  final bool cancelRequested;

  /// Why the last render failed, in the engine's words. Null when the last
  /// render succeeded or was cancelled (a cancellation is not a failure).
  final String? renderError;

  /// Which step that failure named, when it named one this build could join to
  /// a step of the recipe the engine was handed. Null otherwise, including for
  /// every failure that is not about a step at all — a master that cannot be
  /// read, a schema refusal, a stop that did not reach the render.
  final DarkroomRenderFailure? renderFailure;

  /// The phase the last cancelled render stopped in, so the screen can say what
  /// the operator's stop actually interrupted. Null when nothing was cancelled.
  final String? cancelledPhase;

  /// Why the last reorder was refused, in the engine's words. Null when the
  /// last reorder was accepted or none has been attempted.
  final String? reorderRefusal;

  /// Which attempt raised [reorderRefusal], counted from 1. Zero when there is
  /// no refusal.
  ///
  /// The screen announces a refusal once per occurrence, and the only thing
  /// that told two occurrences apart was the sentence: a second refused move of
  /// the same step, for the same reason, produced a byte-identical string, so
  /// the announcement was suppressed and the second press went silent while
  /// the screen's own comment promised it would speak again. The stamp is what
  /// makes an identical refusal a second refusal.
  final int reorderRefusalAttempt;

  /// True while an added step is being measured and checked, so a second press
  /// cannot put two copies of one operation into the stack.
  final bool insertBusy;

  /// Why the last "add step" added nothing, in the words of whoever refused it
  /// — the engine's own sentence for an order it will not run, and the
  /// registry's own note for an operation it could not measure from this
  /// master. Null when the last insert was accepted or none has been attempted.
  final String? insertRefusal;

  /// Which attempt raised [insertRefusal], counted from 1. Zero when there is
  /// none. It exists for the reason [reorderRefusalAttempt] does: the chooser
  /// closes on the choice, so a second identical refusal that announced nothing
  /// left a stack that looked untouched and no word about why.
  final int insertRefusalAttempt;

  /// How many channels the open recipe's linear master has, read from its
  /// library row. Null when the recipe carries no library row, or before that
  /// row has been read — in which case nothing states a channel precondition,
  /// because the count is not known here.
  ///
  /// It is a fact about the MASTER, and every operation this build registers
  /// preserves the channel count, so it is also the count that reaches any step
  /// the operator adds. That is what lets the chooser refuse a three-channel
  /// operation over a mono master before it is added, instead of committing the
  /// step and discovering it in a failed render.
  final int? masterChannels;

  /// What the master's own integration recorded about the calibration it
  /// applied, or null when the recipe carries no library row / before that row
  /// has been read.
  ///
  /// Parsed from the SAME `integrated_masters.stats_json` the dawn autopilot's
  /// morning report reads, so the editor and that report cannot disagree about
  /// which darks, flats and bias reached these pixels. It is the one fact about
  /// the base master that changes what the operator should believe about every
  /// step above it — a gradient over an uncalibrated frame is a sensor
  /// signature, not sky — and the Recipe panel's provenance block, which names
  /// the author and the file, said nothing about it at all.
  final DawnMasterStats? masterCalibration;

  /// Why the field carries no catalogue photometry, when it does not. The
  /// color calibration is skipped with the engine's own reason in that case;
  /// this states the app-side half of the same fact.
  final String? photometryNote;

  /// Number of catalogue stars lent to `color_calibrate`.
  final int photometryStarCount;

  /// True when an earlier step list can be restored.
  final bool canUndo;

  /// True when an undone step list can be re-applied.
  final bool canRedo;

  /// True while an edit is waiting to be written to the recipe row.
  final bool savePending;

  /// Why the last write to the recipe row failed. Null when the row is current.
  final String? saveError;

  /// The composing pass's own account of this recipe: one note per operation
  /// the operation registry decided about, with the reason it gave.
  ///
  /// Read from `recipes.draft_notes_json` when the recipe opens, so the reasons
  /// survive the pass that recorded them. They used to be attached in memory by
  /// the in-session "Draft for me" alone: the dawn autopilot's own draft opened
  /// with none of them, and one Reload erased the rest. The operator was
  /// promised "color where there is color to calibrate" and then handed a
  /// four-step stack that said nothing about the colour step it did not carry.
  ///
  /// Empty for a recipe nobody drafted — which is what [composedByRegistry]
  /// reads to tell a drafted stack from a hand-written one.
  final List<RecipeDraftNote> draftNotes;

  /// Why the draft account could not be read off the recipe row. Null when it
  /// was read — including when it was read and there was nothing in it.
  final String? draftNotesError;

  /// The other masters of the same night, with the newest recipe over each.
  ///
  /// Empty when the night produced one master, or before the walk settles.
  final List<DarkroomSiblingDraft> siblings;

  /// Why the night's other masters could not be listed, in the words the bar
  /// prints. Null when the walk succeeded — including when it succeeded and
  /// found none.
  final String? siblingsError;

  /// What the last `.nsrecipe` import read, in the file's own numbers. Null
  /// when nothing was imported into this editor session.
  final String? importNote;

  const DarkroomState({
    this.loading = true,
    this.loadError,
    this.offer,
    this.offerBusy = false,
    this.offerError,
    this.recipeId,
    this.recipeName = '',
    this.baseMasterPath = '',
    this.author = RecipeAuthor.user,
    this.masterId,
    this.steps = const [],
    this.catalog,
    this.catalogError,
    this.preview,
    this.reports = const [],
    this.reportedSteps = const [],
    this.issues = const [],
    this.issuedSteps = const [],
    this.omittedFromRender = const [],
    this.recipeError,
    this.rendering = false,
    this.cancelRequested = false,
    this.renderError,
    this.renderFailure,
    this.cancelledPhase,
    this.reorderRefusal,
    this.reorderRefusalAttempt = 0,
    this.insertBusy = false,
    this.insertRefusal,
    this.insertRefusalAttempt = 0,
    this.masterChannels,
    this.masterCalibration,
    this.photometryNote,
    this.photometryStarCount = 0,
    this.canUndo = false,
    this.canRedo = false,
    this.savePending = false,
    this.saveError,
    this.draftNotes = const [],
    this.draftNotesError,
    this.siblings = const [],
    this.siblingsError,
    this.importNote,
  });

  /// True when a recipe is open and editable.
  bool get hasRecipe => recipeId != null;

  /// True when every step is disabled — the state "Reset to linear" leaves
  /// behind, with every step and its parameters intact.
  bool get isLinear => steps.isNotEmpty && steps.every((s) => !s.enabled);

  /// True when the operation registry composed this stack rather than a hand
  /// building it step by step.
  ///
  /// The draft account is written by the composing pass and by nothing else —
  /// one note per operation it decided about, `included` ones as well — so a
  /// recipe that carries one is a recipe something drafted. That is what lets
  /// the identity tag say "drafted" for a stack the operator asked the registry
  /// for, instead of crediting them with steps they did not choose.
  bool get composedByRegistry => draftNotes.isNotEmpty;

  /// The draft notes worth printing: every one about an operation the stack
  /// does NOT carry as the registry measured it.
  ///
  /// An `included` note repeats what its own step card already says, in the
  /// panel's most prominent slot; the decisions with nothing on screen to speak
  /// for them are the ones that have to be read.
  List<RecipeDraftNote> get statedDraftNotes => List.unmodifiable(
        draftNotes.where((note) => note.outcome != 'included'),
      );

  /// True when the stack carries a color calibration.
  ///
  /// The catalogue photometry is lent to that one operation and to no other, so
  /// it is the only step whose absence of catalogue stars is worth stating. A
  /// stack without it has nothing the missing catalogue would have changed.
  bool get hasColorCalibrateStep =>
      steps.any((step) => step.opId == kDarkroomColorCalibrateOpId);

  /// Where a step for [op] goes so the stack keeps the engine's stage order, or
  /// null when this build cannot place it.
  ///
  /// The rule is the engine's own (`recipe/render.rs` `validate`): a
  /// linear-stage operation cannot run after a stretched one. A stretched
  /// operation therefore goes on the end, and a linear one goes in front of the
  /// first stretched step there is — the last position the rule leaves for it,
  /// and the one that keeps every step already in the stack where it is.
  ///
  /// The stage of a step is read from the catalogue exactly as the engine reads
  /// it from its registry: a DISABLED step still carries its stage into the
  /// rule, and a step whose operation this build does not register has no stage
  /// here to order against.
  ///
  /// This decides where to PROPOSE the step, never whether it is legal — the
  /// engine is asked about the whole candidate stack before the insert commits.
  /// Null for an operation whose stage the registry names and this build does
  /// not model: there is no side of the stretch to put it on, and guessing one
  /// would propose an order no rule in this build supports.
  int? insertIndexFor(DarkroomOpSpec op) {
    switch (op.stage) {
      case DarkroomOpStage.stretched:
        return steps.length;
      case DarkroomOpStage.unmodelled:
        return null;
      case DarkroomOpStage.linear:
        for (var i = 0; i < steps.length; i++) {
          if (catalog?.specFor(steps[i])?.stage == DarkroomOpStage.stretched) {
            return i;
          }
        }
        return steps.length;
    }
  }

  /// The render report for the step at [index], or null when the last render
  /// carried no line for that step.
  ///
  /// Joined on [DarkroomStep.identity], never on list position: an outcome the
  /// engine produced for one step must never be read onto the step that later
  /// took its index.
  DarkroomStepReport? reportFor(int index) =>
      _joinByIdentity(index, reports, reportedSteps, (r) => r.index);

  /// The validation verdict for the step at [index], or null when the last
  /// `validate` carried no entry for that step. Joined on identity, as
  /// [reportFor] is.
  DarkroomStepIssue? issueFor(int index) =>
      _joinByIdentity(index, issues, issuedSteps, (i) => i.index);

  T? _joinByIdentity<T>(
    int index,
    List<T> entries,
    List<Object> describes,
    int Function(T entry) indexOf,
  ) {
    if (index < 0 || index >= steps.length) return null;
    final identity = steps[index].identity;
    for (final entry in entries) {
      final at = indexOf(entry);
      if (at < 0 || at >= describes.length) continue;
      if (identical(describes[at], identity)) return entry;
    }
    return null;
  }

  /// True when the last render's failure NAMED the step at [index].
  ///
  /// Joined on [DarkroomStep.identity], never on list position, for the reason
  /// [reportFor] is: the stack can have been edited since the render was asked,
  /// and a fault attributed to whichever step later took an index is a lie
  /// about a step the engine never ran.
  bool isFailedStep(int index) => failureReasonFor(index) != null;

  /// The engine's reason for the step at [index], when that step is the one the
  /// last render's failure named. Null otherwise.
  String? failureReasonFor(int index) {
    final failure = renderFailure;
    if (failure == null) return null;
    if (index < 0 || index >= steps.length) return null;
    return identical(steps[index].identity, failure.stepIdentity)
        ? failure.reason
        : null;
  }

  /// True when the step at [index] was left out of the last render request
  /// because it is switched off and this build cannot run it.
  bool isOmittedFromRender(int index) {
    if (index < 0 || index >= steps.length) return false;
    final identity = steps[index].identity;
    for (final omitted in omittedFromRender) {
      if (identical(omitted, identity)) return true;
    }
    return false;
  }

  /// The engine's whole-stack refusal, or null when the stack renders.
  ///
  /// The engine refuses a recipe on its FIRST bad step, switched on or off, so
  /// its sentence alone would tell an operator who has already switched that
  /// step off that the stack still cannot run — which is untrue, because the
  /// render is asked without it. The refusal therefore stands only when a step
  /// the render will actually replay is the one at fault, or when the engine
  /// named a fault the per-step diagnosis does not attribute to any step (a
  /// stage-ordering rule, the schema version, the branch link) and which
  /// switching a step off cannot answer.
  String? get blockingRecipeError {
    final error = recipeError;
    if (error == null) return null;
    var attributed = false;
    for (var index = 0; index < steps.length; index++) {
      final issue = issueFor(index);
      if (issue == null || issue.isClean) continue;
      attributed = true;
      if (steps[index].enabled) return error;
    }
    return attributed ? null : error;
  }

  DarkroomState copyWith({
    bool? loading,
    String? loadError,
    bool clearLoadError = false,
    DarkroomStartOffer? offer,
    bool clearOffer = false,
    bool? offerBusy,
    String? offerError,
    bool clearOfferError = false,
    int? recipeId,
    String? recipeName,
    String? baseMasterPath,
    RecipeAuthor? author,
    int? masterId,
    List<DarkroomStep>? steps,
    DarkroomCatalog? catalog,
    String? catalogError,
    DarkroomPreviewImage? preview,
    List<DarkroomStepReport>? reports,
    List<Object>? reportedSteps,
    List<DarkroomStepIssue>? issues,
    List<Object>? issuedSteps,
    List<Object>? omittedFromRender,
    String? recipeError,
    bool clearRecipeError = false,
    bool? rendering,
    bool? cancelRequested,
    String? renderError,
    bool clearRenderError = false,
    DarkroomRenderFailure? renderFailure,
    bool clearRenderFailure = false,
    String? cancelledPhase,
    bool clearCancelledPhase = false,
    String? reorderRefusal,
    int? reorderRefusalAttempt,
    bool clearReorderRefusal = false,
    bool? insertBusy,
    String? insertRefusal,
    int? insertRefusalAttempt,
    bool clearInsertRefusal = false,
    int? masterChannels,
    bool clearMasterChannels = false,
    DawnMasterStats? masterCalibration,
    String? photometryNote,
    int? photometryStarCount,
    bool? canUndo,
    bool? canRedo,
    bool? savePending,
    String? saveError,
    bool clearSaveError = false,
    List<RecipeDraftNote>? draftNotes,
    String? draftNotesError,
    bool clearDraftNotesError = false,
    List<DarkroomSiblingDraft>? siblings,
    String? siblingsError,
    bool clearSiblingsError = false,
    String? importNote,
    bool clearImportNote = false,
  }) {
    return DarkroomState(
      loading: loading ?? this.loading,
      loadError: clearLoadError ? null : (loadError ?? this.loadError),
      offer: clearOffer ? null : (offer ?? this.offer),
      offerBusy: offerBusy ?? this.offerBusy,
      offerError: clearOfferError ? null : (offerError ?? this.offerError),
      recipeId: recipeId ?? this.recipeId,
      recipeName: recipeName ?? this.recipeName,
      baseMasterPath: baseMasterPath ?? this.baseMasterPath,
      author: author ?? this.author,
      masterId: masterId ?? this.masterId,
      steps: steps ?? this.steps,
      catalog: catalog ?? this.catalog,
      catalogError: catalogError ?? this.catalogError,
      preview: preview ?? this.preview,
      reports: reports ?? this.reports,
      reportedSteps: reportedSteps ?? this.reportedSteps,
      issues: issues ?? this.issues,
      issuedSteps: issuedSteps ?? this.issuedSteps,
      omittedFromRender: omittedFromRender ?? this.omittedFromRender,
      recipeError: clearRecipeError ? null : (recipeError ?? this.recipeError),
      rendering: rendering ?? this.rendering,
      cancelRequested: cancelRequested ?? this.cancelRequested,
      renderError: clearRenderError ? null : (renderError ?? this.renderError),
      renderFailure:
          clearRenderFailure ? null : (renderFailure ?? this.renderFailure),
      cancelledPhase:
          clearCancelledPhase ? null : (cancelledPhase ?? this.cancelledPhase),
      reorderRefusal:
          clearReorderRefusal ? null : (reorderRefusal ?? this.reorderRefusal),
      // The stamp goes with the sentence it is about: cleared with it, so a
      // stale attempt number can never outlive the refusal it counted.
      reorderRefusalAttempt: clearReorderRefusal
          ? 0
          : (reorderRefusalAttempt ?? this.reorderRefusalAttempt),
      insertBusy: insertBusy ?? this.insertBusy,
      insertRefusal:
          clearInsertRefusal ? null : (insertRefusal ?? this.insertRefusal),
      insertRefusalAttempt: clearInsertRefusal
          ? 0
          : (insertRefusalAttempt ?? this.insertRefusalAttempt),
      masterChannels:
          clearMasterChannels ? null : (masterChannels ?? this.masterChannels),
      masterCalibration: masterCalibration ?? this.masterCalibration,
      photometryNote: photometryNote ?? this.photometryNote,
      photometryStarCount: photometryStarCount ?? this.photometryStarCount,
      canUndo: canUndo ?? this.canUndo,
      canRedo: canRedo ?? this.canRedo,
      savePending: savePending ?? this.savePending,
      saveError: clearSaveError ? null : (saveError ?? this.saveError),
      draftNotes: draftNotes ?? this.draftNotes,
      draftNotesError: clearDraftNotesError
          ? null
          : (draftNotesError ?? this.draftNotesError),
      siblings: siblings ?? this.siblings,
      siblingsError:
          clearSiblingsError ? null : (siblingsError ?? this.siblingsError),
      importNote: clearImportNote ? null : (importNote ?? this.importNote),
    );
  }
}
