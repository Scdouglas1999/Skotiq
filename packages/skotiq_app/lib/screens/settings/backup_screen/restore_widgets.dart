part of '../backup_screen.dart';

class _ReplaceState {
  const _ReplaceState({
    this.pendingBackup,
    this.pendingSafetyBackup,
    this.outcome,
    this.outcomeRestored = false,
  });

  /// The backup that takes the database's place at the next start.
  final String? pendingBackup;
  final String? pendingSafetyBackup;

  /// What the last start did with a replace, in words.
  final String? outcome;
  final bool outcomeRestored;
}

/// Asks how a backup is to be restored and says what each way does.
class _RestoreChoiceDialog extends StatefulWidget {
  const _RestoreChoiceDialog({required this.backupName, required this.onHost});

  final String backupName;
  final bool onHost;

  static Future<RestoreMode?> show(
    BuildContext context, {
    required String backupName,
    required bool onHost,
  }) =>
      showDialog<RestoreMode>(
        context: context,
        builder: (_) =>
            _RestoreChoiceDialog(backupName: backupName, onHost: onHost),
      );

  @override
  State<_RestoreChoiceDialog> createState() => _RestoreChoiceDialogState();
}

class _RestoreChoiceDialogState extends State<_RestoreChoiceDialog> {
  RestoreMode _mode = RestoreMode.merge;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    Widget choice(RestoreMode mode, String title) {
      final selected = _mode == mode;
      return Semantics(
        button: true,
        selected: selected,
        label: title,
        child: InkWell(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          onTap: () => setState(() => _mode = mode),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: selected
                  ? colors.primary.withValues(alpha: 0.08)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
              border: Border.all(
                color: selected ? colors.primary : colors.border,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  selected ? LucideIcons.checkCircle2 : LucideIcons.circle,
                  size: 18,
                  color: selected ? colors.primary : colors.textMuted,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: SkotiqTypography.labelStrong
                            .copyWith(color: colors.textPrimary),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        mode.summary,
                        style: SkotiqTypography.caption.copyWith(
                          color: colors.textSecondary,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return SkotiqDialog(
      title: 'Restore backup',
      width: 520,
      showCloseButton: false,
      actions: [
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
          onPressed: () => Navigator.pop(context),
        ),
        SkotiqButton(
          label: _mode == RestoreMode.merge
              ? 'Add missing records'
              : 'Replace database',
          variant: _mode == RestoreMode.merge
              ? ButtonVariant.primary
              : ButtonVariant.destructive,
          size: ButtonSize.small,
          onPressed: () => Navigator.pop(context, _mode),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.onHost
                ? '"${widget.backupName}" is restored on the imaging '
                    'computer: "this database" below is its database.'
                : '"${widget.backupName}"',
            style:
                SkotiqTypography.caption.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: 12),
          choice(RestoreMode.merge, 'Add what is missing'),
          const SizedBox(height: 8),
          choice(RestoreMode.replace, 'Replace this database'),
        ],
      ),
    );
  }
}

/// How far a backup or restore is.
class _BackupProgressCard extends StatelessWidget {
  const _BackupProgressCard({required this.progress});

  final RestoreProgress progress;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Card(
      color: colors.surface,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: SkotiqProgressBar(
          value: progress.fraction.clamp(0.0, 1.0),
          label: progress.step,
          showPercentage: true,
        ),
      ),
    );
  }
}

/// A notice that stays on the Backup & Restore screen until acted on.
class _NoticeBanner extends StatelessWidget {
  final String title;
  final String message;
  final List<Widget> actions;

  const _NoticeBanner({
    required this.title,
    required this.message,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.refreshCw, size: 18, color: colors.warning),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: SkotiqTypography.labelStrong
                      .copyWith(color: colors.textPrimary),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textSecondary,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: actions),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
