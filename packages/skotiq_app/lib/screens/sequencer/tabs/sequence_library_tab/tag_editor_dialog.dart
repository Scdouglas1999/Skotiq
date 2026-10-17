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

class _TagEditorDialogState extends ConsumerState<_TagEditorDialog> {
  late final List<String> _tags;
  late final SkotiqBackend _authority;
  late final SequenceRepository _repository;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;
  final _controller = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _tags = [...widget.initialTags];
    _authority = ref.read(backendProvider);
    _repository = ref.read(sequenceRepositoryProvider);
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (previous == null || identical(previous, next) || !mounted) return;
        context.showWarningSnackBar(
          'The connected host changed. Tag editing cancelled.',
        );
        closeAuthorityBoundDialog(context);
      },
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _backendSubscription?.close();
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
    if (!identical(ref.read(backendProvider), _authority)) return;
    _addTag();
    setState(() => _saving = true);
    try {
      await _repository.setTags(widget.sequenceId, _tags);
      if (!mounted || !identical(ref.read(backendProvider), _authority)) return;
      ref.invalidate(savedSequenceSummariesProvider);
      Navigator.of(context).pop();
      context.showSuccessSnackBar('Updated tags for "${widget.sequenceName}"');
    } catch (e) {
      if (!mounted || !identical(ref.read(backendProvider), _authority)) return;
      setState(() => _saving = false);
      context.showErrorSnackBar('Failed to save tags: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final dialog = AlertDialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        side: BorderSide(color: colors.border),
      ),
      title: Row(
        children: [
          Icon(LucideIcons.tags, size: 18, color: colors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Edit Tags',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize16,
                fontWeight: FontWeight.w700,
                color: colors.textPrimary,
              ),
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: AdaptiveDialogConstraints.hybrid(
          context,
          designMaxWidth: 440,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.sequenceName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize12,
                color: colors.textMuted,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    autofocus: true,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _addTag(),
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize13,
                      color: colors.textPrimary,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Add a tag',
                      isDense: true,
                      prefixIcon: Icon(LucideIcons.tag,
                          size: 16, color: colors.textMuted),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SkotiqButton(
                  label: 'Add',
                  icon: LucideIcons.plus,
                  variant: ButtonVariant.outline,
                  size: ButtonSize.small,
                  onPressed: _addTag,
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_tags.isEmpty)
              Text(
                'No tags yet.',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize12,
                  color: colors.textMuted,
                ),
              )
            else
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final tag in _tags)
                    Container(
                      padding: const EdgeInsets.only(
                          left: 10, right: 4, top: 4, bottom: 4),
                      decoration: SkotiqDecorations.tintedBadge(
                        colors.primary,
                        borderRadius: BorderRadius.circular(
                            SkotiqTokens.radiusInline8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            tag,
                            style: SkotiqTypography.labelStrongSm
                                .copyWith(color: colors.primary),
                          ),
                          const SizedBox(width: 4),
                          GestureDetector(
                            onTap: () => setState(() => _tags.remove(tag)),
                            child: Icon(LucideIcons.x,
                                size: 14, color: colors.primary),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
      actions: [
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
        ),
        SkotiqButton(
          label: _saving ? 'Saving…' : 'Save',
          variant: ButtonVariant.primary,
          size: ButtonSize.small,
          onPressed: _saving ? null : _save,
        ),
      ],
    );
    return PopScope(canPop: !_saving, child: dialog);
  }
}
