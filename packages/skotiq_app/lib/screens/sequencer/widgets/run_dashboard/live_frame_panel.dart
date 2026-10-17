import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart' hide ConnectionState;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../imaging/widgets/image_display.dart';
import '../../../../utils/filter_label.dart';
import '../../../../widgets/frame_thumbnail_loader.dart';
import 'hfr_sparkline.dart';

part 'live_frame_panel_parts/_viewer.dart';
part 'live_frame_panel_parts/_badges.dart';
part 'live_frame_panel_parts/_history.dart';
part 'live_frame_panel_parts/_inspect_dialog.dart';

/// Live-frame tile for the Run dashboard.
///
/// Layout: the current sub-exposure fills the main area on the left, with a
/// vertical, scrollable column of recent-capture thumbnails pinned to the
/// right. This keeps the main image near-square while still surfacing the
/// session's frame history at a glance.
///
/// Interaction model (see [_LiveFrameViewer]):
/// - Zoom is driven by on-image **buttons** (in / out / fit) and by **pinch**
///   on touch; `constrained: true` clamps the scaled child to the viewport so
///   it can never be flung off-canvas, and the readout/buttons stay in sync
///   via `onInteractionUpdate`.
/// - Pan is drag, clamped so the frame can never be dragged fully off-canvas;
///   "fit" recentres and rescales to fill.
///
/// Reuses [ImageDisplayWidget] (the Imaging screen's decoder) so stretch /
/// decode logic is never reimplemented here.
class RunDashboardLiveFrame extends ConsumerWidget {
  const RunDashboardLiveFrame({super.key});

  /// Below this width the history column is dropped (the standalone "Recent
  /// Frames" tile still carries it) so the main image keeps a usable area on a
  /// narrow, user-resized panel.
  static const double _historyBreakpoint = 320.0;

  /// Fixed width of the vertical history column when shown.
  static const double _historyColumnWidth = 96.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final currentImage = ref.watch(currentImageProvider);
    final sessionImages = ref.watch(recentSessionFramesProvider);

    // The current frame's own settings can carry a null filter (the live
    // preview is published before the persisted history row is written); fall
    // back to the newest history entry, which is the same source the column
    // renders from, so the badge shows "L" instead of "no filter".
    final resolvedFilter =
        _resolveFilter(currentImage?.settings.filter, sessionImages);

    return SkotiqCard(
      padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final showHistory = constraints.maxWidth >= _historyBreakpoint &&
              sessionImages.isNotEmpty;

          final main = _FramePane(
            colors: colors,
            image: currentImage,
            filterLabel: resolvedFilter,
            hfrHistory: _hfrHistory(sessionImages),
          );

          // The dashboard lays its tiles out in a vertical scroll view, so this
          // widget is built with an UNBOUNDED height. Nothing below supplies one:
          // `Row(crossAxisAlignment: stretch)` hands `constraints.maxHeight`
          // straight to its children as a tight height, and [_FramePane] is a
          // Stack whose children are all `Positioned.fill`, so it takes whatever
          // it is given. The infinity reached InteractiveViewer's transform, the
          // engine logged "TransformLayer is constructed with an invalid matrix"
          // and dropped the layer subtree — which blanked not just this tile but
          // the whole primary column it shared. Bound the box here so every
          // descendant is finite; honour a real bound when the parent gives one.
          final Widget body = !showHistory
              ? main
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: main),
                    const SizedBox(width: SkotiqTokens.spaceSm),
                    SizedBox(
                      width: _historyColumnWidth,
                      child: _HistoryColumn(
                        colors: colors,
                        images: sessionImages,
                        currentImage: currentImage,
                      ),
                    ),
                  ],
                );

          if (constraints.hasBoundedHeight) {
            return body;
          }
          return SizedBox(
            height: _unboundedHeightFor(constraints.maxWidth),
            child: body,
          );
        },
      ),
    );
  }

  /// Height to adopt when the parent imposes none (a dashboard scroll zone).
  ///
  /// A 4:3 box is what this panel documents itself as; the clamp keeps it
  /// readable on a narrow tile and stops it eating the whole viewport on a
  /// wide one.
  static double _unboundedHeightFor(double maxWidth) {
    if (!maxWidth.isFinite) return 320;
    return (maxWidth * 3 / 4).clamp(180.0, 420.0);
  }

  /// Recent per-frame HFR values (oldest→newest) for the inline sparkline.
  /// Pulls from the same session history the column renders from; frames
  /// without a measured HFR are skipped so the trend reflects only real
  /// measurements. Capped to keep the sparkline readable.
  static List<double> _hfrHistory(List<CapturedImage> history) {
    const maxPoints = 40;
    final values = <double>[];
    for (final image in history) {
      final hfr = image.stats?.hfr;
      if (hfr != null && hfr > 0) values.add(hfr);
    }
    if (values.length > maxPoints) {
      return values.sublist(values.length - maxPoints);
    }
    return values;
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

/// The main image pane: the interactive viewer (or an empty-state) plus the
/// metadata badge overlay.
class _FramePane extends StatelessWidget {
  final SkotiqColors colors;
  final CapturedImageData? image;
  final String? filterLabel;
  final List<double> hfrHistory;

  const _FramePane({
    required this.colors,
    required this.image,
    required this.filterLabel,
    required this.hfrHistory,
  });

  @override
  Widget build(BuildContext context) {
    final img = image;
    return ClipRRect(
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
      child: Stack(
        children: [
          Positioned.fill(child: Container(color: colors.background)),
          if (img != null)
            Positioned.fill(
              child: _LiveFrameViewer(image: img, colors: colors),
            )
          else
            Positioned.fill(child: _WaitingState(colors: colors)),
          if (img != null)
            Positioned(
              right: 8,
              top: 8,
              child: _FrameBadge(
                colors: colors,
                filterLabel: filterLabel,
                exposure: img.settings.exposureTime,
                stats: img.stats,
                hfrHistory: hfrHistory,
              ),
            ),
        ],
      ),
    );
  }
}

class _WaitingState extends StatelessWidget {
  final SkotiqColors colors;

  const _WaitingState({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.image, size: 36, color: colors.textMuted),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Text(
            'Waiting for first frame…',
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize12, color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}
