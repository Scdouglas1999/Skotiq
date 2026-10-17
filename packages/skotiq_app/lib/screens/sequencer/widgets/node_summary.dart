// Pure, dependency-free at-a-glance summaries for every sequencer node, plus a
// structural classification of which fragments are inline-editable.
//
// This file is deliberately FREE of Flutter widget dependencies. It imports
// only the node model (`skotiq_core`) and `IconData` (from
// `dart:ui`/`package:flutter/foundation` via `lucide_icons`). The rendering
// layer (the sequence-tree row + the inline quick-edit chips) consumes
// [nodeSummary] and decides how to paint each [SummaryFragment]; the styling
// contract (colors / typography / spacing) lives entirely in that widget
// layer so this logic stays trivially unit-testable.
//
// WHY A SEPARATE CLASSIFIER:
// This module produces a terse, structured summary for ALL 38 node subtypes
// and, crucially, marks the handful of properties that are genuinely safe +
// sensible to edit inline (a single scalar / enum / filter pick) as
// [EditableFragment]. Everything else — coordinate entry, watchdog thresholds,
// multi-field config — is rendered as a non-interactive [StaticFragment]. Those
// belong in the full properties panel, not in a one-tap chip, and surfacing
// them as editable would be a footgun.
//
// EDITABLE-VS-STATIC RATIONALE (the contract the tree row and the inline
// editors build against):
//   * Editable  → a single, low-risk value with an obvious widget (number
//                 field, stepper, or a closed dropdown like filter/binning).
//                 Editing it can never silently corrupt coordinate math or a
//                 safety watchdog.
//   * Static    → coordinates (panel-grade entry), watchdog/trigger
//                 thresholds (MeridianFlip, Recovery), multi-field structures
//                 (SmartExposure plans, scheduler weights), and terminal
//                 actions (park, stop guiding) where a one-tap edit has no
//                 single meaningful scalar.
//
// The [nodeSummary] dispatch is an EXHAUSTIVE Dart-3 `switch (node)` over the
// sealed [SequenceNode] hierarchy with NO `_` wildcard: adding a new node
// subtype fails to compile here until its summary is authored. That is the
// whole point — a new instruction can never silently render a blank row.

// `IconData` is the only Flutter type referenced here; importing it with a
// `show` clause keeps this module free of any widget-building surface while
// still letting [SummaryFragment] carry an optional lead icon for the
// renderer to paint.
import 'package:flutter/widgets.dart' show IconData;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../../../utils/count_label.dart';

/// The kind of property an [EditableFragment] edits inline.
///
/// Each value names exactly one genuinely-editable scalar/enum/pick on a
/// specific node type. The set is intentionally small: these are the
/// properties where a single inline control (number field, stepper, or
/// closed dropdown) is both safe and useful. Everything else stays in the
/// full properties panel.
enum InlineEditKind {
  /// [ExposureNode.filter] — the imaging filter (closed dropdown of the
  /// active profile's filter names).
  exposureFilter,

  /// [FilterChangeNode.filterName] — the target filter for a standalone
  /// filter change (closed dropdown).
  filterChange,

  /// [ExposureNode.count] — number of sub-exposures (integer stepper).
  exposureCount,

  /// [LoopNode.repeatCount] — iteration count for a `count`-mode loop
  /// (integer stepper). Only valid when the loop's condition is
  /// [LoopConditionType.count]; other loop conditions are static.
  loopIterations,

  /// [ExposureNode.durationSecs] — per-sub exposure length in seconds
  /// (number field).
  exposureDuration,

  /// [DelayNode.seconds] — fixed delay in seconds (number field).
  delaySeconds,

  /// [ExposureNode.gain] — camera gain override (integer field).
  gain,

  /// [ExposureNode.binning] — binning mode (closed dropdown: 1x1..4x4).
  binning,

  /// [DitherNode.pixels] — dither amplitude in pixels (number field).
  ditherPixels,

  /// [DitherNode.pattern] — dither pattern (closed dropdown:
  /// random / grid).
  ditherPattern,

  /// [CenterNode.accuracyArcsec] — plate-solve centering tolerance in
  /// arcseconds (number field). The coordinates themselves stay static.
  centerTolerance,

  /// [AutofocusNode.method] — autofocus curve-fit method (closed
  /// dropdown). Only offered while the node is in override mode
  /// ([AutofocusNode.useSettingsDefaults] false); with defaults on, the
  /// executor discards this field, so the row shows the global method
  /// instead of an inert control.
  autofocusMethod,

  /// [CoolCameraNode.targetTemp] — target sensor temperature in °C
  /// (number field).
  coolTargetTemp,
}

/// A single piece of a node's at-a-glance summary line.
///
/// A summary is an ordered `List<SummaryFragment>`; the widget layer lays the
/// fragments out left-to-right. Two concrete forms exist:
///   * [StaticFragment] — non-interactive text (muted) or a read-only chip
///     (emphasized), optionally led by an icon.
///   * [EditableFragment] — an interactive chip whose tap opens an inline
///     editor for the named [InlineEditKind].
///
/// Equality is structural so tests can assert the exact fragment list a node
/// produces without reaching into the widget tree.
sealed class SummaryFragment {
  const SummaryFragment();
}

/// Non-interactive summary text.
///
/// When [emphasized] is true the widget layer renders this as a read-only
/// chip (e.g. a filter name that is fixed for this node type); otherwise it
/// is muted inline text (e.g. `× `, `gain 120`, a binning label).
class StaticFragment extends SummaryFragment {
  /// The literal text to render. No styling tokens are baked in here.
  final String text;

  /// When true, render as a chip (visually distinct); when false, render as
  /// muted inline text.
  final bool emphasized;

  /// Optional leading icon for this fragment.
  final IconData? icon;

  const StaticFragment(
    this.text, {
    this.emphasized = false,
    this.icon,
  });

  @override
  bool operator ==(Object other) =>
      other is StaticFragment &&
      other.text == text &&
      other.emphasized == emphasized &&
      other.icon == icon;

  @override
  int get hashCode => Object.hash(text, emphasized, icon);

  @override
  String toString() =>
      'StaticFragment("$text", emphasized: $emphasized, icon: $icon)';
}

/// An interactive summary chip that opens an inline editor.
///
/// [displayValue] is the value currently shown on the chip (already
/// formatted, e.g. `"120s"` / `"Ha"` / `"2x2"`). [kind] tells the widget
/// layer which inline editor to present and which node property to write
/// back via `currentSequenceProvider.notifier.updateNode(...)`.
class EditableFragment extends SummaryFragment {
  /// Which node property this chip edits.
  final InlineEditKind kind;

  /// The current value rendered on the chip.
  final String displayValue;

  /// Optional leading icon for this fragment.
  final IconData? icon;

  const EditableFragment(
    this.kind,
    this.displayValue, {
    this.icon,
  });

  @override
  bool operator ==(Object other) =>
      other is EditableFragment &&
      other.kind == kind &&
      other.displayValue == displayValue &&
      other.icon == icon;

  @override
  int get hashCode => Object.hash(kind, displayValue, icon);

  @override
  String toString() => 'EditableFragment($kind, "$displayValue", icon: $icon)';
}

/// Build the at-a-glance summary fragments for [node].
///
/// Returns a terse, ordered list (typically 1-3 fragments) describing the
/// node's most important configuration. The dispatch is an EXHAUSTIVE
/// `switch (node)` over the sealed [SequenceNode] hierarchy — there is
/// deliberately NO `_` wildcard, so introducing a new node subtype forces a
/// compile error here until its summary is authored.
///
/// Fragments marked [EditableFragment] carry an [InlineEditKind] identifying
/// a single safe-to-edit property; all other content is [StaticFragment].
///
/// [globalAutofocusMethod] is the persisted `AppSettings.afMethod` (e.g.
/// 'Star HFR'). An [AutofocusNode] in defaults mode runs THAT method — the
/// executor drops the node's own `method` field — so the caller passes it in
/// and the row reports what will actually run. This function stays pure: the
/// widget layer reads the setting and hands it over.
List<SummaryFragment> nodeSummary(
  SequenceNode node, {
  String? globalAutofocusMethod,
}) {
  return switch (node) {
    // Imaging — the lead row in most sequences. Count × duration + filter
    // are the at-a-glance leads; gain (when overridden) and binning trail as
    // editable chips so the whole capture spec is one-tap adjustable inline.
    ExposureNode(
      count: final count,
      durationSecs: final dur,
      filter: final filter,
      gain: final gain,
      binning: final binning,
    ) =>
      <SummaryFragment>[
        EditableFragment(
          InlineEditKind.exposureCount,
          '$count',
          icon: LucideIcons.camera,
        ),
        const StaticFragment('× '),
        EditableFragment(
          InlineEditKind.exposureDuration,
          '${_fmtSecs(dur)}s',
        ),
        if (filter != null && filter.isNotEmpty)
          EditableFragment(
            InlineEditKind.exposureFilter,
            filter,
            icon: LucideIcons.circle,
          ),
        if (gain != null)
          EditableFragment(
            InlineEditKind.gain,
            'gain $gain',
            icon: LucideIcons.gauge,
          ),
        EditableFragment(InlineEditKind.binning, binning.label),
      ],

    // Target header is covered for completeness/testing; the tree renders
    // target headers via a dedicated card and does not consume this.
    TargetHeaderNode(displayName: final displayName) => <SummaryFragment>[
        StaticFragment(displayName, emphasized: true),
        StaticFragment('${_fmtRa(node.raHours)} ${_fmtDec(node.decDegrees)}'),
      ],

    // Slew — coordinate entry is panel-grade, so the whole line is static.
    SlewNode(
      useTargetCoords: final useTarget,
      customRa: final ra,
      customDec: final dec,
    ) =>
      <SummaryFragment>[
        StaticFragment(
          useTarget
              ? '→ target'
              : '→ ${_fmtRa(ra ?? 0)} / ${_fmtDec(dec ?? 0)}',
          icon: LucideIcons.arrowRight,
        ),
      ],

    // Center — tolerance is a single safe scalar (editable); the filter is
    // a read-only hint here (plate-solve filter is panel-grade).
    CenterNode(accuracyArcsec: final acc, filter: final filter) =>
      <SummaryFragment>[
        EditableFragment(
          InlineEditKind.centerTolerance,
          '${_fmtSecs(acc)}"',
          icon: LucideIcons.crosshair,
        ),
        if (filter != null && filter.isNotEmpty) StaticFragment(filter),
      ],

    // Standalone filter change — the target filter is the one editable pick.
    FilterChangeNode(filterName: final filterName) => <SummaryFragment>[
        const StaticFragment('→ '),
        EditableFragment(
          InlineEditKind.filterChange,
          filterName,
          icon: LucideIcons.circle,
        ),
      ],

    // Autofocus — the row must name the method the RUN will use. With
    // `useSettingsDefaults` on (the default) the executor passes
    // `nodeOverrides: null` and resolves every parameter from AppSettings,
    // so `node.method` is dead data: showing it as an editable chip
    // advertised a control that changed nothing and contradicted the
    // properties panel beside it. In that mode we print the global method
    // and offer no chip; the pick returns only in override mode, where it
    // is the value that actually runs.
    AutofocusNode(
      method: final method,
      useSettingsDefaults: final useDefaults,
    ) =>
      useDefaults
          ? <SummaryFragment>[
              StaticFragment(
                globalAutofocusMethod == null
                    ? 'global AF settings'
                    : '$globalAutofocusMethod (global)',
                icon: LucideIcons.settings,
              ),
            ]
          : <SummaryFragment>[
              EditableFragment(InlineEditKind.autofocusMethod, method.name),
              const StaticFragment('custom'),
            ],

    // Wait — absolute time / twilight crossing is panel-grade; static.
    WaitTimeNode(
      waitUntil: final until,
      waitForTwilight: final twilight,
    ) =>
      <SummaryFragment>[
        StaticFragment(
          'until ${twilight != null ? '${twilight.name} twilight' : _fmtTime(until)}',
          icon: LucideIcons.clock,
        ),
      ],

    // Delay — a single safe scalar.
    DelayNode(seconds: final secs) => <SummaryFragment>[
        const StaticFragment('for '),
        EditableFragment(
          InlineEditKind.delaySeconds,
          '${_fmtSecs(secs)}s',
          icon: LucideIcons.timer,
        ),
      ],

    // Dither — amplitude (pixels) and pattern are both safe inline edits.
    DitherNode(pixels: final px, pattern: final pattern) => <SummaryFragment>[
        EditableFragment(
          InlineEditKind.ditherPixels,
          '${_fmtSecs(px)}px',
          icon: LucideIcons.shuffle,
        ),
        EditableFragment(InlineEditKind.ditherPattern, pattern.name),
      ],

    // Cool — target temperature is the single meaningful scalar.
    CoolCameraNode(targetTemp: final temp) => <SummaryFragment>[
        const StaticFragment('→ '),
        EditableFragment(
          InlineEditKind.coolTargetTemp,
          '${_fmtSecs(temp)}°C',
          icon: LucideIcons.snowflake,
        ),
      ],

    // Warm — rate + target together; no single scalar makes sense to edit
    // inline, so the whole line is static.
    WarmCameraNode(targetTemp: final temp, ratePerMin: final rate) =>
      <SummaryFragment>[
        StaticFragment(
          '→ ${_fmtSecs(temp)}°C @ ${_fmtSecs(rate)}°/min',
          icon: LucideIcons.thermometer,
        ),
      ],

    // Rotator — angle + reference are panel-grade together; static.
    RotatorNode(targetAngle: final angle, relative: final relative) =>
      <SummaryFragment>[
        StaticFragment('→ ${_fmtSecs(angle)}° ${relative ? 'rel' : 'abs'}'),
      ],

    // Flat-panel calibrator on — brightness shown statically (the panel
    // exposes the slider + timeout together).
    CalibratorOnNode(brightness: final brightness) => <SummaryFragment>[
        StaticFragment('brightness $brightness'),
      ],

    // Cover/calibrator/dome terminal actions — static labels. Where the
    // node has a `shutterOnly` flavor, surface that as the one distinguishing
    // hint.
    CalibratorOffNode() => const <SummaryFragment>[
        StaticFragment('panel off'),
      ],
    OpenCoverNode() => const <SummaryFragment>[
        StaticFragment('open cover'),
      ],
    CloseCoverNode() => const <SummaryFragment>[
        StaticFragment('close cover'),
      ],
    OpenDomeNode(shutterOnly: final shutterOnly) => <SummaryFragment>[
        StaticFragment(shutterOnly ? 'shutter only' : 'open dome'),
      ],
    CloseDomeNode(shutterOnly: final shutterOnly) => <SummaryFragment>[
        StaticFragment(shutterOnly ? 'shutter only' : 'close dome'),
      ],
    ParkDomeNode(shutterOnly: final shutterOnly) => <SummaryFragment>[
        StaticFragment(shutterOnly ? 'shutter only' : 'park dome'),
      ],

    // Smart exposure — a multi-row plan. Per-filter editing is panel-grade
    // (each row carries count/duration/gain/binning/dither), so the fragments
    // are read-only chips rather than inline editors — but we still surface the
    // actual per-filter capture spec (filter · count×duration) instead of a
    // bare "N filters", so the user sees at a glance what each filter will
    // shoot (and e.g. that L/R/G/B carry different exposures).
    SmartExposureNode(
      plans: final plans,
      rotateFilters: final rotate,
      loopUntilStopped: final loop,
    ) =>
      plans.isEmpty
          ? const <SummaryFragment>[
              StaticFragment('No filters configured'),
            ]
          // Loop-until-stopped ignores per-filter counts — show
          // "L·R·G·B · 1 each · looping" rather than the (irrelevant) fixed
          // counts so the tree summary matches the actual round-robin-forever
          // behaviour.
          : loop
              ? <SummaryFragment>[
                  StaticFragment(
                    plans
                        .map((p) => p.filterName.isEmpty
                            ? '#${(p.filterIndex ?? 0) + 1}'
                            : p.filterName)
                        .join('·'),
                    emphasized: true,
                  ),
                  const StaticFragment('1 each'),
                  const StaticFragment('looping'),
                  // A depth binding is the one thing that can end a filter
                  // before its authored bound, so the tree says which filters
                  // carry one rather than leaving it to the properties pane.
                  if (_depthLockedFilters(plans) != null)
                    StaticFragment('depth goal: ${_depthLockedFilters(plans)}'),
                ]
              : <SummaryFragment>[
                  for (final plan in plans)
                    StaticFragment(
                      '${plan.filterName.isEmpty ? '#${(plan.filterIndex ?? 0) + 1}' : plan.filterName}'
                      ' ${plan.count}×${_fmtSecs(plan.durationSecs)}s',
                      emphasized: true,
                    ),
                  if (_depthLockedFilters(plans) != null)
                    StaticFragment('depth goal: ${_depthLockedFilters(plans)}'),
                  StaticFragment(rotate ? 'rotate' : 'drain'),
                ],

    // Polar alignment — hemisphere + start altitude summary; static.
    PolarAlignmentNode(
      isNorth: final isNorth,
      startAltitude: final startAlt,
    ) =>
      <SummaryFragment>[
        StaticFragment('${isNorth ? 'N' : 'S'} · alt ${_fmtSecs(startAlt)}°'),
      ],

    // Guiding lifecycle — settle params are a tuple; static.
    StartGuidingNode(
      settlePixels: final settlePx,
      settleTime: final settleTime,
    ) =>
      <SummaryFragment>[
        StaticFragment(
          'settle ${_fmtSecs(settlePx)}px/${_fmtSecs(settleTime)}s',
        ),
      ],
    StopGuidingNode() => const <SummaryFragment>[
        StaticFragment('stop guiding'),
      ],

    // Mount park / unpark — terminal actions; static.
    ParkNode() => const <SummaryFragment>[
        StaticFragment('park mount'),
      ],
    UnparkNode() => const <SummaryFragment>[
        StaticFragment('unpark mount'),
      ],

    // Script / notification — descriptors; static.
    ScriptNode(scriptPath: final path) => <SummaryFragment>[
        StaticFragment(path.isEmpty ? '(no script)' : _basename(path)),
      ],
    NotificationNode(level: final level, title: final title) =>
      <SummaryFragment>[
        StaticFragment(
            '${level.name}: ${title.isEmpty ? '(untitled)' : title}'),
      ],

    // Logic / containers.
    // Loop — only the `count` condition exposes a single editable scalar
    // (iteration count). Unbounded and until-* conditions are static
    // descriptors.
    LoopNode(
      conditionType: final cond,
      repeatCount: final repeatCount,
      repeatUntil: final repeatUntil,
      repeatUntilAltitude: final repeatUntilAltitude,
      integrationTimeTarget: final integrationTarget,
    ) =>
      _loopSummary(
        cond,
        repeatCount,
        repeatUntil,
        repeatUntilAltitude,
        integrationTarget,
      ),

    // Conditional — describe the branch condition; static.
    ConditionalNode(
      conditionType: final cond,
      thresholdValue: final threshold,
    ) =>
      <SummaryFragment>[
        StaticFragment('if ${_conditionalDescriptor(cond, threshold)}'),
      ],

    // Parallel — fan-out with optional quorum; static.
    ParallelNode(requiredSuccesses: final required) => <SummaryFragment>[
        StaticFragment(
          'parallel${required != null ? ' · needs $required' : ''}',
        ),
      ],

    // Recovery — error/recovery action with optional trigger; static.
    RecoveryNode(
      recoveryAction: final action,
      triggerType: final trigger,
    ) =>
      <SummaryFragment>[
        StaticFragment(
          '${action.name}${trigger != null ? ' on ${trigger.name}' : ''}',
        ),
      ],

    // Instruction set — child count; static.
    InstructionSetNode() => <SummaryFragment>[
        StaticFragment(countLabel(node.childIds.length, 'step')),
      ],

    // Target scheduler — its config is multi-axis; describe child count.
    TargetSchedulerNode() => <SummaryFragment>[
        StaticFragment(
          '${node.childIds.length} targets · min score '
          '${_fmtSecs(node.minScoreToRun)}',
        ),
      ],

    // Live stacking — mode + method descriptor; static.
    LiveStackingNode(mode: final mode, stackMethod: final method) =>
      <SummaryFragment>[
        StaticFragment('${mode.label} · ${method.label}'),
      ],

    // Science photometry — target + filter + burst descriptor; static.
    SciencePhotometryNode(
      targetDesignation: final designation,
      filter: final filter,
      count: final count,
    ) =>
      <SummaryFragment>[
        StaticFragment(
          '${designation.isEmpty ? '(no target)' : designation} · '
          '$filter · $count frames',
        ),
      ],

    // Plugin node — opaque to us; show the plugin-provided label.
    PluginInstructionNode(
      pluginName: final pluginName,
      nodeTypeId: final nodeTypeId,
    ) =>
      <SummaryFragment>[
        StaticFragment(
          pluginName.isEmpty ? nodeTypeId : '$pluginName · $nodeTypeId',
        ),
      ],

    // Trigger (watchdog).
    // Meridian flip — a parallel hour-angle / pier-side watchdog. NEVER
    // editable inline: the row already carries the Watchdog badge and the
    // thresholds interact (trigger method ↔ minutes-past ↔ auto-center).
    MeridianFlipNode(
      triggerMethod: final method,
      minutesPastMeridian: final minutesPast,
      autoCenter: final autoCenter,
    ) =>
      <SummaryFragment>[
        StaticFragment(
          '${method.name} · ${_fmtSecs(minutesPast)} min past'
          '${autoCenter ? ' · auto-center' : ''}',
        ),
      ],
  };
}

/// Convenience: true iff [node]'s summary contains at least one inline-
/// editable fragment. The tree uses this to decide whether to show the
/// "quick-edit" affordance on a row.
bool summaryHasInlineEdits(SequenceNode node) =>
    nodeSummary(node).any((f) => f is EditableFragment);

// Private helpers — terse value formatting. No styling tokens here; these
// produce the plain strings the widget layer paints.

/// Build the Loop summary. Only the `count` condition yields an editable
/// iteration count; every other condition is a static descriptor.
List<SummaryFragment> _loopSummary(
  LoopConditionType cond,
  int? repeatCount,
  DateTime? repeatUntil,
  double? repeatUntilAltitude,
  double? integrationTimeTarget,
) {
  switch (cond) {
    case LoopConditionType.count:
      return <SummaryFragment>[
        const StaticFragment('×'),
        EditableFragment(
          InlineEditKind.loopIterations,
          '${repeatCount ?? 1}',
          icon: LucideIcons.repeat,
        ),
      ];
    case LoopConditionType.forever:
      return const <SummaryFragment>[StaticFragment('∞ forever')];
    case LoopConditionType.whileDark:
      return const <SummaryFragment>[StaticFragment('∞ while dark')];
    case LoopConditionType.untilTime:
      return <SummaryFragment>[
        StaticFragment('until ${_fmtTime(repeatUntil)}'),
      ];
    case LoopConditionType.untilAltitude:
      return <SummaryFragment>[
        StaticFragment(
          'until alt ≤ ${_fmtSecs(repeatUntilAltitude ?? 0)}°',
        ),
      ];
    case LoopConditionType.altitudeAbove:
      return <SummaryFragment>[
        StaticFragment(
          'until alt ≥ ${_fmtSecs(repeatUntilAltitude ?? 0)}°',
        ),
      ];
    case LoopConditionType.integrationTime:
      return <SummaryFragment>[
        StaticFragment(
          'until ${_fmtDurationHm(integrationTimeTarget ?? 0)} integrated',
        ),
      ];
  }
}

/// Human-readable descriptor for a [ConditionalNode] branch condition.
String _conditionalDescriptor(ConditionalType cond, double? threshold) {
  final t = threshold;
  switch (cond) {
    case ConditionalType.always:
      return 'always';
    case ConditionalType.altitudeAbove:
      return 'alt ≥ ${_fmtSecs(t ?? 0)}°';
    case ConditionalType.timeAfter:
      return 'time is later';
    case ConditionalType.guidingRmsBelow:
      return 'guide RMS ≤ ${_fmtSecs(t ?? 0)}"';
    case ConditionalType.hfrBelow:
      return 'HFR ≤ ${_fmtSecs(t ?? 0)}';
    case ConditionalType.weatherSafe:
      return 'weather safe';
    case ConditionalType.moonSeparationAbove:
      return 'moon sep ≥ ${_fmtSecs(t ?? 0)}°';
    case ConditionalType.safetyMonitorSafe:
      return 'safety monitor safe';
  }
}

/// Format a duration in seconds compactly: drops a trailing `.0` so whole
/// numbers read cleanly (`60` not `60.0`) while keeping one decimal for
/// fractional values (`1.5`).
String _fmtSecs(double value) {
  if (value == value.roundToDouble()) {
    return value.toStringAsFixed(0);
  }
  return value.toStringAsFixed(1);
}

/// Format an integration-target (seconds) as `Hh Mm` / `Mm`.
String _fmtDurationHm(double seconds) {
  final total = seconds.round();
  final hours = total ~/ 3600;
  final mins = (total % 3600) ~/ 60;
  if (hours > 0) {
    return mins > 0 ? '${hours}h ${mins}m' : '${hours}h';
  }
  return '${mins}m';
}

/// Format right ascension (hours) as `HHhMMm`.
String _fmtRa(double raHours) {
  var h = raHours % 24.0;
  if (h < 0) h += 24.0;
  var hh = h.floor();
  var mm = ((h - hh) * 60).round();
  if (mm == 60) {
    mm = 0;
    hh = (hh + 1) % 24;
  }
  return '${_pad2(hh)}h${_pad2(mm)}m';
}

/// Format declination (degrees) as `±DD°MM'`.
String _fmtDec(double decDegrees) {
  final sign = decDegrees < 0 ? '-' : '+';
  final abs = decDegrees.abs();
  var dd = abs.floor();
  var mm = ((abs - dd) * 60).round();
  if (mm == 60) {
    mm = 0;
    dd += 1;
  }
  return "$sign${_pad2(dd)}°${_pad2(mm)}'";
}

/// Format a wall-clock [DateTime] as `HH:MM` in its own zone. Returns
/// `(unset)` when null so an unconfigured wait/loop reads explicitly rather
/// than blank.
String _fmtTime(DateTime? time) {
  if (time == null) return '(unset)';
  return '${_pad2(time.hour)}:${_pad2(time.minute)}';
}

/// Strip directory components from a path, handling both `/` and `\`
/// separators so a Windows-authored script path renders cleanly anywhere.
String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final trimmed = normalized.endsWith('/')
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
  final idx = trimmed.lastIndexOf('/');
  return idx >= 0 ? trimmed.substring(idx + 1) : trimmed;
}

/// Zero-pad an integer to two digits.
String _pad2(int value) => value.toString().padLeft(2, '0');

/// The filters in [plans] whose rows are bound to a DepthLock goal, joined for
/// the node summary, or null when none are.
///
/// Only the FILTERS are named: a goal id means nothing in a tree row, and the
/// goal's label can change under the binding without the plan changing at all.
String? _depthLockedFilters(List<FilterPlan> plans) {
  final bound = plans
      .where((plan) => plan.depthGoal != null)
      .map(
        (plan) => plan.filterName.isEmpty
            ? '#${(plan.filterIndex ?? 0) + 1}'
            : plan.filterName,
      )
      .toList(growable: false);
  return bound.isEmpty ? null : bound.join('·');
}
