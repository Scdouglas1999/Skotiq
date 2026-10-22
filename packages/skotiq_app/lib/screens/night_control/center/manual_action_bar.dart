// The manual-action bar under the frame: Snapshot, Loop, Autofocus, Solve &
// sync, Center, plus Dither and Flip during a run. The buttons and their
// gating come from the action controller (P2). Pressing one only opens its
// panel tab; the action itself starts from the button in that tab.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart' show linkedManualActionProvider;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../actions/manual_action_gating.dart' show manualActionKey;
import '../actions/night_action_controller.dart';
import '../data/plan/night_run_phase_provider.dart';
import '../night_control_contracts.dart';
import '../night_control_layout.dart';

/// The action the window at the other end of the link is running, while it
/// is current; null when there is none.
ManualActionId? _linkedAction(WidgetRef ref) {
  final linked = ref.watch(linkedManualActionProvider);
  if (linked == null || !linked.isCurrent(DateTime.now())) {
    return null;
  }
  return ManualActionId.values
      .where((id) => id.name == linked.action)
      .firstOrNull;
}

/// The run phases in which a manual action pauses the run first.
bool _runLoaded(NightRunPhase phase) =>
    phase == NightRunPhase.running ||
    phase == NightRunPhase.pausedByUser ||
    phase == NightRunPhase.pausedForAction;

class ManualActionBar extends ConsumerWidget {
  const ManualActionBar({super.key});

  static const double height = 44;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final l10n = context.l10n;
    final density = NightControlDensity.maybeOf(context);
    final actions = ref.watch(nightManualActionsProvider);
    final state = ref.watch(nightActionStateProvider);
    final phase = ref.watch(nightRunPhaseProvider);
    final hideSubs = density?.hideActionSubLabels == true;
    final collapseHint = density?.collapseActionHint == true;

    final linked = state.isBusy ? null : _linkedAction(ref);
    final hint = linked != null
        ? '${l10n.text(manualActionKey('nightActBusy', linked))} · '
            '${l10n.text('nightActOtherWindow')}'
        : l10n.text(_runLoaded(phase) ? 'nightActHint' : 'nightCtrHintIdle');
    final error = state.error?.resolve(l10n);

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: l10n.text('nightCtrActionsLabel'),
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(top: BorderSide(color: colors.border)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: SkotiqTokens.spaceSm),
        child: Row(
          children: <Widget>[
            Expanded(
              child: SingleChildScrollView(
                primary: false,
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: <Widget>[
                    for (final action in actions) ...<Widget>[
                      _ActionButton(action: action, hideSub: hideSubs),
                      const SizedBox(width: 6),
                    ],
                    if (state.isBusy)
                      _CancelButton(
                        onPressed: () => unawaited(
                          ref.read(nightActionApiProvider).cancel(),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (error != null)
              _HintIcon(
                message: error,
                icon: LucideIcons.alertCircle,
                color: colors.error,
                collapsed: collapseHint,
              )
            else
              _HintIcon(
                message: hint,
                icon: LucideIcons.info,
                color: linked != null ? colors.warning : colors.textMuted,
                collapsed: collapseHint,
              ),
          ],
        ),
      ),
    );
  }
}

/// One action. Pressing it shows its panel tab and starts nothing. One that
/// cannot run now is muted and says why in its tooltip and semantics hint,
/// and still opens its tab.
class _ActionButton extends ConsumerWidget {
  const _ActionButton({required this.action, required this.hideSub});

  final ManualActionVm action;
  final bool hideSub;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final l10n = context.l10n;
    final label = action.label.resolve(l10n);
    final sub = hideSub ? null : action.sub?.resolve(l10n);
    final reason = action.enabled ? null : action.disabledReason?.resolve(l10n);
    final running = action.running;

    final Color fill;
    final Color ink;
    if (running) {
      fill = colors.warning.withValues(alpha: SkotiqTokens.opacityStatusFill);
      ink = colors.warning;
    } else if (action.enabled) {
      fill = colors.surfaceHover;
      ink = colors.textPrimary;
    } else {
      fill = colors.surfaceHover.withValues(alpha: SkotiqTokens.opacityMuted);
      ink = colors.textMuted;
    }

    final button = Semantics(
      button: true,
      enabled: true,
      label: sub == null ? label : '$label, $sub',
      hint: reason,
      excludeSemantics: true,
      onTap: () => _press(ref),
      child: Material(
        color: fill,
        shape: RoundedRectangleBorder(
          borderRadius: SkotiqTokens.borderRadiusLg,
          side: running
              ? BorderSide(
                  color: colors.warning.withValues(
                    alpha: SkotiqTokens.opacityEmphasisBorder,
                  ),
                )
              : BorderSide.none,
        ),
        child: InkWell(
          onTap: () => _press(ref),
          borderRadius: SkotiqTokens.borderRadiusLg,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 30),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    label,
                    style: SkotiqTypography.labelStrongSm.copyWith(color: ink),
                  ),
                  if (sub != null) ...<Widget>[
                    const SizedBox(width: 6),
                    Text(
                      sub,
                      style: SkotiqTypography.captionSm.copyWith(
                        color: running ? ink : colors.textMuted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (reason == null) return button;
    return Tooltip(message: reason, excludeFromSemantics: true, child: button);
  }

  void _press(WidgetRef ref) {
    ref.read(nightPanelTabProvider.notifier).state = action.id.panelTab;
  }
}

class _CancelButton extends StatelessWidget {
  const _CancelButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final label = context.l10n.text('nightActCancel');
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onPressed,
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: SkotiqTokens.borderRadiusLg,
          side: BorderSide(color: colors.borderHighlight),
        ),
        child: InkWell(
          onTap: onPressed,
          borderRadius: SkotiqTokens.borderRadiusLg,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 30),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Center(
                widthFactor: 1,
                child: Text(
                  label,
                  style: SkotiqTypography.labelStrongSm.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The bar's trailing note: the text itself, or an info icon carrying it in
/// a tooltip when the center column is narrow.
class _HintIcon extends StatelessWidget {
  const _HintIcon({
    required this.message,
    required this.icon,
    required this.color,
    required this.collapsed,
  });

  final String message;
  final IconData icon;
  final Color color;
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    if (collapsed) {
      return Tooltip(
        message: message,
        child: Semantics(
          label: message,
          excludeSemantics: true,
          child: Padding(
            padding: const EdgeInsets.only(left: SkotiqTokens.spaceSm),
            child: Icon(icon, size: 16, color: color),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: SkotiqTokens.spaceSm),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: Text(
          message,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: SkotiqTypography.captionSm.copyWith(color: color),
        ),
      ),
    );
  }
}
