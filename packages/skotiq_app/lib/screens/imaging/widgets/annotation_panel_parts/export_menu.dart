part of '../annotation_panel.dart';

/// Writes [content] to a destination the operator picks for [format] and
/// returns the path, or null when they cancel.
typedef AnnotationExportSaver = Future<String?> Function(
  AnnotationExportFormat format,
  String suggestedName,
  String content,
);

/// Override point that keeps the native save dialog and the disk write out of
/// widget tests.
final annotationExportSaverProvider = Provider<AnnotationExportSaver>((ref) {
  return (format, suggestedName, content) async {
    final target = await chooseExportTarget(
      suggestedName: suggestedName,
      acceptedTypeGroups: [
        XTypeGroup(
          label: format.fileTypeLabel,
          extensions: [format.extension],
        ),
      ],
    );
    if (target == null) return null;
    await File(target.path).writeAsString(content, flush: true);
    return target.path;
  };
});

/// Why the frame's objects cannot be exported, or null when they can.
String? annotationExportBlocker(
  ImageAnnotation? annotation,
  List<CelestialObjectAnnotation> exportable,
) {
  if (annotation == null) {
    return 'Nothing to export until a frame is plate-solved and annotated';
  }
  if (!annotation.objects.any((object) => object.visible)) {
    return 'Nothing to export: no catalog objects lie in this frame';
  }
  if (exportable.isEmpty) {
    return 'Nothing to export: the filters hide every object';
  }
  return null;
}

/// The annotation panel's Export menu: the objects the panel lists, as CSV or
/// as DS9 regions.
class _AnnotationExportMenu extends ConsumerStatefulWidget {
  const _AnnotationExportMenu({
    required this.colors,
    required this.annotation,
    required this.objects,
  });

  final SkotiqColors colors;
  final ImageAnnotation? annotation;

  /// The objects that pass the panel's display filters.
  final List<CelestialObjectAnnotation> objects;

  @override
  ConsumerState<_AnnotationExportMenu> createState() =>
      _AnnotationExportMenuState();
}

class _AnnotationExportMenuState extends ConsumerState<_AnnotationExportMenu> {
  bool _exporting = false;

  Future<void> _export(AnnotationExportFormat format) async {
    if (_exporting) return;
    setState(() => _exporting = true);
    final timestamp = ClockFormat.fileStamp(DateTime.now());
    try {
      final path = await ref.read(annotationExportSaverProvider)(
        format,
        'annotations_$timestamp.${format.extension}',
        format.render(widget.objects),
      );
      if (path == null || !mounted) return;
      await revealExportedFile(
        context,
        path,
        subject: format.subject,
        desktopMessage: '${format.subject} saved to $path',
        desktopDuration: const Duration(seconds: 4),
      );
    } catch (error) {
      if (!mounted) return;
      context.showErrorSnackBar(
        'Could not save the ${format.subject}: ${userFacingError(error)}',
        duration: const Duration(seconds: 4),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    if (_exporting) {
      return Padding(
        padding: const EdgeInsets.all(SkotiqTokens.spaceXs),
        child: SkotiqSpinner(size: 14, color: colors.primary),
      );
    }
    final blocker = annotationExportBlocker(widget.annotation, widget.objects);
    return PopupMenuButton<AnnotationExportFormat>(
      tooltip: blocker ?? 'Export annotations',
      color: colors.surfaceElevated,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: _annotationMenuShape(colors),
      enabled: blocker == null,
      onSelected: (format) => unawaited(_export(format)),
      itemBuilder: (context) => [
        for (final format in AnnotationExportFormat.values)
          PopupMenuItem(
            value: format,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  switch (format) {
                    AnnotationExportFormat.csv => LucideIcons.fileSpreadsheet,
                    AnnotationExportFormat.ds9Region => SkotiqIcons.map,
                  },
                  size: 14,
                  color: colors.textPrimary,
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Text(
                  format.menuLabel,
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textPrimary),
                ),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(SkotiqTokens.spaceXs),
        child: Icon(
          LucideIcons.fileOutput,
          size: 14,
          color: blocker == null
              ? colors.textMuted
              : colors.textMuted.withValues(alpha: 0.3),
        ),
      ),
    );
  }
}
