import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../../../widgets/tutorial_keys/dashboard_keys.dart';

/// Why "Edit layout" refuses in the first-run state.
///
/// One string, used as the tooltip (pointer), the semantics hint (keyboard and
/// screen reader) and the toast (a click that lands on the disabled control's
/// row). A refusal the operator cannot read is indistinguishable from a broken
/// button.
const String standbyEditRefusalReason =
    'Nothing to arrange yet — the first-light checklist has no panels. '
    'Connect a device or load a sequence to arrange tonight’s panels.';

/// The accessible NAME the refusing control publishes.
///
/// A `Semantics(hint:)` cannot carry the refusal. A widget test sees the hint
/// on the merged node, but the Linux accessibility bridge does not export it,
/// and a descendant re-publishes `isEnabled`, so the live AT-SPI node reads
/// `button: 'Edit Dashboard\nEdit Dashboard'  desc=''  states=['sensitive', …]`
/// — enabled, undescribed, byte-identical to the genuinely-enabled button.
///
/// So the refusal rides the one field the bridge demonstrably does export — the
/// name — and the button's own semantics are excluded so nothing underneath can
/// contradict the state. Anything that only *decorates* the node (hint,
/// tooltip, colour) is a bonus, never the disclosure.
String standbyEditSemanticLabel(String editLabel) =>
    '$editLabel, unavailable. $standbyEditRefusalReason';

/// The page header's actions: "Edit layout", plus Widgets and Reset while
/// editing.
///
/// These live in [PageHeader.actions] (06 §Tonight) — the screen no longer has
/// an action row of its own — so they are always ghost buttons: the page's ONE
/// primary is the hero's (02 rule 4).
class DashboardHeaderActions extends ConsumerWidget {
  final bool isEditing;

  /// False in the first-run state: a checklist is not made of arrangeable
  /// tiles, so offering to edit it would swap the page for panels that are not
  /// on it and leave the visible page unconfigurable.
  final bool canEdit;
  final VoidCallback onToggleEdit;
  final VoidCallback onManageWidgets;
  final VoidCallback onResetLayout;

  const DashboardHeaderActions({
    super.key,
    required this.isEditing,
    required this.canEdit,
    required this.onToggleEdit,
    required this.onManageWidgets,
    required this.onResetLayout,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    const buttonSize = ButtonSize.small;
    final editLabel = l10n.text(isEditing ? 'dbDone' : 'tnEditLayout');

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: canEdit ? '' : standbyEditRefusalReason,
          // `excludeSemantics` is the whole point of the second attempt: the
          // button publishes its own node (label + enabled), and a wrapper that
          // merely wraps it gets contradicted — the live probe read `sensitive`
          // on the refusing control and printed the label twice. Excluding the
          // subtree makes this the ONE node for the control, so its state and
          // its name are the only things exported.
          child: Semantics(
            button: true,
            enabled: canEdit,
            excludeSemantics: !canEdit,
            label: canEdit ? null : standbyEditSemanticLabel(editLabel),
            hint: canEdit ? null : standbyEditRefusalReason,
            // A pointer user gets the reason too, rather than a click that
            // lands on a dead control and produces nothing.
            //
            // `Listener`, not `GestureDetector`: SkotiqButton registers its
            // own tap recognizer even while disabled, so it wins the gesture
            // arena and a parent GestureDetector never fires. Pointer events
            // are delivered regardless of the arena.
            child: Listener(
              behavior: HitTestBehavior.deferToChild,
              onPointerDown: canEdit
                  ? null
                  : (_) => ref.read(uiNotificationProvider.notifier).showInfo(
                      standbyEditRefusalReason,
                      title: 'Nothing to arrange'),
              child: SkotiqButton(
                key: DashboardTutorialKeys.editButton,
                label: editLabel,
                icon: isEditing ? LucideIcons.check : LucideIcons.layoutGrid,
                variant:
                    isEditing ? ButtonVariant.secondary : ButtonVariant.ghost,
                size: buttonSize,
                onPressed: canEdit ? onToggleEdit : null,
              ),
            ),
          ),
        ),
        if (isEditing) ...[
          const SizedBox(width: SkotiqTokens.spaceSm),
          SkotiqButton(
            label: l10n.text('dbWidgets'),
            icon: LucideIcons.layoutGrid,
            variant: ButtonVariant.ghost,
            size: buttonSize,
            onPressed: onManageWidgets,
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          SkotiqButton(
            label: l10n.text('dbReset'),
            icon: LucideIcons.refreshCw,
            variant: ButtonVariant.ghost,
            size: buttonSize,
            onPressed: onResetLayout,
          ),
        ],
      ],
    );
  }
}
