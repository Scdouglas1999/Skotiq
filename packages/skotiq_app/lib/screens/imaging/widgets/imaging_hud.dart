import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/tutorial_keys/imaging_keys.dart';
import 'overlay_widgets.dart' show HistogramPainter;

/// The glass HUD over the frame (05 §14, 06 §Imaging).
///
/// Four corners, spoken for: top-left the frame's measurements, top-right the
/// last frame's status, bottom-right the histogram, bottom-centre the capture
/// bar (owned by the screen). Everything here reads the same providers the old
/// black-box overlays read; what changed is that they are `Glass`, they use
/// `Readout`, and an unknown value is an em dash rather than `---`.

/// Top-left: HFR / Ecc / Stars / Median / Mean.
class FrameStatsHud extends ConsumerWidget {
  const FrameStatsHud({super.key, required this.eccentricity});

  /// Representative per-frame eccentricity, median across the science tiles.
  /// Null when the frame carries no eccentricity measurement.
  final double? eccentricity;

  /// Gap between the readouts (`observatory.css` `.hud-bl .stats`).
  static const double gap = 18;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final image = ref.watch(currentImageProvider);
    final stats = image?.stats;
    // Prefer the live per-frame eccentricity the native star detector puts on
    // ImageStats; fall back to the science-row median only when the frame did
    // not measure it. Reading only the science row is why this said "—" while
    // the badge beside it said 0.25.
    final ecc = image == null ? null : stats?.eccentricity ?? eccentricity;
    return Glass(
      key: ImagingTutorialKeys.statsPanel,
      child: ReadoutRow(
        gap: gap,
        children: <Readout>[
          Readout(
            value: stats?.hfr?.toStringAsFixed(2),
            unit: 'px',
            label: 'HFR',
          ),
          Readout(value: ecc?.toStringAsFixed(2), label: 'Ecc'),
          Readout(value: stats?.starCount?.toString(), label: 'Stars'),
          Readout(value: _whole(stats?.median), label: 'Median'),
          Readout(value: _whole(stats?.mean), label: 'Mean'),
        ],
      ),
    );
  }

  /// A whole-number reading, unseparated.
  ///
  /// 06 "Copy rules" asked for a thin space every three digits; the bundled
  /// fonts carry no U+2009, so the separator rendered as a tofu box inside the
  /// number it was meant to make readable.
  static String? _whole(double? value) =>
      value == null ? null : value.round().toString();
}

/// Top-right: what the frame on screen is, and when it landed.
class LastFrameStatusHud extends ConsumerWidget {
  const LastFrameStatusHud({super.key, this.trailing = const <Widget>[]});

  /// Badges that qualify the same frame — raw-load progress, calibration.
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final image = ref.watch(currentImageProvider);
    if (image == null) return const SizedBox.shrink();

    final exposure = image.settings.exposureTime;
    final exposureLabel = exposure >= 1
        ? '${exposure.toStringAsFixed(1)} s'
        : '${exposure.toStringAsFixed(2)} s';
    final line = <String>[
      _clock(image.capturedAt),
      exposureLabel,
      image.settings.frameType.displayName,
    ].join(' · ');

    return Glass(
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
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              StatusDot(color: colors.success),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Text(
                line,
                style: SkotiqTypography.caption.copyWith(
                  color: colors.textSecondary,
                ),
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

  static String _clock(DateTime at) {
    final local = at.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }
}

/// Bottom-right: the preview histogram, with the stretch actually in force.
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
    final stretch = ref.watch(autoStretchSettingsProvider);
    final caption =
        stretch.enabled ? 'Stretch: ${stretch.method.name}' : 'Stretch: off';

    return Glass(
      key: ImagingTutorialKeys.histogram,
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
        vertical: SkotiqTokens.spaceSm + 2,
      ),
      // See LastFrameStatusHud: everything inside glass resolves the dark
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
                    Text(caption, style: endpoints),
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
