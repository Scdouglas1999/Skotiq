import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/tutorial_keys/imaging_keys.dart';
import 'overlay_widgets.dart' show HistogramPainter;

/// The glass HUD over the frame (05 §14, 06 §Imaging).
///
/// The frame is the screen's subject, so the HUD over it is one compact pill
/// at the top-left: what the frame is, when it landed, and the two numbers an
/// operator glances at between subs. The histogram is opt-in (Overlays →
/// Histogram) and the capture bar owns the bottom edge. Everything here reads
/// the same providers the old corner panels read; an unknown value is left
/// out rather than drawn as an em dash.

/// Top-left: the frame on screen and its key measurements, in one line.
///
/// Folds what used to be two glass panels — a five-readout stats card and a
/// separate "21:24:16 · 2.0 s · Light" status line in the opposite corner —
/// into the single pill the approved Imaging mockup shows. The secondary
/// numbers (eccentricity, median, mean) stay one hover away in the tooltip
/// rather than leaving the screen entirely.
class FrameInfoPill extends ConsumerWidget {
  const FrameInfoPill({
    super.key,
    required this.eccentricity,
    this.trailing = const <Widget>[],
  });

  /// Representative per-frame eccentricity, median across the science tiles.
  /// Null when the frame carries no eccentricity measurement.
  final double? eccentricity;

  /// Badges that qualify the same frame — raw-load progress, calibration, the
  /// accept / reject verdict. Each self-collapses when it has nothing to say.
  final List<Widget> trailing;

  /// Gap between the pill's segments (`Imaging.dc.html`: 12 px).
  static const double gap = SkotiqTokens.spaceMd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final image = ref.watch(currentImageProvider);
    if (image == null) return const SizedBox.shrink();

    final stats = image.stats;
    // Prefer the live per-frame eccentricity the native star detector puts on
    // ImageStats; fall back to the science-row median only when the frame did
    // not measure it.
    final ecc = stats.eccentricity ?? eccentricity;
    final hfr = stats.hfr;
    final stars = stats.starCount;
    final detail = <String>[
      if (hfr != null) 'HFR ${hfr.toStringAsFixed(2)} px',
      if (ecc != null) 'Eccentricity ${ecc.toStringAsFixed(2)}',
      if (stars != null) 'Stars $stars',
      if (stats.median != null) 'Median ${_whole(stats.median!)}',
      if (stats.mean != null) 'Mean ${_whole(stats.mean!)}',
    ];

    return Glass(
      key: ImagingTutorialKeys.statsPanel,
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
        vertical: SkotiqTokens.spaceXs + 2,
      ),
      // Built under Glass's own context: the palette inside glass is the DARK
      // ladder whatever the app theme is (05 §14), and a style resolved from
      // the OUTER context would put light-theme ink on a black frame.
      child: Builder(
        builder: (BuildContext context) {
          final colors = context.skotiqColors;
          final mono = SkotiqTypography.withTabular(SkotiqTypography.monoSm);
          final summary = Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              StatusDot(color: colors.success),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Text(
                frameIdentity(image.settings),
                style: SkotiqTypography.labelSm.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: gap),
              Text(
                _clock(image.capturedAt),
                style: SkotiqTypography.caption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              if (hfr != null) ...<Widget>[
                const SizedBox(width: gap),
                Text(
                  'HFR ${hfr.toStringAsFixed(2)}',
                  style: mono.copyWith(color: colors.textPrimary),
                ),
              ],
              if (stars != null) ...<Widget>[
                const SizedBox(width: gap),
                Text(
                  '$stars stars',
                  style: mono.copyWith(color: colors.textSecondary),
                ),
              ],
            ],
          );
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (detail.isEmpty)
                summary
              else
                SkotiqTooltip(
                  message: detail.join('\n'),
                  position: SkotiqTooltipPosition.bottom,
                  child: summary,
                ),
              for (final Widget badge in trailing) ...<Widget>[
                const SizedBox(width: SkotiqTokens.spaceSm),
                badge,
              ],
            ],
          );
        },
      ),
    );
  }

  /// What the frame is: its filter for a light frame shot through one,
  /// otherwise its frame type, then the exposure — "L · 2.0 s",
  /// "Dark · 300.0 s".
  @visibleForTesting
  static String frameIdentity(ExposureSettings settings) {
    final exposure = settings.exposureTime;
    final exposureLabel = exposure >= 1
        ? '${exposure.toStringAsFixed(1)} s'
        : '${exposure.toStringAsFixed(2)} s';
    final filter = settings.filter?.trim();
    final lead = settings.frameType == FrameType.light &&
            filter != null &&
            filter.isNotEmpty
        ? filter
        : settings.frameType.displayName;
    return '$lead · $exposureLabel';
  }

  /// A whole-number reading, unseparated.
  ///
  /// 06 "Copy rules" asked for a thin space every three digits; the bundled
  /// fonts carry no U+2009, so the separator rendered as a tofu box inside the
  /// number it was meant to make readable.
  static String _whole(double value) => value.round().toString();

  static String _clock(DateTime at) {
    final local = at.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }
}

/// Bottom-right, opt-in: the preview histogram.
///
/// It no longer names the stretch in force. The capture bar's Stretch toggle
/// already says that, and the same "Stretch: off" twice on one canvas is one
/// fact read as two.
class HistogramHud extends ConsumerWidget {
  const HistogramHud({super.key});

  /// Panel width (`mockups/imaging.html` `.hud-br .glass`).
  static const double width = 220;

  /// Height of the bars themselves.
  static const double barsHeight = 44;

  /// The top of a 16-bit frame, the histogram's right-hand edge.
  static const int fullWell = 65535;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final histogram = ref.watch(previewDisplayHistogramProvider);

    return Glass(
      key: ImagingTutorialKeys.histogram,
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
        vertical: SkotiqTokens.spaceSm + 2,
      ),
      // See FrameInfoPill: everything inside glass resolves the dark
      // palette, so the styles are built from the INNER context.
      child: Builder(
        builder: (BuildContext context) {
          final colors = context.skotiqColors;
          final endpoints = SkotiqTypography.monoCaption.copyWith(
            color: colors.textMuted,
          );
          return SizedBox(
            width: width,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  'Histogram',
                  style: SkotiqTypography.eyebrow.copyWith(
                    color: colors.textMuted,
                  ),
                ),
                const SizedBox(height: SkotiqTokens.spaceXs + 2),
                SizedBox(
                  height: barsHeight,
                  child: histogram != null && histogram.isNotEmpty
                      ? CustomPaint(
                          painter: HistogramPainter(
                            histogram: histogram,
                            color: colors.primary,
                          ),
                          size: Size.infinite,
                        )
                      : Center(child: Text('No data', style: endpoints)),
                ),
                const SizedBox(height: SkotiqTokens.spaceXs),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: <Widget>[
                    Text('0', style: endpoints),
                    Text('$fullWell', style: endpoints),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
