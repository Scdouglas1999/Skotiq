part of '../annotation_panel.dart';

typedef AnnotationPngSavePicker = Future<String?> Function(
  String suggestedName,
);

typedef AnnotationPngWriter = Future<void> Function(
  String path,
  Uint8List bytes,
);

/// Override points keep native dialogs and disk writes deterministic in tests.
///
/// The destination comes from [chooseExportTarget], not `getSaveLocation`:
/// Android/iOS have no save dialog (`getSavePath` throws UnimplementedError),
/// so saving an annotated image was dead on a phone. On touch platforms the
/// returned path is inside the app sandbox and callers finish with
/// [revealExportedFile].
final annotationPngSavePickerProvider =
    Provider<AnnotationPngSavePicker>((ref) {
  return (suggestedName) async {
    final target = await chooseExportTarget(
      suggestedName: suggestedName,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PNG images', extensions: ['png']),
      ],
    );
    return target?.path;
  };
});

final annotationPngWriterProvider = Provider<AnnotationPngWriter>((ref) {
  return (path, bytes) => File(path).writeAsBytes(bytes);
});

String annotationPngSuggestedName({
  required String? sourcePath,
  required DateTime capturedAt,
}) {
  if (sourcePath == null || sourcePath.trim().isEmpty) {
    final timestamp = DateFormat('yyyyMMdd_HHmmss').format(capturedAt);
    return 'capture_${timestamp}_annotated.png';
  }

  // A remote imaging host may use a different path separator than this
  // client. Normalize both forms before deriving the local suggested name.
  final fileName = p.posix.basename(sourcePath.replaceAll('\\', '/'));
  final lowerName = fileName.toLowerCase();
  const compressedFitsExtensions = ['.fits.fz', '.fit.fz', '.fts.fz'];
  for (final extension in compressedFitsExtensions) {
    if (lowerName.endsWith(extension)) {
      return '${fileName.substring(0, fileName.length - extension.length)}_annotated.png';
    }
  }
  return '${p.posix.basenameWithoutExtension(fileName)}_annotated.png';
}

Future<void> renderAnnotatedImagePng({
  required Uint8List rgbaBytes,
  required int width,
  required int height,
  required ImageAnnotation annotation,
  required AnnotationSettings settings,
  required AnnotationMarkerStyle markerStyle,
  required String outputPath,
  required AnnotationPngWriter writeBytes,
}) async {
  ui.Image? baseImage;
  ui.PictureRecorder? recorder;
  ui.Picture? picture;
  ui.Image? compositeImage;

  try {
    baseImage = await _rgbaBufferToImage(rgbaBytes, width, height);
    recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImage(baseImage, Offset.zero, Paint());

    EnhancedAnnotationPainter(
      annotation: annotation,
      settings: settings,
      markerStyle: markerStyle,
      zoomLevel: 1.0,
      imageOffset: Offset.zero,
    ).paint(canvas, Size(width.toDouble(), height.toDouble()));

    picture = recorder.endRecording();
    compositeImage = await picture.toImage(width, height);
    final pngData =
        await compositeImage.toByteData(format: ui.ImageByteFormat.png);
    if (pngData == null) {
      throw StateError('Failed to encode annotated image as PNG');
    }

    await writeBytes(outputPath, pngData.buffer.asUint8List());
  } finally {
    compositeImage?.dispose();
    picture?.dispose();
    if (recorder?.isRecording ?? false) {
      recorder!.endRecording().dispose();
    }
    baseImage?.dispose();
  }
}

Future<ui.Image> _rgbaBufferToImage(
  Uint8List rgbaBytes,
  int width,
  int height,
) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgbaBytes,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

class AnnotationObjectsPanel extends ConsumerStatefulWidget {
  final NightshadeColors colors;
  final void Function(CelestialObjectAnnotation object) onObjectSelected;
  final String? selectedObjectId;

  const AnnotationObjectsPanel({
    super.key,
    required this.colors,
    required this.onObjectSelected,
    this.selectedObjectId,
  });

  @override
  ConsumerState<AnnotationObjectsPanel> createState() =>
      _AnnotationObjectsPanelState();
}

class _AnnotationObjectsPanelState
    extends ConsumerState<AnnotationObjectsPanel> {
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
          backgroundColor: NightshadeColors.of(context).error,
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
            backgroundColor: NightshadeColors.of(context).error,
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
            backgroundColor: NightshadeColors.of(context).error,
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
      await revealExportedFile(
        context,
        path,
        subject: 'Annotation CSV',
        desktopMessage: 'Annotations exported to $path',
        desktopDuration: const Duration(seconds: 4),
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
      await revealExportedFile(
        context,
        path,
        subject: 'DS9 region file',
        desktopMessage: 'DS9 regions exported to $path',
        desktopDuration: const Duration(seconds: 4),
      );
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
    final objects = annotation?.objects ?? [];

    final typeCounts = <ObjectType, int>{};
    for (final obj in objects) {
      typeCounts[obj.type] = (typeCounts[obj.type] ?? 0) + 1;
    }

    // Apply visibility rules consistent with overlay rendering.
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

    // Apply search filter on top of display filters.
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final panelWidth = Responsive.previewOverlayMaxWidth(
          constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width,
          maxAbsolute: 320,
        );
        return SizedBox(
          width: panelWidth,
          child: _buildPanelContent(
            annotation,
            filteredObjects,
            displayableObjects,
            settings,
            typeCounts,
          ),
        );
      },
    );
  }

  Widget _buildPanelContent(
    ImageAnnotation? annotation,
    List<CelestialObjectAnnotation> filteredObjects,
    List<CelestialObjectAnnotation> displayableObjects,
    AnnotationSettings settings,
    Map<ObjectType, int> typeCounts,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: widget.colors.surface,
        border: Border(
          left: BorderSide(color: widget.colors.border),
        ),
      ),
      child: Column(
        children: [
          // Header
          _buildHeader(annotation, filteredObjects, displayableObjects),

          // Search bar
          AnnotationSearchBar(
            onChanged: (value) => setState(() => _searchQuery = value),
          ),

          // Filters section
          _buildFiltersSection(settings, typeCounts),

          Divider(height: 1, color: widget.colors.border),

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
                        onTap: () => widget.onObjectSelected(object),
                        isSelected: widget.selectedObjectId == object.id,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(
    ImageAnnotation? annotation,
    List<CelestialObjectAnnotation> filteredObjects,
    List<CelestialObjectAnnotation> displayableObjects,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: widget.colors.surfaceAlt,
        border: Border(
          bottom: BorderSide(color: widget.colors.border),
        ),
      ),
      child: Row(
        children: [
          Icon(
            LucideIcons.sparkle,
            size: 16,
            color: widget.colors.primary,
          ),
          const SizedBox(width: 8),
          Text(
            'Detected Objects',
            style: NightshadeTypography.labelStrong
                .copyWith(color: widget.colors.textPrimary),
          ),
          const Spacer(),
          // Object count badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: NightshadeDecorations.tintedBadge(
              widget.colors.primary,
              borderRadius: BorderRadius.circular(NightshadeTokens.radiusLg),
            ),
            child: Text(
              '${filteredObjects.length}/${displayableObjects.length}',
              style: NightshadeTypography.labelStrongSm
                  .copyWith(color: widget.colors.primary),
            ),
          ),
          const SizedBox(width: 8),
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
                  style: NightshadeTypography.caption
                      .copyWith(color: widget.colors.textPrimary),
                ),
              ),
              PopupMenuItem(
                value: AnnotationPanelSortMode.name,
                child: Text(
                  'Sort: Name',
                  style: NightshadeTypography.caption
                      .copyWith(color: widget.colors.textPrimary),
                ),
              ),
              PopupMenuItem(
                value: AnnotationPanelSortMode.type,
                child: Text(
                  'Sort: Type',
                  style: NightshadeTypography.caption
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
                      BorderRadius.circular(NightshadeTokens.radiusInline4),
                  child: Tooltip(
                    message: 'Re-annotate image',
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        NightshadeIcons.refresh,
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
                  onTap: annotation != null ? _handleSaveAnnotatedImage : null,
                  borderRadius:
                      BorderRadius.circular(NightshadeTokens.radiusInline4),
                  child: Tooltip(
                    message: 'Save annotated image',
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        NightshadeIcons.download,
                        size: 14,
                        color: annotation != null
                            ? widget.colors.textMuted
                            : widget.colors.textMuted.withValues(alpha: 0.3),
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
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.fileSpreadsheet,
                        size: 14, color: widget.colors.textPrimary),
                    const SizedBox(width: 8),
                    Text('Export CSV',
                        style: NightshadeTypography.caption
                            .copyWith(color: widget.colors.textPrimary)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'ds9',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(NightshadeIcons.map,
                        size: 14, color: widget.colors.textPrimary),
                    const SizedBox(width: 8),
                    Text('Export DS9 Regions',
                        style: NightshadeTypography.caption
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
          // Close button
          InkWell(
            onTap: () =>
                ref.read(annotationPanelVisibleProvider.notifier).state = false,
            borderRadius: BorderRadius.circular(NightshadeTokens.radiusInline4),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                NightshadeIcons.close,
                size: 16,
                color: widget.colors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFiltersSection(
    AnnotationSettings settings,
    Map<ObjectType, int> typeCounts,
  ) {
    // Wrap in a transparent Material so the ExpansionTile's internal ListTile
    // paints its background/ink on this Material rather than the surrounding
    // DecoratedBox (Flutter 3.44 asserts when a ListTile's nearest ancestor
    // with a background color is a DecoratedBox instead of a Material).
    return Material(
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
          style: NightshadeTypography.labelSm
              .copyWith(color: widget.colors.textSecondary),
        ),
        trailing: Icon(
          _filtersExpanded
              ? NightshadeIcons.chevronUp
              : NightshadeIcons.chevronDown,
          size: 16,
          color: widget.colors.textMuted,
        ),
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              AnnotationQuickSettingChip(
                label:
                    settings.visibleTypes.contains(AnnotationObjectFilter.stars)
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
                label: settings.compassEnabled ? 'Compass On' : 'Compass Off',
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
                label:
                    settings.scaleBarEnabled ? 'Scale Bar On' : 'Scale Bar Off',
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
                  final updated =
                      Set<AnnotationObjectFilter>.from(settings.visibleTypes);
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
            child: NightshadeButton(
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

/// Annotation panel adapted for use as a tab in the imaging panel tabs.
/// Contains object list, filters, search, re-annotate and save buttons.
