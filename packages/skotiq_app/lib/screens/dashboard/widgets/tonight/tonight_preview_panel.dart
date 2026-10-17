// The live preview panel — Tonight's c8 hero tile (06 §Tonight, row 1).
//
// The sky is the hero (02 rule 1): the frame runs to the panel's edges in a
// `well`, the readouts float over it in glass, and the only chrome is the 32 px
// thumbnail strip underneath.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart' hide ConnectionState;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../../../../utils/filter_label.dart';
import '../../../../widgets/frame_thumbnail_loader.dart';
import '../../../imaging/widgets/image_display.dart';
import '../../../sequencer/widgets/run_dashboard/quality_panel.dart'
    show runDashboardQualitySummaryProvider;

/// The image area's height. Tall enough to read a sub at a glance, short enough
/// that the row-2 panels stay above the fold at 900 px.
const double _previewHeight = 300;

/// The thumbnail strip's cells: 52 × 32, per the mockup.
const double _thumbWidth = 52;
const double _thumbHeight = 32;

/// Newest frames shown in the strip.
const int _maxThumbs = 8;

class TonightPreviewPanel extends ConsumerWidget {
  const TonightPreviewPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);

    return SkotiqPanel(
      flush: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            height: _previewHeight,
            child: ColoredBox(
              color: colors.well,
              child: const _PreviewSurface(),
            ),
          ),
          const _ThumbnailStrip(),
        ],
      ),
    );
  }
}

/// The frame itself, with the two glass HUD corners over it.
class _PreviewSurface extends ConsumerWidget {
  const _PreviewSurface();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final image = ref.watch(currentImageProvider);

    if (image == null) {
      return EmptyState(
        icon: LucideIcons.imageOff,
        title: l10n.text('tnNoFramesTitle'),
        body: l10n.text('tnNoFramesBody'),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ImageDisplayWidget(
          imageData: image,
          zoomLevel: 1.0,
          panOffset: Offset.zero,
        ),
        const Positioned(
          top: SkotiqTokens.spaceMd,
          right: SkotiqTokens.spaceMd,
          child: _LastSubGlass(),
        ),
        const Positioned(
          left: SkotiqTokens.spaceMd,
          bottom: SkotiqTokens.spaceMd,
          child: _QualityGlass(),
        ),
      ],
    );
  }
}

/// Top-right: "Last sub 22:39:51 · L · 120 s" with a live dot.
class _LastSubGlass extends ConsumerWidget {
  const _LastSubGlass();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final frames = ref.watch(recentSessionFramesProvider);
    if (frames.isEmpty) return const SizedBox.shrink();
    final last = frames.last;
    final capturing = ref.watch(
      sessionStateProvider.select((s) => s.isCapturing),
    );

    final at = last.capturedAt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final time = '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
    final exposure = last.settings.exposureTime;

    return Glass(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd - 2,
        vertical: SkotiqTokens.spaceSm - 2,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          StatusDot(color: colors.success, live: capturing),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Text(
            context.l10n.text(
              'tnLastSub',
              params: {
                'time': time,
                'filter': filterLabel(last.settings.filter),
                'exposure': exposure >= 1
                    ? '${exposure.toStringAsFixed(0)} s'
                    : '${exposure.toStringAsFixed(1)} s',
              },
            ),
            style: SkotiqTypography.bodySm,
          ),
        ],
      ),
    );
  }
}

/// Bottom-left: the frame's quality readouts.
class _QualityGlass extends ConsumerWidget {
  const _QualityGlass();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final grades = ref.watch(runDashboardQualitySummaryProvider).recent;
    final latest = grades.isEmpty ? null : grades.first;
    final guider = ref.watch(guiderStateProvider);
    // RMS is a statement about guiding happening NOW; the value lingers in
    // guider state after a session stops, so an unguarded read would print last
    // night's number beside tonight's frame.
    final rms = guider.isGuiding ? guider.rmsTotal : null;

    if (latest == null && rms == null) return const SizedBox.shrink();

    return Glass(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
        vertical: SkotiqTokens.spaceSm,
      ),
      child: ReadoutRow(
        gap: 18,
        children: <Readout>[
          Readout(
            value: latest?.hfr?.toStringAsFixed(2),
            unit: 'px',
            label: l10n.text('tnHfr'),
          ),
          Readout(
            value: latest?.eccentricity?.toStringAsFixed(2),
            label: l10n.text('tnEcc'),
          ),
          Readout(
            value: latest?.starCount?.toString(),
            label: l10n.text('tnStars'),
          ),
          Readout(
            value: rms?.toStringAsFixed(2),
            unit: '"',
            label: l10n.text('tnRms'),
          ),
        ],
      ),
    );
  }
}

/// The 32 px strip of the newest captures under the frame.
class _ThumbnailStrip extends ConsumerWidget {
  const _ThumbnailStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final frames = ref.watch(recentSessionFramesProvider);
    if (frames.isEmpty) return const SizedBox.shrink();

    // `recentSessionFramesProvider` yields capture order, so the newest frame
    // is last; take the tail and reverse it so the strip leads with the newest.
    final tail = frames.length > _maxThumbs
        ? frames.sublist(frames.length - _maxThumbs)
        : frames;
    final newestFirst = tail.reversed.toList(growable: false);

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
        vertical: SkotiqTokens.spaceSm,
      ),
      child: SizedBox(
        height: _thumbHeight,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: newestFirst.length,
          separatorBuilder: (_, __) =>
              const SizedBox(width: SkotiqTokens.spaceXs + 2),
          itemBuilder: (context, index) => _Thumb(
            image: newestFirst[index],
            selected: index == 0,
          ),
        ),
      ),
    );
  }
}

class _Thumb extends ConsumerStatefulWidget {
  const _Thumb({required this.image, required this.selected});

  final CapturedImage image;
  final bool selected;

  @override
  ConsumerState<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends ConsumerState<_Thumb> {
  Future<Uint8List?>? _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = _load();
  }

  @override
  void didUpdateWidget(covariant _Thumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image.id != widget.image.id) _bytes = _load();
  }

  Future<Uint8List?> _load() async {
    final id = int.tryParse(widget.image.id);
    if (id == null) return null;
    return fetchFrameThumbnailBytes(ref, id, source: 'TonightPreviewPanel');
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final at = widget.image.capturedAt.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final label = '${two(at.hour)}:${two(at.minute)}';

    return Tooltip(
      message: '${filterLabel(widget.image.settings.filter)} · $label',
      waitDuration: SkotiqTokens.durationSlow,
      child: Container(
        width: _thumbWidth,
        height: _thumbHeight,
        decoration: BoxDecoration(
          color: colors.well,
          borderRadius: SkotiqTokens.borderRadiusXs,
          border: widget.selected
              ? Border.all(color: colors.primary, width: 2)
              : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            FrameThumbnail(
              iconSize: 12,
              bytesFuture: _bytes,
              fallbackFilePath: widget.image.filePath,
              colors: colors,
            ),
            Positioned(
              left: SkotiqTokens.spaceXs,
              bottom: 2,
              child: Text(
                label,
                style: SkotiqTypography.monoCaption.copyWith(
                  color: colors.textMuted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
