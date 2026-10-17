part of '../notes_panel.dart';

class _SentimentPicker extends StatelessWidget {
  final String? value;
  final ValueChanged<String?> onChanged;
  final SkotiqColors colors;

  const _SentimentPicker({
    required this.value,
    required this.onChanged,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    // The STORED value stays the emoji — `JournalNote.sentiment` persists it
    // and old notes must keep resolving — but a colour emoji is a bitmap no
    // theme can retint, so red night could not put it on the red axis and the
    // light theme could not darken it. The glyph is a Lucide icon in the
    // kit's own colour; only the painting changed, not the data.
    const options = <(String, IconData, String)>[
      ('😊', LucideIcons.smile, 'Good night'),
      ('😐', LucideIcons.meh, 'Mixed night'),
      ('😞', LucideIcons.frown, 'Poor night'),
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (opt, icon, tooltip) in options)
          Padding(
            padding: const EdgeInsets.only(left: SkotiqTokens.spaceXs),
            child: SkotiqTooltip(
              message: tooltip,
              child: InkWell(
                onTap: () => onChanged(value == opt ? null : opt),
                borderRadius: SkotiqTokens.borderRadiusMd,
                child: Container(
                  padding: const EdgeInsets.all(SkotiqTokens.spaceXs + 2),
                  decoration: BoxDecoration(
                    color: value == opt
                        ? SkotiqDecorations.selectedSurface(
                            colors.primary,
                            borderRadius: SkotiqTokens.borderRadiusMd,
                            fillAlpha: SkotiqTokens.opacityStatusFill,
                          ).color
                        : Colors.transparent,
                    borderRadius: SkotiqTokens.borderRadiusMd,
                    border: Border.all(
                      color: value == opt ? colors.primary : colors.border,
                    ),
                  ),
                  child: Icon(
                    icon,
                    size: SkotiqTokens.iconSm,
                    color: value == opt ? colors.primary : colors.textSecondary,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// Auto-prompt dialog (post-run "How did this go?" sheet)

/// Auto-prompt that appears after a run completes (when the
/// `notes.prompt_after_run` setting is true). Pre-fills body from run
/// stats and routes through the same [NoteEditorDialog] save path.
///
/// The dialog is intentionally a thin wrapper around [NoteEditorDialog]
/// that pre-populates fields — splitting them keeps the editor logic
/// in one place and means "edit note" / "create note" / "auto-prompt"
/// all behave identically.
class NotesQuickPromptDialog extends ConsumerWidget {
  final String targetId;
  final int? sequenceRunId;
  final String prefilledBody;
  final String? prefilledTitle;

  const NotesQuickPromptDialog({
    super.key,
    required this.targetId,
    required this.sequenceRunId,
    required this.prefilledBody,
    this.prefilledTitle,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    return Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        side: BorderSide(color: colors.border),
      ),
      child: ConstrainedBox(
        constraints: AdaptiveDialogConstraints.hybrid(
          context,
          designMaxWidth: 560,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.messageCircle,
                      size: 22, color: colors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'How did this run go?',
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize17,
                        fontWeight: FontWeight.w700,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(LucideIcons.x, color: colors.textMuted),
                    tooltip: 'Skip',
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'A quick note now is worth a long memory later.',
                style: TextStyle(
                    fontSize: SkotiqTypography.fontSize12,
                    color: colors.textMuted),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                icon: const Icon(LucideIcons.pencil, size: 14),
                label: const Text('Write note'),
                onPressed: () async {
                  Navigator.of(context).pop();
                  await showDialog<JournalNote>(
                    context: context,
                    builder: (_) => NoteEditorDialog(
                      targetId: targetId,
                      sequenceRunId: sequenceRunId,
                      initialBody: prefilledBody,
                      initialTitle: prefilledTitle,
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () async {
                  // "Don't ask again" disables the prompt for the
                  // current user globally; they can re-enable it from
                  // Settings → Sequencer → Notes.
                  await ref.read(notesPromptToggleProvider)(false);
                  if (context.mounted) Navigator.of(context).pop();
                },
                child: const Text("Don't ask again"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
