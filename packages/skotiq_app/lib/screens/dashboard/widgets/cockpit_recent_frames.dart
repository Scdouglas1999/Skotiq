import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart' hide ConnectionState;
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../utils/filter_label.dart';
import '../../../widgets/frame_thumbnail_loader.dart';

/// Reusable horizontal strip of the most recent captures from the active
/// session.
///
/// Source: [recentSessionFramesProvider] (`List<CapturedImage>`, oldest-first
/// as the session appends; remote-aware so a slave sees the master's frames).
/// We take the last [_maxFrames] and reverse them so the
/// newest capture leads the strip. Each cell renders a small thumbnail plus
/// filter / exposure / time, mirroring the efficient rendering used by the
/// sequencer's `ExposureNodeThumbnailStrip`: thumbnails are fetched on demand
/// via `ImagingBackend.getImageThumbnail` (a pre-rendered ~512px JPEG) rather
/// than re-decoding the full FITS per cell. A local-file fallback covers
/// ad-hoc captures whose backend thumbnail is a Flutter-decodable image.
///
/// When the session has no frames yet, the strip shows a compact empty hint so
/// the surface still reads as "recent frames will land here" instead of
/// collapsing to nothing.
///
/// This is the shared rendering used by both the opt-in [CockpitRecentFrames]
/// tile and the merged `CockpitFrames` tile, so the thumbnail-loading logic
/// lives in exactly one place.
class RecentFramesStrip extends ConsumerWidget {
  const RecentFramesStrip({super.key});

  /// Newest N frames shown in the strip. Older frames are summarised by a
  /// trailing "+N" badge so a long night never grows the surface unbounded.
  static const int _maxFrames = 8;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final images = ref.watch(recentSessionFramesProvider);

    // recentSessionFramesProvider yields capture order, so the newest frame is
    // last. Take the tail (newest [_maxFrames]) and reverse to newest-first.
    final total = images.length;
    final tail =
        total > _maxFrames ? images.sublist(total - _maxFrames) : images;
    final newestFirst = tail.reversed.toList(growable: false);
    final hiddenCount = total - newestFirst.length;

    if (newestFirst.isEmpty) {
      return _EmptyHint(colors: colors);
    }
    return _FramesRow(
      frames: newestFirst,
      hiddenCount: hiddenCount,
      colors: colors,
    );
  }
}

/// Recent-frames cockpit tile — a glanceable horizontal strip of the most
/// recent captures from the active session, with a labelled header.
///
/// Opt-in tile retained for power users. The strip rendering itself lives in
/// [RecentFramesStrip] so the merged `CockpitFrames` tile and this card share
/// one implementation.
class CockpitRecentFrames extends ConsumerWidget {
  const CockpitRecentFrames({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final total = ref.watch(recentSessionFramesProvider).length;

    return SkotiqPanel(
        child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(LucideIcons.galleryThumbnails,
                size: 14, color: colors.textMuted),
            const SizedBox(width: 8),
            Text(
              'Recent Frames',
              style: SkotiqTypography.eyebrow
                  .copyWith(color: colors.textSecondary),
            ),
            const Spacer(),
            if (total > 0)
              Text(
                total == 1 ? '1 frame' : '$total frames',
                style: SkotiqTypography.withTabular(
                  SkotiqTypography.caption.copyWith(color: colors.textMuted),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        const RecentFramesStrip(),
      ],
    ));
  }
}

class _EmptyHint extends StatelessWidget {
  final SkotiqColors colors;

  const _EmptyHint({required this.colors});

  @override
  Widget build(BuildContext context) {
    return SkotiqPanel(
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.imageOff, size: 20, color: colors.textMuted),
            const SizedBox(height: 6),
            Text(
              'No frames captured this session yet',
              style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
            ),
          ],
        ));
  }
}

class _FramesRow extends StatelessWidget {
  final List<CapturedImage> frames;
  final int hiddenCount;
  final SkotiqColors colors;

  /// Thumbnail edge in logical pixels. Matches the compact end of the
  /// sequencer strip so the two surfaces feel consistent.
  static const double _tilePx = 72.0;

  /// Height reserved below the thumbnail for the filter + exposure + time
  /// caption rows.
  static const double _captionHeight = 34.0;

  const _FramesRow({
    required this.frames,
    required this.hiddenCount,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    // The caption under each tile is text, so its height follows the app's
    // font-size / UI-scale setting (both land on MediaQuery.textScaler). A
    // hard-coded 34 px made every tile overflow its row by 2 px as soon as the
    // user picked "Large" in Appearance settings.
    final captionHeight =
        MediaQuery.textScalerOf(context).scale(_captionHeight);
    return SizedBox(
      height: _tilePx + captionHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: frames.length + (hiddenCount > 0 ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          if (hiddenCount > 0 && index == frames.length) {
            return _MoreBadge(
              count: hiddenCount,
              colors: colors,
              tilePx: _tilePx,
            );
          }
          return _FrameTile(
            image: frames[index],
            tilePx: _tilePx,
            colors: colors,
          );
        },
      ),
    );
  }
}

class _MoreBadge extends StatelessWidget {
  final int count;
  final SkotiqColors colors;
  final double tilePx;

  const _MoreBadge({
    required this.count,
    required this.colors,
    required this.tilePx,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '$count earlier frames not shown',
      child: Container(
        width: tilePx,
        height: tilePx,
        decoration: BoxDecoration(
          color: colors.surfaceAlt,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
          border: Border.all(color: colors.border),
        ),
        alignment: Alignment.center,
        child: Text(
          '+$count',
          style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
        ),
      ),
    );
  }
}

class _FrameTile extends ConsumerStatefulWidget {
  final CapturedImage image;
  final double tilePx;
  final SkotiqColors colors;

  const _FrameTile({
    required this.image,
    required this.tilePx,
    required this.colors,
  });

  @override
  ConsumerState<_FrameTile> createState() => _FrameTileState();
}

class _FrameTileState extends ConsumerState<_FrameTile> {
  Future<Uint8List?>? _bytesFuture;

  @override
  void initState() {
    super.initState();
    _bytesFuture = _loadBytes();
  }

  @override
  void didUpdateWidget(covariant _FrameTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image.id != widget.image.id ||
        oldWidget.image.filePath != widget.image.filePath) {
      _bytesFuture = _loadBytes();
    }
  }

  Future<Uint8List?> _loadBytes() async {
    final imageId = int.tryParse(widget.image.id);
    if (imageId == null) return null;
    return fetchFrameThumbnailBytes(ref, imageId, source: 'RecentFramesStrip');
  }

  String _filterLabel() => filterLabel(widget.image.settings.filter);

  String _exposureLabel() {
    final secs = widget.image.settings.exposureTime;
    if (secs >= 1) return '${secs.toStringAsFixed(0)}s';
    return '${secs.toStringAsFixed(1)}s';
  }

  String _timeLabel() {
    final t = widget.image.capturedAt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final px = widget.tilePx;
    return Tooltip(
      message: '${_fileName(widget.image.filePath)}\n'
          '${_filterLabel()} · ${_exposureLabel()} · ${_timeLabel()}',
      waitDuration: const Duration(milliseconds: 350),
      child: SizedBox(
        width: px,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: px,
              height: px,
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                border: Border.all(
                  color: colors.border,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: FrameThumbnail(
                iconSize: 18,
                bytesFuture: _bytesFuture,
                fallbackFilePath: widget.image.filePath,
                colors: colors,
              ),
            ),
            const SizedBox(height: 3),
            Row(
              children: [
                Text(
                  _filterLabel(),
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textSecondary),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _exposureLabel(),
                    style: SkotiqTypography.withTabular(
                      SkotiqTypography.caption
                          .copyWith(color: colors.textMuted),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
            Text(
              _timeLabel(),
              style: SkotiqTypography.withTabular(
                SkotiqTypography.caption.copyWith(color: colors.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _fileName(String path) {
    if (path.isEmpty) return widget.image.targetName ?? 'Captured frame';
    return path.split(RegExp(r'[/\\]')).last;
  }
}
