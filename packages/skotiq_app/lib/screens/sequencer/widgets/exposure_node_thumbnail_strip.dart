import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show ProducingNodeThumbnail, exposureNodeThumbnailsProvider;
import 'package:skotiq_ui/skotiq_ui.dart';

import 'thumbnail_strip_prefs.dart';
import '../../../utils/filter_label.dart';
import '../../../widgets/frame_thumbnail_loader.dart';

/// Inline frame strip rendered beneath each
/// ExposureNode in the sequence tree.
///
/// Each tile is a square (size driven by [ThumbnailStripPrefs]) with a
/// coloured border encoding the runtime grade verdict:
///   * green  — accepted (grader passed all thresholds)
///   * yellow — borderline (HFR above the running baseline but still inside
///              the reject threshold — surfaced via `runtimeGrade='pending'`
///              or via the FrameQuality advisor's "needsReview" level)
///   * red    — rejected (`isAccepted=false` or runtime grade == reject)
///   * grey   — ungraded / pending
///
/// Hover (desktop) or long-press (mobile) surfaces an HFR / eccentricity
/// / exposure / filter / timestamp tooltip. Tap opens the full image in a
/// modal viewer using the existing `backend.getImageThumbnail` thumbnail
/// preview followed by a "Open in viewer" affordance.
///
/// The strip lazy-loads thumbnails: only the actual JPEG/PNG bytes are
/// fetched on demand (via `backend.getImageThumbnail` — same path as the
/// analytics strip), keeping tree-render cost flat regardless of the
/// number of attached frames. Pagination kicks in past 10 tiles via a
/// horizontal scroll plus a trailing "+N more" badge.
class ExposureNodeThumbnailStrip extends ConsumerWidget {
  final String nodeId;

  /// Optional override — when the consumer has already obtained
  /// [ThumbnailStripPrefs] (e.g. from a parent rebuild), we skip the
  /// `AsyncValue` plumbing and render directly. Tests pass this so they
  /// don't have to seed the SettingsDao.
  final ThumbnailStripPrefs? prefsOverride;

  const ExposureNodeThumbnailStrip({
    super.key,
    required this.nodeId,
    this.prefsOverride,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefsAsync = prefsOverride != null
        ? AsyncValue<ThumbnailStripPrefs>.data(prefsOverride!)
        : ref.watch(thumbnailStripPrefsProvider);

    return prefsAsync.when(
      data: (prefs) {
        // Visibility toggle OFF — collapse silently so the tree stays
        // compact. We deliberately return SizedBox.shrink rather than
        // null so callers can drop the result into a Column without
        // worrying about nullability.
        if (!prefs.enabled) return const SizedBox.shrink();
        return _StripBody(nodeId: nodeId, prefs: prefs);
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

class _StripBody extends ConsumerWidget {
  final String nodeId;
  final ThumbnailStripPrefs prefs;

  const _StripBody({required this.nodeId, required this.prefs});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final thumbnailsAsync = ref.watch(exposureNodeThumbnailsProvider(nodeId));
    return thumbnailsAsync.when(
      data: (thumbnails) {
        if (thumbnails.isEmpty) {
          // No frames yet — render nothing (the spec is explicit: an empty
          // strip is collapsed silently so the tree row keeps its compact
          // height until a frame actually lands).
          return const SizedBox.shrink();
        }
        return _ThumbnailRow(
          nodeId: nodeId,
          thumbnails: thumbnails,
          prefs: prefs,
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (error, _) {
        // A tiny inline marker rather than an empty strip: with no marker, a
        // crash here is indistinguishable from a node that captured nothing.
        final colors = SkotiqColors.of(context);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.alertTriangle, size: 12, color: colors.warning),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  'Failed to load frame thumbnails: $error',
                  style: TextStyle(
                      fontSize: SkotiqTypography.fontSize10,
                      color: colors.warning),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ThumbnailRow extends StatelessWidget {
  final String nodeId;
  final List<ProducingNodeThumbnail> thumbnails;
  final ThumbnailStripPrefs prefs;

  /// Above this count we paginate horizontally (scrollable row + trailing
  /// "+N more" badge). Below it, every tile fits in a Wrap so a short
  /// strip never gets a scrollbar.
  static const int paginationThreshold = 10;

  const _ThumbnailRow({
    required this.nodeId,
    required this.thumbnails,
    required this.prefs,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final tilePx = prefs.pixelSize;
    final stripHeight = tilePx + prefs.badgeRowHeight + 6;

    final overThreshold = thumbnails.length > paginationThreshold;
    final visible = overThreshold
        ? thumbnails.sublist(thumbnails.length - paginationThreshold)
        : thumbnails;
    final hiddenCount = thumbnails.length - visible.length;

    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 4, top: 2, bottom: 6),
      child: SizedBox(
        height: stripHeight,
        child: ListView.separated(
          key: ValueKey('thumbstrip-$nodeId'),
          scrollDirection: Axis.horizontal,
          itemCount: visible.length + (hiddenCount > 0 ? 1 : 0),
          separatorBuilder: (_, __) => const SizedBox(width: 4),
          itemBuilder: (context, index) {
            if (hiddenCount > 0 && index == 0) {
              // Leading badge tells the user there are older frames not
              // shown — clicking it could scroll to a full library view
              // in a future iteration; today it's an informational chip.
              return _MoreBadge(
                count: hiddenCount,
                colors: colors,
                tilePx: tilePx,
              );
            }
            final offset = hiddenCount > 0 ? 1 : 0;
            final thumb = visible[index - offset];
            return _ThumbnailTile(
              thumbnail: thumb,
              tilePx: tilePx,
              badgeHeight: prefs.badgeRowHeight,
              colors: colors,
            );
          },
        ),
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
      message: '$count earlier frames not shown in strip',
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
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize10,
            fontWeight: FontWeight.w600,
            color: colors.textMuted,
          ),
        ),
      ),
    );
  }
}

class _ThumbnailTile extends ConsumerStatefulWidget {
  final ProducingNodeThumbnail thumbnail;
  final double tilePx;
  final double badgeHeight;
  final SkotiqColors colors;

  const _ThumbnailTile({
    required this.thumbnail,
    required this.tilePx,
    required this.badgeHeight,
    required this.colors,
  });

  @override
  ConsumerState<_ThumbnailTile> createState() => _ThumbnailTileState();
}

class _ThumbnailTileState extends ConsumerState<_ThumbnailTile> {
  Future<Uint8List?>? _bytesFuture;

  @override
  void initState() {
    super.initState();
    _bytesFuture = _loadBytes();
  }

  @override
  void didUpdateWidget(covariant _ThumbnailTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.thumbnail.id != widget.thumbnail.id ||
        oldWidget.thumbnail.filePath != widget.thumbnail.filePath) {
      _bytesFuture = _loadBytes();
    }
  }

  Future<Uint8List?> _loadBytes() async {
    return fetchFrameThumbnailBytes(
      ref,
      widget.thumbnail.id,
      source: 'ExposureNodeThumbnailStrip',
    );
  }

  Color _borderColor() {
    final kind = widget.thumbnail.gradeKind;
    switch (kind) {
      case 'pass':
        return widget.colors.success;
      case 'reject':
        return widget.colors.error;
      case 'pending':
        return widget.colors.warning;
      default:
        return widget.colors.textMuted;
    }
  }

  String _tooltip() {
    final t = widget.thumbnail;
    final parts = <String>[];
    parts.add(
        '${filterLabel(t.filter)} · ${t.exposureDuration.toStringAsFixed(0)}s');
    if (t.hfr != null) parts.add('HFR ${t.hfr!.toStringAsFixed(2)}');
    if (t.eccentricity != null) {
      parts.add('ecc ${t.eccentricity!.toStringAsFixed(2)}');
    }
    if (t.starCount != null) parts.add('${t.starCount} stars');
    if (!t.isAccepted) {
      parts.add(
          'REJECTED${t.rejectionReason == null ? '' : ': ${t.rejectionReason!}'}');
    } else {
      parts.add(_gradeLabel(t.gradeKind));
    }
    parts.add(t.capturedAt.toLocal().toString().split('.').first);
    return parts.join('\n');
  }

  String _gradeLabel(String kind) {
    switch (kind) {
      case 'pass':
        return 'Accepted';
      case 'reject':
        return 'Rejected';
      case 'pending':
        return 'Borderline / pending review';
      default:
        return 'Not graded';
    }
  }

  void _openInViewer() {
    final t = widget.thumbnail;
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _FullFrameDialog(
        thumbnail: t,
        bytesFuture: _bytesFuture,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final px = widget.tilePx;
    final borderColor = _borderColor();
    return Tooltip(
      message: _tooltip(),
      waitDuration: const Duration(milliseconds: 350),
      child: GestureDetector(
        onTap: _openInViewer,
        onLongPress: _openInViewer,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: px,
              height: px,
              decoration: BoxDecoration(
                color: widget.colors.surface,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                border: Border.all(
                  color: borderColor,
                  width: 2,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: FrameThumbnail(
                iconSize: 14,
                bytesFuture: _bytesFuture,
                fallbackFilePath: widget.thumbnail.filePath,
                colors: widget.colors,
              ),
            ),
            SizedBox(
              height: widget.badgeHeight,
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  filterLabel(widget.thumbnail.filter),
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize9,
                    fontWeight: FontWeight.w600,
                    color: widget.colors.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FullFrameDialog extends ConsumerWidget {
  final ProducingNodeThumbnail thumbnail;
  final Future<Uint8List?>? bytesFuture;

  const _FullFrameDialog({
    required this.thumbnail,
    required this.bytesFuture,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final t = thumbnail;
    return Dialog(
      backgroundColor: colors.surface,
      child: ConstrainedBox(
        constraints: AdaptiveDialogConstraints.hybrid(
          context,
          designMaxWidth: 800,
          designMaxHeight: 720,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      t.fileName,
                      style: SkotiqTypography.labelStrong
                          .copyWith(color: colors.textPrimary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(LucideIcons.x, size: 16),
                    color: colors.textMuted,
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: 'Close',
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: Container(
                width: double.infinity,
                color: colors.background,
                padding: const EdgeInsets.all(12),
                child: FutureBuilder<Uint8List?>(
                  future: bytesFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(
                          child: SkotiqMark(
                              motion: SkotiqMarkMotion.loading, size: 36));
                    }
                    final bytes = snapshot.data;
                    if (bytes != null && bytes.isNotEmpty) {
                      return InteractiveViewer(
                        child: Image.memory(
                          bytes,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                        ),
                      );
                    }
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(LucideIcons.image,
                              size: 48, color: colors.textMuted),
                          const SizedBox(height: 8),
                          Text(
                            'Preview unavailable for ${t.fileName}.\nOpen in the imaging viewer for the full frame.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: colors.textMuted,
                                fontSize: SkotiqTypography.fontSize12),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: _FrameMetadata(thumb: t, colors: colors),
            ),
          ],
        ),
      ),
    );
  }
}

class _FrameMetadata extends StatelessWidget {
  final ProducingNodeThumbnail thumb;
  final SkotiqColors colors;

  const _FrameMetadata({required this.thumb, required this.colors});

  @override
  Widget build(BuildContext context) {
    Widget chip(String label, String value) => Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: TextStyle(
                      fontSize: SkotiqTypography.fontSize10,
                      color: colors.textMuted)),
              Text(value,
                  style:
                      SkotiqTypography.h6.copyWith(color: colors.textPrimary)),
            ],
          ),
        );
    return Wrap(
      runSpacing: 6,
      children: [
        chip('Filter', filterLabel(thumb.filter)),
        chip('Exposure', '${thumb.exposureDuration.toStringAsFixed(1)}s'),
        chip('HFR', thumb.hfr?.toStringAsFixed(2) ?? '—'),
        chip('Eccentricity', thumb.eccentricity?.toStringAsFixed(2) ?? '—'),
        chip('Stars', thumb.starCount?.toString() ?? '—'),
        chip(
          'Grade',
          thumb.isAccepted ? (thumb.runtimeGrade ?? 'accepted') : 'REJECTED',
        ),
        chip(
          'Captured',
          thumb.capturedAt.toLocal().toString().split('.').first,
        ),
      ],
    );
  }
}
