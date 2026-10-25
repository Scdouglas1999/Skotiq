import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../session_review/widgets/sub_cull_rail.dart'
    show subThumbnailProvider;
import 'overlap_map.dart';

/// Rows of limiting frames shown before the rest are summarized.
const int _limitingRows = 8;

/// Rows of frames left out by the pre-pass shown before the rest are counted.
const int _notIncludedRows = 6;

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

/// The registration pre-pass result: the overlap map, the retained area and
/// the frames that limit the crop, each with a one-click exclude.
class FramingReviewPanel extends ConsumerStatefulWidget {
  const FramingReviewPanel({super.key, required this.job});
  final DarkroomBuildJob job;

  @override
  ConsumerState<FramingReviewPanel> createState() => _FramingReviewPanelState();
}

class _FramingReviewPanelState extends ConsumerState<FramingReviewPanel> {
  OverlapColorBy _colorBy = OverlapColorBy.night;
  String? _highlighted;
  bool _excluding = false;
  double? _minimum;
  Timer? _apply;

  @override
  void dispose() {
    _apply?.cancel();
    super.dispose();
  }

  Future<void> _exclude(Map<String, String> reasons) async {
    setState(() => _excluding = true);
    try {
      await ref.read(darkroomBuildJobsProvider.notifier).exclude(reasons);
    } finally {
      if (mounted) {
        setState(() {
          _excluding = false;
          _highlighted = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final preview = widget.job.preview!;
    final included = preview.included.length;
    final notIncluded = preview.notIncluded.toList();
    final minimum = _minimum ?? preview.minRetainedArea;
    final reference = widget.job.plan?.referencePath;
    final limiting =
        preview.limiting.where((f) => f.path != reference).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (preview.meetsMinimum)
          SkotiqBanner(
            tone: BannerTone.success,
            title: 'Framing checked.',
            message:
                'The common crop keeps ${percent(preview.retainedArea)} of the field. '
                'Build when ready, or exclude frames to keep more.',
          )
        else
          SkotiqBanner(
            tone: BannerTone.warning,
            title: 'The common crop is too small.',
            message: preview.describeLimit(),
          ),
        if (widget.job.error != null) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          SkotiqBanner(
            tone: BannerTone.error,
            title: 'Could not update the plan.',
            message: widget.job.error,
          ),
        ],
        const SizedBox(height: SkotiqTokens.spaceMd),
        MetricGrid(
          columns: 4,
          items: [
            MetricGridItem(
              label: 'Field kept',
              value: percent(preview.retainedArea),
              valueTone: preview.meetsMinimum
                  ? MetricGridTone.good
                  : MetricGridTone.warning,
            ),
            MetricGridItem(
                label: 'Minimum', value: percent(minimum, digits: 0)),
            MetricGridItem(label: 'Frames used', value: '$included'),
            MetricGridItem(
              label: 'Left out',
              value: '${notIncluded.length}',
              valueTone: notIncluded.isEmpty
                  ? MetricGridTone.neutral
                  : MetricGridTone.warning,
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        Row(
          children: [
            Expanded(
              child: Text(
                'Where each frame lands on the reference grid',
                style: SkotiqTypography.labelStrong.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ),
            SegmentedControl(
              dense: true,
              semanticLabel: 'Color frames by',
              segments: const ['By night', 'By pier side'],
              selectedIndex: _colorBy.index,
              onSelected: (i) =>
                  setState(() => _colorBy = OverlapColorBy.values[i]),
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        OverlapMap(
          preview: preview,
          colorBy: _colorBy,
          highlighted: _highlighted,
        ),
        _sectionLabel(context, 'Frames that limit the crop'),
        if (limiting.isEmpty)
          Text(
            'No single frame limits the crop. The field is cut by frames shifted together, '
            'such as a whole night or one side of the pier.',
            style:
                SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
          )
        else ...[
          for (final f in limiting.take(_limitingRows))
            MouseRegion(
              onEnter: (_) => setState(() => _highlighted = f.path),
              onExit: (_) => setState(() => _highlighted = null),
              child: DetailRow(
                title: p.basename(f.path),
                subtitle:
                    '${f.group} · without it ${percent(f.retainedWithout)} is kept',
                trailingWidget: SkotiqButton(
                  label: 'Exclude',
                  size: ButtonSize.small,
                  variant: ButtonVariant.secondary,
                  onPressed: _excluding
                      ? null
                      : () => _exclude({f.path: 'Limits the common crop'}),
                ),
              ),
            ),
          if (limiting.length > 1)
            Align(
              alignment: Alignment.centerLeft,
              child: SkotiqButton(
                label:
                    'Exclude all ${limiting.take(_limitingRows).length} listed',
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: _excluding
                    ? null
                    : () => _exclude({
                          for (final f in limiting.take(_limitingRows))
                            f.path: 'Limits the common crop',
                        }),
              ),
            ),
        ],
        if (notIncluded.isNotEmpty) ...[
          _sectionLabel(context, 'Left out by the check'),
          for (final f in notIncluded.take(_notIncludedRows))
            DetailRow(
              title: p.basename(f.path),
              subtitle: f.reason ?? 'Not included',
            ),
          if (notIncluded.length > _notIncludedRows)
            Text(
              'and ${notIncluded.length - _notIncludedRows} more, listed in the frame audit.',
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textSecondary,
              ),
            ),
        ],
        _sectionLabel(
          context,
          'Smallest crop to accept: ${percent(minimum, digits: 0)} of the field',
        ),
        SkotiqSlider(
          value: minimum,
          min: .5,
          max: 1,
          divisions: 50,
          onChanged: _excluding
              ? null
              : (v) {
                  setState(() => _minimum = v);
                  _apply?.cancel();
                  _apply = Timer(
                    const Duration(milliseconds: 400),
                    () => ref
                        .read(darkroomBuildJobsProvider.notifier)
                        .setMinRetainedArea(v),
                  );
                },
        ),
      ],
    );
  }
}

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
    final error = result['error'];
    if (error != null) {
      return DetailRow(
        title: '${result['filter']}: not built',
        subtitle: '$error',
        icon: SkotiqIcons.warning,
      );
    }
    final seconds = (result['totalIntegrationSec'] as num?) ?? 0;
    final skipped = (result['skipped'] as List? ?? const []).length;
    return DetailRow(
      title:
          '${result['filter']}: ${result['frameCount']} frames, ${describeIntegration(seconds)}',
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

/// The finished build: masters, counts and where they are.
class BuildResultPanel extends StatelessWidget {
  const BuildResultPanel({super.key, required this.job, this.onError});
  final DarkroomBuildJob job;
  final ValueChanged<String>? onError;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final report = job.report!;
    final results = (report['results'] as List).cast<Map>();
    final failures = (report['failures'] as List? ?? const []).cast<Map>();
    final delivery = report['delivery'] as Map;
    final masters = (delivery['masters'] as List).cast<Map>();
    final directory = job.directory;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SkotiqBanner(
          tone: failures.isEmpty ? BannerTone.success : BannerTone.warning,
          title:
              'Masters ready, ${delivery['width']} x ${delivery['height']} px.',
          message:
              '${percent((delivery['retainedArea'] as num).toDouble())} of the field kept. '
              'Linear FITS files open directly in PixInsight; previews are stretched only for display.',
        ),
        for (final w in job.warnings) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          SkotiqBanner(tone: BannerTone.warning, title: 'Note.', message: w),
        ],
        const SizedBox(height: SkotiqTokens.spaceMd),
        for (var i = 0; i < results.length && i < masters.length; i++)
          DetailRow(
            title:
                '${results[i]['filter']}: ${results[i]['frameCount']} frames, ${describeIntegration(results[i]['totalIntegrationSec'] as num)}',
            subtitle:
                '${(results[i]['skipped'] as List).length} left out during processing',
            leading: SizedBox(
              width: 56,
              height: 56,
              child: Image.file(
                File(masters[i]['previewPath'] as String),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    Icon(SkotiqIcons.imageOff, color: colors.textMuted),
              ),
            ),
            trailingWidget: SkotiqButton(
              label: 'Open master',
              size: ButtonSize.small,
              variant: ButtonVariant.secondary,
              onPressed: () async {
                final opened = await launchUrl(
                  Uri.file(masters[i]['path'] as String),
                );
                if (!opened) {
                  onError?.call(
                    'Could not open the FITS viewer. Open the output folder instead.',
                  );
                }
              },
            ),
          ),
        for (final f in failures)
          DetailRow(
            title: '${f['filter']}: not built',
            subtitle: '${f['error']}',
            icon: SkotiqIcons.warning,
          ),
        if (directory != null) ...[
          const SizedBox(height: SkotiqTokens.spaceMd),
          SelectableText(
            directory,
            style: SkotiqTypography.monoCaption.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Align(
            alignment: Alignment.centerLeft,
            child: SkotiqButton(
              label: 'Open output folder',
              icon: SkotiqIcons.folderOpen,
              variant: ButtonVariant.secondary,
              onPressed: () => launchUrl(Uri.directory(directory)),
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Text(
            'The folder holds the full-size masters, the frame audit, the calibration choices and the crop report. '
            'Completed masters also appear in the Masters tab.',
            style:
                SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
          ),
        ],
      ],
    );
  }
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
