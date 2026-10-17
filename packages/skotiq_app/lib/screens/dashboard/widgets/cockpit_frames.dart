import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../imaging/widgets/image_display.dart';
import 'cockpit_recent_frames.dart';

/// Merged "Frames" cockpit tile — the current sub-exposure on top of the
/// recent-frames strip, in a single self-chromed card.
///
/// Replaces the standalone `RunDashboardLiveFrame` (a tall 4:3 box) plus the
/// separate `CockpitRecentFrames` strip, which were redundant: a big "waiting
/// for first frame" panel sitting directly above a thumbnail strip. This
/// consolidation caps the current-frame image at [_frameMaxHeight] (NOT 4:3)
/// and, before any frame exists, collapses to a slim one-line "waiting" row so
/// idle never wastes vertical space.
///
/// - Current frame: `currentImageProvider` + `ImageDisplayWidget`, height-
///   capped, with the filter/exposure badge overlay.
/// - Below: the shared [RecentFramesStrip] (reuses the backend-thumbnail path).
class CockpitFrames extends ConsumerWidget {
  const CockpitFrames({super.key});

  /// Cap for the current-frame image. Deliberately short (a 16:9-ish band, not
  /// a full 4:3 hero) — the whole point of the density pass is fit-without-
  /// scroll, and the recent strip carries the per-frame history below.
  static const double _frameMaxHeight = 200.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final currentImage = ref.watch(currentImageProvider);
    final sessionImages = ref.watch(recentSessionFramesProvider);

    // The live frame's own settings can carry a null filter (the preview is
    // published before the persisted history row is written); fall back to the
    // newest history entry that has one. A genuinely absent filter (mono cam,
    // no wheel) resolves to null and the badge drops the filter chip entirely
    // rather than printing a misleading "no filter".
    final resolvedFilter =
        _resolveFilter(currentImage?.settings.filter, sessionImages);

    return SkotiqPanel(
        padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (currentImage != null)
              _CurrentFrame(
                colors: colors,
                image: currentImage,
                filterLabel: resolvedFilter,
              )
            else
              _WaitingRow(colors: colors),
            const SizedBox(height: SkotiqTokens.spaceSm),
            const RecentFramesStrip(),
          ],
        ));
  }

  static String? _resolveFilter(
    String? currentFilter,
    List<CapturedImage> history,
  ) {
    if (currentFilter != null && currentFilter.isNotEmpty) {
      return currentFilter;
    }
    for (final image in history.reversed) {
      final filter = image.settings.filter;
      if (filter != null && filter.isNotEmpty) {
        return filter;
      }
    }
    return null;
  }
}

/// Height-capped current-frame view with the filter/exposure badge overlay.
class _CurrentFrame extends StatelessWidget {
  final SkotiqColors colors;
  final CapturedImageData image;
  final String? filterLabel;

  const _CurrentFrame({
    required this.colors,
    required this.image,
    required this.filterLabel,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints:
          const BoxConstraints(maxHeight: CockpitFrames._frameMaxHeight),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        child: Stack(
          children: [
            Container(color: colors.background),
            Positioned.fill(
              child: ImageDisplayWidget(
                imageData: image,
                zoomLevel: 1.0,
                panOffset: Offset.zero,
              ),
            ),
            Positioned(
              right: 8,
              top: 8,
              child: _FrameBadge(
                colors: colors,
                filterLabel: filterLabel,
                exposure: image.settings.exposureTime,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Slim one-line "waiting for first frame" row shown before any frame exists.
class _WaitingRow extends StatelessWidget {
  final SkotiqColors colors;

  const _WaitingRow({required this.colors});

  @override
  Widget build(BuildContext context) {
    return SkotiqPanel(
        padding: const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.spaceMd,
          vertical: SkotiqTokens.spaceSm,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.image, size: 14, color: colors.textMuted),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Text(
              'Waiting for first frame…',
              style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
            ),
          ],
        ));
  }
}

class _FrameBadge extends StatelessWidget {
  final SkotiqColors colors;
  final String? filterLabel;
  final double exposure;

  const _FrameBadge({
    required this.colors,
    required this.filterLabel,
    required this.exposure,
  });

  @override
  Widget build(BuildContext context) {
    final filter = filterLabel;
    final hasFilter = filter != null && filter.isNotEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Only show the filter chip when we actually have a filter — a mono
          // camera with no wheel shouldn't display a "no filter" pseudo-value.
          if (hasFilter) ...[
            Icon(LucideIcons.filter, size: 10, color: colors.textMuted),
            const SizedBox(width: 4),
            Text(
              filter,
              style: SkotiqTypography.withTabular(
                SkotiqTypography.captionSm.copyWith(
                  fontWeight: FontWeight.w600,
                  color: colors.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Container(width: 1, height: 10, color: colors.border),
            const SizedBox(width: 8),
          ],
          Text(
            '${exposure.toStringAsFixed(exposure >= 10 ? 0 : 1)}s',
            style: SkotiqTypography.withTabular(
              SkotiqTypography.captionSm.copyWith(
                fontWeight: FontWeight.w600,
                color: colors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
