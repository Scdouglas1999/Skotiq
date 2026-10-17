// Frame inspect dialog, preview and metadata rows.
part of '../live_frame_panel.dart';

/// Modal that inspects a previously-captured frame: a larger preview plus its
/// filter / exposure / capture-time metadata. Uses the same backend-thumbnail
/// path as the strip so it works both locally and against a remote host.
class _FrameInspectDialog extends ConsumerWidget {
  final CapturedImage image;

  const _FrameInspectDialog({required this.image});

  static Future<void> show(
    BuildContext context, {
    required CapturedImage image,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => _FrameInspectDialog(image: image),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final dialogSize = AdaptiveDialogConstraints.dialogSize(
      context,
      designWidth: 560,
      designHeight: 560,
    );
    return Dialog(
      child: SizedBox(
        width: dialogSize.width,
        height: dialogSize.height,
        child: Padding(
          padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.image, size: 16, color: colors.primary),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Expanded(
                    child: Text(
                      _fileName(image.filePath),
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize14,
                        fontWeight: FontWeight.w700,
                        color: colors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(LucideIcons.x, size: 16),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: SkotiqTokens.spaceMd),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                  child: Container(
                    color: colors.background,
                    width: double.infinity,
                    child: _InspectPreview(image: image, colors: colors),
                  ),
                ),
              ),
              const SizedBox(height: SkotiqTokens.spaceMd),
              _MetaRow(image: image, colors: colors),
            ],
          ),
        ),
      ),
    );
  }

  String _fileName(String path) {
    if (path.isEmpty) return image.targetName ?? 'Captured frame';
    return path.split(RegExp(r'[/\\]')).last;
  }
}

class _InspectPreview extends ConsumerWidget {
  final CapturedImage image;
  final SkotiqColors colors;

  const _InspectPreview({required this.image, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final imageId = int.tryParse(image.id);
    if (imageId == null) {
      return _fallback();
    }
    return FutureBuilder<Uint8List?>(
      future: fetchFrameThumbnailBytes(
        ref,
        imageId,
        source: 'RunDashboardLiveFrame',
      ),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colors.textMuted,
              ),
            ),
          );
        }
        final bytes = snapshot.data;
        if (bytes != null && bytes.isNotEmpty) {
          return Center(
            child: Image.memory(
              bytes,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => _fallback(),
            ),
          );
        }
        return _fallback();
      },
    );
  }

  Widget _fallback() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.imageOff, size: 32, color: colors.textMuted),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Text(
            'Preview unavailable',
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize12,
                color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  final CapturedImage image;
  final SkotiqColors colors;

  const _MetaRow({required this.image, required this.colors});

  @override
  Widget build(BuildContext context) {
    final settings = image.settings;
    final exposure = settings.exposureTime;
    final exposureLabel =
        '${exposure.toStringAsFixed(exposure >= 10 ? 0 : 1)}s';
    final captured = image.capturedAt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final timeLabel =
        '${two(captured.hour)}:${two(captured.minute)}:${two(captured.second)}';

    return Wrap(
      spacing: SkotiqTokens.spaceLg,
      runSpacing: SkotiqTokens.spaceSm,
      children: [
        _MetaChip(
          colors: colors,
          icon: LucideIcons.filter,
          label: settings.filter ?? 'L',
        ),
        _MetaChip(
          colors: colors,
          icon: LucideIcons.timer,
          label: exposureLabel,
        ),
        _MetaChip(
          colors: colors,
          icon: LucideIcons.clock,
          label: timeLabel,
        ),
        if (image.stats?.hfr != null)
          _MetaChip(
            colors: colors,
            icon: LucideIcons.star,
            label: 'HFR ${image.stats!.hfr!.toStringAsFixed(2)}',
          ),
      ],
    );
  }
}

class _MetaChip extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String label;

  const _MetaChip({
    required this.colors,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: colors.textMuted),
        const SizedBox(width: 4),
        Text(
          label,
          style: SkotiqTypography.withTabular(
            SkotiqTypography.labelSm.copyWith(
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
        ),
      ],
    );
  }
}
