part of '../annotation_panel.dart';

class AnnotationTabPanel extends ConsumerStatefulWidget {
  final SkotiqColors colors;

  const AnnotationTabPanel({super.key, required this.colors});

  @override
  ConsumerState<AnnotationTabPanel> createState() => _AnnotationTabPanelState();
}

class _AnnotationTabPanelState extends ConsumerState<AnnotationTabPanel> {
  static const List<ObjectType> _filterTypes = [
    ObjectType.galaxy,
    ObjectType.nebula,
    ObjectType.planetaryNebula,
    ObjectType.starCluster,
    ObjectType.star,
    ObjectType.unknown,
  ];

  bool _filtersExpanded = false;
  String _searchQuery = '';
  bool _isReAnnotating = false;
  bool _isSaving = false;

  Future<void> _runPanelAction(
    Future<void> Function() action,
    String failureMessage,
  ) async {
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$failureMessage: $error'),
          backgroundColor: SkotiqColors.of(context).error,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _handleReAnnotate() async {
    if (_isReAnnotating) return;
    setState(() => _isReAnnotating = true);

    try {
      final annotationService = ref.read(annotationServiceProvider);
      await annotationService.reAnnotate();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Re-annotation failed: $error'),
            backgroundColor: SkotiqColors.of(context).error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isReAnnotating = false);
      }
    }
  }

  Future<void> _handleSaveAnnotatedImage() async {
    if (_isSaving) return;

    final annotation = ref.read(currentAnnotationProvider);
    final currentImage = ref.read(currentImageProvider);
    if (annotation == null || currentImage == null) {
      return;
    }

    setState(() => _isSaving = true);

    try {
      final savePath = await ref.read(annotationPngSavePickerProvider)(
        annotationPngSuggestedName(
          sourcePath: currentImage.filePath,
          capturedAt: currentImage.capturedAt,
        ),
      );
      if (savePath == null || !mounted) return;

      final settingsFuture = ref.read(annotationSettingsProvider.future);
      final markerStyleFuture = ref.read(annotationMarkerStyleProvider.future);
      final settings = await settingsFuture;
      final markerStyle = await markerStyleFuture;
      if (!mounted) return;

      await renderAnnotatedImagePng(
        rgbaBytes: currentImage.displayData,
        width: currentImage.width,
        height: currentImage.height,
        annotation: annotation,
        settings: settings,
        markerStyle: markerStyle,
        outputPath: savePath,
        writeBytes: ref.read(annotationPngWriterProvider),
      );

      if (mounted) {
        await revealExportedFile(
          context,
          savePath,
          subject: 'Annotated image',
          desktopMessage: 'Annotated image saved to $savePath',
          desktopDuration: const Duration(seconds: 4),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save annotated image: $e'),
            backgroundColor: SkotiqColors.of(context).error,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  /// Opens the catalog settings for the section's one setup banner, then
  /// re-reads the install state so the banner clears itself.
  void _openCatalogSettings() {
    showDialog<void>(
      context: context,
      builder: (BuildContext context) => Dialog(
        child: ConstrainedBox(
          constraints: AdaptiveDialogConstraints.hybrid(
            context,
            designMaxWidth: 800,
            designMaxHeight: 700,
          ),
          child: const CatalogSettingsScreen(),
        ),
      ),
    ).then((_) => ref.invalidate(annotationCatalogInstalledProvider));
  }

  void _onObjectSelected(CelestialObjectAnnotation object) {
    ref.read(selectedAnnotationObjectProvider.notifier).state = object;
  }

  Future<void> _exportCsv(List<CelestialObjectAnnotation> objects) async {
    if (objects.isEmpty) return;
    final timestamp = DateFormat('yyyy-MM-dd_HHmmss').format(DateTime.now());
    final csv = generateAnnotationCsv(objects);
    final path = await _saveExportFile(
      suggestedName: 'annotations_$timestamp.csv',
      content: csv,
      label: 'CSV files',
      extensions: ['csv'],
    );
    if (path != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Annotations exported to $path'),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _exportDs9(List<CelestialObjectAnnotation> objects) async {
    if (objects.isEmpty) return;
    final timestamp = DateFormat('yyyy-MM-dd_HHmmss').format(DateTime.now());
    final reg = generateDs9RegionFile(objects);
    final path = await _saveExportFile(
      suggestedName: 'annotations_$timestamp.reg',
      content: reg,
      label: 'DS9 region files',
      extensions: ['reg'],
    );
    if (path != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('DS9 regions exported to $path'),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _saveAsPreset() async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => const _PresetNameDialog(),
    );
    if (name == null || name.trim().isEmpty) return;

    try {
      await ref
          .read(annotationPresetsProvider.notifier)
          .saveCurrentAsPreset(name);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Preset "$name" saved'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save preset: $e'),
            backgroundColor: SkotiqColors.of(context).error,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  Future<void> _applyPreset(String name) async {
    try {
      var preset = builtInAnnotationPresets
          .where((candidate) => candidate.name == name)
          .firstOrNull;
      if (preset == null) {
        final userPresets = await ref.read(annotationPresetsProvider.future);
        preset = userPresets
            .where((candidate) => candidate.name == name)
            .firstOrNull;
      }
      if (preset == null) {
        throw StateError('Preset "$name" not found');
      }
      await ref.read(annotationSettingsProvider.notifier).applyPreset(preset);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to apply preset: $e'),
            backgroundColor: SkotiqColors.of(context).error,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  Future<void> _deletePreset(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => SkotiqDialog(
        title: 'Delete preset',
        icon: SkotiqIcons.delete,
        width: 420,
        actions: [
          SkotiqButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            label: 'Cancel',
            variant: ButtonVariant.outline,
            size: ButtonSize.small,
          ),
          SkotiqButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            label: 'Delete',
            variant: ButtonVariant.destructive,
            size: ButtonSize.small,
          ),
        ],
        child: Text('Delete preset "$name"? This cannot be undone.'),
      ),
    );
    if (confirmed != true) return;

    try {
      await ref.read(annotationPresetsProvider.notifier).deletePreset(name);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Preset "$name" deleted'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to delete preset: $e'),
            backgroundColor: SkotiqColors.of(context).error,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final annotation = ref.watch(currentAnnotationProvider);
    final settingsAsync = ref.watch(annotationSettingsProvider);
    if (settingsAsync.hasError) {
      return _annotationAuthorityState(
        colors: widget.colors,
        label: 'annotation settings',
        error: settingsAsync.error,
        onRetry: () => ref.invalidate(annotationSettingsProvider),
      );
    }
    if (!settingsAsync.hasValue) {
      return _annotationAuthorityState(
        colors: widget.colors,
        label: 'annotation settings',
        onRetry: () => ref.invalidate(annotationSettingsProvider),
      );
    }
    final settings = settingsAsync.requireValue;
    final sortMode = ref.watch(annotationPanelSortModeProvider);
    final selectedObject = ref.watch(selectedAnnotationObjectProvider);
    final presetsAsync = ref.watch(annotationPresetsProvider);
    final presets = [
      ...builtInAnnotationPresets,
      ...?presetsAsync.valueOrNull,
    ];
    final objects = annotation?.objects ?? [];

    final typeCounts = <ObjectType, int>{};
    for (final obj in objects) {
      typeCounts[obj.type] = (typeCounts[obj.type] ?? 0) + 1;
    }

    final displayableObjects = objects.where((obj) {
      if (!obj.visible) return false;
      if (!isTypeVisibleFromSettings(obj.type, settings.visibleTypes)) {
        return false;
      }
      if (obj.magnitude != null) {
        if (obj.magnitude! > settings.magnitudeCutoff) return false;
        if (obj.magnitude! < settings.minMagnitude) return false;
      }
      return true;
    }).toList();

    final filteredObjects = displayableObjects.where((obj) {
      if (_searchQuery.isNotEmpty) {
        final query = _searchQuery.toLowerCase();
        final nameMatch = obj.name.toLowerCase().contains(query);
        final commonNameMatch =
            obj.commonName?.toLowerCase().contains(query) ?? false;
        final catalogMatch =
            obj.catalogId?.toLowerCase().contains(query) ?? false;
        if (!nameMatch && !commonNameMatch && !catalogMatch) return false;
      }
      return true;
    }).toList();

    switch (sortMode) {
      case AnnotationPanelSortMode.brightness:
        filteredObjects.sort((a, b) {
          final aMag = a.magnitude ?? 99.0;
          final bMag = b.magnitude ?? 99.0;
          final magCompare = aMag.compareTo(bMag);
          if (magCompare != 0) return magCompare;
          return a.name.compareTo(b.name);
        });
      case AnnotationPanelSortMode.name:
        filteredObjects.sort((a, b) => a.name.compareTo(b.name));
      case AnnotationPanelSortMode.type:
        filteredObjects.sort((a, b) {
          final typeCompare = _getObjectTypeLabel(a.type)
              .compareTo(_getObjectTypeLabel(b.type));
          if (typeCompare != 0) return typeCompare;
          return (a.magnitude ?? 99.0).compareTo(b.magnitude ?? 99.0);
        });
    }

    return Column(
      children: [
        // Toolbar row with actions
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: widget.colors.border),
            ),
          ),
          child: Row(
            children: [
              // Object count badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: SkotiqDecorations.tintedBadge(
                  widget.colors.primary,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusLg),
                ),
                child: Text(
                  '${filteredObjects.length}/${displayableObjects.length} objects',
                  style: SkotiqTypography.labelStrongSm
                      .copyWith(color: widget.colors.primary),
                ),
              ),
              const Spacer(),
              // Sort menu
              PopupMenuButton<AnnotationPanelSortMode>(
                tooltip: 'Sort objects',
                color: widget.colors.surfaceElevated,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                shape: _annotationMenuShape(widget.colors),
                onSelected: (value) => ref
                    .read(annotationPanelSortModeProvider.notifier)
                    .state = value,
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: AnnotationPanelSortMode.brightness,
                    child: Text(
                      'Sort: Brightness',
                      style: SkotiqTypography.caption
                          .copyWith(color: widget.colors.textPrimary),
                    ),
                  ),
                  PopupMenuItem(
                    value: AnnotationPanelSortMode.name,
                    child: Text(
                      'Sort: Name',
                      style: SkotiqTypography.caption
                          .copyWith(color: widget.colors.textPrimary),
                    ),
                  ),
                  PopupMenuItem(
                    value: AnnotationPanelSortMode.type,
                    child: Text(
                      'Sort: Type',
                      style: SkotiqTypography.caption
                          .copyWith(color: widget.colors.textPrimary),
                    ),
                  ),
                ],
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    LucideIcons.arrowUpDown,
                    size: 14,
                    color: widget.colors.textMuted,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              // Re-annotate button
              _isReAnnotating
                  ? const Padding(
                      padding: EdgeInsets.all(4),
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : InkWell(
                      onTap: _handleReAnnotate,
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusInline4),
                      child: Tooltip(
                        message: 'Re-annotate image',
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            SkotiqIcons.refresh,
                            size: 14,
                            color: widget.colors.textMuted,
                          ),
                        ),
                      ),
                    ),
              const SizedBox(width: 4),
              // Save annotated image button
              _isSaving
                  ? const Padding(
                      padding: EdgeInsets.all(4),
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : InkWell(
                      onTap:
                          annotation != null ? _handleSaveAnnotatedImage : null,
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusInline4),
                      child: Tooltip(
                        message: 'Save annotated image',
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            SkotiqIcons.download,
                            size: 14,
                            color: annotation != null
                                ? widget.colors.textMuted
                                : widget.colors.textMuted
                                    .withValues(alpha: 0.3),
                          ),
                        ),
                      ),
                    ),
              const SizedBox(width: 4),
              // Export menu
              PopupMenuButton<String>(
                tooltip: 'Export annotations',
                color: widget.colors.surfaceElevated,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                shape: _annotationMenuShape(widget.colors),
                enabled: displayableObjects.isNotEmpty,
                onSelected: (value) {
                  switch (value) {
                    case 'csv':
                      unawaited(_runPanelAction(
                        () => _exportCsv(displayableObjects),
                        'CSV export failed',
                      ));
                    case 'ds9':
                      unawaited(_runPanelAction(
                        () => _exportDs9(displayableObjects),
                        'DS9 export failed',
                      ));
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'csv',
                    child: Row(
                      children: [
                        Icon(LucideIcons.fileSpreadsheet,
                            size: 14, color: widget.colors.textPrimary),
                        const SizedBox(width: 8),
                        Text('Export CSV',
                            style: SkotiqTypography.caption
                                .copyWith(color: widget.colors.textPrimary)),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'ds9',
                    child: Row(
                      children: [
                        Icon(SkotiqIcons.map,
                            size: 14, color: widget.colors.textPrimary),
                        const SizedBox(width: 8),
                        Text('Export DS9 Regions',
                            style: SkotiqTypography.caption
                                .copyWith(color: widget.colors.textPrimary)),
                      ],
                    ),
                  ),
                ],
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    LucideIcons.fileOutput,
                    size: 14,
                    color: displayableObjects.isNotEmpty
                        ? widget.colors.textMuted
                        : widget.colors.textMuted.withValues(alpha: 0.3),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              // Presets menu
              PopupMenuButton<String>(
                tooltip: 'Annotation presets',
                color: widget.colors.surfaceElevated,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                shape: _annotationMenuShape(widget.colors),
                onSelected: (value) {
                  if (value == '_retry_presets') {
                    ref.invalidate(annotationPresetsProvider);
                  } else if (value == '_save_as_preset') {
                    unawaited(_saveAsPreset());
                  } else if (value.startsWith('_delete:')) {
                    unawaited(_deletePreset(value.substring(8)));
                  } else {
                    unawaited(_applyPreset(value));
                  }
                },
                itemBuilder: (context) {
                  final items = <PopupMenuEntry<String>>[];
                  for (final preset in presets) {
                    items.add(PopupMenuItem(
                      value: preset.name,
                      child: Row(
                        children: [
                          Icon(
                            preset.isBuiltIn
                                ? LucideIcons.bookmark
                                : SkotiqIcons.user,
                            size: 14,
                            color: widget.colors.textPrimary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              preset.name,
                              style: SkotiqTypography.caption
                                  .copyWith(color: widget.colors.textPrimary),
                            ),
                          ),
                          if (!preset.isBuiltIn)
                            InkWell(
                              onTap: () {
                                Navigator.of(context).pop();
                                unawaited(_deletePreset(preset.name));
                              },
                              child: Padding(
                                padding: const EdgeInsets.all(2),
                                child: Icon(
                                  SkotiqIcons.delete,
                                  size: 12,
                                  color: widget.colors.textMuted,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ));
                  }
                  if (presetsAsync.hasError) {
                    items.add(
                      PopupMenuItem(
                        enabled: false,
                        child: Text(
                          'Saved presets unavailable: ${presetsAsync.error}',
                          style: SkotiqTypography.caption
                              .copyWith(color: widget.colors.error),
                        ),
                      ),
                    );
                    items.add(
                      PopupMenuItem(
                        value: '_retry_presets',
                        child: Text(
                          'Retry saved presets',
                          style: SkotiqTypography.caption
                              .copyWith(color: widget.colors.primary),
                        ),
                      ),
                    );
                  } else if (!presetsAsync.hasValue) {
                    items.add(
                      const PopupMenuItem(
                        enabled: false,
                        child: Text('Loading saved presets…'),
                      ),
                    );
                  }
                  items.add(const PopupMenuDivider());
                  items.add(
                    PopupMenuItem(
                      value: '_save_as_preset',
                      enabled: presetsAsync.hasValue && !presetsAsync.hasError,
                      child: Row(
                        children: [
                          Icon(
                            SkotiqIcons.save,
                            size: 14,
                            color:
                                presetsAsync.hasValue && !presetsAsync.hasError
                                    ? widget.colors.primary
                                    : widget.colors.textMuted,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Save as Preset',
                            style: SkotiqTypography.caption.copyWith(
                                color: presetsAsync.hasValue &&
                                        !presetsAsync.hasError
                                    ? widget.colors.primary
                                    : widget.colors.textMuted),
                          ),
                        ],
                      ),
                    ),
                  );
                  return items;
                },
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    LucideIcons.layoutTemplate,
                    size: 14,
                    color: widget.colors.textMuted,
                  ),
                ),
              ),
            ],
          ),
        ),

        // Search bar
        AnnotationSearchBar(
          onChanged: (value) => setState(() => _searchQuery = value),
        ),

        // Filters section.
        // Wrap in a transparent Material so the ExpansionTile's internal
        // ListTile paints its background/ink on this Material rather than the
        // surrounding DecoratedBox (Flutter 3.44 asserts when a ListTile's
        // nearest ancestor with a background color is a DecoratedBox).
        Material(
          type: MaterialType.transparency,
          child: ExpansionTile(
            initiallyExpanded: _filtersExpanded,
            onExpansionChanged: (expanded) =>
                setState(() => _filtersExpanded = expanded),
            tilePadding: const EdgeInsets.symmetric(horizontal: 12),
            childrenPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            dense: true,
            title: Text(
              'Filters',
              style: SkotiqTypography.labelSm
                  .copyWith(color: widget.colors.textSecondary),
            ),
            trailing: Icon(
              _filtersExpanded
                  ? SkotiqIcons.chevronUp
                  : SkotiqIcons.chevronDown,
              size: 16,
              color: widget.colors.textMuted,
            ),
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  AnnotationQuickSettingChip(
                    label: settings.visibleTypes
                            .contains(AnnotationObjectFilter.stars)
                        ? 'Stars On'
                        : 'Stars Off',
                    isSelected: settings.visibleTypes
                        .contains(AnnotationObjectFilter.stars),
                    colors: widget.colors,
                    onTap: () {
                      unawaited(_runPanelAction(
                        () => ref
                            .read(annotationSettingsProvider.notifier)
                            .toggleObjectType(AnnotationObjectFilter.stars),
                        'Could not save annotation filters',
                      ));
                    },
                  ),
                  AnnotationQuickSettingChip(
                    label: settings.showLabels ? 'Labels On' : 'Labels Off',
                    isSelected: settings.showLabels,
                    colors: widget.colors,
                    onTap: () {
                      unawaited(_runPanelAction(
                        () => ref
                            .read(annotationSettingsProvider.notifier)
                            .setShowLabels(!settings.showLabels),
                        'Could not save label visibility',
                      ));
                    },
                  ),
                  AnnotationQuickSettingChip(
                    label: settings.showMagnitudes ? 'Mag On' : 'Mag Off',
                    isSelected: settings.showMagnitudes,
                    colors: widget.colors,
                    onTap: () {
                      unawaited(_runPanelAction(
                        () => ref
                            .read(annotationSettingsProvider.notifier)
                            .setShowMagnitudes(!settings.showMagnitudes),
                        'Could not save magnitude visibility',
                      ));
                    },
                  ),
                  AnnotationQuickSettingChip(
                    label:
                        settings.compassEnabled ? 'Compass On' : 'Compass Off',
                    isSelected: settings.compassEnabled,
                    colors: widget.colors,
                    onTap: () {
                      unawaited(_runPanelAction(
                        () => ref
                            .read(annotationSettingsProvider.notifier)
                            .setCompassEnabled(!settings.compassEnabled),
                        'Could not save compass visibility',
                      ));
                    },
                  ),
                  AnnotationQuickSettingChip(
                    label: settings.scaleBarEnabled
                        ? 'Scale Bar On'
                        : 'Scale Bar Off',
                    isSelected: settings.scaleBarEnabled,
                    colors: widget.colors,
                    onTap: () {
                      unawaited(_runPanelAction(
                        () => ref
                            .read(annotationSettingsProvider.notifier)
                            .setScaleBarEnabled(!settings.scaleBarEnabled),
                        'Could not save scale-bar visibility',
                      ));
                    },
                  ),
                  AnnotationQuickSettingChip(
                    label: settings.showSolveResiduals
                        ? 'Residuals On'
                        : 'Residuals Off',
                    isSelected: settings.showSolveResiduals,
                    colors: widget.colors,
                    onTap: () {
                      unawaited(_runPanelAction(
                        () => ref
                            .read(annotationSettingsProvider.notifier)
                            .setShowSolveResiduals(
                                !settings.showSolveResiduals),
                        'Could not save residual visibility',
                      ));
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: _filterTypes.map((type) {
                  final isSelected =
                      isTypeVisibleFromSettings(type, settings.visibleTypes);
                  final count = _countForFilterType(type, typeCounts);
                  return AnnotationFilterChip(
                    label: _getObjectTypeLabel(type),
                    count: count,
                    isSelected: isSelected,
                    colors: widget.colors,
                    onTap: () {
                      final notifier =
                          ref.read(annotationSettingsProvider.notifier);
                      final updated = Set<AnnotationObjectFilter>.from(
                          settings.visibleTypes);
                      final typeFilters = filtersForObjectType(type);
                      if (isSelected) {
                        updated.removeAll(typeFilters);
                      } else {
                        updated.addAll(typeFilters);
                      }
                      unawaited(_runPanelAction(
                        () => notifier.setObjectTypes(updated),
                        'Could not save annotation filters',
                      ));
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: SkotiqButton(
                  onPressed: () {
                    unawaited(_runPanelAction(
                      () => ref
                          .read(annotationSettingsProvider.notifier)
                          .setObjectTypes({
                        AnnotationObjectFilter.galaxies,
                        AnnotationObjectFilter.nebulae,
                        AnnotationObjectFilter.starClusters,
                        AnnotationObjectFilter.planetaryNebulae,
                      }),
                      'Could not reset annotation filters',
                    ));
                  },
                  label: 'Reset to defaults',
                  variant: ButtonVariant.ghost,
                  size: ButtonSize.small,
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),

        Divider(height: 1, color: widget.colors.border),

        // The section's status block: the ONE catalog banner, the live
        // annotation status and the re-annotate suggestion. All three used to
        // float over the frame; they belong beside the list they describe.
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: SkotiqTokens.spaceSm,
            vertical: SkotiqTokens.spaceXs,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AnnotationCatalogBanner(onSetup: () => _openCatalogSettings()),
              AnnotationStatusIndicator(colors: widget.colors),
              ReAnnotateSuggestionBanner(colors: widget.colors),
            ],
          ),
        ),

        // Objects list
        Expanded(
          child: filteredObjects.isEmpty
              ? AnnotationEmptyState(
                  colors: widget.colors,
                  annotation: annotation,
                  hasSearchQuery: _searchQuery.isNotEmpty,
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: filteredObjects.length,
                  itemBuilder: (context, index) {
                    final object = filteredObjects[index];
                    return AnnotationObjectListItem(
                      object: object,
                      colors: widget.colors,
                      onTap: () => _onObjectSelected(object),
                      isSelected: selectedObject?.id == object.id,
                    );
                  },
                ),
        ),
      ],
    );
  }

  String _getObjectTypeLabel(ObjectType type) {
    switch (type) {
      case ObjectType.galaxy:
        return 'Galaxies';
      case ObjectType.nebula:
        return 'Nebulae';
      case ObjectType.starCluster:
        return 'Clusters';
      case ObjectType.planetaryNebula:
        return 'PN';
      case ObjectType.star:
        return 'Stars';
      case ObjectType.doubleStar:
        return 'Stars';
      case ObjectType.asterism:
        return 'Asterisms';
      case ObjectType.unknown:
        return 'Other';
    }
  }

  int _countForFilterType(ObjectType type, Map<ObjectType, int> typeCounts) {
    if (type == ObjectType.star) {
      return (typeCounts[ObjectType.star] ?? 0) +
          (typeCounts[ObjectType.doubleStar] ?? 0);
    }
    if (type == ObjectType.unknown) {
      return (typeCounts[ObjectType.unknown] ?? 0) +
          (typeCounts[ObjectType.asterism] ?? 0);
    }
    return typeCounts[type] ?? 0;
  }
}

/// Floating chip row showing the brightest annotated objects on the image.
/// Always visible regardless of annotation fade settings.
/// Tapping a chip selects that object in the annotation panel.
