// Anchored, Riverpod-aware inline editors that a tapped [EditableFragment]
// chip opens.
//
// This is the WIDGET-layer bridge between the pure summary classifier
// (`node_summary.dart`) and the canonical node-commit path. A summary chip
// is structural data only; when the user taps an [EditableFragment] chip the
// row calls [showInlineNodeEditor], which floats a minimal popup anchored to
// the chip's on-screen rect and edits exactly one property.
//
// CONTRACT (matches the full properties panel precisely):
//   * Every mutation is `ref.read(currentSequenceProvider.notifier)
//     .updateNode(node.copyWith(...))` — the same call the panel makes, so
//     undo/redo, autosave, and `modifiedAt` bookkeeping come for free.
//   * Exposure-owned fields (duration / count / filter / gain / binning) ALSO
//     mirror into `sequencerDefaultsProvider.notifier.updateExposureDefaults`,
//     exactly as `_capture_properties.dart` does, so the next exposure node a
//     user drops inherits their latest choice. Loop iterations, dither, center
//     tolerance, etc. are NOT exposure defaults and never mirror.
//   * The editor is GATED on `canEditSequenceProvider`: while a sequence is
//     running/paused/stopping/recovering the popup simply never opens. The
//     `updateNode` call itself also throws `SequenceLockedException` in that
//     state, so this is defence-in-depth, not the only guard.
//
// ERRORS-ARE-A-FEATURE:
//   * [_expect] casts the node to the type a given [InlineEditKind] requires
//     and THROWS [StateError] on mismatch rather than silently no-opping. A
//     chip can only ever be produced for the matching node type, so a mismatch
//     means the summary classifier and this editor have drifted apart — that is
//     a bug we want surfaced loudly in tests/dev, not swallowed.
//   * When the active profile has no filter names, the filter editors fall back
//     to an explicit free-text field (not a guessed filter), mirroring the
//     panel's fallback.
//
// STYLING: every color/spacing/radius/typography value comes from the design
// tokens. The popup is a floating overlay, so a shadow (`shadowMd`) is allowed
// under the elevation rule: cards use borders, only floating surfaces cast
// shadows.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../filter_source.dart';

import 'node_summary.dart';

/// Open the anchored inline editor for [kind] on [node].
///
/// Floats a minimal popup at [anchor]'s global rect and edits exactly one
/// property, committing via `currentSequenceProvider.notifier.updateNode`.
///
/// Returns immediately (opening nothing) when the sequence is not editable —
/// see [canEditSequenceProvider]. The future completes when the popup closes.
Future<void> showInlineNodeEditor({
  required BuildContext context,
  required WidgetRef ref,
  required SequenceNode node,
  required InlineEditKind kind,
  required RenderBox anchor,
}) async {
  // GATE: no inline editing while the sequence is locked. Defence-in-depth —
  // `updateNode` also throws in this state, but we never even surface the UI.
  if (!ref.read(canEditSequenceProvider)) {
    return;
  }

  final overlay =
      Overlay.of(context, rootOverlay: true).context.findRenderObject();
  if (overlay is! RenderBox) {
    // The chip is always mounted inside a routed page that has an Overlay, so
    // this should be unreachable; surfacing it (rather than silently bailing)
    // catches any future caller that invokes us outside an overlay context.
    throw StateError(
      'showInlineNodeEditor requires an ancestor Overlay; none was found for '
      'the supplied context.',
    );
  }

  final anchorRect = Rect.fromPoints(
    anchor.localToGlobal(Offset.zero, ancestor: overlay),
    anchor.localToGlobal(
      anchor.size.bottomRight(Offset.zero),
      ancestor: overlay,
    ),
  );

  await showDialog<void>(
    context: context,
    barrierColor: Colors.transparent,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    useRootNavigator: true,
    builder: (dialogContext) => _AnchoredInlineEditor(
      anchorRect: anchorRect,
      overlaySize: overlay.size,
      child: _InlineEditorBody(node: node, kind: kind),
    ),
  );
}

// Anchored popup shell — positions [child] against the anchor's rect, tapping
// outside dismisses (the transparent barrier), and styles the floating surface.

/// The preferred width of the floating editor. Wide enough for a stepper +
/// label or a comfortable list of filter names, narrow enough to read as a
/// quick-edit popover rather than a panel.
const double _kEditorWidth = 232;

/// Gap between the anchor and the popup edge.
const double _kAnchorGap = SkotiqTokens.spaceXs;

/// Outer margin kept clear of the screen edges so the popup never clips.
const double _kScreenMargin = SkotiqTokens.spaceSm;

class _AnchoredInlineEditor extends StatelessWidget {
  final Rect anchorRect;
  final Size overlaySize;
  final Widget child;

  const _AnchoredInlineEditor({
    required this.anchorRect,
    required this.overlaySize,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    // Horizontal: left-align with the anchor, then clamp inside the margins.
    final maxLeft = overlaySize.width - _kEditorWidth - _kScreenMargin;
    final double left = maxLeft <= _kScreenMargin
        ? _kScreenMargin
        : anchorRect.left.clamp(_kScreenMargin, maxLeft);

    // Vertical: prefer below the anchor; flip above when there isn't room. We
    // anchor the top edge and let the popup size to its content height.
    final spaceBelow = overlaySize.height - anchorRect.bottom - _kScreenMargin;
    final placeBelow =
        spaceBelow >= 96 || spaceBelow >= anchorRect.top - _kScreenMargin;

    final Widget surface = Material(
      type: MaterialType.transparency,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: _kEditorWidth,
          maxHeight: overlaySize.height - 2 * _kScreenMargin,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: colors.surfaceElevated,
            borderRadius: SkotiqTokens.borderRadiusMd,
            border: Border.all(color: colors.border),
            boxShadow: SkotiqTokens.shadowMd,
          ),
          padding: SkotiqTokens.paddingSm,
          child: child,
        ),
      ),
    );

    // Position the popup with a Stack so the top/bottom flip is exact. The
    // transparent barrier provided by showDialog handles outside-tap dismiss.
    return Stack(
      children: [
        Positioned(
          left: left,
          top: placeBelow ? anchorRect.bottom + _kAnchorGap : null,
          bottom: placeBelow
              ? null
              : overlaySize.height - anchorRect.top + _kAnchorGap,
          child: surface,
        ),
      ],
    );
  }
}

// Editor body — dispatches on [InlineEditKind] to the right control.

class _InlineEditorBody extends ConsumerWidget {
  final SequenceNode node;
  final InlineEditKind kind;

  const _InlineEditorBody({required this.node, required this.kind});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Re-resolve the node from the LIVE sequence on every build. The node the
    // chip handed to [showInlineNodeEditor] is a snapshot taken at tap time,
    // and every editor below commits `node.copyWith(...)`. Building from the
    // snapshot therefore recomputes each edit from the ORIGINAL value: a
    // stepper opened on count 4 moves to 5 on the first '+', then every later
    // '+' re-applies 4+1 and is a silent no-op, while the popup keeps
    // rendering the stale 4. Watching the tree makes each commit build on the
    // previous one and keeps the displayed value honest.
    final node = ref.watch(
          currentSequenceProvider.select((s) => s?.nodes[this.node.id]),
        ) ??
        this.node;
    return switch (kind) {
      InlineEditKind.exposureFilter => _ExposureFilterEditor(
          node: _expect<ExposureNode>(node, kind),
        ),
      InlineEditKind.filterChange => _FilterChangeEditor(
          node: _expect<FilterChangeNode>(node, kind),
        ),
      InlineEditKind.exposureCount => _ExposureCountEditor(
          node: _expect<ExposureNode>(node, kind),
        ),
      InlineEditKind.loopIterations => _LoopIterationsEditor(
          node: _expect<LoopNode>(node, kind),
        ),
      InlineEditKind.exposureDuration => _ExposureDurationEditor(
          node: _expect<ExposureNode>(node, kind),
        ),
      InlineEditKind.delaySeconds => _DelaySecondsEditor(
          node: _expect<DelayNode>(node, kind),
        ),
      InlineEditKind.centerTolerance => _CenterToleranceEditor(
          node: _expect<CenterNode>(node, kind),
        ),
      InlineEditKind.coolTargetTemp => _CoolTargetTempEditor(
          node: _expect<CoolCameraNode>(node, kind),
        ),
      InlineEditKind.ditherPixels => _DitherPixelsEditor(
          node: _expect<DitherNode>(node, kind),
        ),
      InlineEditKind.gain => _GainEditor(
          node: _expect<ExposureNode>(node, kind),
        ),
      InlineEditKind.binning => _BinningEditor(
          node: _expect<ExposureNode>(node, kind),
        ),
      InlineEditKind.autofocusMethod => _AutofocusMethodEditor(
          node: _expect<AutofocusNode>(node, kind),
        ),
      InlineEditKind.ditherPattern => _DitherPatternEditor(
          node: _expect<DitherNode>(node, kind),
        ),
    };
  }
}

/// Cast [node] to the subtype [kind] requires, throwing on mismatch.
///
/// Errors-are-a-feature: a chip for [kind] can only be produced from the
/// matching node subtype, so a mismatch means the classifier and this editor
/// have drifted. We surface that loudly rather than silently rendering nothing.
T _expect<T extends SequenceNode>(SequenceNode node, InlineEditKind kind) {
  if (node is T) return node;
  throw StateError(
    'Inline editor for $kind expected a $T but received '
    '${node.runtimeType} (node id "${node.id}"). The summary classifier and '
    'the inline editor have drifted out of sync.',
  );
}

// Shared editor chrome — a small titled section the controls slot into.

class _EditorSection extends StatelessWidget {
  final String title;
  final IconData? icon;
  final Widget child;

  const _EditorSection({required this.title, required this.child, this.icon});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (icon != null) ...[
              Icon(icon,
                  size: SkotiqTokens.iconXs, color: colors.textMuted),
              const SizedBox(width: SkotiqTokens.spaceXs),
            ],
            Flexible(
              child: Text(
                title,
                style: SkotiqTypography.labelSm
                    .copyWith(color: colors.textSecondary),
              ),
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        child,
      ],
    );
  }
}

// Numeric text-field editor — commits clamped-on-change, reformats on blur.

/// A compact numeric field that commits its clamped value on every change and
/// reformats (snaps to the clamp + canonical text) when focus leaves.
///
/// [decimals] controls the displayed precision; [allowNegative] permits a
/// leading `-` (used for cooling temperature). [onCommit] receives the parsed,
/// clamped value — it does the `updateNode` (+ optional defaults mirror).
class _NumericFieldEditor extends StatefulWidget {
  final String title;
  final IconData? icon;
  final double initialValue;
  final double min;
  final double max;
  final int decimals;
  final bool allowNegative;
  final String? suffix;
  final ValueChanged<double> onCommit;

  const _NumericFieldEditor({
    required this.title,
    required this.initialValue,
    required this.min,
    required this.max,
    required this.onCommit,
    this.icon,
    this.decimals = 1,
    this.allowNegative = false,
    this.suffix,
  });

  @override
  State<_NumericFieldEditor> createState() => _NumericFieldEditorState();
}

class _NumericFieldEditorState extends State<_NumericFieldEditor> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _format(widget.initialValue));
    _focusNode = FocusNode()..addListener(_handleFocusChange);
    // Autofocus + select-all so the user can immediately overtype.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  String _format(double value) => value.toStringAsFixed(widget.decimals);

  double _clamp(double value) => value.clamp(widget.min, widget.max);

  void _handleFocusChange() {
    if (!_focusNode.hasFocus) {
      _reformat();
    }
  }

  /// Snap the text to the clamped, canonical representation. Called on blur and
  /// submit so a half-typed or out-of-range value never lingers on screen.
  void _reformat() {
    final parsed = double.tryParse(_controller.text.trim());
    final value = _clamp(parsed ?? widget.initialValue);
    final text = _format(value);
    if (_controller.text != text) {
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
    widget.onCommit(value);
  }

  void _handleChanged(String raw) {
    final parsed = double.tryParse(raw.trim());
    // Commit live only when the text parses to a real number; a transient
    // empty / "-" / "." state is left for the blur reformat to resolve. We
    // never guess a value for unparseable input.
    if (parsed == null) return;
    widget.onCommit(_clamp(parsed));
  }

  @override
  Widget build(BuildContext context) {
    final pattern =
        widget.allowNegative ? RegExp(r'^-?\d*\.?\d*') : RegExp(r'^\d*\.?\d*');
    return _EditorSection(
      title: widget.title,
      icon: widget.icon,
      child: SkotiqTextField(
        controller: _controller,
        focusNode: _focusNode,
        keyboardType: TextInputType.numberWithOptions(
          decimal: widget.decimals > 0,
          signed: widget.allowNegative,
        ),
        suffix: widget.suffix,
        inputFormatters: [
          FilteringTextInputFormatter.allow(pattern),
        ],
        onChanged: _handleChanged,
      ),
    );
  }
}

// Stepper editors (integer count / iterations).

class _ExposureCountEditor extends ConsumerWidget {
  final ExposureNode node;
  const _ExposureCountEditor({required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _EditorSection(
      title: 'Exposure count',
      icon: LucideIcons.camera,
      child: SkotiqStepper(
        value: node.count,
        min: 1,
        max: 9999,
        semanticLabel: 'Exposure count',
        onChanged: (count) {
          ref
              .read(currentSequenceProvider.notifier)
              .updateNode(node.copyWith(count: count));
          ref
              .read(sequencerDefaultsProvider.notifier)
              .updateExposureDefaults(count: count);
        },
      ),
    );
  }
}

class _LoopIterationsEditor extends ConsumerWidget {
  final LoopNode node;
  const _LoopIterationsEditor({required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _EditorSection(
      title: 'Loop iterations',
      icon: LucideIcons.repeat,
      child: SkotiqStepper(
        value: node.repeatCount ?? 1,
        min: 1,
        max: 9999,
        semanticLabel: 'Loop iterations',
        // Loop iterations are NOT an exposure default — no defaults mirror.
        onChanged: (count) => ref
            .read(currentSequenceProvider.notifier)
            .updateNode(node.copyWith(repeatCount: count)),
      ),
    );
  }
}

// Numeric-field editors (scalars with a sensible clamp range).

class _ExposureDurationEditor extends ConsumerWidget {
  final ExposureNode node;
  const _ExposureDurationEditor({required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _NumericFieldEditor(
      title: 'Exposure duration',
      icon: LucideIcons.timer,
      initialValue: node.durationSecs,
      min: 0.001,
      max: 3600,
      decimals: 3,
      suffix: 's',
      onCommit: (value) {
        ref
            .read(currentSequenceProvider.notifier)
            .updateNode(node.copyWith(durationSecs: value));
        ref
            .read(sequencerDefaultsProvider.notifier)
            .updateExposureDefaults(duration: value);
      },
    );
  }
}

class _DelaySecondsEditor extends ConsumerWidget {
  final DelayNode node;
  const _DelaySecondsEditor({required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _NumericFieldEditor(
      title: 'Delay',
      icon: LucideIcons.timer,
      initialValue: node.seconds,
      min: 0,
      max: 86400,
      decimals: 0,
      suffix: 's',
      onCommit: (value) => ref
          .read(currentSequenceProvider.notifier)
          .updateNode(node.copyWith(seconds: value)),
    );
  }
}

class _CenterToleranceEditor extends ConsumerWidget {
  final CenterNode node;
  const _CenterToleranceEditor({required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _NumericFieldEditor(
      title: 'Centering tolerance',
      icon: LucideIcons.crosshair,
      initialValue: node.accuracyArcsec,
      min: 0.1,
      max: 60,
      decimals: 1,
      suffix: '"',
      onCommit: (value) => ref
          .read(currentSequenceProvider.notifier)
          .updateNode(node.copyWith(accuracyArcsec: value)),
    );
  }
}

class _CoolTargetTempEditor extends ConsumerWidget {
  final CoolCameraNode node;
  const _CoolTargetTempEditor({required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _NumericFieldEditor(
      title: 'Target temperature',
      icon: LucideIcons.snowflake,
      initialValue: node.targetTemp,
      min: -50,
      max: 30,
      decimals: 1,
      allowNegative: true,
      suffix: '°C',
      onCommit: (value) => ref
          .read(currentSequenceProvider.notifier)
          .updateNode(node.copyWith(targetTemp: value)),
    );
  }
}

class _DitherPixelsEditor extends ConsumerWidget {
  final DitherNode node;
  const _DitherPixelsEditor({required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _NumericFieldEditor(
      title: 'Dither amount',
      icon: LucideIcons.shuffle,
      initialValue: node.pixels,
      min: 0,
      max: 50,
      decimals: 1,
      suffix: 'px',
      onCommit: (value) => ref
          .read(currentSequenceProvider.notifier)
          .updateNode(node.copyWith(pixels: value)),
    );
  }
}

class _GainEditor extends ConsumerWidget {
  final ExposureNode node;
  const _GainEditor({required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _NumericFieldEditor(
      title: 'Gain',
      icon: LucideIcons.gauge,
      initialValue: (node.gain ?? 0).toDouble(),
      min: 0,
      max: 1000,
      decimals: 0,
      onCommit: (value) {
        final gain = value.toInt();
        ref
            .read(currentSequenceProvider.notifier)
            .updateNode(node.copyWith(gain: gain));
        ref
            .read(sequencerDefaultsProvider.notifier)
            .updateExposureDefaults(gain: gain);
      },
    );
  }
}

// Menu editors (closed enum / filter picks). A vertical list of tappable rows
// styled on the elevated surface; the current value is marked with a check.

/// One selectable row in a menu editor.
class _MenuRow extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _MenuRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: SkotiqTokens.borderRadiusSm,
      hoverColor: colors.surfaceHover,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.spaceSm,
          vertical: SkotiqTokens.spaceSm,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: SkotiqTypography.bodySm.copyWith(
                  color: selected ? colors.primary : colors.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (selected)
              Icon(
                LucideIcons.check,
                size: SkotiqTokens.iconXs,
                color: colors.primary,
              ),
          ],
        ),
      ),
    );
  }
}

/// A scrollable, titled list of [_MenuRow]s. Keeps the popup bounded when a
/// profile defines many filters or an enum has several values.
class _MenuList extends StatelessWidget {
  final String title;
  final IconData? icon;
  final List<Widget> rows;

  const _MenuList({required this.title, required this.rows, this.icon});

  @override
  Widget build(BuildContext context) {
    return _EditorSection(
      title: title,
      icon: icon,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 240),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: rows,
          ),
        ),
      ),
    );
  }
}

class _ExposureFilterEditor extends ConsumerWidget {
  final ExposureNode node;
  const _ExposureFilterEditor({required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(activeEquipmentProfileProvider);
    final filterNames = profile?.filterNames ?? const <String>[];

    // Errors-are-a-feature: with no profile filters we offer explicit free-text
    // (mirroring the panel) rather than guessing a filter name.
    if (filterNames.isEmpty) {
      return _FreeTextFilterEditor(
        initialValue: node.filter ?? '',
        onCommit: (text) {
          final filter = text.isEmpty ? null : text;
          ref.read(currentSequenceProvider.notifier).updateNode(
                node.copyWith(filter: filter, clearFilter: filter == null),
              );
          ref
              .read(sequencerDefaultsProvider.notifier)
              .updateExposureDefaults(filter: filter);
        },
      );
    }

    void select(String? filter, int? index) {
      ref.read(currentSequenceProvider.notifier).updateNode(
            node.copyWith(
              filter: filter,
              filterIndex: index,
              clearFilter: filter == null && index == null,
            ),
          );
      ref
          .read(sequencerDefaultsProvider.notifier)
          .updateExposureDefaults(filter: filter);
      Navigator.of(context).pop();
    }

    // The '(None)' sentinel (index -1 → null filter) is unique to the exposure
    // editor; a standalone filter change must always pick a real filter.
    final bool noneSelected = node.filterIndex == null &&
        (node.filter == null || node.filter!.isEmpty);

    return _MenuList(
      title: 'Filter',
      icon: LucideIcons.circle,
      rows: [
        _MenuRow(
          label: '(None)',
          selected: noneSelected,
          onTap: () => select(null, null),
        ),
        for (var i = 0; i < filterNames.length; i++)
          _MenuRow(
            label: filterNames[i],
            selected: _filterMatches(
                node.filter, node.filterIndex, filterNames[i], i),
            onTap: () => select(filterNames[i], i),
          ),
      ],
    );
  }
}

class _FilterChangeEditor extends ConsumerWidget {
  final FilterChangeNode node;
  const _FilterChangeEditor({required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(activeEquipmentProfileProvider);
    final filterNames = profile?.filterNames ?? const <String>[];

    if (filterNames.isEmpty) {
      return _FreeTextFilterEditor(
        initialValue: node.filterName,
        onCommit: (text) => ref
            .read(currentSequenceProvider.notifier)
            .updateNode(node.copyWith(filterName: text)),
      );
    }

    void select(String name, int index) {
      // Set BOTH name and position for reliable filter changes (panel parity).
      ref.read(currentSequenceProvider.notifier).updateNode(
            node.copyWith(filterName: name, filterPosition: index),
          );
      Navigator.of(context).pop();
    }

    return _MenuList(
      title: 'Filter',
      icon: LucideIcons.circle,
      rows: [
        for (var i = 0; i < filterNames.length; i++)
          _MenuRow(
            label: filterNames[i],
            selected: _filterMatches(
              node.filterName,
              node.filterPosition,
              filterNames[i],
              i,
            ),
            onTap: () => select(filterNames[i], i),
          ),
      ],
    );
  }
}

/// Free-text filter entry shown when the active profile defines no filters.
class _FreeTextFilterEditor extends StatefulWidget {
  final String initialValue;
  final ValueChanged<String> onCommit;

  const _FreeTextFilterEditor({
    required this.initialValue,
    required this.onCommit,
  });

  @override
  State<_FreeTextFilterEditor> createState() => _FreeTextFilterEditorState();
}

class _FreeTextFilterEditorState extends State<_FreeTextFilterEditor> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _EditorSection(
      title: 'Filter',
      icon: LucideIcons.circle,
      child: SkotiqTextField(
        controller: _controller,
        focusNode: _focusNode,
        hint: BuilderFilterSource.emptyHint,
        onChanged: (value) => widget.onCommit(value.trim()),
      ),
    );
  }
}

class _BinningEditor extends ConsumerWidget {
  final ExposureNode node;
  const _BinningEditor({required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _MenuList(
      title: 'Binning',
      rows: [
        for (final mode in BinningMode.values)
          _MenuRow(
            label: mode.label,
            selected: node.binning == mode,
            onTap: () {
              ref
                  .read(currentSequenceProvider.notifier)
                  .updateNode(node.copyWith(binning: mode));
              ref
                  .read(sequencerDefaultsProvider.notifier)
                  .updateExposureDefaults(binning: mode);
              Navigator.of(context).pop();
            },
          ),
      ],
    );
  }
}

class _AutofocusMethodEditor extends ConsumerWidget {
  final AutofocusNode node;
  const _AutofocusMethodEditor({required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _MenuList(
      title: 'Autofocus method',
      rows: [
        for (final method in AutofocusMethod.values)
          _MenuRow(
            label: method.name,
            selected: node.method == method,
            // Autofocus method is not an exposure default — no mirror.
            onTap: () {
              ref
                  .read(currentSequenceProvider.notifier)
                  .updateNode(node.copyWith(method: method));
              Navigator.of(context).pop();
            },
          ),
      ],
    );
  }
}

class _DitherPatternEditor extends ConsumerWidget {
  final DitherNode node;
  const _DitherPatternEditor({required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _MenuList(
      title: 'Dither pattern',
      icon: LucideIcons.shuffle,
      rows: [
        for (final pattern in DitherPattern.values)
          _MenuRow(
            label: pattern.name,
            selected: node.pattern == pattern,
            onTap: () {
              ref
                  .read(currentSequenceProvider.notifier)
                  .updateNode(node.copyWith(pattern: pattern));
              Navigator.of(context).pop();
            },
          ),
      ],
    );
  }
}

/// Whether a profile filter at [index]/[name] is the node's current selection.
/// Index takes precedence (it is the reliable identifier); name is the
/// fallback when no index is recorded — matching the panel's selection logic.
bool _filterMatches(
  String? nodeFilter,
  int? nodeIndex,
  String optionName,
  int optionIndex,
) {
  if (nodeIndex != null) return nodeIndex == optionIndex;
  return (nodeFilter ?? '') == optionName;
}
