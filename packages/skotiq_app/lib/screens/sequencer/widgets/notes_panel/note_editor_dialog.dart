part of '../notes_panel.dart';

class NoteEditorDialog extends ConsumerStatefulWidget {
  final String targetId;
  final int? sequenceRunId;
  final JournalNote? existing;
  final String? initialBody;
  final String? initialTitle;
  final String? initialSentiment;

  const NoteEditorDialog({
    super.key,
    required this.targetId,
    this.sequenceRunId,
    this.existing,
    this.initialBody,
    this.initialTitle,
    this.initialSentiment,
  });

  @override
  ConsumerState<NoteEditorDialog> createState() => _NoteEditorDialogState();
}

class _NoteEditorDialogState extends ConsumerState<NoteEditorDialog> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _bodyCtrl;
  late final TextEditingController _tagCtrl;
  late List<String> _tags;
  String? _sentiment;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(
      text: widget.existing?.title ?? widget.initialTitle ?? '',
    );
    _bodyCtrl = TextEditingController(
      text: widget.existing?.body ?? widget.initialBody ?? '',
    );
    _tagCtrl = TextEditingController();
    _tags = List<String>.from(widget.existing?.tags ?? const <String>[]);
    _sentiment = widget.existing?.sentiment ?? widget.initialSentiment;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    _tagCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final isEditing = widget.existing != null;
    final dialog = Dialog(
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: colors.border)),
              ),
              child: Row(
                children: [
                  Icon(LucideIcons.bookOpen, size: 20, color: colors.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      isEditing ? 'Edit note' : 'New note',
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize16,
                        fontWeight: FontWeight.w700,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  if (widget.sequenceRunId != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        'attached to run #${widget.sequenceRunId}',
                        style: TextStyle(
                            fontSize: SkotiqTypography.fontSize11,
                            color: colors.textMuted),
                      ),
                    ),
                  IconButton(
                    onPressed:
                        _saving ? null : () => Navigator.of(context).pop(),
                    icon: Icon(LucideIcons.x, color: colors.textMuted),
                    tooltip: 'Close',
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _titleCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Title (optional)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      _SentimentPicker(
                        value: _sentiment,
                        onChanged: (v) => setState(() => _sentiment = v),
                        colors: colors,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _bodyCtrl,
                    minLines: 6,
                    maxLines: 12,
                    decoration: const InputDecoration(
                      labelText: 'Body (markdown supported)',
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _tagCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Add tag and press Enter',
                          ),
                          onSubmitted: _addTag,
                        ),
                      ),
                    ],
                  ),
                  if (_tags.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final tag in _tags)
                          InputChip(
                            label: Text('#$tag'),
                            onDeleted: () => setState(() => _tags.remove(tag)),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: colors.border)),
              ),
              child: Row(
                children: [
                  if (isEditing)
                    TextButton.icon(
                      icon: const Icon(LucideIcons.trash2, size: 14),
                      label: const Text('Delete'),
                      onPressed: _saving ? null : _delete,
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed:
                        _saving ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    icon: const Icon(LucideIcons.save, size: 14),
                    label: Text(isEditing ? 'Save changes' : 'Save note'),
                    onPressed: _saving ? null : _save,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return PopScope(canPop: !_saving, child: dialog);
  }

  void _addTag(String raw) {
    final cleaned = raw.trim().replaceAll('#', '');
    if (cleaned.isEmpty) return;
    if (!_tags.contains(cleaned)) {
      setState(() {
        _tags.add(cleaned);
        _tagCtrl.clear();
      });
    } else {
      _tagCtrl.clear();
    }
  }

  Future<void> _save() async {
    // Commit a tag the user typed but didn't submit with Enter so it isn't
    // silently dropped on save.
    if (_tagCtrl.text.trim().isNotEmpty) {
      _addTag(_tagCtrl.text);
    }
    final body = _bodyCtrl.text.trim();
    final title = _titleCtrl.text.trim();
    // Require either a body or sentiment so we never persist an
    // empty stub note that the user can't find later.
    if (body.isEmpty && _sentiment == null && title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Add a title, body, or sentiment before saving.'),
        ),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final service = ref.read(notesRepositoryProvider);
      final JournalNote saved;
      if (widget.existing == null) {
        saved = await service.addNote(
          targetId: widget.targetId,
          sequenceRunId: widget.sequenceRunId,
          body: body,
          title: title.isEmpty ? null : title,
          tags: _tags,
          sentiment: _sentiment,
        );
      } else {
        saved = await service.updateNote(
          widget.existing!.id,
          body: body,
          title: title.isEmpty ? null : title,
          tags: _tags,
          sentiment: _sentiment,
          clearTitle: title.isEmpty,
          clearSentiment: _sentiment == null,
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(saved);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save note: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    setState(() => _saving = true);
    try {
      // Route through the shared confirmation so this destructive action
      // matches every other delete surface; only dismiss the editor once
      // the note was actually deleted, leaving unsaved edits intact on cancel.
      final deleted = await confirmDeleteNote(context, ref, existing);
      if (!mounted) return;
      if (deleted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
