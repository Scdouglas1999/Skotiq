part of '../snippet_palette.dart';

extension _SnippetPaletteActions on _SnippetPaletteState {
  void _showCreateSnippetDialog() {
    final selectedNodeId = ref.read(selectedNodeIdProvider);
    final sequence = ref.read(currentSequenceProvider);

    if (selectedNodeId == null || sequence == null) return;

    final nameController = TextEditingController();
    final descriptionController = TextEditingController();
    SnippetCategory selectedCategory = SnippetCategory.custom;
    String selectedIconName = 'puzzle';

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: widget.colors.surfaceOverlay,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          ),
          title: Row(
            children: [
              Icon(
                LucideIcons.bookmark,
                size: 20,
                color: widget.colors.primary,
              ),
              const SizedBox(width: 12),
              Text(
                'Create Template',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize18,
                  fontWeight: FontWeight.w600,
                  color: widget.colors.textPrimary,
                ),
              ),
            ],
          ),
          content: ConstrainedBox(
            constraints: AdaptiveDialogConstraints.hybrid(
              context,
              designMaxWidth: 400,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Name field
                _buildDialogLabel('Name'),
                const SizedBox(height: 8),
                _buildDialogTextField(
                  controller: nameController,
                  hintText: 'Enter template name',
                ),
                const SizedBox(height: 16),

                // Description field
                _buildDialogLabel('Description'),
                const SizedBox(height: 8),
                _buildDialogTextField(
                  controller: descriptionController,
                  hintText: 'Describe what this template does',
                  maxLines: 2,
                ),
                const SizedBox(height: 16),

                // Category dropdown
                _buildDialogLabel('Category'),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: widget.colors.surfaceAlt,
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                    border: Border.all(color: widget.colors.border),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: AccessibleDropdown<SnippetCategory>(
                      value: selectedCategory,
                      isExpanded: true,
                      dropdownColor: widget.colors.surfaceOverlay,
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize14,
                        color: widget.colors.textPrimary,
                      ),
                      items: SnippetCategory.values.map((category) {
                        return DropdownMenuItem(
                          value: category,
                          child: Row(
                            children: [
                              Icon(
                                _getCategoryIcon(category),
                                size: 16,
                                color: _getCategoryColor(category),
                              ),
                              const SizedBox(width: 8),
                              Text(_getCategoryDisplayName(category)),
                            ],
                          ),
                        );
                      }).toList(),
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => selectedCategory = value);
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Icon selection
                _buildDialogLabel('Icon'),
                const SizedBox(height: 8),
                _buildIconSelector(
                  selectedIconName: selectedIconName,
                  onIconSelected: (iconName) {
                    setDialogState(() => selectedIconName = iconName);
                  },
                ),
              ],
            ),
          ),
          actions: [
            SkotiqButton(
              onPressed: () => Navigator.of(context).pop(),
              label: 'Cancel',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
            ),
            SkotiqButton(
              onPressed: () {
                final name = nameController.text.trim();
                final description = descriptionController.text.trim();

                if (name.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text('Please enter a template name'),
                      backgroundColor: widget.colors.error,
                    ),
                  );
                  return;
                }

                // Capture the full multi-selection when present, else the
                // single selected node. createSnippetFromSelection requires
                // the nodes share a parent / be contiguous; a failure
                // surfaces via the catch in _createSnippetFromSelection.
                final multi = ref.read(multiSelectedNodeIdsProvider);
                final nodeIds =
                    multi.isNotEmpty ? multi.toList() : [selectedNodeId];

                _createSnippetFromSelection(
                  name: name,
                  description:
                      description.isEmpty ? 'Custom template' : description,
                  category: selectedCategory,
                  iconName: selectedIconName,
                  nodeIds: nodeIds,
                  sequence: sequence,
                );

                Navigator.of(context).pop();
              },
              label: 'Create',
              variant: ButtonVariant.primary,
              size: ButtonSize.small,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDialogLabel(String text) {
    return Text(
      text,
      style: SkotiqTypography.labelSm
          .copyWith(color: widget.colors.textSecondary),
    );
  }

  Widget _buildDialogTextField({
    required TextEditingController controller,
    required String hintText,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      style: TextStyle(
        fontSize: SkotiqTypography.fontSize14,
        color: widget.colors.textPrimary,
      ),
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: TextStyle(
          fontSize: SkotiqTypography.fontSize14,
          color: widget.colors.textMuted,
        ),
        filled: true,
        fillColor: widget.colors.surfaceAlt,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          borderSide: BorderSide(color: widget.colors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          borderSide: BorderSide(color: widget.colors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          borderSide: BorderSide(color: widget.colors.primary),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }

  Widget _buildIconSelector({
    required String selectedIconName,
    required Function(String) onIconSelected,
  }) {
    final iconOptions = [
      ('focus', LucideIcons.focus),
      ('palette', LucideIcons.palette),
      ('move', LucideIcons.move),
      ('shield', LucideIcons.shield),
      ('rotate-cw', LucideIcons.rotateCw),
      ('filter', LucideIcons.filter),
      ('camera', LucideIcons.camera),
      ('target', LucideIcons.target),
      ('clock', LucideIcons.clock),
      ('star', LucideIcons.star),
      ('zap', LucideIcons.zap),
      ('layers', LucideIcons.layers),
      ('repeat', LucideIcons.repeat),
      ('grid', LucideIcons.grid),
      ('puzzle', LucideIcons.puzzle),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: iconOptions.map((option) {
        final (name, icon) = option;
        final isSelected = name == selectedIconName;
        return InkWell(
          onTap: () => onIconSelected(name),
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          child: Container(
            width: 40,
            height: 40,
            decoration: isSelected
                ? SkotiqDecorations.selectedSurface(
                    widget.colors.primary,
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                    fillAlpha: 0.2,
                  )
                : BoxDecoration(
                    color: widget.colors.surfaceAlt,
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                    border: Border.all(color: widget.colors.border),
                  ),
            child: Icon(
              icon,
              size: 18,
              color: isSelected
                  ? widget.colors.primary
                  : widget.colors.textSecondary,
            ),
          ),
        );
      }).toList(),
    );
  }

  Future<void> _createSnippetFromSelection({
    required String name,
    required String description,
    required SnippetCategory category,
    required String iconName,
    required List<String> nodeIds,
    required Sequence sequence,
  }) async {
    try {
      final snippet = createSnippetFromSelection(
        name: name,
        description: description,
        category: category,
        iconName: iconName,
        nodeIds: nodeIds,
        sequence: sequence,
      );

      await ref.read(customSnippetsProvider.notifier).addSnippet(snippet);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Template "$name" created successfully'),
            backgroundColor: widget.colors.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to create template: $e'),
            backgroundColor: widget.colors.error,
          ),
        );
      }
    }
  }

  Future<void> _handleDeleteSnippet(TemplateSnippet snippet) async {
    if (snippet.isBuiltIn) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: widget.colors.surfaceOverlay,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        ),
        title: Row(
          children: [
            Icon(
              LucideIcons.trash2,
              size: 20,
              color: widget.colors.error,
            ),
            const SizedBox(width: 12),
            Text(
              'Delete Template',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize18,
                fontWeight: FontWeight.w600,
                color: widget.colors.textPrimary,
              ),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: AdaptiveDialogConstraints.hybrid(
            context,
            designMaxWidth: 400,
          ),
          child: Text(
            'Are you sure you want to delete "${snippet.name}"? This action cannot be undone.',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize14,
              color: widget.colors.textSecondary,
            ),
          ),
        ),
        actions: [
          SkotiqButton(
            onPressed: () => Navigator.of(context).pop(),
            label: 'Cancel',
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
          ),
          SkotiqButton(
            onPressed: () => Navigator.of(context).pop(true),
            label: 'Delete',
            variant: ButtonVariant.destructive,
            size: ButtonSize.small,
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await ref.read(customSnippetsProvider.notifier).removeSnippet(snippet.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Template "${snippet.name}" deleted'),
          backgroundColor: widget.colors.info,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to delete template: $e'),
          backgroundColor: widget.colors.error,
        ),
      );
    }
  }

  /// Returns true if the running platform has a native share sheet
  /// `share_plus` can reach. Desktop platforms (Windows / Linux) have no
  /// system share sheet — those flow through `_handleExportSnippet`
  /// instead so the user manually moves the resulting file. macOS does
  /// have a share sheet, so it's allowed alongside iOS/Android.
  bool get _platformHasShareSheet {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
      case TargetPlatform.android:
      case TargetPlatform.macOS:
        return true;
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  Future<void> _handleImportSnippet() async {
    if (!_beginSnippetFileAction()) return;
    try {
      final service = ref.read(snippetFileServiceProvider);
      final imported = await service.importSnippet();
      if (imported == null) return; // user cancelled

      await ref.read(customSnippetsProvider.notifier).addSnippet(imported);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Imported snippet "${imported.name}"'),
          backgroundColor: widget.colors.success,
        ),
      );
    } on SnippetVersionMismatchException catch (e) {
      // Loud, distinct path so the user understands an upgrade — not a
      // file fix — is required. Different copy from the schema-issue
      // branch below.
      if (!mounted) return;
      _showImportErrorDialog(
        title: 'Snippet from a newer Skotiq',
        body:
            'The selected snippet was authored with schema version ${e.fileVersion}, '
            'but this build of Skotiq only supports up to version '
            '${e.supportedVersion}. Update Skotiq and try again.',
      );
    } on SnippetImportException catch (e) {
      if (!mounted) return;
      _showImportErrorDialog(
        title: 'Snippet file is invalid',
        body: 'The snippet file could not be imported. Fix the following issue'
            '${e.issues.length == 1 ? '' : 's'} and try again:',
        issues: e.issues,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to import snippet: $e'),
          backgroundColor: widget.colors.error,
        ),
      );
    } finally {
      _finishSnippetFileAction();
    }
  }

  Future<void> _handleExportSnippet(TemplateSnippet snippet) async {
    if (!_beginSnippetFileAction()) return;
    try {
      final service = ref.read(snippetFileServiceProvider);
      final savedPath = await service.exportSnippet(snippet);
      if (savedPath == null) return; // user cancelled

      if (!mounted) return;
      // `_handleShareSnippet` routes touch platforms to the share sheet, but
      // this method is still directly invocable there — and on a phone the
      // export now lands in the app sandbox, so naming the basename would
      // describe a file the user cannot open. Reveal handles both: share sheet
      // on touch, the same success line on desktop.
      await revealExportedFile(
        context,
        savedPath,
        subject: 'Skotiq snippet: ${snippet.name}',
        desktopMessage:
            'Exported "${snippet.name}" to ${p.basename(savedPath)}',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to export snippet: $e'),
          backgroundColor: widget.colors.error,
        ),
      );
    } finally {
      _finishSnippetFileAction();
    }
  }

  /// Share via the platform share sheet (iOS / Android / macOS). On
  /// platforms without a share sheet this falls back to
  /// [_handleExportSnippet] — the user gets a save dialog instead and
  /// can attach the resulting file to whatever they like.
  Future<void> _handleShareSnippet(TemplateSnippet snippet) async {
    if (!_platformHasShareSheet) {
      // Desktop fallback: open the export dialog. Same user-visible
      // result (a file they can attach to anything) without pretending
      // we can drive a system share UI that doesn't exist.
      await _handleExportSnippet(snippet);
      return;
    }

    if (!_beginSnippetFileAction()) return;
    try {
      final service = ref.read(snippetFileServiceProvider);

      // Stage the bundle in the OS temp directory under a filename the
      // share sheet preview can show. Cleanup of temp dirs is handled
      // by the OS — share_plus copies the file before returning, so a
      // later sweep won't break the share itself.
      final tmpDir = await getTemporaryDirectory();
      final filename = service.suggestedFilename(snippet);
      final tmpPath = p.join(tmpDir.path, filename);
      await service.exportSnippetToPath(snippet, tmpPath);

      await Share.shareXFiles(
        [XFile(tmpPath, mimeType: 'application/json')],
        subject: snippet.name,
        text: 'Skotiq snippet: ${snippet.name}\n\n${snippet.description}',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to share snippet: $e'),
          backgroundColor: widget.colors.error,
        ),
      );
    } finally {
      _finishSnippetFileAction();
    }
  }

  void _showImportErrorDialog({
    required String title,
    required String body,
    List<SnippetImportIssue> issues = const [],
  }) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: widget.colors.surfaceOverlay,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        ),
        title: Row(
          children: [
            Icon(
              LucideIcons.alertTriangle,
              size: 20,
              color: widget.colors.error,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize18,
                  fontWeight: FontWeight.w600,
                  color: widget.colors.textPrimary,
                ),
              ),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: AdaptiveDialogConstraints.hybrid(
            ctx,
            designMaxWidth: 480,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                body,
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize13,
                  color: widget.colors.textSecondary,
                ),
              ),
              if (issues.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  constraints: const BoxConstraints(maxHeight: 280),
                  decoration: BoxDecoration(
                    color: widget.colors.surfaceAlt,
                    border: Border.all(color: widget.colors.border),
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusMd),
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: issues
                          .map(
                            (i) => Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Text(
                                i.field.isEmpty
                                    ? '• ${i.message}'
                                    : '• ${i.field}: ${i.message}',
                                style: TextStyle(
                                  fontSize: SkotiqTypography.fontSize12,
                                  color: widget.colors.textPrimary,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          SkotiqButton(
            onPressed: () => Navigator.of(ctx).pop(),
            label: 'Close',
            variant: ButtonVariant.primary,
            size: ButtonSize.small,
          ),
        ],
      ),
    );
  }
}
