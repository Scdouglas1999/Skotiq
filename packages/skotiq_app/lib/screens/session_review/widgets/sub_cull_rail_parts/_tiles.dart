// Sub tile, download button and select marker.
part of '../sub_cull_rail.dart';

class _SubTile extends ConsumerWidget {
  final DbCapturedImage sub;
  final FrameQualityAssessment? assessment;
  final bool selectMode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onToggleAccept;
  final SkotiqColors colors;

  const _SubTile({
    required this.sub,
    required this.assessment,
    required this.selectMode,
    required this.selected,
    required this.onTap,
    required this.onToggleAccept,
    required this.colors,
  });

  /// Colour of the top-left grade badge — driven purely by the QUALITY GRADE,
  /// not by accept/reject state. A GOOD sub shows a green GOOD badge whether it
  /// is kept or culled; the reject state is conveyed separately by the
  /// "REJECTED" chip + amber ✕ + card dimming, so the grade must not be
  /// recoloured red just because the sub is rejected.
  Color _gradeColor() {
    switch (assessment?.level) {
      case FrameQualityLevel.good:
        return colors.success;
      case FrameQualityLevel.needsReview:
        return colors.warning;
      case FrameQualityLevel.poor:
        return colors.error;
      case null:
        return colors.border;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final grade = _gradeColor();
    return SkotiqCard(
      onTap: onTap,
      enableHover: true,
      isSelected: selected,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(SkotiqTokens.radiusMd),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _SubThumbnail(imageId: sub.id, colors: colors),
                  Positioned(
                    top: 4,
                    left: 4,
                    child: _Badge(
                      text:
                          (assessment?.label ?? kReadoutUnknown).toUpperCase(),
                      color: grade,
                    ),
                  ),
                  if (sub.hfr != null)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: _Badge(
                        text: 'HFR ${sub.hfr!.toStringAsFixed(1)}',
                        color: colors.info,
                      ),
                    ),
                  if (selectMode)
                    Positioned(
                      bottom: 4,
                      right: 4,
                      child: _SelectMarker(selected: selected, colors: colors),
                    )
                  else
                    Positioned(
                      bottom: 4,
                      right: 4,
                      child: _AcceptToggle(
                        accepted: sub.isAccepted,
                        onTap: onToggleAccept,
                        colors: colors,
                      ),
                    ),
                  if (!sub.isAccepted)
                    Positioned(
                      bottom: 4,
                      left: 4,
                      child: frameExclusionKindOf(sub.rejectionReason) == null
                          ? _Badge(text: 'REJECTED', color: colors.error)
                          : FrameExclusionBadge.forReason(sub.rejectionReason),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${filterLabel(sub.filter)} · ${sub.exposureDuration.toInt()}s',
                    style: SkotiqTypography.labelSm
                        .copyWith(color: colors.textPrimary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (sub.starCount != null)
                  Text(
                    '${sub.starCount}★',
                    style: SkotiqTypography.caption
                        .copyWith(color: colors.textMuted),
                  ),
                // Pull the full-resolution frame off the host to this device.
                // The host has always streamed `GET /api/images/<id>/download`
                // and `downloadImageToDevice` has always wrapped it, but the
                // only button that called it lived in a panel no screen built,
                // so a phone paired to the Pi could reach nothing but the 512px
                // thumbnail. This is that path's one production call site.
                _SubDownloadButton(sub: sub, colors: colors),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Per-tile "save the full-resolution frame to this device" affordance.
/// Streams via [downloadImageToDevice] (mobile → share sheet, desktop → save
/// picker) with an inline spinner while the transfer runs.
class _SubDownloadButton extends ConsumerStatefulWidget {
  final DbCapturedImage sub;
  final SkotiqColors colors;

  const _SubDownloadButton({required this.sub, required this.colors});

  @override
  ConsumerState<_SubDownloadButton> createState() => _SubDownloadButtonState();
}

class _SubDownloadButtonState extends ConsumerState<_SubDownloadButton> {
  bool _busy = false;

  Future<void> _download() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final outcome = await downloadImageToDevice(
        backend: ref.read(imagingBackendProvider),
        imageId: widget.sub.id,
        fileName: widget.sub.fileName,
      );
      if (!mounted) return;
      switch (outcome.status) {
        case ImageDownloadStatus.saved:
          context.showSuccessSnackBar('Saved to ${outcome.savedPath}');
        case ImageDownloadStatus.shared:
          context.showSuccessSnackBar('Frame ready to share');
        case ImageDownloadStatus.cancelled:
          break;
        case ImageDownloadStatus.failed:
          context.showErrorSnackBar(outcome.error ?? 'Download failed');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: _busy
          ? Padding(
              padding: const EdgeInsets.all(8),
              child: SkotiqMark(size: 16, color: widget.colors.textMuted),
            )
          : IconButton(
              padding: EdgeInsets.zero,
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              tooltip: 'Download to this device',
              icon: Icon(
                SkotiqIcons.download,
                color: widget.colors.textSecondary,
              ),
              onPressed: _download,
            ),
    );
  }
}

class _SelectMarker extends StatelessWidget {
  final bool selected;
  final SkotiqColors colors;
  const _SelectMarker({required this.selected, required this.colors});

  @override
  Widget build(BuildContext context) {
    final color = selected ? colors.primary : colors.surfaceOverlay;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.9),
        shape: BoxShape.circle,
        border: Border.all(color: colors.border),
      ),
      child: Icon(
        selected ? SkotiqIcons.check : SkotiqIcons.crosshair,
        size: 14,
        color: selected ? colors.onPrimary : colors.textSecondary,
      ),
    );
  }
}
