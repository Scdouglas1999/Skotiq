part of '../notes_panel.dart';

/// Global notes browser. Watches [allNotesProvider] (every journal note
/// across all targets and runs) and lets the operator search bodies /
/// titles and filter by tag. Reuses [_NoteTile] so a note edited here
/// looks and behaves the same as in the per-target / per-run surfaces.
///
/// Entry point: the History tab header's "Browse all notes" button.
class GlobalNotesDialog extends ConsumerStatefulWidget {
  const GlobalNotesDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => const GlobalNotesDialog(),
    );
  }

  @override
  ConsumerState<GlobalNotesDialog> createState() => _GlobalNotesDialogState();
}

class _GlobalNotesDialogState extends ConsumerState<GlobalNotesDialog> {
  String _query = '';
  final Set<String> _selectedTags = <String>{};

  List<JournalNote> _filter(List<JournalNote> notes) {
    final q = _query.toLowerCase();
    return notes.where((n) {
      if (q.isNotEmpty) {
        final inBody = n.body.toLowerCase().contains(q);
        final inTitle = (n.title ?? '').toLowerCase().contains(q);
        final inTarget = n.targetId.toLowerCase().contains(q);
        if (!inBody && !inTitle && !inTarget) return false;
      }
      if (_selectedTags.isNotEmpty) {
        if (!_selectedTags.every(n.tags.contains)) return false;
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final notesAsync = ref.watch(allNotesProvider);
    final dialogSize = AdaptiveDialogConstraints.dialogSize(
      context,
      designWidth: 680,
      designHeight: 640,
    );

    return Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        side: BorderSide(color: colors.border),
      ),
      child: SizedBox(
        width: dialogSize.width,
        height: dialogSize.height,
        child: Column(
          mainAxisSize: MainAxisSize.max,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: colors.border)),
              ),
              child: Row(
                children: [
                  Icon(LucideIcons.bookOpen, size: 20, color: colors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'All notes',
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize16,
                        fontWeight: FontWeight.w700,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(LucideIcons.x, color: colors.textMuted),
                    tooltip: 'Close',
                  ),
                ],
              ),
            ),
            Expanded(
              child: notesAsync.when(
                data: (notes) {
                  final allTags = <String>{
                    for (final n in notes) ...n.tags,
                  }.toList()
                    ..sort();
                  final filtered = _filter(notes);
                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            TextField(
                              decoration: InputDecoration(
                                hintText: 'Search bodies / titles / targets',
                                isDense: true,
                                prefixIcon: Icon(LucideIcons.search,
                                    size: 16, color: colors.textMuted),
                              ),
                              onChanged: (v) =>
                                  setState(() => _query = v.trim()),
                            ),
                            if (allTags.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (final tag in allTags)
                                    FilterChip(
                                      label: Text(tag),
                                      selected: _selectedTags.contains(tag),
                                      visualDensity: VisualDensity.compact,
                                      onSelected: (selected) {
                                        setState(() {
                                          if (selected) {
                                            _selectedTags.add(tag);
                                          } else {
                                            _selectedTags.remove(tag);
                                          }
                                        });
                                      },
                                    ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      Expanded(
                        child: filtered.isEmpty
                            ? Center(
                                child: Text(
                                  notes.isEmpty
                                      ? 'No notes recorded yet.'
                                      : 'No notes match the current filter.',
                                  style: TextStyle(
                                    fontSize: SkotiqTypography.fontSize13,
                                    color: colors.textMuted,
                                  ),
                                ),
                              )
                            : ListView.separated(
                                padding: const EdgeInsets.all(16),
                                itemCount: filtered.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 8),
                                itemBuilder: (context, index) {
                                  final note = filtered[index];
                                  return _NoteTile(
                                    note: note,
                                    colors: colors,
                                    maxBodyLines: 4,
                                    onEdit: () => _openEditDialog(note),
                                    onDelete: () =>
                                        confirmDeleteNote(context, ref, note),
                                  );
                                },
                              ),
                      ),
                    ],
                  );
                },
                loading: () => Center(
                  child: CircularProgressIndicator(color: colors.primary),
                ),
                error: (e, stack) {
                  developer.log(
                    '[GlobalNotesDialog] All-notes query failed: $e',
                    name: 'GlobalNotesDialog',
                    level: 1000,
                    error: e,
                    stackTrace: stack,
                  );
                  return Center(
                    child: Text(
                      'Notes unavailable: ${userFacingError(e)}',
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize13,
                        color: colors.error,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openEditDialog(JournalNote note) async {
    await showDialog<JournalNote>(
      context: context,
      builder: (_) => NoteEditorDialog(
        targetId: note.targetId,
        sequenceRunId: note.sequenceRunId,
        existing: note,
      ),
    );
  }
}
