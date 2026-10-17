// Dialog used to save the current sequence as a template, including the target-selection option chips.
part of '../templates_tab.dart';

class _SaveTemplateDialog extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final Sequence sequence;

  const _SaveTemplateDialog({
    required this.colors,
    required this.sequence,
  });

  @override
  ConsumerState<_SaveTemplateDialog> createState() =>
      _SaveTemplateDialogState();
}

class _SaveTemplateDialogState extends ConsumerState<_SaveTemplateDialog> {
  late TextEditingController _nameController;
  late TextEditingController _descriptionController;
  late final SkotiqBackend _authority;
  late final SequenceRepository _repository;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;
  bool _isSaving = false;

  bool get _isExistingTemplate =>
      widget.sequence.isTemplate && widget.sequence.databaseId != null;

  /// Instructions the user actually authored — the implicit root container
  /// is not one, so an empty sequence counts 0 rather than 1.
  int get _instructionCount => visibleInstructionCount(widget.sequence);

  /// Creating a NEW template out of an empty sequence produces a catalogue
  /// entry that applies nothing, so that is refused. Re-saving an existing
  /// template row is not: the user may be there to fix its name or
  /// description, and blocking that would strand them with no way to edit
  /// the metadata of a template they already own.
  bool get _blockedAsEmpty => _instructionCount == 0 && !_isExistingTemplate;

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
          'The connected host changed. Template save cancelled.',
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

  Future<void> _saveTemplate() async {
    if (_nameController.text.trim().isEmpty) {
      context.showErrorSnackBar('Please enter a template name');
      return;
    }

    if (!identical(ref.read(backendProvider), _authority)) {
      context.showWarningSnackBar(
        'The connected host changed. Reopen the template editor.',
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      final templateSequence = Sequence.create(
        databaseId: _isExistingTemplate ? widget.sequence.databaseId : null,
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim(),
        nodes: widget.sequence.nodes,
        rootNodeId: widget.sequence.rootNodeId,
        isTemplate: true,
      );

      final savedId =
          await _repository.saveSequence(templateSequence, isTemplate: true);

      if (!mounted || !identical(ref.read(backendProvider), _authority)) {
        return;
      }

      ref.read(currentSequenceProvider.notifier).applyPersistedSave(
            expectedSequenceId: widget.sequence.id,
            databaseId: savedId,
            name: templateSequence.name,
            description: templateSequence.description,
            isTemplate: true,
          );

      notifySequenceCatalogChanged(
        ref,
        sequenceId: savedId,
        action: _isExistingTemplate ? 'updated' : 'saved',
        name: templateSequence.name,
        isTemplate: true,
      );
      ref.invalidate(sequenceTemplatesProvider);

      if (mounted) {
        Navigator.pop(context);

        context.showSuccessSnackBar(
          _isExistingTemplate
              ? 'Template "${_nameController.text}" updated!'
              : 'Template "${_nameController.text}" saved!',
        );
      }
    } catch (e) {
      if (mounted && identical(ref.read(backendProvider), _authority)) {
        context.showErrorSnackBar('Failed to save template: $e');
      }
    } finally {
      if (mounted && identical(ref.read(backendProvider), _authority)) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = Responsive.isMobile(context);

    final dialog = Dialog(
      backgroundColor: widget.colors.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8)),
      child: ConstrainedBox(
        constraints: AdaptiveDialogConstraints.hybrid(
          context,
          designMaxWidth: 450,
          designMaxHeight: 500,
        ),
        child: Padding(
          padding: EdgeInsets.all(isMobile ? 16 : 24),
          child: SingleChildScrollView(
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
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _isExistingTemplate
                                ? 'Update Template'
                                : 'Save as Template',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: SkotiqTypography.fontSize18,
                              fontWeight: FontWeight.w700,
                              color: widget.colors.textPrimary,
                            ),
                          ),
                          Text(
                            _isExistingTemplate
                                ? 'Replace the saved template with these changes'
                                : 'Save this sequence for later reuse',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: SkotiqTypography.fontSize12,
                              color: widget.colors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                // Name field
                Text(
                  'Template Name',
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
                      hintText: 'Enter template name',
                      hintStyle: TextStyle(
                        color: widget.colors.textMuted,
                      ),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),

                const SizedBox(height: 20),

                // Description field
                Text(
                  'Description',
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
                    maxLines: 3,
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize14,
                      color: widget.colors.textPrimary,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Describe what this template is for...',
                      hintStyle: TextStyle(
                        color: widget.colors.textMuted,
                      ),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),

                const SizedBox(height: 24),

                // Info about current sequence
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: widget.colors.surfaceAlt,
                    borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
                  ),
                  child: Row(
                    children: [
                      Icon(LucideIcons.info,
                          size: 16, color: widget.colors.info),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _blockedAsEmpty
                              ? 'This sequence has no instructions yet. Add '
                                  'at least one node before saving it as a '
                                  'template.'
                              : _isExistingTemplate
                                  ? 'This will replace the saved template '
                                      'with ${countLabel(_instructionCount, 'node')} '
                                      'from the editor.'
                                  : 'This will save '
                                      '${countLabel(_instructionCount, 'node')} '
                                      'from the current sequence.',
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
                      onPressed:
                          _isSaving ? null : () => Navigator.pop(context),
                      label: 'Cancel',
                      variant: ButtonVariant.ghost,
                      size: ButtonSize.small,
                    ),
                    const SizedBox(width: 12),
                    // An empty sequence produces an empty template, which
                    // then shows up in the catalogue and applies to nothing.
                    // The info line above states the reason in place.
                    SkotiqButton(
                      label: _isSaving
                          ? 'Saving...'
                          : _isExistingTemplate
                              ? 'Update Template'
                              : 'Save Template',
                      icon: _isSaving ? LucideIcons.loader : LucideIcons.save,
                      onPressed:
                          _isSaving || _blockedAsEmpty ? null : _saveTemplate,
                      size: ButtonSize.small,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return PopScope(canPop: !_isSaving, child: dialog);
  }
}

/// A selectable target option for the target selection dialog
class _TargetOption extends StatefulWidget {
  final SkotiqColors colors;
  final TargetHeaderNode target;
  final VoidCallback onTap;

  const _TargetOption({
    required this.colors,
    required this.target,
    required this.onTap,
  });

  @override
  State<_TargetOption> createState() => _TargetOptionState();
}

class _TargetOptionState extends State<_TargetOption> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: _isHovered
                ? SkotiqDecorations.tintedBadge(
                    widget.colors.warning,
                    borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
                  ).color
                : widget.colors.surfaceAlt,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
            border: Border.all(
              color: _isHovered ? widget.colors.warning : widget.colors.border,
              width: _isHovered ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: SkotiqDecorations.statusChip(
                  widget.colors.warning,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline8),
                  bordered: false,
                ),
                child: Icon(
                  LucideIcons.target,
                  size: 16,
                  color: widget.colors.warning,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.target.targetName,
                      style: SkotiqTypography.labelStrong
                          .copyWith(color: widget.colors.textPrimary),
                    ),
                    Text(
                      'RA: ${_formatRA(widget.target.raHours)} · Dec: ${_formatDec(widget.target.decDegrees)}',
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize11,
                        color: widget.colors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                LucideIcons.chevronRight,
                size: 16,
                color: _isHovered
                    ? widget.colors.warning
                    : widget.colors.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatRA(double raHours) =>
      CoordinateFormat.raHm(raHours, style: SexagesimalStyle.plainLetters);

  String _formatDec(double decDegrees) =>
      CoordinateFormat.decDecimal(decDegrees);
}
