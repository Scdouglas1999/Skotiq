import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../session_review/widgets/sub_cull_rail.dart'
    show subThumbnailProvider;

String percent(double fraction, {int digits = 1}) =>
    '${(fraction * 100).toStringAsFixed(digits)}%';

String describeEta(Duration? eta) {
  if (eta == null) return 'Estimating time left';
  if (eta.inMinutes < 1) return 'Less than a minute left';
  if (eta.inMinutes < 90) return 'About ${eta.inMinutes} min left';
  return 'About ${(eta.inMinutes / 60).toStringAsFixed(1)} h left';
}

Widget _sectionLabel(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.only(
        top: SkotiqTokens.spaceLg,
        bottom: SkotiqTokens.spaceSm,
      ),
      child: Text(
        text,
        style: SkotiqTypography.labelStrong.copyWith(
          color: context.skotiqColors.textPrimary,
        ),
      ),
    );

/// A running build: stage, frame counts, ETA, the light being processed and
/// the filters finished so far.
class BuildProgressPanel extends ConsumerWidget {
  const BuildProgressPanel({super.key, required this.job});
  final DarkroomBuildJob job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final overall =
        job.overallTotal == 0 ? null : job.overallDone / job.overallTotal;
    final framing = job.stage == DarkroomJobStage.framing;
    final detail = framing
        ? 'Registering lights: ${job.framesDone} of ${job.framesTotal}'
        : job.stage == DarkroomJobStage.exporting
            ? 'Cropping every filter to the shared field'
            : 'Filter ${job.filter ?? ''} (${job.filterIndex + 1} of ${job.filterCount}): '
                'light ${job.framesDone} of ${job.framesTotal}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SkotiqBanner(
          tone: BannerTone.info,
          title: framing ? 'Checking framing.' : 'Building masters.',
          message:
              'You can close this window. The work continues in the background and you are notified when it ends.',
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    job.message,
                    style: SkotiqTypography.bodyStrong.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: SkotiqTokens.spaceXs),
                  Text(
                    detail,
                    style: SkotiqTypography.bodySm.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: SkotiqTokens.spaceMd),
                  SkotiqProgressBar(
                    value: overall ?? 0,
                    indeterminate: overall == null,
                    showPercentage: overall != null,
                    label: framing ? 'Framing check' : 'Whole build',
                  ),
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  Text(
                    describeEta(job.eta),
                    style: SkotiqTypography.bodySm.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (job.currentImageId != null) ...[
              const SizedBox(width: SkotiqTokens.spaceLg),
              _CurrentFrame(imageId: job.currentImageId!),
            ],
          ],
        ),
        if (job.filterResults.isNotEmpty) ...[
          _sectionLabel(context, 'Finished filters'),
          for (final r in job.filterResults) _FilterResultRow(result: r),
        ],
        if (job.directory != null) ...[
          const SizedBox(height: SkotiqTokens.spaceMd),
          SelectableText(
            'Build folder: ${job.directory}',
            style: SkotiqTypography.monoCaption.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ],
      ],
    );
  }
}

class _FilterResultRow extends StatelessWidget {
  const _FilterResultRow({required this.result});
  final Map<String, dynamic> result;

  @override
  Widget build(BuildContext context) {
    final build = DarkroomFilterBuild.fromJson(result);
    final error = build.error;
    if (error != null) {
      return DetailRow(
        title: '${build.filter}: not built',
        subtitle: userFacingError(error),
        icon: SkotiqIcons.warning,
      );
    }
    final skipped = build.skippedCount ?? 0;
    return DetailRow(
      title:
          '${build.filter}: ${build.frameCount} frames, ${describeIntegration(build.totalIntegrationSec ?? 0)}',
      subtitle: skipped == 0
          ? 'No frames left out'
          : '$skipped left out during processing',
      icon: SkotiqIcons.check,
    );
  }
}

class _CurrentFrame extends ConsumerWidget {
  const _CurrentFrame({required this.imageId});
  final int imageId;
  static const double _size = 112;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SizedBox(
        width: _size,
        height: _size,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
          child: ref.watch(subThumbnailProvider(imageId)).when(
                loading: () => ColoredBox(color: context.skotiqColors.well),
                error: (_, __) => ColoredBox(color: context.skotiqColors.well),
                data: (bytes) => Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  semanticLabel: 'Light being processed',
                ),
              ),
        ),
      );
}

/// A list row with a second line, and optional leading and trailing widgets.
class DetailRow extends StatelessWidget {
  const DetailRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.leading,
    this.trailingWidget,
  });
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? leading;
  final Widget? trailingWidget;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: SkotiqTokens.spaceMd),
          ] else if (icon != null) ...[
            Icon(icon, size: 15, color: colors.textMuted),
            const SizedBox(width: SkotiqTokens.spaceMd),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: SkotiqTypography.body.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: SkotiqTypography.bodySm.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          if (trailingWidget != null) ...[
            const SizedBox(width: SkotiqTokens.spaceMd),
            trailingWidget!,
          ],
        ],
      ),
    );
  }
}
