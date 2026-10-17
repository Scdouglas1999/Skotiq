// Frame history column and its tiles.
part of '../live_frame_panel.dart';

/// Vertical, scrollable column of recent-capture thumbnails to the right of the
/// main image. Newest-first; the cell matching the currently-displayed frame is
/// highlighted, and tapping any cell opens [_FrameInspectDialog].
class _HistoryColumn extends StatelessWidget {
  final SkotiqColors colors;
  final List<CapturedImage> images;
  final CapturedImageData? currentImage;

  /// Cap the column so a long night never builds an unbounded widget list;
  /// older frames roll off the top (newest-first).
  static const int _maxFrames = 24;

  const _HistoryColumn({
    required this.colors,
    required this.images,
    required this.currentImage,
  });

  @override
  Widget build(BuildContext context) {
    final total = images.length;
    final tail =
        total > _maxFrames ? images.sublist(total - _maxFrames) : images;
    final newestFirst = tail.reversed.toList(growable: false);

    // Identify which history row corresponds to the live frame so it can be
    // highlighted. The live frame and its persisted row share a file path; fall
    // back to the capture timestamp when the path is absent.
    final currentPath = currentImage?.filePath;
    final currentAt = currentImage?.capturedAt;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(LucideIcons.galleryVerticalEnd,
                size: 12, color: colors.textMuted),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                // Scope named on purpose: this strip is SESSION-scoped while
                // IMAGE QUALITY beside it is run-scoped, and two adjacent
                // panels silently counting different things reads as a
                // contradiction (waveM-close M-4).
                'History — session',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  color: colors.textMuted,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        Expanded(
          child: ListView.separated(
            itemCount: newestFirst.length,
            separatorBuilder: (_, __) =>
                const SizedBox(height: SkotiqTokens.spaceSm),
            // Tiles are addressed by frame identity, not by position. The
            // list is newest-first, so every capture shifts each index by one;
            // without the key plus this lookup the sliver rebuilds every
            // visible tile from scratch and each one refetches its thumbnail —
            // up to 24 `getImageThumbnail` round-trips per captured frame.
            findItemIndexCallback: (key) {
              final id = (key as ValueKey<String>).value;
              final index = newestFirst.indexWhere((i) => i.id == id);
              return index < 0 ? null : index;
            },
            itemBuilder: (context, index) {
              final image = newestFirst[index];
              final isCurrent = _matchesCurrent(image, currentPath, currentAt);
              return _HistoryTile(
                key: ValueKey(image.id),
                colors: colors,
                image: image,
                isCurrent: isCurrent,
              );
            },
          ),
        ),
      ],
    );
  }

  bool _matchesCurrent(
    CapturedImage image,
    String? currentPath,
    DateTime? currentAt,
  ) {
    if (currentPath != null &&
        currentPath.isNotEmpty &&
        image.filePath.isNotEmpty) {
      return image.filePath == currentPath;
    }
    if (currentAt != null) {
      return image.capturedAt == currentAt;
    }
    return false;
  }
}

class _HistoryTile extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final CapturedImage image;
  final bool isCurrent;

  const _HistoryTile({
    super.key,
    required this.colors,
    required this.image,
    required this.isCurrent,
  });

  @override
  ConsumerState<_HistoryTile> createState() => _HistoryTileState();
}

class _HistoryTileState extends ConsumerState<_HistoryTile> {
  Future<Uint8List?>? _bytesFuture;

  @override
  void initState() {
    super.initState();
    _bytesFuture = _loadBytes();
  }

  @override
  void didUpdateWidget(covariant _HistoryTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image.id != widget.image.id ||
        oldWidget.image.filePath != widget.image.filePath) {
      _bytesFuture = _loadBytes();
    }
  }

  Future<Uint8List?> _loadBytes() async {
    final imageId = int.tryParse(widget.image.id);
    if (imageId == null) return null;
    return fetchFrameThumbnailBytes(
      ref,
      imageId,
      source: 'RunDashboardLiveFrame',
    );
  }

  String _filterLabel() => filterLabel(widget.image.settings.filter);

  String _exposureLabel() {
    final secs = widget.image.settings.exposureTime;
    if (secs >= 1) return '${secs.toStringAsFixed(0)}s';
    return '${secs.toStringAsFixed(1)}s';
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final highlight = widget.isCurrent;
    return Tooltip(
      message: '${_filterLabel()} · ${_exposureLabel()}',
      waitDuration: const Duration(milliseconds: 350),
      child: InkWell(
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
        onTap: () => _FrameInspectDialog.show(context, image: widget.image),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: Container(
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusSm),
                  border: Border.all(
                    color: highlight ? colors.primary : colors.border,
                    width: highlight ? 2 : 1,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: FrameThumbnail(
                  bytesFuture: _bytesFuture,
                  fallbackFilePath: widget.image.filePath,
                  colors: colors,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                Text(
                  _filterLabel(),
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize9,
                    fontWeight: FontWeight.w700,
                    color: highlight ? colors.primary : colors.textSecondary,
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _exposureLabel(),
                    style: SkotiqTypography.withTabular(
                      TextStyle(
                          fontSize: SkotiqTypography.fontSize9,
                          color: colors.textMuted),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
