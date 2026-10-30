part of '../annotation_panel.dart';

class AnnotationMiniChips extends ConsumerWidget {
  final SkotiqColors colors;

  const AnnotationMiniChips({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final annotation = ref.watch(currentAnnotationProvider);
    final settings = ref.watch(annotationSettingsProvider).valueOrNull;

    if (annotation == null || settings == null || !settings.enabled) {
      return const SizedBox.shrink();
    }

    // Get visible objects, sorted by brightness (lowest magnitude = brightest)
    final visibleObjects = annotation.objects.where((obj) {
      if (!obj.visible) return false;
      if (!isTypeVisibleFromSettings(obj.type, settings.visibleTypes)) {
        return false;
      }
      if (obj.magnitude != null) {
        if (obj.magnitude! > settings.magnitudeCutoff) return false;
        if (obj.magnitude! < settings.minMagnitude) return false;
      }
      // Skip stars for the chip row - they're too numerous and not interesting
      if (obj.type == ObjectType.star || obj.type == ObjectType.doubleStar) {
        return false;
      }
      return true;
    }).toList()
      ..sort((a, b) {
        final aMag = a.magnitude ?? 99.0;
        final bMag = b.magnitude ?? 99.0;
        return aMag.compareTo(bMag);
      });

    // Take the 5 brightest non-star objects
    final topObjects = visibleObjects.take(5).toList();
    if (topObjects.isEmpty) return const SizedBox.shrink();

    return IgnorePointer(
      ignoring: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          children: topObjects.map((obj) {
            return GestureDetector(
              onTap: () {
                ref.read(selectedAnnotationObjectProvider.notifier).state = obj;
                // Switch to the annotations tab when a chip is tapped
                ref.read(selectedImagingPanelProvider.notifier).state =
                    ImagingSidePanel.annotationsSectionIndex;
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  // absolute: chip overlay scrim over the live image canvas
                  color: ImageOverlayColors.shadow.withValues(alpha: 0.6),
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline8),
                  border: Border.all(
                    // absolute: chip border over the live image canvas
                    color: ImageOverlayColors.foreground.withValues(alpha: 0.2),
                  ),
                ),
                child: Text(
                  obj.commonName ?? obj.name,
                  style: SkotiqTypography.caption.copyWith(
                      fontWeight: FontWeight
                          .w500, // absolute: chip label over the live image canvas
                      color: ImageOverlayColors.foreground),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
