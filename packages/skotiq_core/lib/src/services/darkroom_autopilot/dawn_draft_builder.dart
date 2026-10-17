/// Builds the first-draft recipe the operator wakes up to.
///
/// The draft is composed from the Darkroom registry's own measurements — the
/// auto crop rectangle, the auto stretch parameters, and each operation's
/// documented defaults — so the numbers come from the operations that will
/// render them rather than from a second copy kept here that drifts the first
/// time a range moves.
///
/// Three policies live on top of what the registry returns:
///
///  * **Nothing that renders nothing.** A step whose parameters are the
///    identity is left out: it would show in the history stack, change no
///    pixel, and read as broken. Two shapes qualify — an operation that is the
///    identity at its defaults (`saturation`, `curves`), and a `crop` whose
///    measured rectangle is the whole master, which is what the registry
///    returns whenever the registered frames cover every pixel.
///  * **One background retry.** A dense field can leave the background lattice
///    with too few star-free samples to fit a surface. The draft retries once
///    at half the sample spacing, which doubles the lattice density per axis;
///    still failing, the step is left out and the operation's own reason is
///    recorded.
///  * **Colour is proved at full resolution, and its answer is pinned.**
///    `color_calibrate@1` detects stars in the image it is handed, and a
///    downsampled level does not hold enough of them. The draft therefore
///    renders the colour step once at level 0, keeps it only when it actually
///    applied there, and writes the channel scales that render reported into the
///    step. Every later render — the editor's coarse preview included — replays
///    those numbers instead of re-fitting a field it cannot measure.
///  * **The stretch is measured over the stack it actually sits on.** The
///    registry measures the auto stretch over the prefix it drafted. When this
///    composition changes that prefix — a background fit restored, a colour
///    balance pinned where the registry's measurement had skipped it — the black
///    and white points are measured again over the final prefix before the draft
///    is persisted.
library;

import 'dart:convert';

import 'dawn_master_resolver.dart';
import 'dawn_photometry.dart';
import 'darkroom_seam.dart';

/// Wire schema version of the recipe envelope this build writes.
///
/// It matches `RECIPE_SCHEMA_VERSION` in the recipe engine; a recipe whose
/// version differs is refused by the engine rather than reinterpreted.
const int kRecipeSchemaVersion = 1;

/// The pyramid level the draft's colour step is proved at. Level 0 is the
/// master's own pixels.
const int kColorProofLevel = 0;

/// Longest edge, in pixels, of the level the background retry is probed at.
///
/// It matches the registry's own draft-measurement dimension, so a retry that
/// succeeds here succeeds under the same conditions the rest of the draft was
/// measured under.
const int kDraftMeasureMaxDimension = 1024;

/// The `sampleSpacing` a retried `background_extract@1` uses: half the
/// operation's documented 64-pixel default, which quadruples the number of
/// sample boxes and is the smallest change that can rescue a dense field.
const double kBackgroundRetrySampleSpacing = 32.0;

/// Channels `color_calibrate@1` balances, and the length of the `channelScale`
/// payload it accepts.
const int kColorChannelCount = 3;

/// The `stretch@1` parameters the draft re-measures. Every one of them is
/// written by the engine's own auto measurement, so a reply missing any of them
/// is not a measurement this draft can adopt.
const List<String> kStretchMeasuredParams = [
  'blackPoint',
  'whitePoint',
  'd',
  'b',
  'symmetryPoint',
];

/// Operations whose defaults are the identity transform, so a draft that
/// carried them would list a step that changes nothing.
///
/// `crop` is not here because its parameters are MEASURED rather than
/// defaulted: whether it is the identity depends on the rectangle the registry
/// returned for this master, which is what [darkroomCropIsIdentity] answers.
const Set<String> kIdentityAtDefaults = {'saturation', 'curves'};

/// True when [params] is a crop rectangle covering the whole
/// [width]×[height] master, so the step trims nothing.
///
/// `crop@1`'s auto rectangle is the largest area every registered frame covers.
/// A stack whose frames all landed on the same pixels — an undithered night,
/// and every simulated master — leaves that rectangle equal to the frame, and
/// the draft then carried `{x: 0, y: 0, width: W, height: H}` over a W×H
/// master: a step card reading "Applied by the last render" over an operation
/// that moved no pixel.
///
/// False for a rectangle this cannot read — a missing corner, a non-numeric
/// edge, a master whose dimensions are unknown. An unreadable rectangle is not
/// PROVEN to be the identity, and dropping a step on a guess would remove a
/// crop the registry meant.
bool darkroomCropIsIdentity(
  Object? params, {
  required int width,
  required int height,
}) {
  if (params is! Map) return false;
  if (width <= 0 || height <= 0) return false;
  final x = _asPixels(params['x']);
  final y = _asPixels(params['y']);
  final w = _asPixels(params['width']);
  final h = _asPixels(params['height']);
  if (x == null || y == null || w == null || h == null) return false;
  return x == 0 && y == 0 && w == width && h == height;
}

/// The sentence a draft records for a crop it left out because the rectangle
/// covers the whole master.
///
/// Shared by the dawn pass and the editor's own "Draft for me" so the two
/// paths give one account of the same decision.
String darkroomIdentityCropReason(int width, int height) =>
    'the crop rectangle measured over this master is the whole '
    '$width×$height frame, so it trims nothing: a draft carrying it would '
    'list a step that changes no pixel. Add a crop by hand to trim an edge.';

/// One crop edge as whole pixels, or null when it is not a finite number.
int? _asPixels(Object? value) {
  if (value is int) return value;
  if (value is double) {
    if (!value.isFinite || value != value.roundToDouble()) return null;
    return value.toInt();
  }
  return null;
}

/// The order a draft's steps are written in.
///
/// Every linear-stage operation precedes the stretch, because the engine's
/// validation refuses a linear operation after a stretched one. A step
/// re-inserted by a retry takes its place from this list rather than from
/// wherever the retry happened to run.
const List<String> kDraftStepOrder = [
  'crop',
  'background_extract',
  'denoise',
  'color_calibrate',
  'star_reduce',
  'stretch',
  'saturation',
  'curves',
];

/// What happened to one operation while the draft was composed.
class DawnDraftNote {
  /// The operation the note is about.
  final String opId;

  /// `included`, `retried`, `remeasured`, or `omitted`.
  final String outcome;

  /// Why, in the words the morning report prints.
  final String reason;

  const DawnDraftNote({
    required this.opId,
    required this.outcome,
    required this.reason,
  });

  /// The note as report JSON.
  Map<String, dynamic> toJson() => {
    'opId': opId,
    'outcome': outcome,
    'reason': reason,
  };

  @override
  String toString() => '$opId: $outcome — $reason';
}

/// A composed first draft: the steps, and the account of how they got there.
class DawnDraft {
  /// The linear master these steps replay over.
  final String baseMasterRef;

  /// The ordered op stack, each entry `{opId, opVersion, params, enabled}`.
  final List<Map<String, dynamic>> steps;

  /// One note per operation the composition decided about.
  final List<DawnDraftNote> notes;

  const DawnDraft({
    required this.baseMasterRef,
    required this.steps,
    required this.notes,
  });

  /// True when the draft has nothing to render.
  bool get isEmpty => steps.isEmpty;

  /// Index of [opId] in the step list, or -1 when it is absent.
  int indexOfOp(String opId) =>
      steps.indexWhere((step) => step['opId'] == opId);

  /// The `recipes.steps_json` payload: the step list alone. The envelope's
  /// schema version lives in the row's own `schema_version` column.
  String encodeStepsJson() => jsonEncode(steps);

  /// The full recipe envelope the render entry points take, carrying [recipeId]
  /// as the recipe's identity.
  String encodeRecipeJson(String recipeId) => jsonEncode({
    'id': recipeId,
    'schemaVersion': kRecipeSchemaVersion,
    'baseMasterRef': baseMasterRef,
    'createdBy': 'autopilot',
    'steps': steps,
  });
}

/// One composition decision's result: the steps after it, and whether it left
/// different pixels under the stretch.
///
/// The second half is what the stretch re-measurement keys on. A decision that
/// removes a step the measurement had already recorded as skipped changes no
/// pixel, and re-measuring after it would spend a render to arrive at the same
/// numbers.
class _DraftStage {
  /// The step list after the decision.
  final List<Map<String, dynamic>> steps;

  /// Whether the pixels the stretch is measured over changed.
  final bool movedThePrefix;

  const _DraftStage({required this.steps, required this.movedThePrefix});
}

/// The draft could not be composed at all.
class DawnDraftException implements Exception {
  final String message;

  const DawnDraftException(this.message);

  @override
  String toString() => 'Cannot compose a first draft: $message';
}

/// Composes the first-draft recipe for one master.
class DawnDraftBuilder {
  final DarkroomSeam _darkroom;

  const DawnDraftBuilder({required DarkroomSeam darkroom})
    : _darkroom = darkroom;

  /// Build the draft for [master].
  ///
  /// [renderId] makes every render this issues cancellable under the job's own
  /// id. [photometry] is what `color_calibrate@1` regresses against; a field
  /// with no colour-indexed star leaves the colour step out with that reason
  /// rather than carrying a step that can only skip.
  ///
  /// Throws [DawnDraftException] when the registry reply does not describe a
  /// draft, and lets a [DarkroomCancelledOutcome] out untouched.
  Future<DawnDraft> build({
    required DawnMaster master,
    required String recipeId,
    required DawnPhotometry photometry,
    required String renderId,
  }) async {
    final reply = await _darkroom.registry({
      'masterPath': master.masterFitsPath,
      'baseMasterRef': master.masterFitsPath,
      'recipeId': recipeId,
    });

    final draft = reply['draft'];
    if (draft is! Map<String, dynamic>) {
      throw DawnDraftException(
        'the registry answered for ${master.masterFitsPath} without a draft, '
        'so there are no measured parameters to build one from',
      );
    }
    final recipe = draft['recipe'];
    if (recipe is! Map<String, dynamic>) {
      throw const DawnDraftException(
        'the registry draft carries no recipe, so it names no operations',
      );
    }
    final rawSteps = recipe['steps'];
    if (rawSteps is! List) {
      throw const DawnDraftException(
        'the registry draft recipe carries no step list',
      );
    }

    final notes = <DawnDraftNote>[];
    _adoptRegistryNotes(draft['notes'], notes);

    var steps = <Map<String, dynamic>>[
      for (final step in rawSteps)
        if (step is Map<String, dynamic>) Map<String, dynamic>.from(step),
    ];
    steps = _dropIdentitySteps(steps, notes, master);
    final background = await _retryBackgroundExtract(
      master: master,
      recipeId: recipeId,
      steps: steps,
      notes: notes,
      renderId: renderId,
    );
    final colour = await _proveColorCalibrate(
      master: master,
      recipeId: recipeId,
      steps: background.steps,
      notes: notes,
      photometry: photometry,
      renderId: renderId,
    );
    steps = colour.steps;

    // The registry measured the stretch over the prefix it drafted. Either of
    // the two decisions above can leave a different prefix under it, and a
    // black point measured over other pixels is not a fit of these ones.
    final causes = <String>[
      if (background.movedThePrefix)
        'the background fit was restored at a denser lattice',
      if (colour.movedThePrefix)
        'the colour balance is now pinned, so it applies at the level the '
            'stretch is measured at instead of skipping there',
    ];
    if (causes.isNotEmpty) {
      steps = await _remeasureStretch(
        master: master,
        recipeId: recipeId,
        steps: steps,
        notes: notes,
        photometry: photometry,
        renderId: renderId,
        causes: causes,
      );
    }

    for (final step in steps) {
      final opId = step['opId'];
      if (opId is! String) continue;
      if (notes.any((n) => n.opId == opId && n.outcome != 'omitted')) continue;
      notes.add(
        DawnDraftNote(
          opId: opId,
          outcome: 'included',
          reason: 'measured from this master by the operation registry',
        ),
      );
    }

    return DawnDraft(
      baseMasterRef: master.masterFitsPath,
      steps: List.unmodifiable(steps),
      notes: List.unmodifiable(notes),
    );
  }

  /// Carry the registry's own omission notes into the draft's account, so a
  /// step the measurement dropped is explained by the words the operation used.
  static void _adoptRegistryNotes(Object? raw, List<DawnDraftNote> notes) {
    if (raw is! List) return;
    for (final entry in raw) {
      if (entry is! Map<String, dynamic>) continue;
      final opId = entry['opId'];
      final reason = entry['reason'];
      final outcome = entry['outcome'];
      if (opId is! String) continue;
      notes.add(
        DawnDraftNote(
          opId: opId,
          outcome: outcome is String ? outcome : 'omitted',
          reason: reason is String
              ? reason
              : 'the operation registry omitted it without stating a reason',
        ),
      );
    }
  }

  /// Drop the steps that render nothing over [master].
  ///
  /// Two shapes: an operation that is the identity at its defaults, and a crop
  /// whose measured rectangle is the whole frame. Both leave a note, because a
  /// draft that silently carries four steps where the registry decided about
  /// five is a draft that hides one of its own decisions.
  static List<Map<String, dynamic>> _dropIdentitySteps(
    List<Map<String, dynamic>> steps,
    List<DawnDraftNote> notes,
    DawnMaster master,
  ) {
    final kept = <Map<String, dynamic>>[];
    for (final step in steps) {
      final opId = step['opId'];
      if (opId is String && kIdentityAtDefaults.contains(opId)) {
        notes.add(
          DawnDraftNote(
            opId: opId,
            outcome: 'omitted',
            reason:
                'at its defaults this operation is the identity transform, so '
                'a first draft carrying it would list a step that changes no '
                'pixel',
          ),
        );
        continue;
      }
      if (opId == 'crop' &&
          darkroomCropIsIdentity(
            step['params'],
            width: master.width,
            height: master.height,
          )) {
        notes.add(
          DawnDraftNote(
            opId: 'crop',
            outcome: 'omitted',
            reason: darkroomIdentityCropReason(master.width, master.height),
          ),
        );
        continue;
      }
      kept.add(step);
    }
    return kept;
  }

  /// Retry a background extraction the registry's measurement dropped.
  ///
  /// The one documented failure is a field too dense for the star-rejected
  /// lattice to leave enough samples; halving the spacing quadruples the sample
  /// count, which is the change that rescues it. The retry is probed at the
  /// same level the registry measured at, so a pass here means a pass there.
  ///
  /// `movedThePrefix` is true only when the step was actually restored: the
  /// pixels under the stretch changed, and the stretch is measured again.
  Future<_DraftStage> _retryBackgroundExtract({
    required DawnMaster master,
    required String recipeId,
    required List<Map<String, dynamic>> steps,
    required List<DawnDraftNote> notes,
    required String renderId,
  }) async {
    const opId = 'background_extract';
    final unchanged = _DraftStage(steps: steps, movedThePrefix: false);
    if (steps.any((step) => step['opId'] == opId)) return unchanged;
    final omission = notes
        .where((n) => n.opId == opId && n.outcome == 'omitted')
        .toList(growable: false);
    if (omission.isEmpty) return unchanged;

    final candidate = <String, dynamic>{
      'opId': opId,
      'opVersion': 1,
      'params': {'sampleSpacing': kBackgroundRetrySampleSpacing},
      'enabled': true,
    };
    final probed = _insertInDraftOrder(steps, candidate);
    final index = probed.indexWhere((step) => step['opId'] == opId);

    final String? failure;
    try {
      final preview = await _darkroom.renderPreview(
        recipeJson: _envelope(recipeId, master.masterFitsPath, probed),
        context: {
          'masterPath': master.masterFitsPath,
          'maxDimension': kDraftMeasureMaxDimension,
          'stopAfter': index,
          'renderId': renderId,
          'encoding': 'unit',
        },
      );
      failure = _skipReasonFor(preview.report, index);
    } on DarkroomSeamException catch (error) {
      notes.add(
        DawnDraftNote(
          opId: opId,
          outcome: 'omitted',
          reason:
              'the retry at half the sample spacing '
              '(${kBackgroundRetrySampleSpacing.toStringAsFixed(0)} px) also '
              'failed: ${error.message}. The draft leaves the background fit '
              'out; the gradient is still in the master and can be removed by '
              'hand in the editor.',
        ),
      );
      return unchanged;
    }

    if (failure != null) {
      notes.add(
        DawnDraftNote(
          opId: opId,
          outcome: 'omitted',
          reason:
              'the retry at half the sample spacing '
              '(${kBackgroundRetrySampleSpacing.toStringAsFixed(0)} px) was '
              'skipped: $failure',
        ),
      );
      return unchanged;
    }

    notes.add(
      DawnDraftNote(
        opId: opId,
        outcome: 'retried',
        reason:
            'the background fit failed at its default 64 px sample spacing and '
            'succeeded at '
            '${kBackgroundRetrySampleSpacing.toStringAsFixed(0)} px, so the '
            'draft carries the denser lattice.',
      ),
    );
    return _DraftStage(steps: probed, movedThePrefix: true);
  }

  /// Prove the colour step at full resolution, keep it only when it applied,
  /// and pin the balance that render fitted.
  ///
  /// `color_calibrate@1` needs three channels, a plate solve, and stars it can
  /// both detect and cross-match. A step that can only skip belongs in the
  /// report, not in the history stack.
  ///
  /// The proof render reports the channel scales it fitted, and they are written
  /// into the step. That is what makes the editor usable: pinned, the step
  /// applies the same balance at every pyramid level, where an unpinned step
  /// would try to re-fit a downsampled level that holds too few detectable stars
  /// and record itself as skipped — a colour-wrong preview of a master the draft
  /// calibrates correctly.
  ///
  /// `movedThePrefix` is true when the scales were pinned. The registry measured
  /// the draft with no catalogue attached, so the colour step skipped there;
  /// pinned, it applies, and the pixels under the stretch are no longer the ones
  /// the stretch was measured over.
  Future<_DraftStage> _proveColorCalibrate({
    required DawnMaster master,
    required String recipeId,
    required List<Map<String, dynamic>> steps,
    required List<DawnDraftNote> notes,
    required DawnPhotometry photometry,
    required String renderId,
  }) async {
    const opId = 'color_calibrate';
    final index = steps.indexWhere((step) => step['opId'] == opId);
    if (index < 0) return _DraftStage(steps: steps, movedThePrefix: false);

    if (!master.isColor) {
      return _dropAt(
        steps,
        index,
        notes,
        opId,
        'this master has ${master.channels} '
        'channel${master.channels == 1 ? '' : 's'} and the colour fit needs '
        'three, so the per-filter masters are combined before it can run',
      );
    }
    if (!photometry.hasStars) {
      final reason = photometry.unavailableReason;
      return _dropAt(
        steps,
        index,
        notes,
        opId,
        reason ??
            'no catalogue star was resolved for this field, so the colour '
                'fit has nothing to regress against',
      );
    }

    final DarkroomRenderedPreview preview;
    try {
      preview = await _darkroom.renderPreview(
        recipeJson: _envelope(recipeId, master.masterFitsPath, steps),
        context: {
          'masterPath': master.masterFitsPath,
          'level': kColorProofLevel,
          'stopAfter': index,
          'renderId': renderId,
          'encoding': 'unit',
          'catalogStars': photometry.stars,
        },
      );
    } on DarkroomSeamException catch (error) {
      return _dropAt(steps, index, notes, opId, error.message);
    }

    final skipped = _skipReasonFor(preview.report, index);
    if (skipped != null) {
      return _dropAt(steps, index, notes, opId, skipped);
    }

    final scales = _channelScalesFrom(preview.report, index);
    if (scales == null) {
      notes.add(
        DawnDraftNote(
          opId: opId,
          outcome: 'included',
          reason:
              'the colour fit applied at full resolution against '
              '${photometry.stars.length} catalogue stars, but the render '
              'reported no fitted channel scales to write into the step, so it '
              'solves the balance again on every render: a preview at a reduced '
              'level can detect too few stars and record the step as skipped '
              'with that reason.',
        ),
      );
      return _DraftStage(steps: steps, movedThePrefix: false);
    }

    notes.add(
      DawnDraftNote(
        opId: opId,
        outcome: 'included',
        reason:
            'the colour fit applied at full resolution against '
            '${photometry.stars.length} catalogue stars, and the draft carries '
            'the balance it fitted '
            '(${scales.map((s) => s.toStringAsFixed(4)).join(', ')}). Every '
            'later render replays those scales, so a preview at a reduced level '
            'shows the same colour as the full-resolution proof instead of '
            're-measuring a level that holds too few stars.',
      ),
    );
    return _DraftStage(
      steps: _withPinnedChannelScale(steps, index, scales),
      movedThePrefix: true,
    );
  }

  /// The same steps with the colour step at [index] carrying [scales].
  ///
  /// Only `channelScale` is written. The reference colour the fit was evaluated
  /// at is in the note, not in the payload: a pinned step reads no `whiteRefBv`,
  /// and a parameter the render ignores would offer the editor a control that
  /// changes nothing.
  static List<Map<String, dynamic>> _withPinnedChannelScale(
    List<Map<String, dynamic>> steps,
    int index,
    List<double> scales,
  ) {
    final out = List<Map<String, dynamic>>.from(steps);
    final step = Map<String, dynamic>.from(out[index]);
    final params = step['params'];
    final pinned = params is Map<String, dynamic>
        ? Map<String, dynamic>.from(params)
        : <String, dynamic>{};
    pinned['channelScale'] = scales;
    step['params'] = pinned;
    out[index] = step;
    return out;
  }

  /// The per-channel scales the render reported for step [index], or null when
  /// it reported none this draft can pin.
  ///
  /// Every element must be a finite number and there must be exactly
  /// [kColorChannelCount] of them, because that is what the operation accepts —
  /// a payload it would refuse is not a draft, and writing one would leave a
  /// recipe that fails to validate the first time the editor opens it.
  static List<double>? _channelScalesFrom(
    Map<String, dynamic> report,
    int index,
  ) {
    final inner = report['report'];
    final steps = inner is Map<String, dynamic> ? inner['steps'] : null;
    if (steps is! List) return null;
    for (final entry in steps) {
      if (entry is! Map<String, dynamic>) continue;
      if (entry['index'] != index) continue;
      final measured = entry['measured'];
      if (measured is! Map<String, dynamic>) return null;
      final raw = measured['channelScale'];
      if (raw is! List || raw.length != kColorChannelCount) return null;
      final scales = <double>[];
      for (final value in raw) {
        if (value is! num || !value.isFinite) return null;
        scales.add(value.toDouble());
      }
      return scales;
    }
    return null;
  }

  /// Remove the step at [index], recording why.
  static _DraftStage _dropAt(
    List<Map<String, dynamic>> steps,
    int index,
    List<DawnDraftNote> notes,
    String opId,
    String reason,
  ) {
    notes.add(DawnDraftNote(opId: opId, outcome: 'omitted', reason: reason));
    final kept = List<Map<String, dynamic>>.from(steps)..removeAt(index);
    // Dropping the colour step leaves the pixels the stretch was measured over
    // exactly as they were: the registry measured with no catalogue attached, so
    // the step was recorded as skipped there and changed nothing.
    return _DraftStage(steps: kept, movedThePrefix: false);
  }

  /// Measure the auto stretch again over the prefix the draft ended up with.
  ///
  /// The measurement is the engine's own: asking a render for the `screen`
  /// encoding runs `stretch@1`'s auto measurement over the pixels that render
  /// produced and names the parameters it used in the reply — the same function,
  /// over the same prefix, at the same level the registry measured the first
  /// draft at. The reply's `screenTransferAffectsRecipe` says the render did not
  /// touch the stored recipe, which is true; adopting the numbers is this
  /// composition's own decision, taken here because the prefix moved under them.
  ///
  /// A measurement that cannot be read leaves the registry's parameters in
  /// place and says so: a starting point measured over the wrong prefix is
  /// still a starting point, while a fabricated one is not.
  Future<List<Map<String, dynamic>>> _remeasureStretch({
    required DawnMaster master,
    required String recipeId,
    required List<Map<String, dynamic>> steps,
    required List<DawnDraftNote> notes,
    required DawnPhotometry photometry,
    required String renderId,
    required List<String> causes,
  }) async {
    const opId = 'stretch';
    final index = steps.indexWhere((step) => step['opId'] == opId);
    if (index <= 0) {
      // No stretch, or nothing under it: there is no prefix to measure over.
      return steps;
    }
    final because = causes.join(' and ');

    final DarkroomRenderedPreview preview;
    try {
      preview = await _darkroom.renderPreview(
        recipeJson: _envelope(recipeId, master.masterFitsPath, steps),
        context: {
          'masterPath': master.masterFitsPath,
          'maxDimension': kDraftMeasureMaxDimension,
          'stopAfter': index - 1,
          'renderId': renderId,
          'encoding': 'screen',
          'catalogStars': photometry.stars,
        },
      );
    } on DarkroomSeamException catch (error) {
      notes.add(
        DawnDraftNote(
          opId: opId,
          outcome: 'included',
          reason:
              'the draft keeps the black and white points the registry measured: '
              '$because, and the render that would have measured them again over '
              'the final stack failed (${error.message}). They are a starting '
              'point for these pixels rather than a fit of them.',
        ),
      );
      return steps;
    }

    final measured = _screenTransferFrom(preview.report);
    if (measured == null) {
      notes.add(
        DawnDraftNote(
          opId: opId,
          outcome: 'included',
          reason:
              'the draft keeps the black and white points the registry measured: '
              '$because, and the render over the final stack reported no auto '
              'stretch parameters to replace them with. They are a starting '
              'point for these pixels rather than a fit of them.',
        ),
      );
      return steps;
    }

    final out = List<Map<String, dynamic>>.from(steps);
    final step = Map<String, dynamic>.from(out[index]);
    step['params'] = measured;
    out[index] = step;
    notes.add(
      DawnDraftNote(
        opId: opId,
        outcome: 'remeasured',
        reason:
            'the black and white points were measured again over the stack the '
            'stretch actually sits on, because $because. They are a fit of the '
            'pixels this draft renders, not of the ones the registry drafted.',
      ),
    );
    return out;
  }

  /// The auto stretch parameters a `screen`-encoded render reports, or null when
  /// the reply does not carry a complete set.
  static Map<String, dynamic>? _screenTransferFrom(
    Map<String, dynamic> report,
  ) {
    final encoding = report['encoding'];
    if (encoding is! Map<String, dynamic>) return null;
    final transfer = encoding['screenTransfer'];
    if (transfer is! Map<String, dynamic>) return null;
    final params = <String, dynamic>{};
    for (final key in kStretchMeasuredParams) {
      final value = transfer[key];
      if (value is! num || !value.isFinite) return null;
      params[key] = value.toDouble();
    }
    return params;
  }

  /// The skip reason the render report records for step [index], or null when
  /// the step applied.
  ///
  /// A step the report does not mention at all is treated as un-run and
  /// reported as such: claiming it applied because no reason was printed is
  /// exactly the silent pass this pipeline refuses.
  static String? _skipReasonFor(Map<String, dynamic> report, int index) {
    final inner = report['report'];
    final steps = inner is Map<String, dynamic> ? inner['steps'] : null;
    if (steps is! List) {
      return 'the render answered without a step report, so nothing states '
          'whether the operation ran';
    }
    for (final entry in steps) {
      if (entry is! Map<String, dynamic>) continue;
      if (entry['index'] != index) continue;
      final outcome = entry['outcome'];
      if (outcome == 'applied') return null;
      final reason = entry['reason'];
      if (reason is String && reason.isNotEmpty) return reason;
      return 'the render recorded the step as "$outcome"';
    }
    return 'the render report carries no entry for step $index, so nothing '
        'states whether the operation ran';
  }

  /// Insert [candidate] into [steps] at its place in [kDraftStepOrder].
  static List<Map<String, dynamic>> _insertInDraftOrder(
    List<Map<String, dynamic>> steps,
    Map<String, dynamic> candidate,
  ) {
    final rank = kDraftStepOrder.indexOf(candidate['opId'] as String);
    final out = List<Map<String, dynamic>>.from(steps);
    for (var i = 0; i < out.length; i++) {
      final other = out[i]['opId'];
      final otherRank = other is String ? kDraftStepOrder.indexOf(other) : -1;
      if (otherRank > rank) {
        out.insert(i, candidate);
        return out;
      }
    }
    out.add(candidate);
    return out;
  }

  static String _envelope(
    String recipeId,
    String baseMasterRef,
    List<Map<String, dynamic>> steps,
  ) {
    return jsonEncode({
      'id': recipeId,
      'schemaVersion': kRecipeSchemaVersion,
      'baseMasterRef': baseMasterRef,
      'createdBy': 'autopilot',
      'steps': steps,
    });
  }
}
