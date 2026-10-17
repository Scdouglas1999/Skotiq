// The per-template card with its hover state, instantiate/duplicate/edit/delete actions, body chips, and the _SmallIconButton primitive used for the card's icon-only secondary actions.
part of '../templates_tab.dart';

class _TemplateCard extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final Sequence template;

  const _TemplateCard({
    required this.colors,
    required this.template,
  });

  @override
  ConsumerState<_TemplateCard> createState() => _TemplateCardState();
}

class _TemplateCardState extends ConsumerState<_TemplateCard>
    with SingleTickerProviderStateMixin {
  bool _isHovered = false;
  late AnimationController _animController;
  late Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 1.02).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  IconData _getTemplateIcon() {
    final name = widget.template.name.toLowerCase();
    // Beginner templates
    if (name.contains('first light')) return LucideIcons.sparkles;
    if (name.contains('osc') || name.contains('one-shot')) {
      return LucideIcons.camera;
    }
    if (name.contains('quick')) return LucideIcons.zap;
    if (name.contains('beginner')) return LucideIcons.graduationCap;
    // Intermediate templates
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
    // Specialized templates
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

  Color _getTemplateColor() {
    final name = widget.template.name.toLowerCase();
    // Beginner templates - green/info
    if (name.contains('first light')) return widget.colors.success;
    if (name.contains('osc') || name.contains('one-shot')) {
      return widget.colors.info;
    }
    if (name.contains('quick')) return widget.colors.success;
    if (name.contains('beginner')) return widget.colors.info;
    // Intermediate templates - primary/accent
    if (name.contains('ha-oiii') || name.contains('bicolor')) {
      return widget.colors.accent;
    }
    if (name.contains('sho') || name.contains('hubble')) {
      return widget.colors.accent;
    }
    if (name.contains('lrgb')) return widget.colors.primary;
    if (name.contains('narrowband')) return widget.colors.accent;
    if (name.contains('multi-target')) return widget.colors.primary;
    if (name.contains('mosaic')) return widget.colors.warning;
    // Specialized templates - warning
    if (name.contains('planetary')) return widget.colors.warning;
    if (name.contains('unattended') || name.contains('all-night')) {
      return widget.colors.warning;
    }
    if (name.contains('comet') || name.contains('asteroid')) {
      return widget.colors.warning;
    }
    if (name.contains('solar')) return widget.colors.warning;
    if (name.contains('lunar')) return widget.colors.warning;
    if (name.contains('remote') || name.contains('observatory')) {
      return widget.colors.warning;
    }
    return widget.colors.textMuted;
  }

  @override
  Widget build(BuildContext context) {
    final onPrimary = Theme.of(context).colorScheme.onPrimary;

    final templateColor = _getTemplateColor();
    // Touch devices have no hover state. Keeping every secondary action
    // behind `_isHovered` made customize/duplicate/delete desktop-only even
    // though the Templates tab is shipped on mobile.
    final showActions = Responsive.isMobile(context) || _isHovered;
    // "Use Template" calls mergeTemplateNodes /
    // loadSequence — both replace tree state and must be gated. "Edit"
    // also calls loadSequence, "Duplicate" goes through the repository
    // (not the editor) so it stays enabled. Delete operates on the
    // template database row, not the active sequence, so also stays
    // enabled. We grey out the whole card's primary action while
    // running so the user can't accidentally clobber their in-flight run.
    final canEdit = ref.watch(canEditSequenceProvider);

    return MouseRegion(
      onEnter: (_) {
        setState(() => _isHovered = true);
        _animController.forward();
      },
      onExit: (_) {
        setState(() => _isHovered = false);
        _animController.reverse();
      },
      child: ScaleTransition(
        scale: _scaleAnim,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: widget.colors.surface,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            border: Border.all(
              color: _isHovered
                  ? templateColor.withValues(alpha: 0.6)
                  : widget.colors.border,
              width: _isHovered ? 2 : 1,
            ),
            boxShadow: null,
          ),
          child: InkWell(
            onTap: canEdit ? () => _useTemplate(context) : null,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Icon and actions
                  Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: SkotiqDecorations.tintedBadge(
                          templateColor,
                          borderRadius:
                              BorderRadius.circular(SkotiqTokens.radiusInline8),
                        ),
                        child: Icon(
                          _getTemplateIcon(),
                          size: 24,
                          color: templateColor,
                        ),
                      ),
                      const Spacer(),
                      if (showActions) ...[
                        // "Duplicate" operates on the template DB row,
                        // not the active sequence — stays enabled.
                        _SmallIconButton(
                          colors: widget.colors,
                          icon: LucideIcons.copy,
                          tooltip: 'Duplicate',
                          onPressed: () => _duplicateTemplate(context),
                        ),
                        const SizedBox(width: 4),
                        // "Edit" calls loadSequence — this replaces the
                        // active sequence and MUST be gated.
                        _SmallIconButton(
                          colors: widget.colors,
                          icon: LucideIcons.pencil,
                          tooltip: canEdit
                              ? widget.template.databaseId == null
                                  ? 'Customize a copy'
                                  : 'Edit template'
                              : 'Edit (locked while sequence is running)',
                          onPressed:
                              canEdit ? () => _editTemplate(context) : null,
                        ),
                        if (widget.template.databaseId != null) ...[
                          const SizedBox(width: 4),
                          // Bundled templates are immutable and expose no
                          // pretend delete action. A custom template has a
                          // real backing row and can be removed.
                          _SmallIconButton(
                            colors: widget.colors,
                            icon: LucideIcons.trash2,
                            tooltip: 'Delete',
                            color: widget.colors.error,
                            onPressed: () => _deleteTemplate(context),
                          ),
                        ],
                      ],
                    ],
                  ),

                  const SizedBox(height: 16),

                  // Name
                  Text(
                    widget.template.name,
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize16,
                      fontWeight: FontWeight.w700,
                      color: widget.colors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),

                  const SizedBox(height: 6),

                  // Description
                  Expanded(
                    child: Text(
                      widget.template.description.isEmpty
                          ? 'No description'
                          : widget.template.description,
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize12,
                        color: widget.colors.textSecondary,
                        height: 1.5,
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Footer
                  Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Icon(
                              LucideIcons.layoutList,
                              size: 12,
                              color: widget.colors.textMuted,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                countLabel(
                                  widget.template.nodes.length,
                                  'node',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: SkotiqTypography.fontSize11,
                                  color: widget.colors.textMuted,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Icon(
                              LucideIcons.calendar,
                              size: 12,
                              color: widget.colors.textMuted,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                DateFormat.yMd()
                                    .format(widget.template.createdAt),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: SkotiqTypography.fontSize11,
                                  color: widget.colors.textMuted,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),

                      // Use button
                      AnimatedOpacity(
                        opacity: showActions ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 150),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: templateColor,
                            borderRadius:
                                BorderRadius.circular(SkotiqTokens.radiusMd),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(LucideIcons.play,
                                  size: 12, color: onPrimary),
                              const SizedBox(width: 6),
                              Text(
                                'Use',
                                style: SkotiqTypography.labelStrongSm
                                    .copyWith(color: onPrimary),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _useTemplate(BuildContext context) {
    final currentSequence = ref.read(currentSequenceProvider);

    // Check if there are existing targets in the current sequence
    final existingTargets = currentSequence?.targetHeaders ?? [];

    if (existingTargets.length > 1) {
      // Multiple targets - prompt user to choose
      _showTargetSelectionDialog(context, existingTargets);
    } else if (existingTargets.length == 1) {
      // Single target - merge directly
      _applyTemplateToTarget(context, existingTargets.first);
    } else {
      // No existing targets - create a new sequence from template
      _createNewSequenceFromTemplate(context);
    }
  }

  void _showTargetSelectionDialog(
      BuildContext context, List<TargetHeaderNode> targets) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: widget.colors.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8)),
        title: Row(
          children: [
            Icon(LucideIcons.target, size: 20, color: widget.colors.warning),
            const SizedBox(width: 12),
            Text(
              'Select Target',
              style: TextStyle(color: widget.colors.textPrimary),
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
                  style: TextStyle(color: widget.colors.textSecondary),
                ),
                const SizedBox(height: 16),
                ...targets.map((target) => _TargetOption(
                      colors: widget.colors,
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
    final authority = ref.read(backendProvider);
    final sequenceNotifier = ref.read(currentSequenceProvider.notifier);
    final newNodes = <String, SequenceNode>{};
    final idMapping = <String, String>{};

    // Generate new IDs for all nodes
    for (final entry in widget.template.nodes.entries) {
      final newId = const Uuid().v4();
      idMapping[entry.key] = newId;
    }

    // Clone nodes with new IDs and updated references
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

    // Get the new root node ID
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
      if (discard != true ||
          !context.mounted ||
          !identical(ref.read(backendProvider), authority)) {
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
    final authority = ref.read(backendProvider);
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

    if (!identical(ref.read(backendProvider), authority)) {
      context.showWarningSnackBar(
        'The connected host changed. Reopen the template catalog.',
      );
      return;
    }

    // Re-key the node graph for the editor while retaining the backing row.
    // The row identity is what lets "Update Template" persist in place.
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
        if (!context.mounted ||
            !identical(ref.read(backendProvider), authority)) {
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
        if (context.mounted &&
            identical(ref.read(backendProvider), authority)) {
          context.showErrorSnackBar('Could not create template copy: $e');
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
      'Editing "${editableTemplate.name}" — use Update Template in the '
      'Templates tab to save changes.',
    );
  }

  Future<void> _duplicateTemplate(BuildContext context) async {
    final authority = ref.read(backendProvider);
    final repository = ref.read(sequenceRepositoryProvider);
    // Check if template has a database ID
    final dbId = widget.template.databaseId;
    if (dbId != null) {
      try {
        final duplicated = await repository.duplicateSequence(
            dbId, '${widget.template.name} (Copy)');

        if (!context.mounted ||
            !identical(ref.read(backendProvider), authority)) {
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
        if (context.mounted &&
            identical(ref.read(backendProvider), authority)) {
          context.showErrorSnackBar('Failed to duplicate template: $e');
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

        if (!context.mounted ||
            !identical(ref.read(backendProvider), authority)) {
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
        if (context.mounted &&
            identical(ref.read(backendProvider), authority)) {
          context.showErrorSnackBar('Failed to duplicate template: $e');
        }
      }
    }
  }

  Future<void> _deleteTemplate(BuildContext context) async {
    final dbId = widget.template.databaseId;
    if (dbId == null) return;
    final authority = ref.read(backendProvider);
    final repository = ref.read(sequenceRepositoryProvider);
    var isDeleting = false;
    BuildContext? routeContext;
    final subscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (previous == null || identical(previous, next)) return;
        final dialogContext = routeContext;
        if (dialogContext != null && dialogContext.mounted) {
          dialogContext.showWarningSnackBar(
            'The connected host changed. Template deletion cancelled.',
          );
          closeAuthorityBoundDialog(dialogContext);
        }
      },
    );

    try {
      // Show confirmation dialog
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          routeContext = dialogContext;
          return StatefulBuilder(
            builder: (dialogContext, setDialogState) => PopScope(
              canPop: !isDeleting,
              child: AlertDialog(
                backgroundColor: widget.colors.surface,
                shape: RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8)),
                title: Text(
                  'Delete Template',
                  style: TextStyle(color: widget.colors.textPrimary),
                ),
                content: ConstrainedBox(
                  constraints: AdaptiveDialogConstraints.hybrid(
                    dialogContext,
                    designMaxWidth: 400,
                  ),
                  child: Text(
                    'Are you sure you want to delete "${widget.template.name}"? This action cannot be undone.',
                    style: TextStyle(color: widget.colors.textSecondary),
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
                              if (!identical(
                                  ref.read(backendProvider), authority)) {
                                Navigator.of(dialogContext).pop();
                                return;
                              }
                              await repository.deleteSequence(dbId);

                              if (!dialogContext.mounted ||
                                  !identical(
                                      ref.read(backendProvider), authority)) {
                                return;
                              }

                              notifySequenceCatalogChanged(
                                ref,
                                sequenceId: dbId,
                                action: 'deleted',
                                name: widget.template.name,
                                isTemplate: true,
                              );
                              ref.invalidate(sequenceTemplatesProvider);

                              if (!dialogContext.mounted) return;
                              dialogContext.showSuccessSnackBar(
                                  'Deleted "${widget.template.name}"');
                              Navigator.of(dialogContext).pop();
                            } catch (e) {
                              if (!dialogContext.mounted) return;
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
    } finally {
      subscription.close();
    }
  }
}

class _SmallIconButton extends StatefulWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String tooltip;
  final Color? color;
  // Nullable so the template card can gray out the "Edit" pencil while
  // the sequence is running. Other callers may still pass a non-null
  // callback unchanged.
  final VoidCallback? onPressed;

  const _SmallIconButton({
    required this.colors,
    required this.icon,
    required this.tooltip,
    this.color,
    required this.onPressed,
  });

  @override
  State<_SmallIconButton> createState() => _SmallIconButtonState();
}

class _SmallIconButtonState extends State<_SmallIconButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? widget.colors.textSecondary;
    final disabled = widget.onPressed == null;
    final iconColor = disabled
        ? widget.colors.textMuted.withValues(alpha: 0.4)
        : (_isHovered ? color : widget.colors.textMuted);

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: disabled ? null : (_) => setState(() => _isHovered = true),
        onExit: disabled ? null : (_) => setState(() => _isHovered = false),
        cursor:
            disabled ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: !disabled && _isHovered
                  ? SkotiqDecorations.tintedBadge(
                      color,
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusMd),
                    ).color
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
            ),
            child: Icon(
              widget.icon,
              size: 14,
              color: iconColor,
            ),
          ),
        ),
      ),
    );
  }
}
