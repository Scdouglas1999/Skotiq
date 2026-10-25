/// Drives the Darkroom editor: the recipe as data, the render loop over it, and
/// the account of what every step did.
///
/// **Where the work happens.** Every Darkroom native call goes through
/// [DarkroomSeam], never through the generated bridge — the UI package must not
/// import it, and a scripted seam is what makes the render loop testable without
/// the Rust library loaded.
///
/// **The render loop.** A render is one synchronous descent into the engine, so
/// it cannot be pre-empted and Dart cannot abort it; it can only be asked to
/// stop. Three mechanisms hold the loop honest:
///
///  * a **debounce** ([kDarkroomRenderDebounce]) so a parameter drag renders
///    once at its end rather than once per frame;
///  * a **single-flight latch** so two renders never enter the engine at once;
///  * a **generation counter** that rides inside the render id, so a superseded
///    render is cancelled by that id and its pixels — which describe a recipe
///    the operator has already changed — are dropped rather than painted.
///
/// The generation moves at the EDIT, ahead of the debounce, because the reply
/// that has to be dropped is the one from a render that is already inside the
/// engine when the edit happens.
///
/// Because the generation is part of the render id, a cancellation flag left
/// armed by a render that finished before it was polled cannot reach into the
/// next render: that one asks under a different id.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart' show XTypeGroup, openFile;
import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:path/path.dart' as p;

import 'darkroom_previews.dart';

part 'darkroom_controller_parts/_models.dart';
part 'darkroom_controller_parts/_state.dart';
part 'darkroom_controller_parts/_helpers.dart';

/// The most step lists the undo journal keeps.
///
/// A recipe is data and a step list is small, so the cap is about bounding a
/// long session's memory, not about the operator running out of undo in
/// practice.
const int kDarkroomJournalDepth = 100;

/// What to do about a `.skrecipe` this build will not read.
///
/// Every import refusal ends on it, because both ways forward are outside this
/// screen: a sidecar is written by an export, so a damaged or partial one is
/// replaced by exporting the recipe again, and any other file is the operator's
/// to choose. A refusal that named the fault and stopped there left them with a
/// closed chooser and nothing to try.
const String kDarkroomImportNextStep =
    'Export the recipe again from the Darkroom that wrote it, or choose a '
    'different .skrecipe file.';

/// Drives one Darkroom scope.
class DarkroomController extends StateNotifier<DarkroomState> {
  /// Collaborators are resolved once, here, rather than read from [ref] on each
  /// use: [dispose] issues the last write and the stop request for a render
  /// that is still inside the engine, and by then the container that owns
  /// [ref] may already be tearing down.
  DarkroomController(Ref ref, this._scope)
      : _darkroom = ref.read(darkroomSeamProvider),
        _recipes = ref.read(recipesDaoProvider),
        _masters = ref.read(integratedMastersDaoProvider),
        _images = ref.read(imagesDaoProvider),
        _nightMasters = ref.read(dawnMasterResolverProvider),
        _photometry = ref.read(dawnPhotometryResolverProvider),
        _sidecars = ref.read(darkroomSidecarReaderProvider),
        super(const DarkroomState()) {
    unawaited(_load());
  }

  final DarkroomScope _scope;
  final DarkroomSeam _darkroom;
  final RecipesDao _recipes;
  final IntegratedMastersDao _masters;
  final ImagesDao _images;
  final DawnMasterResolver _nightMasters;
  final DawnPhotometryResolver _photometry;
  final DarkroomSidecarReader _sidecars;

  Timer? _renderDebounce;
  Timer? _saveDebounce;

  /// Bumped the moment the stack stops being the one a running render
  /// describes. A render whose generation is no longer the newest is
  /// superseded: its pixels describe a recipe the operator has already edited.
  ///
  /// Bumped at the EDIT, not when the next render starts. Bumping it at the
  /// start meant that for the whole render debounce the in-flight render was
  /// still the newest generation, so a render that landed inside that window
  /// passed the check and painted pixels the operator had already edited away.
  int _renderGeneration = 0;

  /// True when a refresh was asked for while a render was inside the engine, so
  /// the newest stack renders as soon as that one lets go.
  ///
  /// A flag rather than a generation comparison: the generation now moves on
  /// every edit, and restarting on that would render once per drag frame
  /// instead of once per debounce.
  bool _renderQueued = false;

  /// Bumped once per requested validation, for the same reason.
  int _validateGeneration = 0;

  /// True while a render is inside the engine.
  bool _renderInFlight = false;

  /// The id the in-flight render is cancellable under, null when none is
  /// running.
  String? _inFlightRenderId;

  /// How many moves this editor has refused, and how many inserts. They stamp
  /// the refusal on the state so a repeat of the same refusal is a second
  /// occurrence rather than the same string arriving twice — see
  /// [_refuseReorder].
  int _reorderRefusals = 0;
  int _insertRefusals = 0;

  /// The step lists an undo restores, oldest first.
  final List<List<DarkroomStep>> _undoJournal = [];

  /// The step lists a redo re-applies, oldest first.
  final List<List<DarkroomStep>> _redoJournal = [];

  /// The catalogue stars `color_calibrate` regresses against. Empty when the
  /// field could not be placed on the sky, which the operation then reports as
  /// its own stated skip reason.
  List<Map<String, dynamic>> _catalogStars = const [];

  /// The identities of the steps the last `validate` classified as ones this
  /// build cannot run: an operation version it does not register, or parameters
  /// the operation refuses.
  ///
  /// Held by identity rather than by index so that inserting, removing or
  /// moving a step cannot re-point this set at a different step; a step whose
  /// identity is no longer in the stack simply never matches.
  final Set<Object> _unrenderable = <Object>{};

  /// True when an edit has not yet reached the recipe row.
  bool _savePending = false;

  /// Which control the last edit came from, and when.
  ///
  /// A slider emits a value per frame, so a drag is one intent and sixty edits.
  /// Journalling each of them would make undo walk back through the drag one
  /// frame at a time; folding consecutive edits from the same control inside
  /// [kDarkroomEditCoalesceWindow] makes one undo step out of one gesture.
  String? _lastEditKey;
  DateTime? _lastEditAt;

  /// The catalogue stars every render of this recipe lends `color_calibrate`.
  ///
  /// Read by the export, which replays the same stack at full resolution: an
  /// export that dropped the photometry would record the color step as skipped
  /// for want of a catalogue the editor plainly had, and write a file whose
  /// HISTORY says so.
  List<Map<String, dynamic>> get catalogStars =>
      List.unmodifiable(_catalogStars);

  // ---------------------------------------------------------------------
  // Loading
  // ---------------------------------------------------------------------

  /// Reload everything this scope names.
  Future<void> refresh() => _load();

  Future<void> _load() async {
    state = state.copyWith(
      loading: true,
      clearLoadError: true,
      clearOffer: true,
      clearOfferError: true,
    );
    unawaited(_loadCatalog());

    if (_scope.isEmpty) {
      _fail(
        'This link named neither a recipe nor a master, so there is nothing to '
        'open. Reach the Darkroom from a master in the session review, or from '
        'the morning notification for a finished draft.',
      );
      return;
    }

    try {
      final recipeId = _scope.recipeId;
      if (recipeId != null) {
        final recipe = await _recipes.getById(recipeId);
        if (!mounted) return;
        if (recipe == null) {
          // Nothing about the master: `recipes.master_id` is ON DELETE SET
          // NULL, so deleting a master cannot take a recipe row with it, and
          // this sentence used to blame a master that was still on disk and
          // still openable — beside a delete dialog that had just said the
          // linear master survives.
          _fail(
            'Recipe $recipeId no longer has a row. Deleting a branch removes '
            'the recipe and nothing else, so whichever linear master it was '
            'written over is still in the library.',
          );
          return;
        }
        await _openRecipe(recipe);
        return;
      }

      final masterId = _scope.masterId!;
      final master = await _masters.getById(masterId);
      if (!mounted) return;
      if (master == null) {
        _fail(
          'Master $masterId does not exist. It may have been deleted from the '
          'library.',
        );
        return;
      }
      final path = master.masterFitsPath;
      if (path == null || path.trim().isEmpty) {
        _fail(
          '"${master.name}" is still accumulating and has not written a linear '
          'master yet, so there are no pixels to interpret. Finalize it in the '
          'session review first.',
        );
        return;
      }
      final existing = await _recipes.listForMaster(path);
      if (!mounted) return;
      if (existing.isNotEmpty) {
        // listForMaster orders newest first, so this is the most recent recipe
        // written over these pixels.
        await _openRecipe(existing.first);
        return;
      }
      state = _noRecipe(
        offer: DarkroomStartOffer(
          masterId: masterId,
          targetId: master.targetId,
          masterName: master.name,
          masterFitsPath: path,
          channels: master.channels,
          width: master.width,
          height: master.height,
        ),
      );
      unawaited(_loadSiblings(masterId));
    } catch (error) {
      if (!mounted) return;
      _fail('The Darkroom could not read this master or its recipes: $error');
    }
  }

  void _fail(String message) {
    state = _noRecipe(loadError: message);
  }

  /// The state with NO recipe open, carrying forward only what does not
  /// describe one.
  ///
  /// Both states that reach this are states in which nothing is open: a load
  /// that failed, and a master whose recipes have all been deleted. [copyWith]
  /// cannot null a field out, so building the state whole is the only way to
  /// drop the previous recipe — and carrying it forward is what printed a
  /// deleted recipe's name in the header above the subtitle "No recipe yet",
  /// left [DarkroomState.hasRecipe] true over a screen with no recipe on it,
  /// and kept the deleted stack's steps in [DarkroomState.steps].
  ///
  /// The operation catalogue survives because it describes this build's
  /// registry rather than any one recipe.
  DarkroomState _noRecipe({String? loadError, DarkroomStartOffer? offer}) {
    _undoJournal.clear();
    _redoJournal.clear();
    _unrenderable.clear();
    _catalogStars = const [];
    _lastEditKey = null;
    _lastEditAt = null;
    return DarkroomState(
      loading: false,
      loadError: loadError,
      offer: offer,
      catalog: state.catalog,
      catalogError: state.catalogError,
    );
  }

  Future<void> _loadCatalog() async {
    try {
      final reply = await _darkroom.registry(const <String, dynamic>{});
      if (!mounted) return;
      state = state.copyWith(catalog: decodeDarkroomCatalog(reply));
    } on DarkroomSeamException catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        catalogError:
            'The operation catalogue could not be read, so the parameter '
            'ranges behind these controls are unknown: ${error.message}',
      );
    } on DarkroomRecipeFormatException catch (error) {
      if (!mounted) return;
      state = state.copyWith(catalogError: error.message);
    }
  }

  Future<void> _openRecipe(DarkroomRecipe recipe) async {
    final List<DarkroomStep> steps;
    try {
      steps = decodeDarkroomSteps(recipe.stepsJson);
    } on DarkroomRecipeFormatException catch (error) {
      _fail('${error.message}. The recipe row was not changed.');
      return;
    }

    _undoJournal.clear();
    _redoJournal.clear();
    _unrenderable.clear();
    state = state.copyWith(
      loading: false,
      clearLoadError: true,
      clearOffer: true,
      recipeId: recipe.id,
      recipeName: recipe.name.isEmpty ? 'Recipe ${recipe.id}' : recipe.name,
      baseMasterPath: recipe.baseMasterPath,
      author: recipe.createdBy,
      masterId: recipe.masterId,
      steps: List.unmodifiable(steps),
      // The steps that arrive here are freshly decoded, so nothing the previous
      // render or the previous validation said describes any of them. Carrying
      // those accounts forward would badge a stack this build has not looked at
      // with the outcomes of one it has.
      reports: const [],
      reportedSteps: const [],
      issues: const [],
      issuedSteps: const [],
      omittedFromRender: const [],
      clearRecipeError: true,
      canUndo: false,
      canRedo: false,
      savePending: false,
      clearSaveError: true,
      // The notes and the import receipt describe how the recipe being
      // REPLACED came to be. Carrying either across would attribute one
      // recipe's provenance to another; [_loadDraftNotes] reads THIS recipe's
      // account off its own row.
      draftNotes: const [],
      clearDraftNotesError: true,
      clearImportNote: true,
      // A fact about the master the PREVIOUS recipe rendered. It is re-read for
      // this one by [_resolvePhotometry] below; carrying the old count across
      // would let the chooser state a precondition about the wrong pixels.
      clearMasterChannels: true,
    );

    _lastEditKey = null;
    _lastEditAt = null;
    // A render still inside the engine is rendering the recipe this one
    // replaces, so its pixels must not land in the new recipe's viewport.
    _supersedeRunningRender();
    unawaited(_loadDraftNotes(recipe));
    unawaited(_loadSiblings(recipe.masterId));
    await _resolvePhotometry(recipe.masterId);
    if (!mounted) return;
    unawaited(_refreshNow());
  }

  /// Read the account of the pass that composed [recipe], from the row itself.
  ///
  /// Off the open path rather than inside it: the notes are provenance, and a
  /// recipe whose reasons are one frame late still opens. A read that fails
  /// leaves the notes empty and says so on the panel rather than presenting a
  /// draft as a stack nobody drafted.
  Future<void> _loadDraftNotes(DarkroomRecipe recipe) async {
    final id = recipe.id;
    if (id == null) return;
    try {
      final notes = await _recipes.draftNotesOf(id);
      if (!mounted || state.recipeId != id) return;
      state = state.copyWith(draftNotes: notes);
    } catch (error) {
      if (!mounted || state.recipeId != id) return;
      state = state.copyWith(
        draftNotes: const [],
        draftNotesError:
            'The account of how this recipe was drafted could not be read, so '
            'any operation the draft left out is unexplained here: $error',
      );
    }
  }

  /// List the other masters the same night produced, with the newest recipe
  /// over each.
  ///
  /// Every in-app entry point resolves ONE master for a session and opens it,
  /// so a four-filter night silently hands the editor one of four drafts. The
  /// walk is the resolver the dawn autopilot itself uses, reached from this
  /// master's own fold records, so the set it lists is the set the night's
  /// report counted.
  Future<void> _loadSiblings(int? masterId) async {
    if (masterId == null) {
      state = state.copyWith(siblings: const [], clearSiblingsError: true);
      return;
    }
    try {
      final imageIds = await _masters.getFoldedImageIds(masterId);
      if (!mounted) return;
      int? sessionId;
      for (final imageId in imageIds) {
        final image = await _images.getImageById(imageId);
        if (!mounted) return;
        final id = image?.sessionId;
        if (id != null) {
          sessionId = id;
          break;
        }
      }
      if (sessionId == null) {
        // Said, not swallowed: a master with no fold record back to a session
        // is a master this walk cannot place in a night, and the bar prints
        // that rather than an empty list that reads as "there are no others".
        state = state.copyWith(
          siblings: const [],
          siblingsError:
              'No frame of this master records the session it was captured in, '
              'so the other masters of the same night cannot be found from '
              'here. Open them from the session review.',
        );
        return;
      }
      final set = await _nightMasters.resolve(sessionId);
      if (!mounted) return;
      final siblings = <DarkroomSiblingDraft>[];
      for (final master in set.masters) {
        if (master.masterId == masterId) continue;
        final overThem = await _recipes.listForMaster(master.masterFitsPath);
        if (!mounted) return;
        // listForMaster orders newest first, so this is the recipe a link to
        // the master would open.
        final newest = overThem.isEmpty ? null : overThem.first;
        final newestId = newest?.id;
        final composed = newestId == null
            ? false
            : (await _recipes.draftNotesOf(newestId)).isNotEmpty;
        if (!mounted) return;
        siblings.add(
          DarkroomSiblingDraft(
            composedByRegistry: composed,
            masterId: master.masterId,
            masterName: master.name,
            filter: master.filter,
            recipeId: newest?.id,
            recipeName: newest?.name,
            author: newest?.createdBy,
          ),
        );
      }
      state = state.copyWith(
        siblings: List.unmodifiable(siblings),
        clearSiblingsError: true,
      );
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        siblings: const [],
        siblingsError:
            'The other masters of this night could not be read: $error',
      );
    }
  }

  /// Resolve the catalogue stars `color_calibrate` needs, or state why there
  /// are none.
  ///
  /// The color fit regresses against stars the CALLER supplies; with none
  /// attached the operation records itself as skipped with that reason. Naming
  /// the app-side half of the same fact is what turns the step card's skip
  /// badge into an explanation instead of a failure.
  Future<void> _resolvePhotometry(int? masterId) async {
    if (masterId == null) {
      _catalogStars = const [];
      state = state.copyWith(
        photometryStarCount: 0,
        photometryNote:
            'This recipe carries no library row for its master, so the field '
            'cannot be placed on the sky and the color calibration has no '
            'catalogue stars to regress against.',
      );
      return;
    }
    try {
      final master = await _masters.getById(masterId);
      if (!mounted) return;
      if (master == null) {
        _catalogStars = const [];
        state = state.copyWith(
          photometryStarCount: 0,
          photometryNote:
              'The library row for this master is gone, so its solved '
              'astrometry cannot be read and the color calibration has no '
              'catalogue stars.',
        );
        return;
      }
      // The channel count and the calibration record both travel with the row
      // this walk already reads: they are the master facts the editor needs —
      // one before an operation is added, one before the operator believes what
      // a step reveals — and reading the row again for either would be a second
      // query for something already in hand.
      state = state.copyWith(
        masterChannels: master.channels,
        masterCalibration: DawnMasterStats.parse(master.statsJson),
      );
      final wcs = overlayFromMasterWcs(
        crval1: master.wcsCrval1,
        crval2: master.wcsCrval2,
        crpix1: master.wcsCrpix1,
        crpix2: master.wcsCrpix2,
        cd11: master.wcsCd1_1,
        cd12: master.wcsCd1_2,
        cd21: master.wcsCd2_1,
        cd22: master.wcsCd2_2,
      );
      final masterPath = master.masterFitsPath;
      final photometry = await _photometry.resolve(
        master: DawnMaster(
          masterId: master.id,
          targetId: master.targetId,
          name: master.name,
          filter: master.filter,
          masterFitsPath: masterPath == null || masterPath.isEmpty
              ? state.baseMasterPath
              : masterPath,
          channels: master.channels,
          width: master.width,
          height: master.height,
          frameCount: master.frameCount,
          totalIntegrationSeconds: master.totalIntegrationSeconds,
        ),
        wcs: wcs,
      );
      if (!mounted) return;
      _catalogStars = photometry.stars;
      state = state.copyWith(
        photometryStarCount: photometry.stars.length,
        photometryNote: photometry.unavailableReason,
      );
    } catch (error) {
      if (!mounted) return;
      _catalogStars = const [];
      state = state.copyWith(
        photometryStarCount: 0,
        photometryNote:
            'The star catalogue could not be read, so the color calibration '
            'has nothing to regress against: $error',
      );
    }
  }

  // ---------------------------------------------------------------------
  // Creating a recipe for a master that has none
  // ---------------------------------------------------------------------

  /// Create an empty user recipe over the offered master: the master's own
  /// linear pixels, with nothing interpreted yet.
  Future<void> startFromLinear() async {
    final offer = state.offer;
    if (offer == null || state.offerBusy) return;
    state = state.copyWith(offerBusy: true, clearOfferError: true);
    await _createRecipe(
      masterId: offer.masterId,
      targetId: offer.targetId,
      masterFitsPath: offer.masterFitsPath,
      steps: const [],
      name: 'Linear',
    );
  }

  /// Ask the operation registry for a first draft measured from the offered
  /// master, and open a user recipe carrying it.
  Future<void> draftForMe() async {
    final offer = state.offer;
    if (offer == null || state.offerBusy) return;
    state = state.copyWith(offerBusy: true, clearOfferError: true);

    final List<DarkroomStep> steps;
    final List<RecipeDraftNote> notes;
    try {
      final reply = await _darkroom.registry({
        'masterPath': offer.masterFitsPath,
        'baseMasterRef': offer.masterFitsPath,
      });
      if (!mounted) return;
      // A crop measured as the whole master trims nothing, so the draft states
      // that decision instead of carrying a step whose card would read
      // "Applied by the last render" over an operation that moved no pixel.
      final drafted = darkroomDropIdentityCrop(
        decodeDarkroomDraft(reply),
        width: offer.width,
        height: offer.height,
      );
      steps = drafted.steps;
      // The registry decides about more operations than it ends up carrying,
      // and records why it left each of the others out. Until this call the
      // notes reached the night report on disk and nothing else: the offer
      // promises "color where there is color to calibrate" and then a mono
      // master got a four-step stack that never said the colour step was
      // omitted, let alone why. The account is completed with the operations it
      // DID carry, so the row records that the registry composed this stack.
      final cropReason = drafted.omittedCropReason;
      notes = darkroomComposedAccount(steps, [
        ...decodeDarkroomDraftNotes(reply),
        if (cropReason != null)
          RecipeDraftNote(
            opId: 'crop',
            outcome: 'omitted',
            reason: cropReason,
          ),
      ]);
    } on DarkroomCancelledOutcome catch (cancelled) {
      if (!mounted) return;
      state = state.copyWith(
        offerBusy: false,
        offerError:
            'The draft was stopped during ${cancelled.phase}; no recipe was '
            'created.',
      );
      return;
    } on DarkroomSeamException catch (error) {
      if (!mounted) return;
      final nextStep = darkroomMasterFailureNextStep(
        error.message,
        offer.masterFitsPath,
      );
      state = state.copyWith(
        offerBusy: false,
        offerError:
            'The registry could not measure a draft from this master, so no '
            'recipe was created: ${error.message}'
            '${nextStep == null ? '' : '. $nextStep'}',
      );
      return;
    } on DarkroomRecipeFormatException catch (error) {
      if (!mounted) return;
      state = state.copyWith(offerBusy: false, offerError: error.message);
      return;
    }

    await _createRecipe(
      masterId: offer.masterId,
      targetId: offer.targetId,
      masterFitsPath: offer.masterFitsPath,
      steps: steps,
      name: _draftName(offer.masterName),
      draftNotes: notes,
    );
  }

  /// The name a drafted recipe carries: the master it was drafted over, the way
  /// the dawn autopilot names its own.
  ///
  /// A bare "Draft" named nothing. The branch chip, the compare picker, the
  /// export sheet and the viewport's image semantics all print the recipe name,
  /// so a screen reader heard "Rendered draft of Draft" and a library of them
  /// read as one repeated word. The branch bar drops the master prefix when the
  /// name already opens with it, which is why this reads "Master · L draft"
  /// rather than "Master · L · Master · L draft".
  static String _draftName(String masterName) {
    final name = masterName.trim();
    return name.isEmpty ? 'Draft' : '$name draft';
  }

  /// Write a new recipe row over one master's pixels and open it.
  ///
  /// The three identity fields are taken one by one rather than as a whole
  /// [DarkroomStartOffer]: the import path has a master and a path but no
  /// offer, and building a synthetic offer for it meant filling the fields this
  /// method never reads — the master's name, its channel count, its dimensions
  /// — with zeros and empty strings that describe no master at all.
  Future<void> _createRecipe({
    required int masterId,
    required int? targetId,
    required String masterFitsPath,
    required List<DarkroomStep> steps,
    required String name,
    List<RecipeDraftNote> draftNotes = const [],
    String? importNote,
  }) async {
    try {
      final id = await _recipes.create(
        targetId: targetId,
        masterId: masterId,
        baseMasterPath: masterFitsPath,
        name: name,
        stepsJson: jsonEncode([for (final step in steps) step.toJson()]),
        // The operator asked for this recipe, so the row records them as the
        // one who created it. What COMPOSED its steps is a separate fact, and
        // the draft account beside it is what carries that one.
        createdBy: RecipeAuthor.user,
        draftNotes: draftNotes,
        schemaVersion: kDarkroomRecipeSchemaVersion,
      );
      if (!mounted) return;
      final created = await _recipes.getById(id);
      if (!mounted) return;
      if (created == null) {
        state = state.copyWith(
          offerBusy: false,
          offerError:
              'The recipe row was written as id $id but could not be read '
              'back, so the editor has nothing to open.',
        );
        return;
      }
      state = state.copyWith(offerBusy: false);
      // The draft account is NOT re-attached in memory here: it went to the row
      // above, and [_openRecipe] reads it back from there. One source means the
      // editor shows the same reasons on the first open, on the next Reload,
      // and on a launch tomorrow — which is the whole point of storing it.
      //
      // The import receipt is about the file this call read, which no row
      // records, so it is attached AFTER the open: [_openRecipe] rebuilds the
      // provenance fields empty so a previous recipe's receipt cannot follow
      // the editor onto this one.
      await _openRecipe(created);
      if (!mounted) return;
      state = state.copyWith(importNote: importNote);
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        offerBusy: false,
        offerError: 'The recipe could not be created: $error',
      );
    }
  }

  // ---------------------------------------------------------------------
  // Importing a recipe written outside the database
  // ---------------------------------------------------------------------

  /// Clear the standing import refusal.
  ///
  /// The refusal is durable rather than a toast — it names a file the operator
  /// chose and what was wrong with it, which they may want to read twice — so
  /// something has to be able to put it away. This is that something.
  void dismissOfferError() {
    if (state.offerError == null) return;
    state = state.copyWith(clearOfferError: true);
  }

  /// Read a `.skrecipe` sidecar and open it as a new recipe over the master
  /// this editor is on.
  ///
  /// The sidecar is what every export writes beside its file, and until this
  /// existed it was write-only: the export sheet promised the recipe "survives
  /// outside the database" and nothing in the product could read one back.
  ///
  /// The import is deliberately NOT a merge and NOT a replace of the open
  /// stack: it writes a new recipe row over THESE pixels, so the recipe the
  /// operator was working on is untouched and the imported one arrives as a
  /// branch they can compare against.
  ///
  /// The steps are taken exactly as the file stores them, including operations
  /// this build does not register. They are handed to `validate` and the
  /// verdict is stated, but nothing is dropped or rewritten: the step cards
  /// already name the operation version this build does not register, and
  /// silently discarding such a step would import a recipe the file does not
  /// contain.
  Future<void> importRecipe() async {
    if (state.offerBusy) return;
    final offer = state.offer;
    final masterId = offer?.masterId ?? state.masterId;
    final masterPath = offer?.masterFitsPath ?? state.baseMasterPath;
    if (masterId == null || masterPath.isEmpty) {
      state = state.copyWith(
        offerError:
            'This editor is not on a library master, so an imported recipe '
            'would have no pixels to be written over. Open a master from the '
            'session review and import there.',
      );
      return;
    }

    state = state.copyWith(offerBusy: true, clearOfferError: true);
    final DarkroomSidecarPick? pick;
    try {
      pick = await _sidecars();
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        offerBusy: false,
        offerError: 'That file could not be read, so nothing was imported. '
            '$kDarkroomImportNextStep The reader answered: $error',
      );
      return;
    }
    if (!mounted) return;
    if (pick == null) {
      // The chooser was dismissed. Nothing was read and nothing was written.
      state = state.copyWith(offerBusy: false);
      return;
    }

    final DarkroomImportedRecipe imported;
    try {
      imported = decodeDarkroomSidecar(pick.text);
    } on DarkroomRecipeFormatException catch (error) {
      final detail = error.detail;
      state = state.copyWith(
        offerBusy: false,
        // The fault in the file's own terms, then what to do about it, and only
        // then the reader's words — attributed. This refusal used to END on the
        // Dart JSON parser's fragment ("…: Unexpected character."), which is
        // about no file the operator chose and offers nothing to try.
        offerError: '${p.basename(pick.path)} was not imported: '
            '${error.message}. $kDarkroomImportNextStep'
            '${detail == null ? '' : ' $detail'}',
      );
      return;
    }
    if (imported.steps.isEmpty) {
      state = state.copyWith(
        offerBusy: false,
        offerError: '${p.basename(pick.path)} carries a recipe with no steps, '
            'so importing it would create a recipe that interprets nothing. '
            'Start from linear instead, which is the same thing said out loud.',
      );
      return;
    }

    final verdict = await _validateImported(imported.steps, masterPath);
    if (!mounted) return;

    final targetId = offer?.targetId ?? await _targetIdFor(masterId);
    if (!mounted) return;

    await _createRecipe(
      masterId: masterId,
      targetId: targetId,
      masterFitsPath: masterPath,
      steps: imported.steps,
      name: _importedRecipeName(pick.path),
      importNote: _describeImport(pick, imported, verdict, masterPath),
    );
  }

  /// Ask the engine about an imported step list before it becomes a row.
  ///
  /// Answers null when the engine could not be asked, which the receipt then
  /// states rather than claiming the import was checked.
  Future<DarkroomValidation?> _validateImported(
    List<DarkroomStep> steps,
    String masterPath,
  ) async {
    try {
      final reply = await _darkroom.validate(
        // No row exists yet, so the envelope carries the id the engine uses
        // only to name the recipe back in its own messages.
        recipeJson: jsonEncode({
          'id': 'darkroom-import',
          'schemaVersion': kDarkroomRecipeSchemaVersion,
          'baseMasterRef': masterPath,
          'createdBy': RecipeAuthor.user.wire,
          'steps': [for (final step in steps) step.toJson()],
        }),
        context: const <String, dynamic>{},
      );
      return decodeDarkroomValidation(reply);
    } on DarkroomSeamException {
      return null;
    }
  }

  Future<int?> _targetIdFor(int masterId) async {
    try {
      final master = await _masters.getById(masterId);
      return master?.targetId;
    } catch (error, stack) {
      // The target is bookkeeping on the new row, so a read that fails leaves
      // it unset rather than stopping an import the operator asked for — and
      // says so in the log, because a library read that did not work is a fact
      // about the database and not about this import.
      developer.log(
        'Darkroom: the target of master $masterId could not be read while '
        'importing a recipe, so the new row carries none: $error',
        name: 'Darkroom',
        level: 900,
        stackTrace: stack,
      );
      return null;
    }
  }

  /// The branch name an imported recipe arrives under: the file's own name,
  /// stripped of the sidecar extension, so the bar names what was read.
  static String _importedRecipeName(String path) {
    var name = p.basename(path);
    for (final suffix in const [
      '.skrecipe',
      '.nsrecipe',
      '.fits',
      '.fit',
      '.jpg',
      '.jpeg',
      '.png',
      '.tif',
      '.tiff'
    ]) {
      if (name.toLowerCase().endsWith(suffix)) {
        name = name.substring(0, name.length - suffix.length);
      }
    }
    name = name.trim();
    return name.isEmpty ? 'Imported recipe' : 'Imported: $name';
  }

  /// What the import read, in the file's own numbers and the engine's verdict.
  static String _describeImport(
    DarkroomSidecarPick pick,
    DarkroomImportedRecipe imported,
    DarkroomValidation? verdict,
    String masterPath,
  ) {
    final steps = imported.steps.length;
    final lines = <String>[
      'Imported $steps step${steps == 1 ? '' : 's'} from '
          '${p.basename(pick.path)}.',
    ];
    final from = imported.masterPath;
    if (from != null && from != masterPath) {
      lines.add(
        'That sidecar was written over $from. This recipe replays its steps '
        'over the master this editor is on, so any step whose parameters were '
        'measured from those other pixels is now over these.',
      );
    }
    final fingerprint = imported.fingerprint;
    if (fingerprint != null) {
      lines.add('Recipe fingerprint recorded in the sidecar: $fingerprint.');
    }
    if (verdict == null) {
      lines.add(
        'The engine could not be asked whether these steps validate, so the '
        'per-step verdicts below are the only account of them.',
      );
    } else if (verdict.ok) {
      lines.add('Every step validates against this build.');
    } else {
      final refused = verdict.steps.where((issue) => !issue.isClean).length;
      lines.add(
        'This build refuses $refused of them; each card says which and why. '
        'Nothing was dropped on the way in — the recipe is stored exactly as '
        'the file holds it.',
      );
    }
    return lines.join('\n');
  }

  // ---------------------------------------------------------------------
  // Editing
  // ---------------------------------------------------------------------

  /// Toggle whether the step at [index] renders. Nothing is destroyed: the step
  /// and its parameters survive the disable.
  void toggleStep(int index) {
    final steps = state.steps;
    if (index < 0 || index >= steps.length) return;
    final next = List<DarkroomStep>.from(steps);
    next[index] = next[index].copyWith(enabled: !next[index].enabled);
    _applyEdit(next);
  }

  /// Set one parameter of the step at [index].
  ///
  /// A null [value] removes the key, which restores the operation's own
  /// documented default rather than freezing today's value into the recipe.
  ///
  /// Consecutive changes to one parameter fold into a single undo step; see
  /// [kDarkroomEditCoalesceWindow].
  void setParam(int index, String name, Object? value) {
    final steps = state.steps;
    if (index < 0 || index >= steps.length) return;
    final next = List<DarkroomStep>.from(steps);
    next[index] = next[index].withParam(name, value);
    _applyEdit(next, coalesceKey: 'param:$index:$name');
  }

  /// Take the step at [index] out of the recipe.
  ///
  /// The one edit that is not reversible by a second press of the same control,
  /// and the only way out of a stack carrying an operation this build cannot
  /// run at all: switching such a step off keeps it out of the render, but the
  /// recipe still names an operation nothing here can replay, and an export or
  /// another build reads that name. The removal goes through the same journal
  /// as every other edit, so one undo puts the step back with its parameters.
  void removeStep(int index) {
    final steps = state.steps;
    if (index < 0 || index >= steps.length) return;
    final next = List<DarkroomStep>.from(steps)..removeAt(index);
    _applyEdit(next);
  }

  /// Put a step for [op] into the recipe, where the engine's stage rule leaves
  /// room for it.
  ///
  /// This is the hand-editing half of the Darkroom: a recipe started from the
  /// linear master carries no steps at all, and every other edit here changes
  /// steps that are already in it.
  ///
  /// Three things decide the outcome and none of them is decided here:
  ///
  ///  * WHERE it goes — [DarkroomState.insertIndexFor], which mirrors the
  ///    engine's stage rule so the proposed order is one the engine can accept;
  ///  * WHAT it starts with — [_openingParamsFor], which takes the operation's
  ///    own documented defaults, or the registry's measurement of this master
  ///    for a required parameter that has no default;
  ///  * WHETHER it is legal — `validate`, asked about the whole candidate stack
  ///    before anything commits, exactly as [reorderStep] asks it. A refusal
  ///    keeps the stack on screen unchanged and states the engine's sentence.
  ///
  /// The commit goes through the same journal as every other edit, so one undo
  /// restores the step list as it was, and the render that follows replays the
  /// stack WITH the new step.
  ///
  /// Answers false when nothing was added; [DarkroomState.insertRefusal] then
  /// carries the reason.
  Future<bool> insertStep(DarkroomOpSpec op) async {
    if (state.recipeId == null || state.insertBusy) return false;
    final at = state.insertIndexFor(op);
    if (at == null) {
      _refuseInsert(
        'The operation registry states ${op.id}@${op.version}\'s stage as '
        '"${op.stageWire}", which this build does not model, so this editor '
        'cannot say where in the stack it belongs. Nothing was added.',
      );
      return false;
    }
    state = state.copyWith(insertBusy: true, clearInsertRefusal: true);

    final opening = await _openingParamsFor(op);
    if (!mounted) return false;
    final openingRefusal = opening.refusal;
    if (openingRefusal != null) {
      _refuseInsert(openingRefusal);
      return false;
    }

    final candidate = List<DarkroomStep>.from(state.steps)
      ..insert(
        at,
        DarkroomStep(
          opId: op.id,
          opVersion: op.version,
          params: opening.params!,
          enabled: true,
        ),
      );

    final DarkroomValidation? verdict;
    try {
      verdict = await _validateSteps(candidate);
    } catch (error) {
      // The check names its own failure rather than letting it escape: this
      // future is awaited by a chooser callback, and a throw here would leave
      // the chooser closed, the stack unchanged and nothing on screen saying
      // why — the same reason the reorder path catches.
      if (!mounted) return false;
      _refuseInsert(
        'That step could not be checked with the engine, so it was not added: '
        '$error',
      );
      return false;
    }
    if (!mounted) return false;
    if (verdict == null) {
      _refuseInsert(
        'The engine could not be asked whether that step is legal here, so it '
        'was not added.',
      );
      return false;
    }
    if (!verdict.ok) {
      // The per-step entries index the REJECTED stack, so adopting them would
      // attach each message to the wrong card — the same reason the reorder
      // path shows the whole-recipe sentence alone.
      final error = verdict.error;
      _refuseInsert(
        error == null
            ? 'The engine refused that step without naming a reason. Nothing '
                'was added, so the stack on screen is unchanged.'
            : _refusalOverCandidate(
                error,
                candidate,
                counted: 'the stack the added step would have produced',
                undone: 'the step was not added',
                nextStep: 'Answer what the sentence names — a step whose '
                    'parameters the engine refuses, or one this build does not '
                    'register — and add the step again.',
              ),
      );
      return false;
    }
    state = state.copyWith(insertBusy: false);
    _applyEdit(candidate, verdict: verdict, verdictOf: candidate);
    return true;
  }

  /// The parameters a freshly added [op] opens with, or the reason it cannot be
  /// added at all.
  ///
  /// An operation whose required parameters all have a documented default opens
  /// with NO parameters written: an absent key is the operation's own default
  /// for the life of its version, and freezing today's value into the recipe is
  /// what stops an improved default from ever reaching it. That is what the
  /// registry's own draft stores for `background_extract` and `denoise`.
  ///
  /// An operation with a required parameter the registry publishes no default
  /// for — the crop rectangle, the stretch's black and white points — has no
  /// opening value this editor may supply: the engine refuses the step without
  /// one, and a number chosen here would be a measurement nothing measured.
  /// Those come from the registry's measurement of THIS master, the same call
  /// "Draft for me" makes. When that measurement leaves the operation out, the
  /// registry's own note for it is the refusal.
  Future<({Map<String, dynamic>? params, String? refusal})> _openingParamsFor(
    DarkroomOpSpec op,
  ) async {
    final unmeasured = [
      for (final param in op.params)
        if (param.required && param.defaultValue == null) param,
    ];
    if (unmeasured.isEmpty) {
      return (params: const <String, dynamic>{}, refusal: null);
    }

    final title = darkroomOpTitle(op.id);
    final names = _namesOf(unmeasured);
    final has = unmeasured.length == 1 ? 'has' : 'have';
    final masterPath = state.baseMasterPath;

    final Map<String, dynamic> reply;
    try {
      reply = await _darkroom.registry({
        'masterPath': masterPath,
        'baseMasterRef': masterPath,
      });
    } on DarkroomCancelledOutcome catch (cancelled) {
      return (
        params: null,
        refusal: 'Measuring $names from this master was stopped during '
            '${cancelled.phase}, so no $title step was added.',
      );
    } on DarkroomSeamException catch (error) {
      final nextStep = darkroomMasterFailureNextStep(error.message, masterPath);
      return (
        params: null,
        refusal: 'The operation registry could not measure $names from this '
            'master, so no $title step was added: ${error.message}'
            '${nextStep == null ? '' : '. $nextStep'}',
      );
    }

    final List<DarkroomStep> measured;
    try {
      measured = decodeDarkroomDraft(reply);
    } on DarkroomRecipeFormatException catch (error) {
      return (
        params: null,
        refusal: 'The operation registry answered without a measured draft of '
            'this master, so $names could not be read and no $title step was '
            'added: ${error.message}',
      );
    }
    for (final step in measured) {
      if (step.opId == op.id && step.opVersion == op.version) {
        return (params: step.params, refusal: null);
      }
    }

    // The registry decides about more operations than its draft carries and
    // records why it left each of the others out. That note is the honest
    // refusal: the alternative is an invented rectangle or an invented black
    // point, which is a measurement of nothing.
    for (final note in decodeDarkroomDraftNotes(reply)) {
      if (note.opId != op.id) continue;
      return (
        params: null,
        refusal: 'The operation registry left $title out of its measurement of '
            'this master, and $names $has no documented default to fall back '
            'on, so nothing was added: ${note.reason}',
      );
    }
    return (
      params: null,
      refusal: 'The operation registry\'s measurement of this master carries '
          'no $title step and states no reason for leaving it out. $names '
          '$has no documented default either, so nothing was added rather '
          'than a step opening on a value nothing measured.',
    );
  }

  /// The parameters a refusal names: "a", "a and b", "a, b and c".
  static String _namesOf(List<DarkroomParamSpec> params) {
    final names = [for (final param in params) param.displayName];
    if (names.length == 1) return names.single;
    return '${names.take(names.length - 1).join(', ')} and ${names.last}';
  }

  /// Turn every step off. Nothing is destroyed — the stack is intact and one
  /// undo (or one toggle each) brings it back.
  void resetToLinear() {
    final steps = state.steps;
    if (steps.isEmpty || steps.every((step) => !step.enabled)) return;
    _applyEdit([for (final step in steps) step.copyWith(enabled: false)]);
  }

  /// Move the step at [oldIndex] to [newIndex], but only when the engine
  /// accepts the resulting order.
  ///
  /// The order carries a rule — a linear-stage operation cannot run after a
  /// stretched one — that the engine owns. Asking it BEFORE the move commits is
  /// what keeps the panel from showing an order that renders nothing; the
  /// refusal carries the engine's own sentence.
  ///
  /// [newIndex] is the destination in the list AFTER the step is lifted out of
  /// it — the index `ReorderableListView.onReorderItem` reports.
  Future<bool> reorderStep(int oldIndex, int newIndex) async {
    final steps = state.steps;
    if (oldIndex < 0 || oldIndex >= steps.length) return false;
    var target = newIndex;
    if (target < 0) target = 0;
    if (target >= steps.length) target = steps.length - 1;
    if (target == oldIndex) {
      state = state.copyWith(clearReorderRefusal: true);
      return true;
    }

    final candidate = List<DarkroomStep>.from(steps);
    candidate.insert(target, candidate.removeAt(oldIndex));

    final DarkroomValidation? verdict;
    try {
      verdict = await _validateSteps(candidate);
    } catch (error) {
      // The caller is a drag gesture, which cannot await this future: anything
      // thrown here would be an unobserved async error, and the list would snap
      // back with no reason stated anywhere on the screen. The move is refused
      // and the failure is named instead.
      if (!mounted) return false;
      _refuseReorder(
        'That order could not be checked with the engine, so the move was not '
        'made: $error',
      );
      return false;
    }
    if (!mounted) return false;
    if (verdict == null) {
      _refuseReorder(
        'The engine could not be asked whether that order is legal, so the '
        'move was not made.',
      );
      return false;
    }
    if (!verdict.ok) {
      // The verdict's per-step entries index the REJECTED order, so adopting
      // them here would attach each message to the wrong card. Only the
      // whole-recipe sentence is shown, counted in the order the move would
      // have produced — see [_refusalOverCandidate].
      final error = verdict.error;
      _refuseReorder(
        error == null
            ? 'The engine refused that order without naming a reason. The move '
                'was not made, so the stack on screen is unchanged. Try a '
                'different destination for that step, or switch it off if it '
                'should not run at all.'
            : _refusalOverCandidate(error, candidate),
      );
      return false;
    }
    _applyEdit(candidate, verdict: verdict, verdictOf: candidate);
    return true;
  }

  /// Publish a refused move, stamped with the attempt that raised it.
  ///
  /// Every refusal goes through here rather than writing the field directly,
  /// because the stamp is the whole point: the screen announces one refusal
  /// once, and it told two occurrences apart by the sentence alone — so a
  /// second press of the same enabled control, refused for the same reason,
  /// produced a byte-identical string and said nothing at all. The inline
  /// alert stayed up, so the reason remained readable, but the operator got no
  /// acknowledgement that their second attempt had been refused too.
  void _refuseReorder(String message) {
    state = state.copyWith(
      reorderRefusal: message,
      reorderRefusalAttempt: ++_reorderRefusals,
    );
  }

  /// Publish a refused insert, stamped the same way and for the same reason —
  /// and clearing the busy flag, which every one of these paths must.
  void _refuseInsert(String message) {
    state = state.copyWith(
      insertBusy: false,
      insertRefusal: message,
      insertRefusalAttempt: ++_insertRefusals,
    );
  }

  /// Restore the step list as it was before the last edit.
  void undo() {
    if (_undoJournal.isEmpty) return;
    final previous = _undoJournal.removeLast();
    _redoJournal.add(state.steps);
    _commitJournalledSteps(previous);
  }

  /// Re-apply the step list an [undo] set aside.
  void redo() {
    if (_redoJournal.isEmpty) return;
    final next = _redoJournal.removeLast();
    _undoJournal.add(state.steps);
    _commitJournalledSteps(next);
  }

  void _commitJournalledSteps(List<DarkroomStep> steps) {
    // An undo is a deliberate step, never part of the gesture that preceded it.
    _lastEditKey = null;
    _lastEditAt = null;
    state = state.copyWith(
      steps: List.unmodifiable(steps),
      canUndo: _undoJournal.isNotEmpty,
      canRedo: _redoJournal.isNotEmpty,
      clearReorderRefusal: true,
      clearInsertRefusal: true,
    );
    _scheduleRefresh();
    _scheduleSave();
  }

  /// Adopt [steps] as the edited stack: journal the previous list, re-check and
  /// re-render it, and schedule the write to the recipe row.
  ///
  /// [coalesceKey] names the control the edit came from. Consecutive edits from
  /// the same control inside [kDarkroomEditCoalesceWindow] extend the journal's
  /// top entry instead of adding one, so a slider drag is one undo step.
  void _applyEdit(
    List<DarkroomStep> steps, {
    DarkroomValidation? verdict,
    List<DarkroomStep>? verdictOf,
    String? coalesceKey,
  }) {
    final now = DateTime.now();
    final lastAt = _lastEditAt;
    final continues = coalesceKey != null &&
        coalesceKey == _lastEditKey &&
        lastAt != null &&
        now.difference(lastAt) < kDarkroomEditCoalesceWindow;
    if (!continues) {
      _undoJournal.add(state.steps);
      if (_undoJournal.length > kDarkroomJournalDepth) {
        _undoJournal.removeAt(0);
      }
      _redoJournal.clear();
    }
    _lastEditKey = coalesceKey;
    _lastEditAt = now;

    state = state.copyWith(
      steps: List.unmodifiable(steps),
      canUndo: _undoJournal.isNotEmpty,
      canRedo: _redoJournal.isNotEmpty,
      clearReorderRefusal: true,
      clearInsertRefusal: true,
      // A verdict arrives from the two paths that ask the engine before they
      // commit — a move and an added step — which already asked about this
      // exact stack; every other edit re-asks on the debounce rather than
      // carrying the previous stack's verdicts forward.
      issues: verdict?.steps,
      issuedSteps: verdictOf == null ? null : _identitiesOf(verdictOf),
      recipeError: verdict?.error,
      clearRecipeError: verdict != null && verdict.ok,
    );
    if (verdict != null) _adoptUnrenderable(verdict, verdictOf ?? steps);
    _scheduleRefresh();
    _scheduleSave();
  }

  static List<Object> _identitiesOf(List<DarkroomStep> steps) =>
      List.unmodifiable([for (final step in steps) step.identity]);

  /// The engine's refusal, said over the order the move was asking for.
  ///
  /// The engine's own sentences count steps from 1, the same way this screen's
  /// cards and the export sheet's filenames do, so the numbers are passed
  /// through untouched. What the engine cannot say is WHICH arrangement it
  /// counted, and that is this method's whole job: it numbered the recipe it
  /// was HANDED — the [candidate] order — not the stack still on screen.
  ///
  /// **Why not re-point them at the cards on screen.** A refused move is not
  /// committed, so the panel still shows the order from BEFORE it, and mapping
  /// the numbers onto that order preserves each operation's name while
  /// inverting the relation the sentence asserts: a stage-rule refusal about
  /// the attempted `crop, background extract, stretch, denoise` came out as
  /// "step 3 (denoise) is a linear-stage operation but step 4 (stretch) already
  /// left the linear stage" — which describes the arrangement the operator is
  /// looking at, and that one is LEGAL. The sentence is about the order that
  /// was refused, so it says which order that is.
  ///
  /// The clarifying sentence is added only when the message actually names a
  /// step the candidate list has; a refusal about no step in particular, or
  /// about a number outside that list, gets no claim about counting it never
  /// made.
  ///
  /// [counted] names the arrangement the numbers count, [undone] what did not
  /// happen, and [nextStep] what to do about it — so the two edits that ask the
  /// engine before they commit, a move and an added step, each report their own
  /// refusal in their own words while sharing the framing.
  static String _refusalOverCandidate(
    String message,
    List<DarkroomStep> candidate, {
    String counted = 'the order the move would have produced',
    String undone = 'the move was refused',
    String nextStep = 'Try a different destination for that step, or switch a '
        'step off if it should not run at all.',
  }) {
    final namesCandidateStep = RegExp(r'\bstep (\d+)\b')
        .allMatches(message)
        .map((match) => int.tryParse(match.group(1)!))
        .any((at) => at != null && at >= 1 && at <= candidate.length);
    if (!namesCandidateStep) {
      return '$message. The stack on screen is unchanged, because $undone. '
          '$nextStep';
    }
    return '$message. Those step numbers count $counted, from 1 — not the '
        'stack on screen, which is unchanged because $undone. $nextStep';
  }

  /// Record which of [steps] the engine's refusal names, from [verdict]'s own
  /// per-step diagnosis.
  ///
  /// Only from a verdict that REFUSES. An engine that accepts a recipe carrying
  /// a switched-off operation it does not register is an engine that will report
  /// that step itself, in its own words, as disabled — and its account of a step
  /// is always better than the app leaving the step out and describing the
  /// absence. The set is what the render is asked WITHOUT, so it is populated
  /// only when sending the recipe whole is what stops the render.
  ///
  /// Rebuilt from scratch each time rather than merged: a step whose parameters
  /// have just come back inside their range must stop being one the render
  /// leaves out.
  void _adoptUnrenderable(
      DarkroomValidation verdict, List<DarkroomStep> steps) {
    _unrenderable.clear();
    if (verdict.ok) return;
    for (final issue in verdict.steps) {
      if (issue.isClean) continue;
      if (issue.index < 0 || issue.index >= steps.length) continue;
      _unrenderable.add(steps[issue.index].identity);
    }
  }

  // ---------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------

  /// Re-check the committed step list and adopt its per-step verdicts.
  ///
  /// The whole list is validated, disabled steps included: the per-step
  /// diagnosis is what every card prints, and a step that is switched off still
  /// has to be able to say that this build does not register it.
  Future<void> _revalidate() async {
    final generation = ++_validateGeneration;
    final validated = state.steps;
    final verdict = await _validateSteps(validated);
    if (!mounted || generation != _validateGeneration) return;
    if (verdict == null) return;
    _adoptUnrenderable(verdict, validated);
    state = state.copyWith(
      issues: verdict.steps,
      issuedSteps: _identitiesOf(validated),
      recipeError: verdict.error,
      clearRecipeError: verdict.ok,
    );
  }

  /// Ask the engine about [steps], or return null when it could not be asked.
  Future<DarkroomValidation?> _validateSteps(List<DarkroomStep> steps) async {
    final recipeId = state.recipeId;
    if (recipeId == null) return null;
    try {
      final reply = await _darkroom.validate(
        recipeJson: encodeDarkroomRecipe(
          recipeId: recipeId,
          baseMasterRef: state.baseMasterPath,
          author: state.author,
          steps: steps,
        ),
        context: const <String, dynamic>{},
      );
      return decodeDarkroomValidation(reply);
    } on DarkroomSeamException catch (error) {
      if (!mounted) return null;
      state = state.copyWith(
        recipeError: 'The recipe could not be checked: ${error.message}',
      );
      return null;
    }
  }

  // ---------------------------------------------------------------------
  // Rendering
  // ---------------------------------------------------------------------

  /// Re-check and re-render the committed stack after the edit debounce.
  ///
  /// Both halves ride one timer: `validate` touches no pixels, so asking it
  /// first costs nothing and means the inline verdicts and the picture describe
  /// the same step list.
  void _scheduleRefresh() {
    _supersedeRunningRender();
    _renderDebounce?.cancel();
    _renderDebounce = Timer(kDarkroomRenderDebounce, () {
      unawaited(_refreshNow());
    });
  }

  /// Re-check and re-render now, superseding whatever is in flight.
  Future<void> refreshRender() async {
    _renderDebounce?.cancel();
    _supersedeRunningRender();
    await _refreshNow();
  }

  /// Retire the generation any running render answers under.
  ///
  /// Called the moment the stack stops being the one that render describes —
  /// the edit itself, not the debounce that follows it. [_runRender] compares
  /// the generation it was started with against this counter BEFORE the reply
  /// reaches [state], so a render that lands after this drops its pixels
  /// instead of painting a recipe the operator has already changed.
  void _supersedeRunningRender() => _renderGeneration++;

  Future<void> _refreshNow() async {
    await _revalidate();
    if (!mounted) return;
    await _startRender();
  }

  Future<void> _startRender() async {
    if (!mounted) return;
    if (state.recipeId == null || state.baseMasterPath.isEmpty) return;
    if (_renderInFlight) {
      // The engine renders one recipe at a time, so the running render is asked
      // to stop by its own id; its completion starts the newest generation.
      // This is not the operator's stop, so nothing announces "Stopping…".
      _renderQueued = true;
      await _requestCancel(_inFlightRenderId, announce: false);
      return;
    }
    _renderQueued = false;
    await _runRender(_renderGeneration);
  }

  Future<void> _runRender(int generation) async {
    final recipeId = state.recipeId;
    final masterPath = state.baseMasterPath;
    if (recipeId == null || masterPath.isEmpty) return;

    // An engine that validates the whole recipe before it touches a pixel is
    // refused by ONE step it cannot run — including a step switched off, which
    // the replay would have skipped anyway, and which therefore strands every
    // other step in the stack behind an operation that was never going to run.
    // When that is the refusal in hand, the render is asked about the steps it
    // can actually replay: every enabled step, plus every disabled step the
    // refusal does not name (so the engine keeps reporting those itself, as
    // disabled, in its own words). Only a switched-off step the engine refuses
    // is left out, and its card says it was left out.
    //
    // The set is empty whenever the engine accepts the recipe as it stands, so
    // this asks the engine for less than the whole recipe only while asking for
    // the whole recipe is what produces no picture at all.
    //
    // Validation is NOT filtered — see [_revalidate]. The card verdicts and the
    // whole-stack sentence describe the recipe as stored; only the render
    // request describes the subset that can run.
    final asked = <DarkroomStep>[];
    final askedIdentities = <Object>[];
    final omitted = <Object>[];
    for (final step in state.steps) {
      if (!step.enabled && _unrenderable.contains(step.identity)) {
        omitted.add(step.identity);
        continue;
      }
      asked.add(step);
      askedIdentities.add(step.identity);
    }

    final renderId = 'darkroom-editor-$recipeId-$generation';
    _renderInFlight = true;
    _inFlightRenderId = renderId;
    state = state.copyWith(
      rendering: true,
      cancelRequested: false,
      clearRenderError: true,
      clearRenderFailure: true,
      clearCancelledPhase: true,
      omittedFromRender: List.unmodifiable(omitted),
    );

    final recipeJson = encodeDarkroomRecipe(
      recipeId: recipeId,
      baseMasterRef: masterPath,
      author: state.author,
      steps: asked,
    );

    try {
      final preview = await _darkroom.renderPreview(
        recipeJson: recipeJson,
        context: {
          'masterPath': masterPath,
          'maxDimension': kDarkroomPreviewMaxDimension,
          'renderId': renderId,
          'encoding': 'auto',
          if (_catalogStars.isNotEmpty) 'catalogStars': _catalogStars,
        },
      );
      if (!mounted || generation != _renderGeneration) return;
      state = state.copyWith(
        rendering: false,
        cancelRequested: false,
        preview: DarkroomPreviewImage(
          width: preview.width,
          height: preview.height,
          isColor: preview.isColor,
          rgba: preview.rgba,
          encoding: decodeDarkroomEncoding(preview.report),
          level: decodeDarkroomLevel(preview.report),
          scaleFromMaster: decodeDarkroomScaleFromMaster(preview.report),
        ),
        reports: decodeDarkroomStepReports(preview.report),
        reportedSteps: List.unmodifiable(askedIdentities),
        clearRenderFailure: true,
      );
      final encoding = decodeDarkroomEncoding(preview.report);
      if (darkroomRenderIsDisplayable(
        encoding.applied,
        encoding.sourceDomain,
      )) {
        // The finished render becomes the recipe's draft thumbnail, which the
        // Targets and Edit lists show in place of the master's preview.
        unawaited(
          saveDarkroomRecipePreview(
            path: darkroomRecipePreviewPath(masterPath, recipeId),
            width: preview.width,
            height: preview.height,
            rgba: preview.rgba,
          ).catchError((Object error) {
            developer.log(
              'The draft thumbnail for recipe $recipeId could not be saved: '
              '$error',
              name: 'DarkroomController',
            );
          }),
        );
      }
    } on DarkroomCancelledOutcome catch (cancelled) {
      if (!mounted || generation != _renderGeneration) return;
      // A stopped render is the operator's own instruction being obeyed, not a
      // failure: the previous picture stays up and the phase it stopped in is
      // named.
      state = state.copyWith(
        rendering: false,
        cancelRequested: false,
        cancelledPhase: cancelled.phase,
        clearRenderFailure: true,
      );
    } on DarkroomSeamException catch (error) {
      if (!mounted || generation != _renderGeneration) return;
      // A render that did not finish produced no outcomes, so the previous
      // render's account is dropped rather than left on the cards. Keeping it
      // is what let a stack wear "Applied by the last render" across a render
      // that never applied anything.
      //
      // A failure about the base master is not a failure about a step, so it
      // takes the sentence that names what to do about the FILE rather than the
      // one that explains how the engine numbered a step.
      final nextStep = darkroomMasterFailureNextStep(
        error.message,
        state.baseMasterPath,
      );
      final failure = _failureOf(error.message, asked, askedIdentities);
      state = state.copyWith(
        rendering: false,
        cancelRequested: false,
        renderError: nextStep == null
            ? _renderErrorFor(error.message, omitted.length)
            : '${error.message}. $nextStep',
        reports: const [],
        reportedSteps: const [],
        renderFailure: failure,
        clearRenderFailure: failure == null,
      );
    } finally {
      _renderInFlight = false;
      _inFlightRenderId = null;
      if (mounted && _renderQueued) {
        _renderQueued = false;
        unawaited(_runRender(_renderGeneration));
      }
    }
  }

  /// The step a render failure NAMES, or null when it names none this build can
  /// join to one.
  ///
  /// The engine writes `step N failed: <opId>@<version>: <fault>`, where N
  /// counts the recipe it was HANDED from 1 — [asked], which is the stack minus
  /// any switched-off step this build cannot run. Both halves are checked: the
  /// position has to exist in that list AND the operation at it has to be the
  /// operation the message names. A message that fails either check attributes
  /// nothing, because the alternative is badging a step the engine never ran.
  ///
  /// [identities] is [asked]'s identity list, so the attribution survives an
  /// edit that moves the step before the failure reaches a card.
  static DarkroomRenderFailure? _failureOf(
    String message,
    List<DarkroomStep> asked,
    List<Object> identities,
  ) {
    final match = RegExp(r'^step (\d+) failed: ([A-Za-z0-9_]+)@(\d+): (.+)$',
            dotAll: true)
        .firstMatch(message);
    if (match == null) return null;
    final ordinal = int.tryParse(match.group(1)!);
    final version = int.tryParse(match.group(3)!);
    if (ordinal == null || version == null) return null;
    final at = ordinal - 1;
    if (at < 0 || at >= asked.length || at >= identities.length) return null;
    final step = asked[at];
    if (step.opId != match.group(2) || step.opVersion != version) return null;
    return DarkroomRenderFailure(
      stepIdentity: identities[at],
      reason: match.group(4)!,
    );
  }

  /// The engine's refusal, plus what it was counting when it numbered a step.
  ///
  /// A refusal counts a step from 1 over the recipe the engine was HANDED.
  /// When that recipe was the stack minus the switched-off steps this build
  /// cannot run, the number the engine wrote is not the number the operator can
  /// count to in the panel — so the difference is stated rather than left for
  /// them to discover by counting.
  static String _renderErrorFor(String message, int omittedCount) {
    if (omittedCount == 0) return message;
    final steps = omittedCount == 1 ? 'step' : 'steps';
    return '$message. The render was asked without $omittedCount '
        'switched-off $steps this build cannot run, so the step it numbers is '
        'counted over the steps it was given rather than over the whole stack.';
  }

  /// Ask the running render to stop.
  ///
  /// Cooperative: the engine honours the request at its next step boundary or
  /// pixel-budget poll, so the button reads "Stopping…" until the render
  /// answers rather than pretending the stop was instant.
  Future<void> cancelRender() async {
    final renderId = _inFlightRenderId;
    if (renderId == null || state.cancelRequested) return;
    await _requestCancel(renderId, announce: true);
  }

  Future<void> _requestCancel(String? renderId,
      {required bool announce}) async {
    if (renderId == null) return;
    if (announce) state = state.copyWith(cancelRequested: true);
    try {
      await _darkroom.cancel({'op': 'cancel', 'renderId': renderId});
    } on DarkroomSeamException catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        cancelRequested: false,
        renderError: 'The stop request did not reach the render: '
            '${error.message}',
        // A stop that did not arrive is not a fault of any step's.
        clearRenderFailure: true,
      );
    }
  }

  // ---------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------

  void _scheduleSave() {
    _savePending = true;
    state = state.copyWith(savePending: true);
    _saveDebounce?.cancel();
    _saveDebounce = Timer(kDarkroomSaveDebounce, () {
      unawaited(_commitSteps());
    });
  }

  Future<void> _commitSteps() async {
    final recipeId = state.recipeId;
    if (recipeId == null) return;
    final payload = jsonEncode([for (final step in state.steps) step.toJson()]);
    try {
      final rows = await _recipes.updateSteps(recipeId, payload);
      _savePending = false;
      if (!mounted) return;
      if (rows == 0) {
        state = state.copyWith(
          savePending: false,
          saveError:
              'Recipe $recipeId no longer has a row, so this edit was not '
              'stored.',
        );
        return;
      }
      state = state.copyWith(savePending: false, clearSaveError: true);
    } catch (error) {
      _savePending = false;
      if (!mounted) return;
      state = state.copyWith(
        savePending: false,
        saveError: 'This edit could not be written to the recipe: $error',
      );
    }
  }

  @override
  void dispose() {
    _renderDebounce?.cancel();
    _saveDebounce?.cancel();
    final renderId = _inFlightRenderId;
    if (renderId != null) {
      // The render is inside the engine and outlives this notifier; leaving it
      // running would hold the engine against the next screen that wants it.
      unawaited(
        _darkroom.cancel({'op': 'cancel', 'renderId': renderId}).then(
          (_) {},
          onError: (Object error, StackTrace stack) {
            developer.log(
              'Darkroom: the stop request for $renderId did not land: $error',
              name: 'Darkroom',
              level: 900,
              stackTrace: stack,
            );
          },
        ),
      );
    }
    final recipeId = state.recipeId;
    if (_savePending && recipeId != null) {
      // A debounced edit that is never written is an edit the operator made and
      // lost. The write is issued here and its outcome logged, because dispose
      // cannot await it.
      final payload = jsonEncode([
        for (final step in state.steps) step.toJson(),
      ]);
      unawaited(
        _recipes.updateSteps(recipeId, payload).then(
          (_) {},
          onError: (Object error, StackTrace stack) {
            developer.log(
              'Darkroom: the last edit to recipe $recipeId was not stored: '
              '$error',
              name: 'Darkroom',
              level: 1000,
              stackTrace: stack,
            );
          },
        ),
      );
    }
    super.dispose();
  }
}

/// Family provider keyed by the scope, so a recipe opened by id and a master
/// opened by id are independent controllers.
///
/// **autoDispose, and why it is not optional.** A controller reads its recipe
/// row once, in its constructor, and then owns the step list for as long as it
/// lives. Without autoDispose a family member outlives the screen that made it,
/// so re-entering the Darkroom by the same route served the stack as it stood
/// when that route was last open — and the next edit wrote that stale stack
/// over the row, silently discarding whatever had been done through the other
/// route in between. A deleted recipe stayed openable for the same reason: the
/// surviving controller kept rendering a row that no longer existed. Disposing
/// with the screen means every entry re-reads the row, which is the only way
/// the editor and the database can be describing the same recipe.
final darkroomControllerProvider = StateNotifierProvider.autoDispose
    .family<DarkroomController, DarkroomState, DarkroomScope>(
        (ref, scope) => DarkroomController(ref, scope));
