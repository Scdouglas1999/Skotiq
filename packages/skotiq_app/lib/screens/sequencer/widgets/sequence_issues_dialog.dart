import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Read-only list of the live validation issues behind the sequence header's
/// count badges.
///
/// The badges are the only place the builder admits a sequence has problems.
/// This shows what "1 error" means WITHOUT arming a run — the alternative is
/// pressing Start and reading the pre-flight dialog — and selects the offending
/// node when one is named.
class SequenceIssuesDialog extends ConsumerWidget {
  const SequenceIssuesDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
        context: context,
        builder: (_) => const SequenceIssuesDialog(),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final issues = ref.watch(liveValidationProvider).issues;

    // Errors first: they are what blocks Start.
    const order = [
      ValidationSeverity.error,
      ValidationSeverity.warning,
      ValidationSeverity.info,
    ];
    final sorted = [
      for (final severity in order)
        ...issues.where((i) => i.severity == severity),
    ];

    return AlertDialog(
      title: Row(
        children: [
          Icon(LucideIcons.listChecks, size: 18, color: colors.textSecondary),
          const SizedBox(width: 10),
          const Expanded(child: Text('Sequence issues')),
        ],
      ),
      content: ConstrainedBox(
        constraints:
            AdaptiveDialogConstraints.hybrid(context, designMaxWidth: 480),
        child: sorted.isEmpty
            ? Text(
                'No issues. This sequence is ready to start.',
                style:
                    SkotiqTypography.body.copyWith(color: colors.textSecondary),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final issue in sorted)
                      _IssueRow(
                        issue: issue,
                        colors: colors,
                        onSelectNode: issue.affectedNodeId == null
                            ? null
                            : () {
                                ref
                                    .read(selectedNodeIdProvider.notifier)
                                    .state = issue.affectedNodeId;
                                Navigator.of(context).pop();
                              },
                      ),
                  ],
                ),
              ),
      ),
      actions: [
        SkotiqButton(
          label: 'Close',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

class _IssueRow extends StatelessWidget {
  final ValidationIssue issue;
  final SkotiqColors colors;
  final VoidCallback? onSelectNode;

  const _IssueRow({
    required this.issue,
    required this.colors,
    required this.onSelectNode,
  });

  (Color, IconData) get _tone => switch (issue.severity) {
        ValidationSeverity.error => (colors.error, LucideIcons.xCircle),
        ValidationSeverity.warning => (
            colors.warning,
            LucideIcons.alertTriangle
          ),
        ValidationSeverity.info => (colors.info, LucideIcons.info),
      };

  @override
  Widget build(BuildContext context) {
    final (tone, icon) = _tone;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onSelectNode,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 14, color: tone),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      issue.title,
                      style: SkotiqTypography.labelStrong
                          .copyWith(color: colors.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      issue.description,
                      style: SkotiqTypography.caption
                          .copyWith(color: colors.textSecondary),
                    ),
                    if (issue.resolutionHint != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        issue.resolutionHint!,
                        style: SkotiqTypography.caption.copyWith(color: tone),
                      ),
                    ],
                  ],
                ),
              ),
              if (onSelectNode != null)
                Icon(
                  LucideIcons.chevronRight,
                  size: 14,
                  color: colors.textMuted,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
