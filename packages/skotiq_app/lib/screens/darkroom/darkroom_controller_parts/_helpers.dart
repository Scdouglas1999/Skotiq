part of '../darkroom_controller.dart';

/// How long the editor waits after the last edit before it renders.
///
/// A parameter drag emits a value per frame; rendering each one would queue
/// renders the operator has already superseded. The wait is short enough that a
/// released slider feels immediate and long enough that a drag produces one
/// render at its end.
const Duration kDarkroomRenderDebounce = Duration(milliseconds: 250);

/// How long the editor waits after the last edit before writing the recipe row.
///
/// Longer than the render debounce: pixels are what the operator is watching,
/// the row is what survives the session.
const Duration kDarkroomSaveDebounce = Duration(milliseconds: 750);

/// How long consecutive edits from one control fold into a single undo step.
///
/// Long enough to span a slider drag's frame-by-frame values and the pauses in
/// typing a number; short enough that two deliberate nudges of the same control
/// stay two undo steps.
const Duration kDarkroomEditCoalesceWindow = Duration(milliseconds: 1200);

/// Longest edge, in pixels, the interactive preview renders at.
///
/// The render is a synchronous descent into the engine, so the preview is
/// deliberately a screen-sized level rather than the master's own: the full
/// resolution belongs to export.
const int kDarkroomPreviewMaxDimension = 1600;

/// Widest parameter range a slider is given.
///
/// Chosen against the registry's own table: it keeps a slider on the ranges an
/// operator nudges (`sampleSpacing` 8–1024, `magLimit` 5–22, `strength` 0–1)
/// and hands a typed field to the ones a slider cannot resolve — `minStars`
/// (8–100 000), the crop rectangle (1–1 000 000) and the stretch's ±1e12 black
/// and white points. See [DarkroomParamSpec.isSliderRanged].
const double kDarkroomSliderMaxSpan = 10000.0;

/// Registry id of the color calibration.
///
/// The one operation the editor lends catalogue photometry to, so it is the one
/// step whose presence decides whether a missing catalogue is worth reporting.
const String kDarkroomColorCalibrateOpId = 'color_calibrate';

/// The operations the recipe engine defines a result for on THREE channels
/// only, with what each one states it requires — the `expected` clause of its
/// own `unsupported channel layout` refusal, word for word.
///
/// The registry's published catalogue carries an operation's stage and its
/// parameter table and nothing about channels, so this is the one precondition
/// the chooser cannot read off the catalogue. It is stated here rather than
/// discovered by a failed render: a mono master accepted `Color calibrate`,
/// wrote the step into the recipe, and the next render came back refused with
/// the picture left stale until the operator found and removed the step —
/// while the Recipe panel two inches away already said the master has one
/// channel and the colour fit needs three.
///
/// Every operation this build registers preserves the channel count, so the
/// master's own count is the count that reaches the step wherever it lands.
const Map<String, String> kDarkroomThreeChannelOps = {
  kDarkroomColorCalibrateOpId:
      'a colour master with 3 channels; combine a per-filter mono master first',
  'saturation': 'a colour master with 3 channels',
};

/// Wire schema version of the recipe envelope this build writes. It matches the
/// recipe engine's `RECIPE_SCHEMA_VERSION`; an envelope at any other version is
/// refused by the engine rather than reinterpreted.
const int kDarkroomRecipeSchemaVersion = 1;

/// The recipe envelope the Darkroom entry points take.
///
/// `steps_json` in the database stores the step array alone — the envelope's
/// schema version lives in the row's own column — so the envelope is rebuilt
/// here for every call rather than stored twice.
String encodeDarkroomRecipe({
  required int recipeId,
  required String baseMasterRef,
  required RecipeAuthor author,
  required List<DarkroomStep> steps,
}) {
  return jsonEncode({
    'id': '$recipeId',
    'schemaVersion': kDarkroomRecipeSchemaVersion,
    'baseMasterRef': baseMasterRef,
    'createdBy': author.wire,
    'steps': [for (final step in steps) step.toJson()],
  });
}

/// Decode a stored `recipes.steps_json` payload.
///
/// Throws [DarkroomRecipeFormatException] when the payload is not a step array;
/// the screen surfaces the message rather than opening an editor over a recipe
/// it could not read.
List<DarkroomStep> decodeDarkroomSteps(String stepsJson) {
  final Object? decoded;
  try {
    decoded = jsonDecode(stepsJson);
  } on FormatException catch (error) {
    throw DarkroomRecipeFormatException(
      'the stored step list is not JSON: ${error.message}',
    );
  }
  if (decoded is! List) {
    throw DarkroomRecipeFormatException(
      'the stored step list is ${darkroomJsonKind(decoded)}, and a recipe '
      'stores a JSON array of steps',
    );
  }
  return [
    for (var i = 0; i < decoded.length; i++)
      DarkroomStep.fromJson(decoded[i], index: i),
  ];
}

/// Name a decoded JSON value the way JSON names it.
///
/// The refusals below tell the operator what the row holds instead of a step
/// list, and `jsonDecode` answers with Dart's own private implementation
/// classes — `_Map<String, dynamic>`, `_GrowableList` — whose spelling means
/// nothing to anyone reading the screen. This says "a JSON object" instead,
/// which is the same fact in the vocabulary of the file being read.
String darkroomJsonKind(Object? value) {
  if (value == null) return 'null';
  if (value is Map) return 'a JSON object';
  if (value is List) return 'a JSON array';
  if (value is String) return 'a JSON string';
  if (value is num) return 'a JSON number';
  if (value is bool) return 'a JSON boolean';
  return 'not a value JSON can carry';
}

/// Read a JSON number as a double, or null when the value is not a finite
/// number. Absence is reported as absence — never as zero.
double? darkroomNumber(Object? value) {
  if (value is int) return value.toDouble();
  if (value is double) return value.isFinite ? value : null;
  return null;
}

/// Read a JSON number as an int, or null when the value is not an integral
/// number.
int? darkroomInteger(Object? value) {
  if (value is int) return value;
  if (value is double && value.isFinite && value == value.roundToDouble()) {
    return value.toInt();
  }
  return null;
}

/// Decode the operation catalogue from a `registry` reply.
///
/// Throws [DarkroomRecipeFormatException] when the reply names no operations:
/// an editor drawing controls without the ranges behind them would let the
/// operator write values the operation refuses.
DarkroomCatalog decodeDarkroomCatalog(Map<String, dynamic> reply) {
  final ops = reply['ops'];
  if (ops is! List) {
    throw const DarkroomRecipeFormatException(
      'the operation registry answered without an operation list, so no '
      'parameter ranges are known',
    );
  }
  final specs = <DarkroomOpSpec>[];
  for (final raw in ops) {
    if (raw is! Map<String, dynamic>) continue;
    final id = raw['id'];
    final version = darkroomInteger(raw['version']);
    if (id is! String || version == null) continue;
    final stageWire = raw['stage'];
    final summary = raw['summary'];
    final params = raw['params'];
    specs.add(
      DarkroomOpSpec(
        id: id,
        version: version,
        stage: DarkroomOpStage.fromWire(stageWire is String ? stageWire : null),
        stageWire: stageWire is String ? stageWire : 'unstated',
        summary: summary is String ? summary : '',
        params: params is List ? _decodeParams(params) : const [],
      ),
    );
  }
  if (specs.isEmpty) {
    throw const DarkroomRecipeFormatException(
      'the operation registry named no operations this build can render',
    );
  }
  return DarkroomCatalog(List.unmodifiable(specs));
}

List<DarkroomParamSpec> _decodeParams(List<dynamic> raw) {
  final out = <DarkroomParamSpec>[];
  for (final entry in raw) {
    if (entry is! Map<String, dynamic>) continue;
    final name = entry['name'];
    if (name is! String) continue;
    final displayName = entry['displayName'];
    final kindWire = entry['kind'];
    final allowed = entry['allowed'];
    final required = entry['required'];
    final independent = entry['independent'];
    final summary = entry['summary'];
    out.add(
      DarkroomParamSpec(
        name: name,
        // The wire key when the registry publishes no display name: a build
        // whose catalogue predates the field labels its controls with the key
        // it does have rather than with a name this file made up.
        displayName: displayName is String && displayName.trim().isNotEmpty
            ? displayName.trim()
            : name,
        kindWire: kindWire is String ? kindWire : 'unstated',
        kind: DarkroomParamKind.fromWire(kindWire is String ? kindWire : null),
        required: required is bool && required,
        min: darkroomNumber(entry['min']),
        max: darkroomNumber(entry['max']),
        length: darkroomInteger(entry['length']),
        allowed: allowed is List
            ? List.unmodifiable(allowed.whereType<String>())
            : const [],
        defaultValue: entry['default'],
        // A parameter the registry does not describe as jointly constrained is
        // validated on its own; the flag is present on every row this build
        // publishes, and a missing flag is read as the stricter case so the
        // editor validates the pair rather than assuming it may not have to.
        independent: independent is bool && independent,
        summary: summary is String ? summary : '',
      ),
    );
  }
  return List.unmodifiable(out);
}

/// Decode the first-draft recipe out of a `registry` reply that carried a
/// `masterPath`.
///
/// Throws [DarkroomRecipeFormatException] when the reply carries no draft:
/// "draft for me" that silently produced an empty stack would look like an
/// operation that ran and decided on nothing.
List<DarkroomStep> decodeDarkroomDraft(Map<String, dynamic> reply) {
  final draft = reply['draft'];
  if (draft is! Map<String, dynamic>) {
    throw const DarkroomRecipeFormatException(
      'the operation registry answered without a draft, so there are no '
      'measured parameters to build one from',
    );
  }
  final recipe = draft['recipe'];
  if (recipe is! Map<String, dynamic>) {
    throw const DarkroomRecipeFormatException(
      'the registry draft carries no recipe, so it names no operations',
    );
  }
  final steps = recipe['steps'];
  if (steps is! List) {
    throw const DarkroomRecipeFormatException(
      'the registry draft recipe carries no step list',
    );
  }
  return [
    for (var i = 0; i < steps.length; i++)
      DarkroomStep.fromJson(steps[i], index: i),
  ];
}

/// A decoded draft after the identity rule has been applied: the steps it
/// carries, and the account of the one it dropped.
///
/// Modelled rather than returned as a bare list because the omission is a fact
/// the recipe row has to store: a stack that silently arrives one step shorter
/// than the registry proposed is a stack hiding one of its own decisions.
class DarkroomDraftSteps {
  /// The steps the draft carries.
  final List<DarkroomStep> steps;

  /// Why the drafted crop was left out, or null when the draft kept the crop —
  /// or was never offered one.
  final String? omittedCropReason;

  const DarkroomDraftSteps({
    required this.steps,
    required this.omittedCropReason,
  });
}

/// [steps] without a crop whose rectangle covers the whole [width]×[height]
/// master.
///
/// The registry proposes a crop for every master, measured as the area every
/// registered frame covers. When the frames all cover the same pixels that area
/// IS the frame, and the step trims nothing — so "Draft for me" wrote
/// `{x: 0, y: 0, width: W, height: H}` over a W×H master and its card read
/// "Applied by the last render" over an operation that moved no pixel.
///
/// The rule and its wording are [darkroomCropIsIdentity] and
/// [darkroomIdentityCropReason], which the dawn autopilot's own draft builder
/// uses: one rule, so the draft an operator asks for and the draft that arrives
/// at dawn decide this the same way.
DarkroomDraftSteps darkroomDropIdentityCrop(
  List<DarkroomStep> steps, {
  required int width,
  required int height,
}) {
  String? reason;
  final kept = <DarkroomStep>[];
  for (final step in steps) {
    if (step.opId == 'crop' &&
        darkroomCropIsIdentity(step.params, width: width, height: height)) {
      reason = darkroomIdentityCropReason(width, height);
      continue;
    }
    kept.add(step);
  }
  return DarkroomDraftSteps(steps: kept, omittedCropReason: reason);
}

/// The notes the registry recorded while composing a draft — the operations it
/// decided about and did not carry. Empty when the reply carried none.
List<RecipeDraftNote> decodeDarkroomDraftNotes(Map<String, dynamic> reply) {
  final draft = reply['draft'];
  if (draft is! Map<String, dynamic>) return const [];
  final notes = draft['notes'];
  if (notes is! List) return const [];
  final out = <RecipeDraftNote>[];
  for (final entry in notes) {
    if (entry is! Map<String, dynamic>) continue;
    final opId = entry['opId'];
    final reason = entry['reason'];
    final outcome = entry['outcome'];
    if (opId is! String) continue;
    out.add(
      RecipeDraftNote(
        opId: opId,
        outcome: outcome is String ? outcome : 'omitted',
        reason: reason is String && reason.isNotEmpty
            ? reason
            : 'the operation registry stated no reason',
      ),
    );
  }
  return List.unmodifiable(out);
}

/// The whole composition account for a draft: the registry's own [notes], plus
/// one `included` line for every step it DID carry that no note already covers.
///
/// The same account the dawn pass records for its own drafts, built here so the
/// two paths store one shape. It is what makes "this stack was drafted" a fact
/// the row carries rather than a guess: a colour master's draft can leave
/// nothing out, and without the included lines its account would be empty and
/// indistinguishable from a recipe written by hand.
List<RecipeDraftNote> darkroomComposedAccount(
  List<DarkroomStep> steps,
  List<RecipeDraftNote> notes,
) {
  final account = <RecipeDraftNote>[...notes];
  for (final step in steps) {
    if (account.any((note) => note.opId == step.opId)) continue;
    account.add(
      RecipeDraftNote(
        opId: step.opId,
        outcome: 'included',
        reason: 'measured from this master by the operation registry',
      ),
    );
  }
  return List.unmodifiable(account);
}

/// One draft note as the editor prints it.
///
/// The operation is named the way every step card names it — "Background
/// extract", not `background_extract` — so a note and the stack it is about do
/// not read as two different vocabularies.
String darkroomDraftNoteSentence(RecipeDraftNote note) =>
    '${darkroomOpTitle(note.opId)} — ${note.outcome}: ${note.reason}';

/// What the operator can do about a failure that is about the base master
/// itself, or null when the failure is about something else.
///
/// Every base-master refusal the engine raises quotes the path it was handed —
/// `cannot read`, `is not renderable`, `cannot build a preview pyramid for`,
/// each of them naming the file in single quotes — so a message carrying the
/// recipe's own base-master path in quotes is
/// a failure about the FILE rather than about a step in the stack. That
/// distinction is the whole test: it is read off the message the engine wrote
/// and the path this recipe was opened over, never guessed from the wording of
/// an OS error.
///
/// The two acts named are the only two that recover it, and both are outside
/// this screen — which is why the failure card, whose one control re-runs the
/// render that just failed, cannot carry the answer on its own.
///
/// Returns null for a step failure: re-integrating a night does not fix an
/// operation that refused its parameters, and offering it as the next step
/// would send the operator to rebuild a master that is perfectly fine.
String? darkroomMasterFailureNextStep(String message, String masterPath) {
  if (masterPath.isEmpty || !message.contains("'$masterPath'")) return null;
  return 'The Darkroom only ever reads that file, so nothing here can put it '
      'back: restore the master at that path, or re-integrate this night in '
      'Session Review to write it again.';
}

/// A `.nsrecipe` file the operator chose, and what it holds.
@immutable
class DarkroomSidecarPick {
  /// Absolute path of the chosen file, so the import can say what it read.
  final String path;

  /// The file's text, exactly as it was on disk.
  final String text;

  const DarkroomSidecarPick({required this.path, required this.text});
}

/// Choose and read a `.nsrecipe` sidecar, as a seam a test can script.
///
/// Both halves are unavailable inside a widget test — the platform file chooser
/// and the read off disk — so they are one overridable function rather than two
/// calls the import path makes directly. Answers null when the operator backed
/// out of the chooser.
typedef DarkroomSidecarReader = Future<DarkroomSidecarPick?> Function();

Future<DarkroomSidecarPick?> _defaultDarkroomSidecarReader() async {
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(
        label: 'Skotiq recipe sidecar',
        extensions: ['nsrecipe'],
      ),
    ],
    confirmButtonText: 'Import recipe',
  );
  if (file == null) return null;
  // XFile's own read, not `dart:io`: the chooser already handed back a handle,
  // and on the platforms whose chooser returns a content URI rather than a path
  // that handle is the only thing that can be read.
  return DarkroomSidecarPick(path: file.path, text: await file.readAsString());
}

/// Override point for the `.nsrecipe` import source (tests script this).
final darkroomSidecarReaderProvider = Provider<DarkroomSidecarReader>(
  (ref) => _defaultDarkroomSidecarReader,
);

/// A `.nsrecipe` sidecar, read back.
///
/// The sidecar is what an export writes beside its file so the recipe survives
/// outside the database. This is the reader for it: the same document, decoded
/// into the step list the editor edits, plus the provenance the sidecar carries
/// about the pixels it was written over.
@immutable
class DarkroomImportedRecipe {
  /// The steps the sidecar stored, in application order.
  final List<DarkroomStep> steps;

  /// The master the sidecar's export was rendered from, when it named one.
  /// Never used as the imported recipe's base — the import writes a recipe over
  /// the master the operator is looking at — but stated, so an import over a
  /// different master says so.
  final String? masterPath;

  /// The recipe fingerprint the exporting build computed, when it recorded one.
  final String? fingerprint;

  /// The recipe schema version the sidecar declares, when it declares one.
  final int? schemaVersion;

  const DarkroomImportedRecipe({
    required this.steps,
    required this.masterPath,
    required this.fingerprint,
    required this.schemaVersion,
  });
}

/// Decode a `.nsrecipe` sidecar document.
///
/// Throws [DarkroomRecipeFormatException] naming what the file holds instead:
/// an import that silently produced an empty stack would look like a recipe
/// that was read and decided on nothing, and a truncated sidecar is exactly the
/// case this refusal exists for.
DarkroomImportedRecipe decodeDarkroomSidecar(String text) {
  final Object? document;
  try {
    document = jsonDecode(text);
  } on FormatException catch (error) {
    // The reader's own words go in `detail`, never into the sentence: what the
    // operator is shown has to be about the file they chose.
    final offset = error.offset;
    throw DarkroomRecipeFormatException(
      'this file is not JSON, so it carries no recipe to read',
      detail: offset == null
          ? 'The JSON reader stopped: ${error.message}.'
          : 'The JSON reader stopped at character $offset: ${error.message}.',
    );
  }
  if (document is! Map<String, dynamic>) {
    throw DarkroomRecipeFormatException(
      'this file holds ${darkroomJsonKind(document)}, and a .nsrecipe sidecar '
      'is a JSON object',
    );
  }
  final kind = document['kind'];
  if (kind != 'nsrecipe') {
    throw DarkroomRecipeFormatException(
      kind is String
          ? 'this file declares itself a "$kind" document, not the "nsrecipe" '
              'sidecar an export writes'
          : 'this file declares no "kind", so it is not a .nsrecipe sidecar '
              'this build can read',
    );
  }
  final recipe = document['recipe'];
  if (recipe is! Map<String, dynamic>) {
    throw const DarkroomRecipeFormatException(
      'this sidecar carries no recipe object, so it names no operations',
    );
  }
  final steps = recipe['steps'];
  if (steps is! List) {
    throw DarkroomRecipeFormatException(
      'this sidecar\'s recipe carries ${darkroomJsonKind(steps)} where its '
      'step list belongs',
    );
  }
  final masterPath = document['masterPath'] ?? recipe['baseMasterRef'];
  final fingerprint = document['fingerprint'];
  return DarkroomImportedRecipe(
    steps: [
      for (var i = 0; i < steps.length; i++)
        DarkroomStep.fromJson(steps[i], index: i),
    ],
    masterPath:
        masterPath is String && masterPath.isNotEmpty ? masterPath : null,
    fingerprint:
        fingerprint is String && fingerprint.isNotEmpty ? fingerprint : null,
    schemaVersion: darkroomInteger(document['schemaVersion']),
  );
}

/// Decode a `validate` reply.
DarkroomValidation decodeDarkroomValidation(Map<String, dynamic> reply) {
  final ok = reply['ok'];
  final error = reply['error'];
  final steps = reply['steps'];
  final issues = <DarkroomStepIssue>[];
  if (steps is List) {
    for (final entry in steps) {
      if (entry is! Map<String, dynamic>) continue;
      final index = darkroomInteger(entry['index']);
      if (index == null) continue;
      final registered = entry['registered'];
      final valid = entry['valid'];
      final message = entry['error'];
      issues.add(
        DarkroomStepIssue(
          index: index,
          registered: registered is bool && registered,
          valid: valid is bool && valid,
          error: message is String ? message : null,
          latestVersion: darkroomInteger(entry['latestVersion']),
        ),
      );
    }
  }
  return DarkroomValidation(
    ok: ok is bool && ok,
    error: error is String && error.isNotEmpty ? error : null,
    steps: List.unmodifiable(issues),
  );
}

/// Decode the per-step outcomes out of a render report.
///
/// The report the preview carries nests the engine's own report under `report`;
/// a reply without it produces no entries, and the step cards then read
/// "not reported" rather than claiming every operation applied.
List<DarkroomStepReport> decodeDarkroomStepReports(
  Map<String, dynamic> report,
) {
  final inner = report['report'];
  if (inner is! Map<String, dynamic>) return const [];
  final steps = inner['steps'];
  if (steps is! List) return const [];
  final out = <DarkroomStepReport>[];
  for (final entry in steps) {
    if (entry is! Map<String, dynamic>) continue;
    final index = darkroomInteger(entry['index']);
    if (index == null) continue;
    final opId = entry['opId'];
    final outcome = entry['outcome'];
    final reason = entry['reason'];
    final measured = entry['measured'];
    out.add(
      DarkroomStepReport(
        index: index,
        opId: opId is String ? opId : 'unnamed operation',
        outcome: DarkroomStepOutcome.fromWire(
          outcome is String ? outcome : null,
        ),
        reason: reason is String && reason.isNotEmpty ? reason : null,
        measured: measured is Map<String, dynamic> ? measured : null,
      ),
    );
  }
  return List.unmodifiable(out);
}

/// Decode the `encoding` block of a render report.
///
/// The block is an object — `applied`, `sourceDomain`, and `screenTransfer`
/// when the engine lifted the picture for display. A reply that carries no
/// object leaves every field unstated, and the viewport then says the engine
/// named nothing rather than naming a transfer nothing reported.
DarkroomEncoding decodeDarkroomEncoding(Map<String, dynamic> report) {
  final encoding = report['encoding'];
  if (encoding is! Map<String, dynamic>) return DarkroomEncoding.unstated;
  final applied = encoding['applied'];
  final domain = encoding['sourceDomain'];
  final screen = encoding['screenTransfer'];
  return DarkroomEncoding(
    applied: applied is String && applied.isNotEmpty ? applied : null,
    sourceDomain: domain is String && domain.isNotEmpty ? domain : null,
    screenTransfer: screen is Map<String, dynamic> && screen.isNotEmpty
        ? Map<String, dynamic>.unmodifiable(screen)
        : null,
  );
}

/// The pyramid level a render answered at, or null when the reply did not name
/// one. A level nothing states is left unstated rather than assumed to be 0,
/// which would make the zoom readout claim master-resolution pixels.
int? decodeDarkroomLevel(Map<String, dynamic> report) {
  final level = report['level'];
  if (level is! Map<String, dynamic>) return null;
  return darkroomInteger(level['level']);
}

/// Rendered pixels per master pixel for a render, or null when the reply did
/// not state the level's scale.
double? decodeDarkroomScaleFromMaster(Map<String, dynamic> report) {
  final level = report['level'];
  if (level is! Map<String, dynamic>) return null;
  final scale = darkroomNumber(level['scaleFromMaster']);
  if (scale == null || scale <= 0) return null;
  return scale;
}

/// Title-case an operation id for the step card: `background_extract` reads
/// "Background extract".
String darkroomOpTitle(String opId) {
  if (opId.isEmpty) return 'Unnamed operation';
  final words = opId.split('_').where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return opId;
  final first = words.first;
  final head = '${first[0].toUpperCase()}${first.substring(1)}';
  return [head, ...words.skip(1)].join(' ');
}
