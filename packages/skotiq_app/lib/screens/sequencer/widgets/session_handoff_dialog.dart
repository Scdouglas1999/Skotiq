import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Multi-night carry-over banner / dialog.
///
/// Surfaces when one or more of the sequence's targets has unfinished
/// integration from a recent prior session. Lets the operator pick a
/// global decision (Resume / Restart / Continue New) plus per-target
/// overrides. The decisions are written to
/// [sessionHandoffDecisionProvider] so the executor and the
/// IntegrationBudget tracker can read them at sequence start.
///
/// **Not** a hard pre-flight blocker — the dialog can be dismissed and
/// the sequence still starts. The default decision when the user
/// dismisses without choosing is `continueNew`, which preserves the
/// historical frames in the database but doesn't apply any carry-over
/// to the in-progress budget.
class SessionHandoffDialog extends ConsumerStatefulWidget {
  /// Sequence database id (when persisted). Used as the key for the
  /// per-target decision state so two independent sequences can each
  /// have their own choice.
  final int? sequenceId;

  /// Detected carry-over candidates — at least one is required (the
  /// helper short-circuits when the list is empty).
  final List<SessionCarryOver> carryOvers;

  /// Called after the user picks a decision so the caller can resume
  /// the start-sequence flow. The map is keyed by target id and the
  /// value is the operator's choice for that target.
  final void Function(Map<int, SessionHandoffDecision> decisions)?
      onDecisionsChosen;

  const SessionHandoffDialog({
    super.key,
    required this.sequenceId,
    required this.carryOvers,
    this.onDecisionsChosen,
  });

  /// Convenience launcher used by the pre-flight flow.
  static Future<Map<int, SessionHandoffDecision>?> show({
    required BuildContext context,
    required int? sequenceId,
    required List<SessionCarryOver> carryOvers,
  }) {
    if (carryOvers.isEmpty) return Future.value(null);
    return showDialog<Map<int, SessionHandoffDecision>>(
      context: context,
      builder: (_) => SessionHandoffDialog(
        sequenceId: sequenceId,
        carryOvers: carryOvers,
        onDecisionsChosen: (map) =>
            Navigator.of(context).pop<Map<int, SessionHandoffDecision>>(map),
      ),
    );
  }

  @override
  ConsumerState<SessionHandoffDialog> createState() =>
      _SessionHandoffDialogState();
}

class _SessionHandoffDialogState extends ConsumerState<SessionHandoffDialog> {
  late Map<int, SessionHandoffDecision> _decisions;

  @override
  void initState() {
    super.initState();
    // Default each target to Resume — that's the value-add of the
    // banner: "carry over by default unless the operator says no".
    _decisions = {
      for (final c in widget.carryOvers)
        c.targetId: SessionHandoffDecision.resume,
    };
  }

  /// Carry-over integration, in the one h/m/s shape the rest of the app uses
  /// (see `formatIntegrationSeconds`).
  ///
  /// Rounding to whole minutes renders a real 12-second prior session as "0m",
  /// beside its own non-zero accepted-frame count. Sub-minute carry-overs are
  /// exactly the ones a handoff decision is least obvious for, so they must not
  /// read as zero.
  String _formatHours(double seconds) => formatIntegrationSeconds(seconds);

  String _formatDate(DateTime dt) =>
      DateFormat('MMM d, yyyy').format(dt.toLocal());

  void _applyAll(SessionHandoffDecision decision) {
    setState(() {
      _decisions = {
        for (final c in widget.carryOvers) c.targetId: decision,
      };
    });
  }

  void _confirm() {
    // Persist the operator's choice keyed by `(sequenceId, targetId)`
    // so the pre-flight check next time can see what was chosen.
    for (final entry in _decisions.entries) {
      final key = (sequenceId: widget.sequenceId, targetId: entry.key);
      ref.read(sessionHandoffDecisionProvider(key).notifier).state =
          entry.value;
    }
    widget.onDecisionsChosen?.call(_decisions);
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final dialogSize = AdaptiveDialogConstraints.dialogSize(
      context,
      designWidth: 640,
      designHeight: 600,
    );

    return Dialog(
      backgroundColor: colors.surfaceElevated,
      shape: RoundedRectangleBorder(
        borderRadius: SkotiqTokens.borderRadiusMd,
        side: BorderSide(color: colors.border),
      ),
      child: SizedBox(
        width: dialogSize.width,
        height: dialogSize.height,
        child: Column(
          mainAxisSize: MainAxisSize.max,
          children: [
            _buildHeader(colors),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildSummary(colors),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _BulkButton(
                          label: 'Resume all',
                          icon: LucideIcons.playCircle,
                          onPressed: () =>
                              _applyAll(SessionHandoffDecision.resume),
                          colors: colors,
                        ),
                        _BulkButton(
                          label: 'Restart all',
                          icon: LucideIcons.rotateCcw,
                          onPressed: () =>
                              _applyAll(SessionHandoffDecision.restart),
                          colors: colors,
                        ),
                        _BulkButton(
                          label: 'Continue new',
                          icon: LucideIcons.arrowRight,
                          onPressed: () =>
                              _applyAll(SessionHandoffDecision.continueNew),
                          colors: colors,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    for (final co in widget.carryOvers) ...[
                      _buildCarryOverTile(colors, co),
                      const SizedBox(height: 8),
                    ],
                  ],
                ),
              ),
            ),
            _buildActions(colors),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(SkotiqColors colors) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.history, size: 22, color: colors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Resume from previous night?',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize16,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
                Text(
                  '${widget.carryOvers.length} target'
                  '${widget.carryOvers.length == 1 ? '' : 's'} '
                  'have unfinished integration in a recent session.',
                  style: TextStyle(
                      fontSize: SkotiqTypography.fontSize12,
                      color: colors.textMuted),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(LucideIcons.x, color: colors.textMuted),
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildSummary(SkotiqColors colors) {
    final totalCampaignSecs = widget.carryOvers
        .fold<double>(0.0, (sum, c) => sum + c.campaignIntegrationSecs);
    final totalPrevSecs = widget.carryOvers
        .fold<double>(0.0, (sum, c) => sum + c.previousIntegrationSecs);
    final totalBudgetSecs = widget.carryOvers
        .where((c) => c.budgetSecs != null)
        .fold<double>(0.0, (sum, c) => sum + c.budgetSecs!);
    return SkotiqCard(
      padding: const EdgeInsets.all(12),
      borderRadius: SkotiqTokens.radiusInline8,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Carry-over total',
                  style: TextStyle(
                      fontSize: SkotiqTypography.fontSize11,
                      color: colors.textMuted),
                ),
                const SizedBox(height: 2),
                Text(
                  _formatHours(totalCampaignSecs),
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize18,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Most recent night',
                  style: TextStyle(
                      fontSize: SkotiqTypography.fontSize11,
                      color: colors.textMuted),
                ),
                const SizedBox(height: 2),
                Text(
                  _formatHours(totalPrevSecs),
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize18,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          if (totalBudgetSecs > 0)
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Budget remaining',
                    style: TextStyle(
                        fontSize: SkotiqTypography.fontSize11,
                        color: colors.textMuted),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _formatHours((totalBudgetSecs - totalCampaignSecs)
                        .clamp(0, double.infinity)),
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize18,
                      fontWeight: FontWeight.w700,
                      color: colors.primary,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCarryOverTile(SkotiqColors colors, SessionCarryOver co) {
    final decision = _decisions[co.targetId] ?? SessionHandoffDecision.resume;
    final filterChips =
        co.perFilterIntegrationSecs.entries.where((e) => e.value > 0).map((e) {
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: colors.surfaceAlt,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
          ),
          child: Text(
            '${e.key}: ${_formatHours(e.value)}',
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize10,
                color: colors.textSecondary),
          ),
        ),
      );
    }).toList();

    return SkotiqCard(
      variant: CardVariant.subtle,
      padding: const EdgeInsets.all(12),
      borderRadius: SkotiqTokens.radiusInline8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.target, size: 16, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  co.targetName,
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize13,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              if (co.previousSessionStartedAt != null)
                Text(
                  _formatDate(co.previousSessionStartedAt!),
                  style: TextStyle(
                      fontSize: SkotiqTypography.fontSize11,
                      color: colors.textMuted),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Carry-over: ${co.targetName} has '
            '${_formatHours(co.previousIntegrationSecs)} from the most '
            'recent session '
            '(${co.previousAcceptedFrames} accepted frames). '
            'Campaign total: ${_formatHours(co.campaignIntegrationSecs)}.',
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize12,
                color: colors.textSecondary),
          ),
          if (co.budgetSecs != null) ...[
            const SizedBox(height: 4),
            Text(
              'Budget ${_formatHours(co.budgetSecs!)}; '
              '${_formatHours(co.remainingSecs ?? 0)} remaining.',
              style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: colors.textMuted),
            ),
          ],
          if (filterChips.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(children: filterChips),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _DecisionChip(
                label: 'Resume',
                selected: decision == SessionHandoffDecision.resume,
                onTap: () => setState(() {
                  _decisions[co.targetId] = SessionHandoffDecision.resume;
                }),
                colors: colors,
              ),
              _DecisionChip(
                label: 'Restart',
                selected: decision == SessionHandoffDecision.restart,
                onTap: () => setState(() {
                  _decisions[co.targetId] = SessionHandoffDecision.restart;
                }),
                colors: colors,
              ),
              _DecisionChip(
                label: 'Continue new',
                selected: decision == SessionHandoffDecision.continueNew,
                onTap: () => setState(() {
                  _decisions[co.targetId] = SessionHandoffDecision.continueNew;
                }),
                colors: colors,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActions(SkotiqColors colors) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          SkotiqButton(
            label: 'Cancel',
            variant: ButtonVariant.ghost,
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 8),
          SkotiqButton(
            label: 'Confirm',
            icon: LucideIcons.check,
            onPressed: _confirm,
          ),
        ],
      ),
    );
  }
}

class _BulkButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final SkotiqColors colors;

  const _BulkButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return SkotiqButton(
      label: label,
      icon: icon,
      onPressed: onPressed,
      variant: ButtonVariant.outline,
      size: ButtonSize.small,
    );
  }
}

class _DecisionChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final SkotiqColors colors;

  const _DecisionChip({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: SkotiqTokens.borderRadiusSm,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color:
              selected ? colors.primary.withValues(alpha: 0.2) : colors.surface,
          borderRadius: SkotiqTokens.borderRadiusSm,
          border: Border.all(
            color: selected ? colors.primary : colors.border,
            width: selected ? 1.5 : 1.0,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize11,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? colors.primary : colors.textSecondary,
          ),
        ),
      ),
    );
  }
}
