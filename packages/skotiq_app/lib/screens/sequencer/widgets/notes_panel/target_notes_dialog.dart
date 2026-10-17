part of '../notes_panel.dart';

class TargetNotesDialog extends ConsumerStatefulWidget {
  final String targetId;
  final SkotiqColors colors;
  final int? defaultSequenceRunId;

  const TargetNotesDialog({
    super.key,
    required this.targetId,
    required this.colors,
    this.defaultSequenceRunId,
  });

  @override
  ConsumerState<TargetNotesDialog> createState() => _TargetNotesDialogState();
}

class _TargetNotesDialogState extends ConsumerState<TargetNotesDialog> {
  String _query = '';
  final Set<String> _selectedTags = {};

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final notesAsync = ref.watch(notesForTargetProvider(widget.targetId));
    final dialogSize = AdaptiveDialogConstraints.dialogSize(
      context,
      designWidth: 720,
      designHeight: 720,
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
        child: notesAsync.when(
          data: (notes) {
            // Collect all tags across notes for the chip filter row.
            final allTags = <String>{};
            for (final n in notes) {
              allTags.addAll(n.tags);
            }
            final filtered = notes.where((n) {
              if (_selectedTags.isNotEmpty &&
                  !_selectedTags.any((t) => n.tags.contains(t))) {
                return false;
              }
              if (_query.isEmpty) return true;
              final q = _query.toLowerCase();
              return n.body.toLowerCase().contains(q) ||
                  (n.title?.toLowerCase().contains(q) ?? false);
            }).toList(growable: false);
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildHeader(notes.length, colors),
                _buildSearchRow(allTags, colors),
                Expanded(
                  child: filtered.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              notes.isEmpty
                                  ? 'No notes yet for this target.'
                                  : 'No notes match the current filter.',
                              style: TextStyle(
                                  fontSize: SkotiqTypography.fontSize13,
                                  color: colors.textMuted),
                            ),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: filtered.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (_, i) {
                            return _NoteTile(
                              note: filtered[i],
                              colors: colors,
                              maxBodyLines: 10,
                              onEdit: () => _openEditor(context, filtered[i]),
                              onDelete: () =>
                                  _confirmDelete(context, filtered[i]),
                            );
                          },
                        ),
                ),
                _buildFooter(context, colors),
              ],
            );
          },
          loading: () => Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: CircularProgressIndicator(color: colors.primary),
            ),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Failed to load notes: $e',
              style: TextStyle(color: colors.error),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(int total, SkotiqColors colors) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.bookOpen, size: 22, color: colors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Notes — ${widget.targetId}',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize18,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
                Text(
                  '$total note${total == 1 ? '' : 's'} on this target',
                  style: TextStyle(
                      fontSize: SkotiqTypography.fontSize12,
                      color: colors.textMuted),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: Icon(LucideIcons.x, color: colors.textMuted),
            tooltip: 'Close',
          ),
        ],
      ),
    );
  }

  Widget _buildSearchRow(Set<String> tags, SkotiqColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            decoration: InputDecoration(
              hintText: 'Search note bodies / titles',
              isDense: true,
              prefixIcon:
                  Icon(LucideIcons.search, size: 16, color: colors.textMuted),
            ),
            onChanged: (v) => setState(() => _query = v.trim()),
          ),
          if (tags.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: [
                for (final tag in tags)
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
    );
  }

  Widget _buildFooter(BuildContext context, SkotiqColors colors) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          FilledButton.icon(
            icon: const Icon(LucideIcons.plus, size: 16),
            label: const Text('Add note'),
            onPressed: () async {
              final created = await showDialog<JournalNote>(
                context: context,
                builder: (_) => NoteEditorDialog(
                  targetId: widget.targetId,
                  sequenceRunId: widget.defaultSequenceRunId,
                ),
              );
              if (created != null && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('Note saved'),
                      duration: Duration(seconds: 2)),
                );
              }
            },
          ),
          const Spacer(),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _openEditor(BuildContext context, JournalNote note) async {
    await showDialog<JournalNote>(
      context: context,
      builder: (_) => NoteEditorDialog(
        targetId: widget.targetId,
        sequenceRunId: note.sequenceRunId,
        existing: note,
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, JournalNote note) {
    return confirmDeleteNote(context, ref, note);
  }
}

// Note tile (single-row preview)
