part of '../templates_tab.dart';

/// What a template card's "more" menu offers.
enum _TemplateAction { duplicate, delete }

class _TemplateCard extends ConsumerStatefulWidget {
  const _TemplateCard({required this.template});

  final Sequence template;

  @override
  ConsumerState<_TemplateCard> createState() => _TemplateCardState();
}

class _TemplateCardState extends ConsumerState<_TemplateCard> {
  SkotiqColors get _colors => SkotiqColors.of(context);

  IconData _getTemplateIcon() {
    final name = widget.template.name.toLowerCase();
    if (name.contains('first light')) return LucideIcons.sparkles;
    if (name.contains('osc') || name.contains('one-shot')) {
      return LucideIcons.camera;
    }
    if (name.contains('quick')) return LucideIcons.zap;
    if (name.contains('beginner')) return LucideIcons.graduationCap;
    if (name.contains('ha-oiii') || name.contains('bicolor')) {
      return LucideIcons.contrast;
    }
    if (name.contains('sho') || name.contains('hubble')) {
      return LucideIcons.waves;
    }
    if (name.contains('lrgb')) return LucideIcons.palette;
    if (name.contains('narrowband')) return LucideIcons.waves;
    if (name.contains('multi-target')) return LucideIcons.list;
    if (name.contains('mosaic')) return LucideIcons.layoutGrid;
    if (name.contains('planetary')) return LucideIcons.orbit;
    if (name.contains('unattended') || name.contains('all-night')) {
      return LucideIcons.moon;
    }
    if (name.contains('comet') || name.contains('asteroid')) {
      return LucideIcons.move;
    }
    if (name.contains('solar')) return LucideIcons.sun;
    if (name.contains('lunar')) return LucideIcons.moonStar;
    if (name.contains('remote') || name.contains('observatory')) {
      return LucideIcons.radio;
    }
    return LucideIcons.fileStack;
  }

  String get _facts {
    final template = widget.template;
    final steps = visibleInstructionCount(template);
    return <String>[
      _templateCategoryOptions
          .firstWhere(
            (option) => option.key == _inferTemplateCategory(template),
          )
          .value,
      countLabel(steps, 'step'),
      if (template.databaseId == null)
        'built in'
      else
        'saved ${ClockFormat.monthDayYear(template.createdAt.toLocal())}',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    // Use and Edit replace the Builder's tree and wait for the run to end.
    // Duplicate and Delete work on the library row and stay available.
    final canEdit = ref.watch(canEditSequenceProvider);
    final builtIn = widget.template.databaseId == null;
    final editLabel = builtIn ? 'Customize a copy' : 'Edit template';

    return _CatalogCard(
      icon: _getTemplateIcon(),
      title: widget.template.name,
      facts: _facts,
      description: widget.template.description.isEmpty
          ? 'No description'
          : widget.template.description,
      primary: SkotiqButton(
        label: 'Use template',
        icon: LucideIcons.play,
        variant: ButtonVariant.secondary,
        size: ButtonSize.small,
        onPressed: canEdit ? () => _useTemplate(context) : null,
        semanticsHint: canEdit
            ? null
            : 'The sequence is running, so the builder cannot change.',
      ),
      actions: [
        SkotiqIconButton(
          icon: LucideIcons.pencil,
          tooltip: canEdit ? editLabel : '$editLabel (not while running)',
          onPressed: canEdit ? () => _editTemplate(context) : null,
        ),
        _moreMenu(builtIn: builtIn),
      ],
    );
  }

  Widget _moreMenu({required bool builtIn}) {
    return MoreMenuButton<_TemplateAction>(
      tooltip: 'More actions for ${widget.template.name}',
      entries: [
        const MoreMenuEntry(_TemplateAction.duplicate, 'Duplicate'),
        // A bundled template is part of the product and cannot be deleted.
        if (!builtIn)
          const MoreMenuEntry(
            _TemplateAction.delete,
            'Delete',
            destructive: true,
          ),
      ],
      onSelected: (action) => switch (action) {
        _TemplateAction.duplicate => _duplicateTemplate(context),
        _TemplateAction.delete => _deleteTemplate(context),
      },
    );
  }

  void _useTemplate(BuildContext context) {
    final currentSequence = ref.read(currentSequenceProvider);

    final existingTargets = currentSequence?.targetHeaders ?? [];

    if (existingTargets.length > 1) {
      _showTargetSelectionDialog(context, existingTargets);
    } else if (existingTargets.length == 1) {
      _applyTemplateToTarget(context, existingTargets.first);
    } else {
      _createNewSequenceFromTemplate(context);
    }
  }

  void _showTargetSelectionDialog(
      BuildContext context, List<TargetHeaderNode> targets) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _colors.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8)),
        title: Row(
          children: [
            Icon(LucideIcons.target, size: 20, color: _colors.warning),
            const SizedBox(width: 12),
            Text(
              'Select Target',
              style: TextStyle(color: _colors.textPrimary),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: AdaptiveDialogConstraints.hybrid(
            dialogContext,
            designMaxWidth: 480,
            designMaxHeight: 520,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Which target should "${widget.template.name}" be added to?',
                  style: TextStyle(color: _colors.textSecondary),
                ),
                const SizedBox(height: 16),
                ...targets.map((target) => _TargetOption(
                      colors: _colors,
                      target: target,
                      onTap: () {
                        Navigator.of(dialogContext).pop();
                        _applyTemplateToTarget(context, target);
                      },
                    )),
              ],
            ),
          ),
        ),
        actions: [
          SkotiqButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            label: 'Cancel',
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
          ),
        ],
      ),
    );
  }

  void _applyTemplateToTarget(BuildContext context, TargetHeaderNode target) {
    final sequenceNotifier = ref.read(currentSequenceProvider.notifier);

    try {
      sequenceNotifier.mergeTemplateNodes(
        templateNodes: widget.template.nodes,
        templateRootId: widget.template.rootNodeId,
        targetId: target.id,
      );
    } on SequenceLockedException catch (e) {
      // The InkWell that triggers this is gated by
      // canEditSequenceProvider, but a Start race can still slip a
      // running state under us. Surface to user instead of red overlay.
      context.showErrorSnackBar(e.message);
      return;
    }

    // Switch to the Builder tab so user can see the result
    ref.read(sequencerTabProvider.notifier).state = 0;

    context.showSuccessSnackBar(
        'Added "${widget.template.name}" to ${target.targetName}');
  }

  Future<void> _createNewSequenceFromTemplate(BuildContext context) async {
    final host = ref.backendScope();
    final sequenceNotifier = ref.read(currentSequenceProvider.notifier);
    final newNodes = <String, SequenceNode>{};
    final idMapping = <String, String>{};

    for (final entry in widget.template.nodes.entries) {
      final newId = const Uuid().v4();
      idMapping[entry.key] = newId;
    }

    for (final entry in widget.template.nodes.entries) {
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

    final newRootId = widget.template.rootNodeId != null
        ? idMapping[widget.template.rootNodeId]
        : null;

    final newSequence = Sequence.create(
      name: '${widget.template.name} - Copy',
      description: widget.template.description,
      nodes: newNodes,
      rootNodeId: newRootId,
      isTemplate: false,
    );

    try {
      sequenceNotifier.loadSequence(newSequence);
    } on UnsavedChangesException catch (e) {
      if (!context.mounted) return;
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Discard unsaved changes?'),
          content: ConstrainedBox(
            constraints:
                AdaptiveDialogConstraints.hybrid(ctx, designMaxWidth: 440),
            child: Text('"${e.currentSequenceName}" has unsaved changes. '
                'Creating a sequence from "${widget.template.name}" will '
                'discard them.'),
          ),
          actions: [
            SkotiqButton(
              label: 'Cancel',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () => Navigator.of(ctx).pop(false),
            ),
            SkotiqButton(
              label: 'Discard and create',
              variant: ButtonVariant.destructive,
              size: ButtonSize.small,
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
      );
      if (discard != true || !context.mounted || host.isStale) {
        return;
      }
      sequenceNotifier.loadSequence(newSequence, discardUnsaved: true);
    } on SequenceLockedException catch (e) {
      if (context.mounted) context.showErrorSnackBar(e.message);
      return;
    }

    // Switch to the Builder tab so user can see the loaded sequence
    ref.read(sequencerTabProvider.notifier).state = 0;

    context
        .showSuccessSnackBar('Created sequence from "${widget.template.name}"');
  }

  Future<void> _editTemplate(BuildContext context) async {
    final host = ref.backendScope();
    final editor = ref.read(currentSequenceProvider.notifier);

    if (editor.isDirty) {
      final currentName = ref.read(currentSequenceProvider)?.name ?? 'sequence';
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Discard unsaved changes?'),
          content: ConstrainedBox(
            constraints:
                AdaptiveDialogConstraints.hybrid(ctx, designMaxWidth: 440),
            child: Text('"$currentName" has unsaved changes. Opening '
                '"${widget.template.name}" for editing will discard them.'),
          ),
          actions: [
            SkotiqButton(
              label: 'Cancel',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () => Navigator.of(ctx).pop(false),
            ),
            SkotiqButton(
              label: 'Discard and edit',
              variant: ButtonVariant.destructive,
              size: ButtonSize.small,
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
      );
      if (discard != true || !context.mounted) return;
    }

    if (host.isStale) {
      context.showWarningSnackBar(
        'The connected host changed. Reopen the template catalog.',
      );
      return;
    }

    // Re-key the node graph for the editor while retaining the backing row.
    // The row identity is what lets "Update template" persist in place.
    final newNodes = <String, SequenceNode>{};
    final idMapping = <String, String>{};

    for (final entry in widget.template.nodes.entries) {
      final newId = const Uuid().v4();
      idMapping[entry.key] = newId;
    }

    for (final entry in widget.template.nodes.entries) {
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

    final newRootId = widget.template.rootNodeId != null
        ? idMapping[widget.template.rootNodeId]
        : null;

    var editableTemplate = Sequence.create(
      databaseId: widget.template.databaseId,
      name: widget.template.databaseId == null
          ? '${widget.template.name} (Custom)'
          : widget.template.name,
      description: widget.template.description,
      nodes: newNodes,
      rootNodeId: newRootId,
      isTemplate: true,
    );

    // A bundled template is immutable. "Customize" first creates a real user
    // row, then opens that row so subsequent updates never mutate the bundled
    // catalog or pretend to save an unaddressable template.
    if (editableTemplate.databaseId == null) {
      final repository = ref.read(sequenceRepositoryProvider);
      try {
        final savedId = await repository.saveSequence(
          editableTemplate,
          isTemplate: true,
        );
        if (!context.mounted || host.isStale) {
          return;
        }
        editableTemplate = editableTemplate.copyWith(databaseId: savedId);
        notifySequenceCatalogChanged(
          ref,
          sequenceId: savedId,
          action: 'created',
          name: editableTemplate.name,
          isTemplate: true,
        );
        ref.invalidate(sequenceTemplatesProvider);
      } catch (e) {
        if (context.mounted && host.isCurrent) {
          context.showErrorSnackBar(
              'Could not create template copy: ${userFacingError(e)}');
        }
        return;
      }
    }

    try {
      editor.loadSequence(editableTemplate, discardUnsaved: true);
    } on SequenceLockedException catch (e) {
      if (context.mounted) context.showErrorSnackBar(e.message);
      return;
    }
    ref.read(sequencerTabProvider.notifier).state = 0;

    context.showInfoSnackBar(
      'Editing "${editableTemplate.name}". Update template on the Templates '
      'tab saves your changes.',
    );
  }

  Future<void> _duplicateTemplate(BuildContext context) async {
    final host = ref.backendScope();
    final repository = ref.read(sequenceRepositoryProvider);
    final dbId = widget.template.databaseId;
    if (dbId != null) {
      try {
        final duplicated = await repository.duplicateSequence(
            dbId, '${widget.template.name} (Copy)');

        if (!context.mounted || host.isStale) {
          return;
        }

        if (duplicated?.databaseId != null) {
          notifySequenceCatalogChanged(
            ref,
            sequenceId: duplicated!.databaseId!,
            action: 'duplicated',
            name: duplicated.name,
            isTemplate: true,
          );
        }
        ref.invalidate(sequenceTemplatesProvider);

        context.showSuccessSnackBar('Duplicated "${widget.template.name}"');
      } catch (e) {
        if (context.mounted && host.isCurrent) {
          context.showErrorSnackBar(
              'Failed to duplicate template: ${userFacingError(e)}');
        }
      }
    } else {
      // Built-in template - save a copy to database
      try {
        final newTemplate = Sequence.create(
          name: '${widget.template.name} (Copy)',
          description: widget.template.description,
          nodes: widget.template.nodes,
          rootNodeId: widget.template.rootNodeId,
          isTemplate: true,
        );
        final savedId =
            await repository.saveSequence(newTemplate, isTemplate: true);

        if (!context.mounted || host.isStale) {
          return;
        }

        notifySequenceCatalogChanged(
          ref,
          sequenceId: savedId,
          action: 'created',
          name: newTemplate.name,
          isTemplate: true,
        );
        ref.invalidate(sequenceTemplatesProvider);

        context.showSuccessSnackBar('Duplicated "${widget.template.name}"');
      } catch (e) {
        if (context.mounted && host.isCurrent) {
          context.showErrorSnackBar(
              'Failed to duplicate template: ${userFacingError(e)}');
        }
      }
    }
  }

  Future<void> _deleteTemplate(BuildContext context) async {
    final dbId = widget.template.databaseId;
    if (dbId == null) return;
    final repository = ref.read(sequenceRepositoryProvider);
    var isDeleting = false;
    await showHostBoundDialog<void>(
      context: context,
      ref: ref,
      hostChangedMessage:
          'The connected host changed. Template deletion canceled.',
      hostChangeDiscardsInput: true,
      builder: (dialogContext, host) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) => PopScope(
            canPop: !isDeleting,
            child: AlertDialog(
              backgroundColor: _colors.surface,
              shape: RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline8)),
              title: Text(
                'Delete Template',
                style: TextStyle(color: _colors.textPrimary),
              ),
              content: ConstrainedBox(
                constraints: AdaptiveDialogConstraints.hybrid(
                  dialogContext,
                  designMaxWidth: 400,
                ),
                child: Text(
                  'Are you sure you want to delete "${widget.template.name}"? This action cannot be undone.',
                  style: TextStyle(color: _colors.textSecondary),
                ),
              ),
              actions: [
                SkotiqButton(
                  onPressed: isDeleting
                      ? null
                      : () => Navigator.of(dialogContext).pop(),
                  label: 'Cancel',
                  variant: ButtonVariant.ghost,
                  size: ButtonSize.small,
                ),
                SkotiqButton(
                  onPressed: isDeleting
                      ? null
                      : () async {
                          setDialogState(() => isDeleting = true);
                          try {
                            if (!dialogContext.mounted || host.isStale) return;
                            await repository.deleteSequence(dbId);
                            if (!dialogContext.mounted || host.isStale) return;

                            notifySequenceCatalogChanged(
                              ref,
                              sequenceId: dbId,
                              action: 'deleted',
                              name: widget.template.name,
                              isTemplate: true,
                            );
                            ref.invalidate(sequenceTemplatesProvider);

                            if (!dialogContext.mounted || host.isStale) return;
                            dialogContext.showSuccessSnackBar(
                                'Deleted "${widget.template.name}"');
                            Navigator.of(dialogContext).pop();
                          } catch (e) {
                            if (!dialogContext.mounted || host.isStale) return;
                            setDialogState(() => isDeleting = false);
                            dialogContext.showErrorSnackBar(
                                'Failed to delete template: $e');
                          }
                        },
                  label: 'Delete',
                  variant: ButtonVariant.destructive,
                  size: ButtonSize.small,
                  isLoading: isDeleting,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
