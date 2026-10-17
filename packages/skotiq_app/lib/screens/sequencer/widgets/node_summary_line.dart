// The row-level renderer for a node's at-a-glance summary. Turns the pure
// [SummaryFragment] list from `node_summary.dart` into design-system chips +
// muted text, and wires editable chips to the anchored inline editors in
// `node_summary_inline_editors.dart`.
//
// It owns ZERO domain logic and ZERO formatting: `node_summary.dart` produces
// the terse, capped (1-3) fragment list and decides which fragments are
// editable. This layer only paints them and routes taps.
//
// CHIP TEMPLATE: emphasized/editable chips mirror `_WatchdogBadge` in
// `sequence_tree.dart` exactly — `Container(padding: paddingXs,
// decoration: SkotiqDecorations.statusChip(tint, borderRadius:
// borderRadiusSm))` with an `overline`-styled label and optional `iconXs`
// lead. The tint is the node's category color, mapped identically to
// `sequence_tree`'s `_getCategoryColor`, so a summary chip reads as belonging
// to its node's color family.
//
// EDIT ROUTING: a tapped [EditableFragment] calls [showInlineNodeEditor]
// which commits through `currentSequenceProvider.notifier.updateNode`
// — the same path the full properties panel uses (undo/redo + autosave +
// `modifiedAt` for free). Tapping is gated on [canEditSequenceProvider]: while
// the sequence is running we render the editable fragment as a plain,
// non-tappable chip with NO chevron, so there is no fake affordance.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'node_summary.dart';
import 'node_summary_inline_editors.dart';

/// Renders the at-a-glance summary for [node] on a single line.
///
/// Lays the [nodeSummary] fragments left-to-right, wrapping to a second run
/// only when the row is too narrow. [StaticFragment]s render as muted
/// `labelQuiet` text (emphasized → a read-only chip); [EditableFragment]s
/// render as tappable chips that open the C3 inline editor — but only while
/// [canEditSequenceProvider] is true.
///
/// [mutedColorOverride] lets the tree pass the status-derived muted color used
/// for skipped/cancelled rows so the summary dims in lock-step with the rest
/// of the row.
class NodeSummaryLine extends ConsumerWidget {
  final SequenceNode node;
  final SkotiqColors colors;
  final bool isMobile;
  final Color? mutedColorOverride;

  const NodeSummaryLine({
    super.key,
    required this.node,
    required this.colors,
    required this.isMobile,
    this.mutedColorOverride,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // With `useSettingsDefaults` on, the executor resolves the AF method from
    // AppSettings and ignores the node's own field — the row must report the
    // global value, not the dead one.
    final localNode = node;
    final globalAfMethod =
        localNode is AutofocusNode && localNode.useSettingsDefaults
            ? ref.watch(autofocusSettingsProvider).method
            : null;
    final fragments =
        nodeSummary(localNode, globalAutofocusMethod: globalAfMethod);
    if (fragments.isEmpty) return const SizedBox.shrink();

    final canEdit = ref.watch(canEditSequenceProvider);
    final tint = _categoryColor(node.category);
    final mutedColor = mutedColorOverride ?? colors.textMuted;

    return Wrap(
      spacing: SkotiqTokens.spaceXs,
      runSpacing: SkotiqTokens.spaceXs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final fragment in fragments)
          switch (fragment) {
            StaticFragment(emphasized: false) => _MutedText(
                text: fragment.text,
                color: mutedColor,
              ),
            StaticFragment(emphasized: true) => _SummaryChip(
                text: fragment.text,
                icon: fragment.icon,
                tint: tint,
                colors: colors,
              ),
            EditableFragment() => _EditableChip(
                fragment: fragment,
                node: node,
                tint: tint,
                colors: colors,
                canEdit: canEdit,
              ),
          },
      ],
    );
  }

  /// Map [category] to its chip tint, mirroring `sequence_tree`'s
  /// `_getCategoryColor` exactly so summary chips match their node's color.
  Color _categoryColor(NodeCategory category) =>
      categoryColorForTesting(colors, category);

  /// The same mapping as [_categoryColor], reachable from tests so the
  /// agreement check against `nodeCategoryTint` (which the ledger row's glyph
  /// tint uses) cannot drift — the two must produce identical tints for every
  /// category.
  @visibleForTesting
  static Color categoryColorForTesting(
    SkotiqColors colors,
    NodeCategory category,
  ) {
    switch (category) {
      case NodeCategory.instruction:
        return colors.primary;
      case NodeCategory.trigger:
        return colors.warning;
      case NodeCategory.logic:
        return colors.accent;
      case NodeCategory.target:
        return colors.warning;
    }
  }
}

/// Muted inline text for a non-emphasized [StaticFragment]. `labelQuiet`
/// (11px) is the design-system muted-label token.
class _MutedText extends StatelessWidget {
  final String text;
  final Color color;

  const _MutedText({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: SkotiqTypography.labelQuiet.copyWith(color: color),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// A read-only summary chip for an emphasized [StaticFragment]. Same visual as
/// `_WatchdogBadge`: a tinted `statusChip` with an `overline` label and an
/// optional leading icon. No tap handler.
class _SummaryChip extends StatelessWidget {
  final String text;
  final IconData? icon;
  final Color tint;
  final SkotiqColors colors;

  const _SummaryChip({
    required this.text,
    required this.icon,
    required this.tint,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: SkotiqTokens.paddingXs,
      decoration: SkotiqDecorations.statusChip(
        tint,
        borderRadius: SkotiqTokens.borderRadiusSm,
      ),
      child: _ChipContent(
        text: text,
        icon: icon,
        tint: tint,
        colors: colors,
        showChevron: false,
      ),
    );
  }
}

/// An [EditableFragment] chip. Visually identical to [_SummaryChip] but:
///   * when [canEdit] is true it is tappable (opens the C3 inline editor),
///     carries a trailing chevron as the edit affordance, and is wrapped in a
///     tooltip + button [Semantics];
///   * when [canEdit] is false it degrades to a plain, non-tappable chip with
///     NO chevron — no fake affordance while the sequence is running.
class _EditableChip extends ConsumerWidget {
  final EditableFragment fragment;
  final SequenceNode node;
  final Color tint;
  final SkotiqColors colors;
  final bool canEdit;

  const _EditableChip({
    required this.fragment,
    required this.node,
    required this.tint,
    required this.colors,
    required this.canEdit,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chip = Container(
      padding: SkotiqTokens.paddingXs,
      decoration: SkotiqDecorations.statusChip(
        tint,
        borderRadius: SkotiqTokens.borderRadiusSm,
      ),
      child: _ChipContent(
        text: fragment.displayValue,
        icon: fragment.icon,
        tint: tint,
        colors: colors,
        showChevron: canEdit,
      ),
    );

    if (!canEdit) {
      return chip;
    }

    final label = _editLabel(fragment.kind);
    return SkotiqTooltip(
      message: 'Tap to edit $label',
      child: Semantics(
        // Semantics publishes isEnabled only when this field is given;
        // omitting it makes assistive tech announce a live control as
        // disabled. Measured on the running app 2026-08-09.
        enabled: true,
        button: true,
        label: label,
        value: fragment.displayValue,
        child: InkWell(
          borderRadius: SkotiqTokens.borderRadiusSm,
          onTap: () {
            final box = context.findRenderObject();
            if (box is! RenderBox) {
              // The chip is always laid out (we are inside its own build), so a
              // missing/invalid render object means the widget tree is in an
              // impossible state — surface it rather than silently no-op.
              throw StateError(
                'NodeSummaryLine editable chip has no RenderBox to anchor the '
                'inline editor (kind ${fragment.kind}, node "${node.id}").',
              );
            }
            showInlineNodeEditor(
              context: context,
              ref: ref,
              node: node,
              kind: fragment.kind,
              anchor: box,
            );
          },
          child: chip,
        ),
      ),
    );
  }
}

/// The inner content shared by static and editable chips: optional lead icon,
/// `overline` label tinted to match the chip, and an optional trailing chevron
/// (the editability affordance).
class _ChipContent extends StatelessWidget {
  final String text;
  final IconData? icon;
  final Color tint;
  final SkotiqColors colors;
  final bool showChevron;

  const _ChipContent({
    required this.text,
    required this.icon,
    required this.tint,
    required this.colors,
    required this.showChevron,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: SkotiqTokens.iconXs, color: tint),
          const SizedBox(width: SkotiqTokens.spaceXs),
        ],
        Flexible(
          child: Text(
            text,
            style: SkotiqTypography.overline.copyWith(color: tint),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (showChevron) ...[
          const SizedBox(width: SkotiqTokens.spaceXs),
          Icon(
            LucideIcons.chevronDown,
            size: SkotiqTokens.iconXs,
            color: colors.textMuted,
          ),
        ],
      ],
    );
  }
}

/// A short, human-readable name for [kind] used in the tooltip + accessibility
/// label of an editable chip (e.g. "Tap to edit exposure count").
String _editLabel(InlineEditKind kind) {
  switch (kind) {
    case InlineEditKind.exposureFilter:
    case InlineEditKind.filterChange:
      return 'filter';
    case InlineEditKind.exposureCount:
      return 'exposure count';
    case InlineEditKind.loopIterations:
      return 'loop iterations';
    case InlineEditKind.exposureDuration:
      return 'exposure duration';
    case InlineEditKind.delaySeconds:
      return 'delay';
    case InlineEditKind.gain:
      return 'gain';
    case InlineEditKind.binning:
      return 'binning';
    case InlineEditKind.ditherPixels:
      return 'dither amount';
    case InlineEditKind.ditherPattern:
      return 'dither pattern';
    case InlineEditKind.centerTolerance:
      return 'centering tolerance';
    case InlineEditKind.autofocusMethod:
      return 'autofocus method';
    case InlineEditKind.coolTargetTemp:
      return 'target temperature';
  }
}
