part of '../sequence_library_tab.dart';

/// Add / remove library tags for a saved sequence.
///
/// Persists through [SequenceRepository.setTags] (which trims, drops blanks and
/// de-duplicates) and invalidates the summaries provider so the card, the
/// filter row and the tag universe all refresh.
class _TagEditorDialog extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final int sequenceId;
  final String sequenceName;
  final List<String> initialTags;

  const _TagEditorDialog({
    required this.colors,
    required this.sequenceId,
    required this.sequenceName,
    required this.initialTags,
  });

  @override
  ConsumerState<_TagEditorDialog> createState() => _TagEditorDialogState();
}

class _TagEditorDialogState extends ConsumerState<_TagEditorDialog>
    with HostBoundDialogState<_TagEditorDialog> {
  @override
  String get hostChangedMessage =>
      'The connected host changed. Tag editing canceled.';

  @override
  bool get hostChangeDiscardsInput => true;

  late final List<String> _tags;
  late final SequenceRepository _repository;
  final _controller = TextEditingController();
  final _field = FocusNode();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _tags = [...widget.initialTags];
    _repository = ref.read(sequenceRepositoryProvider);
  }

  @override
  void dispose() {
    _controller.dispose();
    _field.dispose();
    super.dispose();
  }

  void _addTag() {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    if (!_tags.any((t) => t.toLowerCase() == value.toLowerCase())) {
      setState(() => _tags.add(value));
    }
    _controller.clear();
  }

  Future<void> _save() async {
    if (host.isStale) return;
    _addTag();
    setState(() => _saving = true);
    try {
      await _repository.setTags(widget.sequenceId, _tags);
      if (!mounted || host.isStale) return;
      ref.invalidate(savedSequenceSummariesProvider);
      Navigator.of(context).pop();
      context.showSuccessSnackBar('Updated tags for "${widget.sequenceName}"');
    } catch (e) {
      if (!mounted || host.isStale) return;
      setState(() => _saving = false);
      context.showErrorSnackBar('Failed to save tags: ${userFacingError(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final muted = SkotiqTypography.bodySm.copyWith(color: colors.textMuted);
    final dialog = SkotiqDialog(
      title: 'Edit tags',
      width: SkotiqDialog.widthConfirm,
      actions: [
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
        ),
        SkotiqButton(
          label: _saving ? 'Saving…' : 'Save',
          onPressed: _saving ? null : _save,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.sequenceName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: muted,
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          Row(
            children: [
              Expanded(
                child: SkotiqTextField(
                  controller: _controller,
                  focusNode: _field,
                  autofocus: true,
                  hint: 'Add a tag',
                  prefixIcon: LucideIcons.tag,
                  textInputAction: TextInputAction.done,
                  // Enter adds the tag and keeps the field focused, so the
                  // next tag can be typed straight away.
                  onSubmitted: (_) {
                    _addTag();
                    _field.requestFocus();
                  },
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              SkotiqButton(
                label: 'Add',
                icon: LucideIcons.plus,
                variant: ButtonVariant.secondary,
                onPressed: _addTag,
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          if (_tags.isEmpty)
            Text('No tags yet.', style: muted)
          else
            Wrap(
              spacing: SkotiqTokens.spaceSm,
              runSpacing: SkotiqTokens.spaceSm,
              children: [
                for (final tag in _tags)
                  Tooltip(
                    message: 'Remove $tag',
                    child: SkotiqChip(
                      label: tag,
                      icon: LucideIcons.x,
                      tone: ChipTone.primary,
                      onTap: () => setState(() => _tags.remove(tag)),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
    return PopScope(canPop: !_saving, child: dialog);
  }
}
