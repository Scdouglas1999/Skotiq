import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'glass_card.dart';

/// Dashboard Storage tile.
///
/// Shows free space on the capture directory plus, when a sequence is loaded,
/// a horizontal bar comparing projected sequence size against free space with
/// the warning (10 GB) and abort (2 GB) thresholds marked.
///
/// Reads from [captureDirDiskSpaceProvider] for the polled free-space stream
/// and [sequenceDiskProjectionProvider] for the projection.
class StorageCard extends ConsumerWidget {
  final SkotiqColors colors;

  const StorageCard({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diskAsync = ref.watch(captureDirDiskSpaceProvider);
    final projectionAsync = ref.watch(sequenceDiskProjectionProvider);

    return DashboardGlassCard(
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          DashboardCardHeader(
            colors: colors,
            icon: LucideIcons.hardDrive,
            title: 'Storage',
            accent: colors.info,
          ),
          const SizedBox(height: DashboardCardStyle.headerGap),
          diskAsync.when(
            data: (info) => _buildBody(
              info,
              projectionAsync,
              onRetryProjection: () =>
                  ref.invalidate(sequenceDiskProjectionProvider),
            ),
            loading: () => _buildLoading(),
            error: (e, _) => _buildError(
              e,
              onRetry: () => ref.invalidate(captureDirDiskSpaceProvider),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(DiskSpaceInfo? info,
      AsyncValue<SequenceDiskProjectionSnapshot> projectionAsync,
      {required VoidCallback onRetryProjection}) {
    if (info == null) {
      // imageOutputPath empty — surface as a soft prompt rather than a hard error.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Set a capture directory in Settings → File Output to track free space.',
          style: SkotiqTypography.caption
              .copyWith(color: colors.textSecondary),
        ),
      );
    }

    final projection = projectionAsync.valueOrNull?.projection;
    final freeGb = _gb(info.freeBytes);
    final totalGb = _gb(info.totalBytes);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(
              freeGb,
              style: SkotiqTypography.pageTitle.copyWith(
                  color: _freeColor(info, projection),
                  fontFeatures: const [FontFeature.tabularFigures()]),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 4, left: 4),
              child: Text(
                'GB free',
                style: SkotiqTypography.caption
                    .copyWith(color: colors.textSecondary),
              ),
            ),
            const Spacer(),
            Text(
              'of $totalGb GB',
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textMuted),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          info.path,
          style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 10),
        _StorageBar(
          colors: colors,
          info: info,
          projection: projection,
        ),
        if (projection != null) ...[
          const SizedBox(height: 8),
          Text(
            projection.headline,
            style: SkotiqTypography.caption
                .copyWith(color: _severityColor(projection.severity)),
          ),
        ] else if (projectionAsync.isLoading) ...[
          const SizedBox(height: 8),
          Text(
            'Calculating sequence storage…',
            style:
                SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
        ] else if (projectionAsync.hasError) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(LucideIcons.alertTriangle, size: 13, color: colors.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Sequence storage estimate unavailable',
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.error),
                ),
              ),
              TextButton(
                onPressed: onRetryProjection,
                child: const Text('Retry'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildLoading() {
    return SizedBox(
      height: 60,
      child: Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: colors.primary,
          ),
        ),
      ),
    );
  }

  Widget _buildError(Object error, {required VoidCallback onRetry}) {
    return Row(
      children: [
        Icon(LucideIcons.alertTriangle, size: 14, color: colors.error),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            // Same distinction the readiness card makes: a missing capture
            // folder is a different problem from a query that broke, and the
            // exception already knows which one it is.
            error is DiskSpaceException &&
                    error.kind == DiskSpaceFailureKind.pathMissing
                ? 'Capture folder not found: ${error.path}'
                : 'Disk query failed: $error',
            style: SkotiqTypography.caption.copyWith(color: colors.error),
            overflow: TextOverflow.ellipsis,
            maxLines: 2,
          ),
        ),
        TextButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    );
  }

  Color _freeColor(DiskSpaceInfo info, DiskSpaceProjection? projection) {
    if (projection != null &&
        projection.severity == DiskSpaceSeverity.blocking) {
      return colors.error;
    }
    if (projection != null &&
        projection.severity == DiskSpaceSeverity.warning) {
      return colors.warning;
    }
    if (info.freeBytes < 2 * 1024 * 1024 * 1024) return colors.error;
    if (info.freeBytes < 10 * 1024 * 1024 * 1024) return colors.warning;
    return colors.textPrimary;
  }

  Color _severityColor(DiskSpaceSeverity severity) {
    return switch (severity) {
      DiskSpaceSeverity.info => colors.textSecondary,
      DiskSpaceSeverity.warning => colors.warning,
      DiskSpaceSeverity.blocking => colors.error,
    };
  }

  static String _gb(int bytes) {
    final gb = bytes / (1024 * 1024 * 1024);
    if (gb < 10) return gb.toStringAsFixed(2);
    if (gb < 100) return gb.toStringAsFixed(1);
    return gb.toStringAsFixed(0);
  }
}

/// Horizontal stacked bar:
///  - Used portion (left, neutral)
///  - Projected new usage on top of existing free (orange, only when sequence loaded)
///  - Remaining free (right, green)
/// Threshold markers (10 GB warning, 2 GB abort) overlaid as vertical ticks
/// counted from the right edge.
class _StorageBar extends StatelessWidget {
  final SkotiqColors colors;
  final DiskSpaceInfo info;
  final DiskSpaceProjection? projection;

  const _StorageBar({
    required this.colors,
    required this.info,
    required this.projection,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final total = info.totalBytes;
        final used = info.usedBytes;
        if (total <= 0) {
          return SizedBox(height: 12, width: w);
        }

        final usedFrac = (used / total).clamp(0.0, 1.0);
        double projectedFrac = 0;
        if (projection != null && projection!.projectedBytes > 0) {
          projectedFrac =
              (projection!.projectedBytes / total).clamp(0.0, 1.0 - usedFrac);
        }
        final freeFrac = (1.0 - usedFrac - projectedFrac).clamp(0.0, 1.0);

        return Stack(
          children: [
            // Bar background
            Container(
              height: 12,
              width: w,
              decoration: BoxDecoration(
                color: colors.surfaceAlt,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
              ),
            ),
            // Used segment
            ClipRRect(
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
              child: Row(
                children: [
                  Container(
                    height: 12,
                    width: w * usedFrac,
                    color: colors.textMuted.withValues(alpha: 0.55),
                  ),
                  if (projectedFrac > 0)
                    Container(
                      height: 12,
                      width: w * projectedFrac,
                      color: colors.warning.withValues(alpha: 0.75),
                    ),
                  if (freeFrac > 0)
                    Container(
                      height: 12,
                      width: w * freeFrac,
                      color: colors.success.withValues(alpha: 0.6),
                    ),
                ],
              ),
            ),
            // 10 GB warning threshold tick (from the right edge)
            _thresholdTick(
              w: w,
              totalBytes: total,
              offsetBytes: 10 * 1024 * 1024 * 1024,
              color: colors.warning,
            ),
            // 2 GB abort threshold tick
            _thresholdTick(
              w: w,
              totalBytes: total,
              offsetBytes: 2 * 1024 * 1024 * 1024,
              color: colors.error,
            ),
          ],
        );
      },
    );
  }

  /// Vertical tick mark drawn `offsetBytes` from the *right* edge of the bar,
  /// representing the point at which `free == offsetBytes`. Skipped if the
  /// threshold doesn't fit on the bar (e.g. tiny disk).
  Widget _thresholdTick({
    required double w,
    required int totalBytes,
    required int offsetBytes,
    required Color color,
  }) {
    if (offsetBytes >= totalBytes) return const SizedBox.shrink();
    final fracFromRight = offsetBytes / totalBytes;
    final x = w * (1.0 - fracFromRight);
    return Positioned(
      left: x - 0.5,
      top: -2,
      child: Container(
        width: 1,
        height: 16,
        color: color.withValues(alpha: 0.9),
      ),
    );
  }
}
