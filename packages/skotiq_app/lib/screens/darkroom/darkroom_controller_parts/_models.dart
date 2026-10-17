part of '../darkroom_controller.dart';

/// What the `/darkroom` route was asked to open.
///
/// Both ids are nullable and both may be absent: a deep link that names neither
/// (or names one that is not an integer) resolves to [DarkroomScope.empty],
/// which the screen renders as an empty state rather than crashing on a bad
/// link. It is the family key, so it carries value equality.
@immutable
class DarkroomScope {
  /// `recipes.id` to open, or null when the link named a master instead.
  final int? recipeId;

  /// `integrated_masters.id` whose recipes are offered, or null.
  final int? masterId;

  const DarkroomScope({this.recipeId, this.masterId});

  /// A recipe opened by row id.
  const DarkroomScope.recipe(int id) : this(recipeId: id);

  /// A master opened by row id; its newest recipe is loaded, and when it has
  /// none the screen offers to create one.
  const DarkroomScope.master(int id) : this(masterId: id);

  /// The link named nothing this screen can open.
  const DarkroomScope.empty() : this();

  /// True when neither id was supplied.
  bool get isEmpty => recipeId == null && masterId == null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DarkroomScope &&
          other.recipeId == recipeId &&
          other.masterId == masterId;

  @override
  int get hashCode => Object.hash(recipeId, masterId);

  @override
  String toString() => 'DarkroomScope(recipe=$recipeId, master=$masterId)';
}

/// One operation invocation in the edited recipe.
///
/// The field names are the recipe engine's own wire keys (`opId`, `opVersion`,
/// `params`, `enabled`); the engine decodes with `deny_unknown_fields`, so a key
/// this class invents would be refused rather than ignored — which is why
/// [identity] is an app-side field that [toJson] never writes.
@immutable
class DarkroomStep {
  /// Registry id of the operation (`background_extract`, `stretch`, …).
  final String opId;

  /// Registry version. A recipe keeps rendering with the version it was written
  /// with, so the editor never rewrites this on its own.
  final int opVersion;

  /// The operation's parameters. A key that is absent means the operation reads
  /// its own documented default, which is why the editor writes a key only when
  /// the operator moves that control.
  final Map<String, dynamic> params;

  /// `false` renders as if the step were absent while the step and its
  /// parameters survive — the non-destructive disable.
  final bool enabled;

  /// This step's identity for the lifetime of the editor session.
  ///
  /// Every edit rebuilds the step as a new immutable value, so the OBJECT is
  /// not a usable identity and the POSITION is not one either — a step moves,
  /// and steps in front of it come and go. Two things join on this token
  /// instead of on list order: the widget key of the step card, so a parameter
  /// change re-renders the card rather than tearing it down mid-gesture, and
  /// the per-step verdicts and render outcomes, so a report can never be read
  /// onto a step the engine never had.
  ///
  /// Fresh for a step decoded from the row or built by a draft; carried
  /// unchanged through [copyWith] and [withParam], which produce the SAME step
  /// with something adjusted.
  final Object identity;

  DarkroomStep({
    required this.opId,
    required this.opVersion,
    required this.params,
    required this.enabled,
    Object? identity,
  }) : identity = identity ?? Object();

  /// Decode one entry of a stored `steps_json` array.
  ///
  /// Throws [DarkroomRecipeFormatException] when a required key is missing or
  /// carries the wrong type: a step with no `opId` names no operation, and
  /// substituting one would render a recipe the operator never wrote.
  ///
  /// [index] is the entry's 0-based position in the array — the caller's own
  /// loop counter — and every sentence below counts it from 1, the way the
  /// engine's own refusals do and the way the step cards, the move buttons and
  /// the export filenames all count. The number the operator reads names the
  /// same step whichever surface reports the fault.
  factory DarkroomStep.fromJson(Object? raw, {required int index}) {
    final ordinal = index + 1;
    if (raw is! Map<String, dynamic>) {
      throw DarkroomRecipeFormatException(
        'step $ordinal is ${darkroomJsonKind(raw)}, and every step is a JSON '
        'object',
      );
    }
    final opId = raw['opId'];
    if (opId is! String || opId.isEmpty) {
      throw DarkroomRecipeFormatException(
        'step $ordinal names no operation (its "opId" is ${raw['opId']})',
      );
    }
    final version = raw['opVersion'];
    if (version is! int) {
      throw DarkroomRecipeFormatException(
        'step $ordinal ($opId) carries no integer "opVersion", so no '
        'registered operation version can be matched to it',
      );
    }
    // A step written without the key states nothing about whether it renders,
    // and the engine's own schema requires it — so its absence is a format
    // fault rather than an implied "on".
    final enabled = raw['enabled'];
    if (enabled is! bool) {
      throw DarkroomRecipeFormatException(
        'step $ordinal ($opId) carries no boolean "enabled", so whether it '
        'renders is unstated',
      );
    }
    // An absent parameter object is the engine's own documented default (its
    // serde default is the empty object), so it decodes to no overrides.
    final params = raw['params'];
    return DarkroomStep(
      opId: opId,
      opVersion: version,
      params: params is Map<String, dynamic>
          ? Map<String, dynamic>.from(params)
          : const <String, dynamic>{},
      enabled: enabled,
    );
  }

  /// The wire form the recipe engine decodes.
  Map<String, dynamic> toJson() => {
        'opId': opId,
        'opVersion': opVersion,
        'params': params,
        'enabled': enabled,
      };

  DarkroomStep copyWith({Map<String, dynamic>? params, bool? enabled}) {
    return DarkroomStep(
      opId: opId,
      opVersion: opVersion,
      params: params ?? this.params,
      enabled: enabled ?? this.enabled,
      identity: identity,
    );
  }

  /// The same step with [name] set to [value], or removed when [value] is null.
  ///
  /// Removing restores the operation's own documented default rather than
  /// freezing today's value into the recipe.
  DarkroomStep withParam(String name, Object? value) {
    final next = Map<String, dynamic>.from(params);
    if (value == null) {
      next.remove(name);
    } else {
      next[name] = value;
    }
    return copyWith(params: next);
  }

  @override
  String toString() => 'DarkroomStep($opId@$opVersion, enabled=$enabled)';
}

/// A stored recipe, or a registry reply, could not be read as this build's
/// recipe format.
class DarkroomRecipeFormatException implements Exception {
  /// What is wrong with the document, in the vocabulary of the file — the
  /// sentence an operator is shown.
  final String message;

  /// What the reader underneath said, when a reader was what refused.
  ///
  /// Carried apart from [message] because a parser fragment ("Unexpected
  /// character") names nothing the operator chose and nothing they can do: it
  /// may FOLLOW the sentence, attributed to the reader that produced it, and it
  /// may never be the sentence. A refusal this build composes itself carries
  /// none.
  final String? detail;

  const DarkroomRecipeFormatException(this.message, {this.detail});

  @override
  String toString() => 'The stored recipe cannot be read: $message'
      '${detail == null ? '' : ' ($detail)'}';
}

/// The domain an operation emits: the rule that orders the stack.
enum DarkroomOpStage {
  /// Emits linear pixels. A linear operation cannot run after a stretched one.
  linear,

  /// Emits stretched (display-domain) pixels.
  stretched,

  /// The registry named a stage this build does not model. The editor states
  /// the token rather than guessing which side of the stretch it belongs on.
  unmodelled;

  /// The wire token, or [DarkroomOpStage.unmodelled] when it is not one this
  /// build knows.
  static DarkroomOpStage fromWire(String? wire) {
    switch (wire) {
      case 'linear':
        return DarkroomOpStage.linear;
      case 'stretched':
        return DarkroomOpStage.stretched;
      default:
        return DarkroomOpStage.unmodelled;
    }
  }

  /// The words the step card prints.
  String get label {
    switch (this) {
      case DarkroomOpStage.linear:
        return 'Linear';
      case DarkroomOpStage.stretched:
        return 'Stretched';
      case DarkroomOpStage.unmodelled:
        return 'Stage unstated';
    }
  }
}

/// The JSON type of one operation parameter, as the registry publishes it.
enum DarkroomParamKind {
  /// A finite float.
  number,

  /// A non-negative integer.
  integer,

  /// One of the spec's `allowed` tokens.
  enumerated,

  /// A fixed-length array of finite floats.
  numberArray,

  /// A variable-length array of finite floats.
  numberList,

  /// The registry named a type this build's editor draws no control for. The
  /// value is shown as its JSON text and left alone, which is the only honest
  /// rendering: inventing a control for an unknown type would write values the
  /// operation may refuse.
  unrepresented;

  static DarkroomParamKind fromWire(String? wire) {
    switch (wire) {
      case 'number':
        return DarkroomParamKind.number;
      case 'integer':
        return DarkroomParamKind.integer;
      case 'enum':
        return DarkroomParamKind.enumerated;
      case 'numberArray':
        return DarkroomParamKind.numberArray;
      case 'numberList':
        return DarkroomParamKind.numberList;
      default:
        return DarkroomParamKind.unrepresented;
    }
  }
}

/// One parameter of one operation version, as the registry documents it.
@immutable
class DarkroomParamSpec {
  /// Wire key.
  final String name;

  /// What the control's label reads, with the unit the registry states.
  ///
  /// The wire key is the recipe engine's own vocabulary — `d`, `b`,
  /// `blackPoint` — and a control labelled with it asks the operator to know
  /// the engine's field names. The registry publishes a display name beside
  /// every key; when it publishes none this falls back to [name], because the
  /// wire key is then the only name that exists and inventing a prettier one
  /// would label the control with something no schema states.
  final String displayName;

  /// The type token exactly as the registry wrote it, so an unmodelled kind can
  /// be named in the message that explains why it has no control.
  final String kindWire;

  final DarkroomParamKind kind;

  /// Whether the payload must carry it.
  final bool required;

  /// Lowest accepted value, or null when the registry states no floor.
  final double? min;

  /// Highest accepted value, or null when the registry states no ceiling.
  final double? max;

  /// Exact element count for a `numberArray`.
  final int? length;

  /// Accepted tokens for an `enum`; empty for every other kind.
  final List<String> allowed;

  /// The value the operation reads when the key is absent, or null when the
  /// parameter is required (or when its absence means something other than a
  /// value).
  final Object? defaultValue;

  /// Whether the parameter is validated on its own. `false` means it is
  /// constrained jointly with another one, so a control that changed it alone
  /// could be refused for a reason its own range does not show.
  final bool independent;

  /// What the parameter does, in the registry's words.
  final String summary;

  const DarkroomParamSpec({
    required this.name,
    required this.displayName,
    required this.kindWire,
    required this.kind,
    required this.required,
    required this.min,
    required this.max,
    required this.length,
    required this.allowed,
    required this.defaultValue,
    required this.independent,
    required this.summary,
  });

  /// True when a continuous control can span this parameter's range.
  ///
  /// A slider over `blackPoint`'s documented ±1e12 range moves by 4×10⁹ per
  /// pixel of travel, so wide-ranged parameters take a typed field instead. The
  /// threshold is a span a slider can resolve to roughly one part in a thousand
  /// across a panel a few hundred pixels wide.
  bool get isSliderRanged {
    final lo = min;
    final hi = max;
    if (lo == null || hi == null) return false;
    if (!lo.isFinite || !hi.isFinite) return false;
    final span = hi - lo;
    return span > 0 && span <= kDarkroomSliderMaxSpan;
  }
}

/// One registered operation version, as the registry documents it.
@immutable
class DarkroomOpSpec {
  final String id;
  final int version;
  final DarkroomOpStage stage;

  /// The stage token exactly as the registry wrote it.
  final String stageWire;

  final String summary;
  final List<DarkroomParamSpec> params;

  const DarkroomOpSpec({
    required this.id,
    required this.version,
    required this.stage,
    required this.stageWire,
    required this.summary,
    required this.params,
  });

  /// The spec for [name], or null when this operation has no such parameter.
  DarkroomParamSpec? param(String name) {
    for (final spec in params) {
      if (spec.name == name) return spec;
    }
    return null;
  }
}

/// The operation catalogue this build renders.
@immutable
class DarkroomCatalog {
  /// Every registered `(id, version)` with its stage and parameter table.
  final List<DarkroomOpSpec> ops;

  const DarkroomCatalog(this.ops);

  /// The documentation for one step's operation, or null when this build
  /// registers no such version — which is exactly what `validate` reports as an
  /// unregistered step.
  DarkroomOpSpec? specFor(DarkroomStep step) {
    for (final op in ops) {
      if (op.id == step.opId && op.version == step.opVersion) return op;
    }
    return null;
  }
}

/// What a render did with one step.
enum DarkroomStepOutcome {
  /// The operation ran and changed the image.
  applied,

  /// The step was toggled off, so the render skipped it by the operator's own
  /// instruction.
  disabled,

  /// The operation declined to run and said why. This is not a failure, and the
  /// reason is always shown.
  skipped,

  /// The render report carried no line for this step. Treating that as
  /// "applied" would claim an operation ran when nothing says it did.
  unreported;

  static DarkroomStepOutcome fromWire(String? wire) {
    switch (wire) {
      case 'applied':
        return DarkroomStepOutcome.applied;
      case 'disabled':
        return DarkroomStepOutcome.disabled;
      case 'skipped':
        return DarkroomStepOutcome.skipped;
      default:
        return DarkroomStepOutcome.unreported;
    }
  }
}

/// One line of a render report: what happened to the step at [index].
@immutable
class DarkroomStepReport {
  final int index;

  /// The operation the engine named for this line. The step card renders the
  /// recipe's own `(opId, opVersion)`; this is what the report attributed the
  /// outcome to, so a mismatch is visible rather than hidden.
  final String opId;

  final DarkroomStepOutcome outcome;

  /// Why the operation declined, when it did. Null for every other outcome.
  final String? reason;

  /// What the operation measured while applying, verbatim from the report.
  /// An applied step is not always applied as written — crop publishes
  /// `clampedToImage` here when the recipe's rectangle did not fit the master
  /// it replayed over — and a card that ignores this wears plain "Applied"
  /// over an adjustment the engine stated.
  final Map<String, dynamic>? measured;

  const DarkroomStepReport({
    required this.index,
    required this.opId,
    required this.outcome,
    required this.reason,
    this.measured,
  });
}

/// What `validate` said about the step at [index].
@immutable
class DarkroomStepIssue {
  final int index;

  /// Whether this build registers the step's `(opId, opVersion)`.
  final bool registered;

  /// Whether the step's parameters passed the operation's own validation.
  final bool valid;

  /// The engine's message, in its own words. Null when the step is valid.
  final String? error;

  /// The newest version this build registers for the step's operation, when the
  /// step's own version is not registered.
  final int? latestVersion;

  const DarkroomStepIssue({
    required this.index,
    required this.registered,
    required this.valid,
    required this.error,
    required this.latestVersion,
  });

  /// True when the step renders as written.
  bool get isClean => registered && valid;
}

/// The verdict of one `validate` call over a candidate step list.
@immutable
class DarkroomValidation {
  /// Whether the whole recipe validates — the ordering rules included.
  final bool ok;

  /// The engine's message for the recipe as a whole, null when [ok].
  final String? error;

  /// One entry per step, in order.
  final List<DarkroomStepIssue> steps;

  const DarkroomValidation({
    required this.ok,
    required this.error,
    required this.steps,
  });
}

/// What the engine did to turn a render into the RGBA the viewport paints.
///
/// The engine answers with an OBJECT, never a sentence: which transfer it
/// applied, which domain the render was in when it applied it, and — when the
/// transfer was the screen one — that transfer's own parameters. The three are
/// separate facts and none stands in for another: a screen transfer over
/// still-linear pixels is a display-only lift that no export carries, while
/// unit encoding of stretched pixels IS the recipe's own output.
@immutable
class DarkroomEncoding {
  /// The transfer the engine applied — `screen` for the display lift, `unit`
  /// for the render's own samples. Null when the reply named none.
  final String? applied;

  /// The domain the render was in — `linear` or `stretched`. Null when the
  /// reply named none.
  final String? sourceDomain;

  /// The screen transfer's own parameters, when the engine applied one and
  /// named them. Null otherwise.
  final Map<String, dynamic>? screenTransfer;

  const DarkroomEncoding({
    required this.applied,
    required this.sourceDomain,
    required this.screenTransfer,
  });

  /// The reply carried no encoding block, so nothing about the transfer is
  /// known. Rendered as the engine having named nothing rather than as any
  /// particular transfer.
  static const DarkroomEncoding unstated = DarkroomEncoding(
    applied: null,
    sourceDomain: null,
    screenTransfer: null,
  );

  /// The strip's sentence: what was applied, over what, and which half the
  /// engine left unstated when it left one unstated.
  String get sentence {
    final transfer = switch (applied) {
      'screen' => 'a screen transfer, applied for display only',
      'unit' => 'the render\'s own samples, unchanged',
      null => null,
      final String named => 'a transfer the engine named "$named"',
    };
    final domain = switch (sourceDomain) {
      'linear' => 'still-linear pixels',
      'stretched' => 'stretched pixels',
      null => null,
      final String named => 'pixels the engine called "$named"',
    };
    if (transfer == null && domain == null) {
      return 'the engine did not name the display transfer it applied';
    }
    if (domain == null) {
      return '$transfer, over pixels whose domain the engine did not name';
    }
    if (transfer == null) {
      return 'over $domain, through a transfer the engine did not name';
    }
    return '$transfer, over $domain';
  }

  /// [sentence], so a caller that interpolates this value states the same fact
  /// the strip does rather than a Dart type name.
  @override
  String toString() => sentence;
}

/// The pixels of one render, in the shape [AstroImageViewer] decodes.
@immutable
class DarkroomPreviewImage {
  final int width;
  final int height;
  final bool isColor;

  /// Row-major RGBA8 samples, four bytes per pixel.
  final Uint8List rgba;

  /// The display transfer the engine applied — a still-linear stage is shown
  /// through a screen transfer, and saying so is what keeps the picture from
  /// being read as the recipe's own output.
  final DarkroomEncoding encoding;

  /// The pyramid level rendered (level 0 is the master's own pixels), or null
  /// when the reply named none.
  final int? level;

  /// Rendered pixels per master pixel at [level] — `1.0` at level 0, `0.5` one
  /// level down, and so on. The zoom readout multiplies by it so the percentage
  /// on screen is relative to the MASTER, not to whichever level happened to be
  /// cheap enough to render. Null when the reply stated no scale, and the
  /// readout then says so rather than claiming master-resolution pixels.
  final double? scaleFromMaster;

  const DarkroomPreviewImage({
    required this.width,
    required this.height,
    required this.isColor,
    required this.rgba,
    required this.encoding,
    required this.level,
    required this.scaleFromMaster,
  });
}

/// A master that has no recipe yet, and the two ways to give it one.
@immutable
class DarkroomStartOffer {
  final int masterId;

  /// The target the master was integrated for, carried onto the new recipe so
  /// the row keeps the same identity the master has.
  final int? targetId;

  final String masterName;
  final String masterFitsPath;
  final int channels;
  final int width;
  final int height;

  const DarkroomStartOffer({
    required this.masterId,
    required this.targetId,
    required this.masterName,
    required this.masterFitsPath,
    required this.channels,
    required this.width,
    required this.height,
  });

  /// True when the master has the three channels the color calibration fits.
  bool get isColor => channels == 3;
}
