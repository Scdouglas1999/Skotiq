import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/user_facing_error.dart';

part 'notes_panel/target_notes_dialog.dart';
part 'notes_panel/note_tile.dart';
part 'notes_panel/note_editor_dialog.dart';
part 'notes_panel/sentiment_and_prompt.dart';
part 'notes_panel/global_notes_dialog.dart';

/// Embeddable notes UI used by the target header card,
/// the session report dialog, and the history tab.
///
/// Two public surfaces:
///   * [TargetNotesSection]: collapsed-by-default panel that shows the
///     latest N notes for a target, with "View all" / "Add note" actions.
///   * [RunNotesSection]: same shape but scoped to a specific
///     `sequence_runs.id` instead of a target.
///   * [NoteEditorDialog]: modal sheet for creating or editing a note.
///   * [NotesQuickPromptDialog]: post-run "how did it go?" prompt that
///     pre-fills body from the just-finished run stats.
///
/// Why one file: every UI surface here renders the same `JournalNote`
/// record with the same affordances (markdown body, tag chips, timestamp,
/// edit/delete), so a tweak to the markdown renderer or tag-chip styling has
/// one place to land.

/// Shared "delete this note?" confirmation used by every notes surface
/// (target section, run section, target dialog, editor). Standardizes on
/// [SkotiqDialog] and the single delete-on-confirm path so the four notes
/// surfaces cannot drift. Returns whether the note
/// was actually deleted (false on cancel) so callers like the editor can
/// decide whether to also dismiss themselves.
Future<bool> confirmDeleteNote(
  BuildContext context,
  WidgetRef ref,
  JournalNote note,
) async {
  final colors = SkotiqColors.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => SkotiqDialog(
      title: 'Delete note?',
      icon: LucideIcons.trash2,
      width: 420,
      bodyPadding: const EdgeInsets.all(SkotiqTokens.spaceXl),
      actions: [
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
          onPressed: () => Navigator.of(ctx).pop(false),
        ),
        SkotiqButton(
          label: 'Delete',
          variant: ButtonVariant.destructive,
          size: ButtonSize.small,
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      ],
      child: Text(
        'This note will be permanently removed.',
        style: TextStyle(color: colors.textSecondary),
      ),
    ),
  );
  if (confirmed == true) {
    await ref.read(notesRepositoryProvider).deleteNote(note.id);
    return true;
  }
  return false;
}

// Section widgets (embedded in TargetHeaderCard / SessionReportDialog / HistoryTab)

/// Notes section for a specific target. Shows the two newest notes
/// inline, plus a "View all" link that opens [TargetNotesDialog] with
/// the full chronological list and the "Add note" button.
class TargetNotesSection extends ConsumerWidget {
  /// Logical target id (catalog id like "M31" or display name when no
  /// catalog id is set).
  final String targetId;

  /// Optional title for the section header — defaults to "Notes".
  final String headerLabel;

  /// Optional explicit "create note" defaults — used by post-run flow
  /// to attach a freshly-created note to a specific run.
  final int? defaultSequenceRunId;

  final SkotiqColors colors;

  /// When true, omit the section heading + outer container — the
  /// parent (e.g. the session report dialog) is supplying its own.
  final bool embedded;

  const TargetNotesSection({
    super.key,
    required this.targetId,
    required this.colors,
    this.headerLabel = 'Notes',
    this.defaultSequenceRunId,
    this.embedded = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notesAsync = ref.watch(notesForTargetProvider(targetId));
    return notesAsync.when(
      data: (notes) => _buildBody(context, ref, notes),
      loading: () => Padding(
        padding: const EdgeInsets.all(8),
        child: SizedBox(
          height: 14,
          width: 14,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: colors.primary,
          ),
        ),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(8),
        child: Text(
          'Notes unavailable: $e',
          style: TextStyle(
              fontSize: SkotiqTypography.fontSize11, color: colors.error),
        ),
      ),
    );
  }

  Widget _buildBody(
      BuildContext context, WidgetRef ref, List<JournalNote> notes) {
    final preview = notes.take(2).toList(growable: false);
    final header = Row(
      children: [
        Icon(LucideIcons.bookOpen, size: 14, color: colors.primary),
        const SizedBox(width: 6),
        Text(
          headerLabel,
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize12,
            fontWeight: FontWeight.w700,
            color: colors.textSecondary,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(width: 8),
        if (notes.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: colors.surfaceAlt,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            ),
            child: Text(
              '${notes.length}',
              style: TextStyle(
                  fontSize: SkotiqTypography.fontSize10,
                  color: colors.textMuted),
            ),
          ),
        const Spacer(),
        TextButton.icon(
          icon: const Icon(LucideIcons.plus, size: 14),
          label: const Text('Add note'),
          onPressed: () => _openCreateDialog(context, ref),
        ),
        if (notes.length > 2)
          TextButton(
            onPressed: () => _openAllNotesDialog(context),
            child: Text('View all (${notes.length})'),
          ),
      ],
    );

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (notes.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Text(
              'No notes yet. The first one is always the most useful.',
              style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: colors.textMuted),
            ),
          )
        else
          for (final note in preview) ...[
            _NoteTile(
              note: note,
              colors: colors,
              maxBodyLines: 3,
              onEdit: () => _openEditDialog(context, ref, note),
              onDelete: () => confirmDeleteNote(context, ref, note),
            ),
            const SizedBox(height: 6),
          ],
      ],
    );

    if (embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [header, const SizedBox(height: 6), body],
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: colors.border.withValues(alpha: 0.5)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [header, const SizedBox(height: 6), body],
      ),
    );
  }

  Future<void> _openCreateDialog(BuildContext context, WidgetRef ref) async {
    final created = await showDialog<JournalNote>(
      context: context,
      builder: (_) => NoteEditorDialog(
        targetId: targetId,
        sequenceRunId: defaultSequenceRunId,
      ),
    );
    if (created != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Note saved'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _openAllNotesDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => TargetNotesDialog(
        targetId: targetId,
        colors: colors,
        defaultSequenceRunId: defaultSequenceRunId,
      ),
    );
  }

  Future<void> _openEditDialog(
      BuildContext context, WidgetRef ref, JournalNote note) async {
    await showDialog<JournalNote>(
      context: context,
      builder: (_) => NoteEditorDialog(
        targetId: targetId,
        sequenceRunId: note.sequenceRunId,
        existing: note,
      ),
    );
  }
}

/// Notes section scoped to a single sequence run. Renders identically
/// to [TargetNotesSection] except the queries pull from
/// `notes_journal.sequence_run_id` and the "Add note" call attaches the
/// resulting record to that run id.
class RunNotesSection extends ConsumerWidget {
  final int sequenceRunId;
  final String targetId;
  final SkotiqColors colors;
  final String headerLabel;
  final bool embedded;

  const RunNotesSection({
    super.key,
    required this.sequenceRunId,
    required this.targetId,
    required this.colors,
    this.headerLabel = 'Notes',
    this.embedded = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notesAsync = ref.watch(notesForRunProvider(sequenceRunId));
    return notesAsync.when(
      data: (notes) => _NotesPanelLayout(
        title: headerLabel,
        notes: notes,
        colors: colors,
        embedded: embedded,
        emptyHint: 'No notes for this run yet. Add one to record what worked.',
        onAdd: () => _openCreateDialog(context, ref),
        onEdit: (n) => _openEditDialog(context, ref, n),
        onDelete: (n) => confirmDeleteNote(context, ref, n),
      ),
      loading: () => const SizedBox.shrink(),
      // The reason is carried through instead of being called "temporary": a
      // corrupt journal table or a denied database path does not clear on its
      // own, and telling the operator to wait for it hides the one fact that
      // would let them fix it.
      error: (e, stack) {
        developer.log(
          '[NotesPanel] Journal notes query failed: $e',
          name: 'NotesPanel',
          level: 1000,
          error: e,
          stackTrace: stack,
        );
        return Text(
          'Notes unavailable: ${userFacingError(e)}',
          style: TextStyle(
              fontSize: SkotiqTypography.fontSize11, color: colors.error),
        );
      },
    );
  }

  Future<void> _openCreateDialog(BuildContext context, WidgetRef ref) async {
    await showDialog<JournalNote>(
      context: context,
      builder: (_) => NoteEditorDialog(
        targetId: targetId,
        sequenceRunId: sequenceRunId,
      ),
    );
  }

  Future<void> _openEditDialog(
      BuildContext context, WidgetRef ref, JournalNote note) async {
    await showDialog<JournalNote>(
      context: context,
      builder: (_) => NoteEditorDialog(
        targetId: targetId,
        sequenceRunId: sequenceRunId,
        existing: note,
      ),
    );
  }
}

/// Shared layout for the per-section "Notes" panel. Extracted so the
/// run and target variants stay visually identical.
class _NotesPanelLayout extends StatelessWidget {
  final String title;
  final List<JournalNote> notes;
  final SkotiqColors colors;
  final bool embedded;
  final String emptyHint;
  final VoidCallback onAdd;
  final void Function(JournalNote) onEdit;
  final void Function(JournalNote) onDelete;

  const _NotesPanelLayout({
    required this.title,
    required this.notes,
    required this.colors,
    required this.embedded,
    required this.emptyHint,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final header = Row(
      children: [
        Icon(LucideIcons.bookOpen, size: 14, color: colors.primary),
        const SizedBox(width: 6),
        Text(
          title,
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize12,
            fontWeight: FontWeight.w700,
            color: colors.textSecondary,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(width: 8),
        if (notes.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: colors.surfaceAlt,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            ),
            child: Text(
              '${notes.length}',
              style: TextStyle(
                  fontSize: SkotiqTypography.fontSize10,
                  color: colors.textMuted),
            ),
          ),
        const Spacer(),
        TextButton.icon(
          icon: const Icon(LucideIcons.plus, size: 14),
          label: const Text('Add note'),
          onPressed: onAdd,
        ),
      ],
    );

    final body = notes.isEmpty
        ? Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Text(
              emptyHint,
              style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: colors.textMuted),
            ),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final n in notes) ...[
                _NoteTile(
                  note: n,
                  colors: colors,
                  maxBodyLines: 5,
                  onEdit: () => onEdit(n),
                  onDelete: () => onDelete(n),
                ),
                const SizedBox(height: 6),
              ],
            ],
          );

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [header, const SizedBox(height: 6), body],
    );
    if (embedded) return content;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: colors.border.withValues(alpha: 0.5)),
        ),
      ),
      child: content,
    );
  }
}

// "View all" dialog

/// Modal that lists every note for a target chronologically with
/// search + tag filter and an "Add note" affordance.
