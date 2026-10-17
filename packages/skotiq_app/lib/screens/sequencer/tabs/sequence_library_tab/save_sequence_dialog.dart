part of '../sequence_library_tab.dart';

class _SaveSequenceDialog extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final Sequence sequence;

  const _SaveSequenceDialog({
    required this.colors,
    required this.sequence,
  });

  @override
  ConsumerState<_SaveSequenceDialog> createState() =>
      _SaveSequenceDialogState();
}

class _SaveSequenceDialogState extends ConsumerState<_SaveSequenceDialog> {
  late TextEditingController _nameController;
  late TextEditingController _descriptionController;
  late final SkotiqBackend _authority;
  late final SequenceRepository _repository;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.sequence.name);
    _descriptionController =
        TextEditingController(text: widget.sequence.description);
    _authority = ref.read(backendProvider);
    _repository = ref.read(sequenceRepositoryProvider);
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (previous == null || identical(previous, next) || !mounted) return;
        context.showWarningSnackBar(
          'The connected host changed. Sequence save cancelled.',
        );
        closeAuthorityBoundDialog(context);
      },
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _backendSubscription?.close();
    super.dispose();
  }

  bool get _isExisting => widget.sequence.databaseId != null;

  /// Overwrite the existing saved sequence (only available for a
  /// sequence already in the library). Confirms before clobbering.
  Future<void> _updateExisting() async {
    if (_nameController.text.trim().isEmpty) {
      context.showErrorSnackBar('Please enter a sequence name');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: widget.colors.surface,
        title: Text('Overwrite saved sequence?',
            style: TextStyle(color: widget.colors.textPrimary)),
        content: ConstrainedBox(
          constraints:
              AdaptiveDialogConstraints.hybrid(ctx, designMaxWidth: 400),
          child: Text(
            'This replaces the saved "${widget.sequence.name}" with the '
            'current sequence. This cannot be undone.',
            style: TextStyle(color: widget.colors.textSecondary),
          ),
        ),
        actions: [
          SkotiqButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            label: 'Cancel',
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
          ),
          SkotiqButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            label: 'Overwrite',
            variant: ButtonVariant.destructive,
            size: ButtonSize.small,
          ),
        ],
      ),
    );
    if (confirmed != true ||
        !mounted ||
        !identical(ref.read(backendProvider), _authority)) {
      return;
    }

    await _persist(
      Sequence.create(
        databaseId: widget.sequence.databaseId,
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim(),
        nodes: widget.sequence.nodes,
        rootNodeId: widget.sequence.rootNodeId,
        isTemplate: false,
      ),
    );
  }

  /// Save the current sequence as an independent new copy. Re-keys every
  /// node id so the copy never shares persistence with the original.
  Future<void> _saveAsNew() async {
    if (_nameController.text.trim().isEmpty) {
      context.showErrorSnackBar('Please enter a sequence name');
      return;
    }

    final idMapping = <String, String>{};
    for (final id in widget.sequence.nodes.keys) {
      idMapping[id] = const Uuid().v4();
    }

    final newNodes = <String, SequenceNode>{};
    for (final entry in widget.sequence.nodes.entries) {
      final oldNode = entry.value;
      final newId = idMapping[entry.key]!;
      final newParentId =
          oldNode.parentId != null ? idMapping[oldNode.parentId] : null;
      final newChildIds =
          oldNode.childIds.map((id) => idMapping[id] ?? id).toList();
      newNodes[newId] = oldNode.copyWith(
        id: newId,
        parentId: newParentId,
        childIds: newChildIds,
      );
    }

    final newRootId = widget.sequence.rootNodeId != null
        ? idMapping[widget.sequence.rootNodeId]
        : null;

    await _persist(
      Sequence.create(
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim(),
        nodes: newNodes,
        rootNodeId: newRootId,
        isTemplate: false,
      ),
    );
  }

  Future<void> _persist(Sequence sequenceToSave) async {
    if (!identical(ref.read(backendProvider), _authority)) {
      context.showWarningSnackBar(
        'The connected host changed. Reopen the sequence library.',
      );
      return;
    }
    setState(() => _isSaving = true);

    try {
      final savedId =
          await _repository.saveSequence(sequenceToSave, isTemplate: false);

      Object? versionSnapshotError;
      // Capture a point-in-time version snapshot so the library's version
      // history has a restore point for this save. Re-anchor the saved
      // sequence to its row id first (a brand-new save assigns it here).
      try {
        await _repository.snapshotVersionOnSave(
          sequenceToSave.copyWith(databaseId: savedId),
        );
      } catch (e) {
        // The sequence row is already durable. A secondary history failure
        // must not report the whole save as failed or leave the editor
        // pointing at its old row.
        versionSnapshotError = e;
      }

      if (!mounted || !identical(ref.read(backendProvider), _authority)) {
        return;
      }

      ref.read(currentSequenceProvider.notifier).applyPersistedSave(
            expectedSequenceId: widget.sequence.id,
            databaseId: savedId,
            name: sequenceToSave.name,
            description: sequenceToSave.description,
            isTemplate: false,
          );

      notifySequenceCatalogChanged(
        ref,
        sequenceId: savedId,
        action: 'saved',
        name: sequenceToSave.name,
      );

      if (mounted && identical(ref.read(backendProvider), _authority)) {
        Navigator.pop(context);
        if (versionSnapshotError == null) {
          context
              .showSuccessSnackBar('Sequence "${sequenceToSave.name}" saved!');
        } else {
          context.showWarningSnackBar(
            'Sequence saved, but its version-history snapshot failed: '
            '$versionSnapshotError',
          );
        }
      }
    } catch (e) {
      if (mounted && identical(ref.read(backendProvider), _authority)) {
        context.showErrorSnackBar('Failed to save sequence: $e');
      }
    } finally {
      if (mounted && identical(ref.read(backendProvider), _authority)) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final dialog = Dialog(
      backgroundColor: widget.colors.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8)),
      child: ConstrainedBox(
        constraints: AdaptiveDialogConstraints.hybrid(
          context,
          designMaxWidth: 450,
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: SkotiqDecorations.tintedBadge(
                      widget.colors.primary,
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusLg),
                    ),
                    child: Icon(
                      LucideIcons.save,
                      size: 20,
                      color: widget.colors.primary,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _isExisting ? 'Update sequence' : 'Save sequence',
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize18,
                          fontWeight: FontWeight.w700,
                          color: widget.colors.textPrimary,
                        ),
                      ),
                      Text(
                        _isExisting
                            ? 'Overwrite the original or save an independent copy'
                            : 'Save to your sequence library',
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize12,
                          color: widget.colors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // Name field
              Text(
                'Sequence Name',
                style: SkotiqTypography.h6
                    .copyWith(color: widget.colors.textSecondary),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: widget.colors.surfaceAlt,
                  borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
                  border: Border.all(color: widget.colors.border),
                ),
                child: TextField(
                  controller: _nameController,
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize14,
                    color: widget.colors.textPrimary,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Enter sequence name',
                    hintStyle: TextStyle(color: widget.colors.textMuted),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // Description field
              Text(
                'Description (optional)',
                style: SkotiqTypography.h6
                    .copyWith(color: widget.colors.textSecondary),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: widget.colors.surfaceAlt,
                  borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
                  border: Border.all(color: widget.colors.border),
                ),
                child: TextField(
                  controller: _descriptionController,
                  maxLines: 2,
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize14,
                    color: widget.colors.textPrimary,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Add a description...',
                    hintStyle: TextStyle(color: widget.colors.textMuted),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // Info
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: widget.colors.surfaceAlt,
                  borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
                ),
                child: Row(
                  children: [
                    Icon(LucideIcons.info, size: 16, color: widget.colors.info),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Saving ${countLabel(widget.sequence.nodes.length, 'node')}',
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize12,
                          color: widget.colors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // Actions
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SkotiqButton(
                    onPressed: _isSaving ? null : () => Navigator.pop(context),
                    label: 'Cancel',
                    variant: ButtonVariant.ghost,
                    size: ButtonSize.small,
                  ),
                  const SizedBox(width: 12),
                  if (_isExisting) ...[
                    SkotiqButton(
                      label: 'Save as new copy',
                      icon: LucideIcons.copy,
                      variant: ButtonVariant.outline,
                      onPressed: _isSaving ? null : _saveAsNew,
                      size: ButtonSize.small,
                    ),
                    const SizedBox(width: 12),
                    SkotiqButton(
                      label: _isSaving
                          ? 'Saving...'
                          : 'Update "${widget.sequence.name}"',
                      icon: _isSaving ? LucideIcons.loader : LucideIcons.save,
                      onPressed: _isSaving ? null : _updateExisting,
                      size: ButtonSize.small,
                    ),
                  ] else
                    SkotiqButton(
                      label: _isSaving ? 'Saving...' : 'Save',
                      icon: _isSaving ? LucideIcons.loader : LucideIcons.save,
                      onPressed: _isSaving ? null : _saveAsNew,
                      size: ButtonSize.small,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    return PopScope(canPop: !_isSaving, child: dialog);
  }
}
