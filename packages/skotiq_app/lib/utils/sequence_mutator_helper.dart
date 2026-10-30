import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'snackbar_helper.dart';

/// Universal wrapper for sequence mutations originating from the UI.
///
/// Every mutation site routes through here so the catch and the user-facing
/// feedback are identical: the editor raises typed exceptions
/// ([SequenceLockedException], [SnippetDeserializationException],
/// [CrossParentReorderException], [NoActiveSequenceException],
/// [SequenceValidationFailedException]) which an uncaught call site turns into
/// an undismissable red-error overlay.
///
/// Returns `true` when the action completed without raising one of the known
/// editor exceptions; `false` when one was caught and surfaced (the helper has
/// already shown the snackbar / dialog).
///
/// Synchronous throws from NON-editor code (e.g. `StateError`) are deliberately
/// NOT swallowed — they bubble out to the caller or the framework, because a
/// surprise crash is a bug to fix rather than a user-facing error to paper
/// over.
Future<bool> withSequenceMutation(
  BuildContext context,
  WidgetRef ref, {
  required String operationName,
  required Future<void> Function() action,
}) async {
  try {
    await action();
    return true;
  } on SequenceLockedException catch (e) {
    if (!context.mounted) return false;
    context.showErrorSnackBar('Could not $operationName: ${e.message}');
    return false;
  } on NoActiveSequenceException catch (e) {
    if (!context.mounted) return false;
    context.showErrorSnackBar('Could not $operationName: ${e.message}');
    return false;
  } on CrossParentReorderException catch (e) {
    if (!context.mounted) return false;
    context.showErrorSnackBar('Could not $operationName: ${e.message}');
    return false;
  } on SnippetDeserializationException catch (e) {
    if (!context.mounted) return false;
    // Snippet/template imports get a dialog rather than a snackbar so
    // the user understands the snippet was rejected as a whole (not
    // imported partially). Wording mirrors the spec: "Snippet contains
    // unknown node type 'X' — this may be from a newer version of
    // Skotiq. The snippet was not imported."
    await _showSnippetRejectedDialog(context, e, operationName);
    return false;
  } on SequenceValidationFailedException catch (e) {
    if (!context.mounted) return false;
    // Validation failures get the rich preflight-style dialog with a
    // per-issue card and a "force action anyway" escape hatch.
    await showValidationIssueDialog(
      context,
      issues: e.issues,
      operationName: operationName,
      // No retry callback by default — caller can use
      // `showValidationIssueDialog` directly if they need the "force"
      // path (e.g. saveSequenceFile reruns with forceExport: true).
    );
    return false;
  }
}

Future<void> _showSnippetRejectedDialog(
  BuildContext context,
  SnippetDeserializationException e,
  String operationName,
) async {
  final colors = SkotiqColors.of(context);
  await showDialog<void>(
    context: context,
    builder: (ctx) => SkotiqDialog(
      title: 'Could not $operationName',
      icon: LucideIcons.alertTriangle,
      width: 420,
      actions: [
        SkotiqButton(
          onPressed: () => Navigator.of(ctx).pop(),
          label: 'OK',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
        ),
      ],
      child: Text(
        'Snippet "${e.snippetName}" contains unknown node type '
        '"${e.unknownType}" — this may be from a newer version of '
        'Skotiq. The snippet was not imported.',
        style: TextStyle(
            color: colors.textSecondary, fontSize: SkotiqTypography.fontSize13),
      ),
    ),
  );
}

/// Show a structured dialog listing each validation issue with severity
/// icon, category badge, description, and `resolutionHint`. Returns
/// `true` if the user clicked the "force" button — the caller is then
/// responsible for re-invoking whatever wanted to bypass the gate (e.g.
/// `exportSequence(forceExport: true)`).
///
/// Returns `false` (or `null`, treated as `false`) when the user
/// dismissed the dialog without choosing to force.
///
/// Pass [forceLabel] = `null` to suppress the force button entirely (used
/// when the calling operation has no "force anyway" mode — e.g. import).
Future<bool> showValidationIssueDialog(
  BuildContext context, {
  required List<ValidationIssue> issues,
  required String operationName,
  String? forceLabel = 'Force action anyway',
}) async {
  final colors = SkotiqColors.of(context);

  final errors =
      issues.where((i) => i.severity == ValidationSeverity.error).toList();
  final warnings =
      issues.where((i) => i.severity == ValidationSeverity.warning).toList();
  final infos =
      issues.where((i) => i.severity == ValidationSeverity.info).toList();

  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      return Dialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        ),
        child: ConstrainedBox(
          constraints: AdaptiveDialogConstraints.hybrid(
            ctx,
            designMaxWidth: 520,
            designMaxHeight: 600,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ValidationDialogHeader(
                colors: colors,
                operationName: operationName,
                errorCount: errors.length,
                warningCount: warnings.length,
                infoCount: infos.length,
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final issue in issues)
                        _ValidationIssueCard(colors: colors, issue: issue),
                    ],
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: colors.border)),
                ),
                child: Row(
                  children: [
                    const Spacer(),
                    SkotiqButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      label: 'Cancel',
                      variant: ButtonVariant.ghost,
                      size: ButtonSize.small,
                    ),
                    if (forceLabel != null) ...[
                      const SizedBox(width: 12),
                      SkotiqButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        label: forceLabel,
                        variant: ButtonVariant.destructive,
                        size: ButtonSize.small,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
  return result ?? false;
}

class _ValidationDialogHeader extends StatelessWidget {
  final SkotiqColors colors;
  final String operationName;
  final int errorCount;
  final int warningCount;
  final int infoCount;

  const _ValidationDialogHeader({
    required this.colors,
    required this.operationName,
    required this.errorCount,
    required this.warningCount,
    required this.infoCount,
  });

  @override
  Widget build(BuildContext context) {
    final hasErrors = errorCount > 0;
    final color = hasErrors ? colors.error : colors.warning;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: SkotiqDecorations.statusChip(
              color,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
              bordered: false,
            ),
            child: Icon(
              hasErrors ? LucideIcons.xCircle : LucideIcons.alertTriangle,
              color: color,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Could not $operationName',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize15,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hasErrors
                      ? 'Sequence has $errorCount '
                          'error${errorCount == 1 ? '' : 's'} '
                          'blocking this action.'
                      : 'Sequence has $warningCount '
                          'warning${warningCount == 1 ? '' : 's'}.',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize12,
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(LucideIcons.x, color: colors.textMuted, size: 18),
            tooltip: 'Close',
            onPressed: () => Navigator.of(context).pop(false),
          ),
        ],
      ),
    );
  }
}

class _ValidationIssueCard extends StatelessWidget {
  final SkotiqColors colors;
  final ValidationIssue issue;

  const _ValidationIssueCard({required this.colors, required this.issue});

  @override
  Widget build(BuildContext context) {
    Color severityColor;
    IconData severityIcon;
    switch (issue.severity) {
      case ValidationSeverity.error:
        severityColor = colors.error;
        severityIcon = LucideIcons.xCircle;
        break;
      case ValidationSeverity.warning:
        severityColor = colors.warning;
        severityIcon = LucideIcons.alertTriangle;
        break;
      case ValidationSeverity.info:
        severityColor = colors.info;
        severityIcon = LucideIcons.info;
        break;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: SkotiqDecorations.statusChip(
              severityColor,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
              bordered: false,
            ),
            child: Icon(severityIcon, size: 14, color: severityColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        issue.title,
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize13,
                          fontWeight: FontWeight.w600,
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius:
                            BorderRadius.circular(SkotiqTokens.radiusXs),
                      ),
                      child: Text(
                        issue.category.label,
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize9,
                          fontWeight: FontWeight.w600,
                          color: colors.textMuted,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  issue.description,
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize12,
                    color: colors.textSecondary,
                  ),
                ),
                if (issue.resolutionHint != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(LucideIcons.lightbulb,
                          size: 12, color: colors.primary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          issue.resolutionHint!,
                          style: TextStyle(
                            fontSize: SkotiqTypography.fontSize11,
                            color: colors.primary,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
