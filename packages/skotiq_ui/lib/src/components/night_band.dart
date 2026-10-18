import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';
import 'skotiq_panel.dart';

/// One labelled moment on the [NightBand] legend.
@immutable
class NightBandEvent {
  const NightBandEvent({required this.time, required this.label});

  /// When it happens.
  final DateTime time;

  /// Its label, e.g. "19:12 sunset".
  final String label;
}

/// The imageable span of a target, as two instants.
@immutable
class NightBandWindow {
  const NightBandWindow({required this.start, required this.end});

  final DateTime start;
  final DateTime end;
}

/// The signature timeline of tonight: sunset → astro dark → astro dawn →
/// sunrise, with the current time, the target's altitude arc and its imageable
/// window.
///
/// Every colour is a token, so the light and red-night bands follow with no
/// second code path (the red-night bands sit on the red axis by construction).
class NightBand extends StatelessWidget {
  const NightBand({
    super.key,
    required this.sunset,
    required this.astroDark,
    required this.astroDawn,
    required this.sunrise,
    required this.now,
    this.moonSet,
    this.targetAltitudeCurve,
    this.imageableWindow,
    this.events = const <NightBandEvent>[],
  });

  /// The night's start — the left edge of the canvas.
  final DateTime sunset;

  /// When astronomical darkness begins.
  final DateTime astroDark;

  /// When it ends.
  final DateTime astroDawn;

  /// The night's end — the right edge of the canvas.
  final DateTime sunrise;

  /// The current time. Drives the "now" marker.
  final DateTime now;

  /// When the moon sets, if it does tonight.
  final DateTime? moonSet;

  /// The target's altitude, sampled left to right, each value 0–1 where 1 is
  /// the top of the canvas. Null hides the arc.
  final List<double>? targetAltitudeCurve;

  /// The span in which the target is worth imaging.
  final NightBandWindow? imageableWindow;

  /// Labels for the legend, positioned at their times.
  final List<NightBandEvent> events;

  /// The gradient canvas's height.
  static const double canvasHeight = 52;

  /// The legend's height (two rows: the event labels and the "now" line).
  static const double legendHeight = 30;

  /// Below this width the legend keeps only its first and last labels.
  ///
  /// The labels are `monoCaption` strings like "20:48 astro dark" positioned
  /// at their own times, so at a 700px window the four of them overlap into an
  /// unreadable smear — `reports/observatory/w3-tonight/shots/tonight-narrow-
  /// 700x900.png`. Sunset and sunrise are the two that give the band its
  /// meaning; the middle ones are already drawn on the canvas as the dashed
  /// astro-dark and astro-dawn verticals, so dropping their words loses no
  /// information the picture does not carry.
  static const double legendCompactWidth = 800;

  /// The second legend row, which carries the caret and "now hh:mm" so it can
  /// never collide with an event label.
  static const double nowRowHeight = 15;

  /// The imageable-window bar's thickness.
  static const double windowBarHeight = 4;

  /// The "now" line's thickness and its cap's diameter.
  static const double nowLineWidth = 1.5;
  static const double nowDotSize = 6;

  /// The altitude path's stroke width.
  static const double altitudeStrokeWidth = 1.5;

  /// Fill opacity under the altitude path.
  static const double altitudeFillOpacity = 0.16;

  /// The panel's padding: 12 top and bottom, 16 either side.
  static const EdgeInsets panelPadding = EdgeInsets.symmetric(
    horizontal: SkotiqTokens.spaceLg,
    vertical: SkotiqTokens.spaceMd,
  );

  /// Where [instant] falls between [sunset] and [sunrise], clamped to 0–1.
  ///
  /// Public so a caller — and the widget test — can check the marker without
  /// re-deriving the arithmetic.
  double fractionOf(DateTime instant) {
    final span = sunrise.difference(sunset).inMilliseconds;
    if (span <= 0) return 0;
    final offset = instant.difference(sunset).inMilliseconds;
    return (offset / span).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return SkotiqPanel(
      padding: panelPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ClipRRect(
            borderRadius: SkotiqTokens.borderRadiusSm,
            child: SizedBox(
              height: canvasHeight,
              child: CustomPaint(
                painter: _NightBandPainter(
                  colors: colors,
                  astroDark: fractionOf(astroDark),
                  astroDawn: fractionOf(astroDawn),
                  moonSet: moonSet == null ? null : fractionOf(moonSet!),
                  now: fractionOf(now),
                  altitude: targetAltitudeCurve,
                  windowStart: imageableWindow == null
                      ? null
                      : fractionOf(imageableWindow!.start),
                  windowEnd: imageableWindow == null
                      ? null
                      : fractionOf(imageableWindow!.end),
                ),
              ),
            ),
          ),
          SizedBox(
            height: legendHeight,
            child: _NightBandLegend(
              colors: colors,
              labels: <(double, String)>[
                for (final event in events)
                  (fractionOf(event.time), event.label),
              ],
              nowFraction: fractionOf(now),
              nowLabel: _formatNow(),
            ),
          ),
        ],
      ),
    );
  }

  /// The "now hh:mm" label, WITHOUT a leading caret glyph.
  ///
  /// The caret is drawn as a Lucide icon beside it rather than as a "▲" in the
  /// string: neither bundled font carries U+25B2, and the golden showed it as a
  /// tofu box.
  String _formatNow() {
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    return 'now $hh:$mm';
  }
}

class _NightBandPainter extends CustomPainter {
  _NightBandPainter({
    required this.colors,
    required this.astroDark,
    required this.astroDawn,
    required this.moonSet,
    required this.now,
    required this.altitude,
    required this.windowStart,
    required this.windowEnd,
  });

  final SkotiqColors colors;
  final double astroDark;
  final double astroDawn;
  final double? moonSet;
  final double now;
  final List<double>? altitude;
  final double? windowStart;
  final double? windowEnd;

  /// Dash length and gap for the astro-dark / astro-dawn verticals.
  static const double dashLength = 3;
  static const double dashGap = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // The sky. Five stops: dusk, twilight, the dark middle, twilight again,
    // dawn — the same shape the night has.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: <Color>[
            colors.bandDusk,
            colors.bandTwilight,
            colors.bandDark,
            colors.bandTwilight,
            colors.bandDawn,
          ],
          stops: const <double>[0, 0.14, 0.5, 0.86, 1],
        ).createShader(rect),
    );

    final hairline = Paint()
      ..color = colors.textPrimary.withValues(
        alpha: SkotiqTokens.opacityHairlineStrong,
      )
      ..strokeWidth = 1;
    _dashedVertical(canvas, size, astroDark, hairline);
    _dashedVertical(canvas, size, astroDawn, hairline);
    if (moonSet != null) _dashedVertical(canvas, size, moonSet!, hairline);

    _paintAltitude(canvas, size);
    _paintWindow(canvas, size);
    _paintNow(canvas, size);
  }

  void _dashedVertical(Canvas canvas, Size size, double x, Paint paint) {
    final dx = x * size.width;
    var y = 0.0;
    while (y < size.height) {
      canvas.drawLine(
        Offset(dx, y),
        Offset(dx, (y + dashLength).clamp(0.0, size.height)),
        paint,
      );
      y += dashLength + dashGap;
    }
  }

  void _paintAltitude(Canvas canvas, Size size) {
    final samples = altitude;
    if (samples == null || samples.length < 2) return;

    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final x = size.width * (i / (samples.length - 1));
      final y = size.height * (1 - samples[i].clamp(0.0, 1.0));
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..color = colors.primary.withValues(
          alpha: NightBand.altitudeFillOpacity,
        ),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = colors.primary
        ..style = PaintingStyle.stroke
        ..strokeWidth = NightBand.altitudeStrokeWidth,
    );
  }

  void _paintWindow(Canvas canvas, Size size) {
    final start = windowStart;
    final end = windowEnd;
    if (start == null || end == null || end <= start) return;
    canvas.drawRect(
      Rect.fromLTRB(
        start * size.width,
        size.height - NightBand.windowBarHeight,
        end * size.width,
        size.height,
      ),
      Paint()..color = colors.primary,
    );
  }

  void _paintNow(Canvas canvas, Size size) {
    final dx = now * size.width;
    canvas.drawLine(
      Offset(dx, 0),
      Offset(dx, size.height),
      Paint()
        ..color = colors.textPrimary
        ..strokeWidth = NightBand.nowLineWidth,
    );
    canvas.drawCircle(
      Offset(dx, NightBand.nowDotSize / 2),
      NightBand.nowDotSize / 2,
      Paint()..color = colors.textPrimary,
    );
  }

  @override
  bool shouldRepaint(_NightBandPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.astroDark != astroDark ||
      oldDelegate.astroDawn != astroDawn ||
      oldDelegate.moonSet != moonSet ||
      oldDelegate.now != now ||
      oldDelegate.altitude != altitude ||
      oldDelegate.windowStart != windowStart ||
      oldDelegate.windowEnd != windowEnd;
}

/// Where a legend label sits relative to the time it names.
enum _LabelAnchor { start, centre, end }

/// The legend: event labels on the first row at their own times, and the "now"
/// label on a second row so the two can never collide.
///
/// Labels are NEVER put in a fixed-width box. The first golden did exactly
/// that and clipped "20:48 astro dark" to "20:48 astro dar"; a label sizes
/// itself and is then slid into place, which is the only way a variable-length
/// string can be centred on a point.
class _NightBandLegend extends StatelessWidget {
  const _NightBandLegend({
    required this.colors,
    required this.labels,
    required this.nowFraction,
    required this.nowLabel,
  });

  final SkotiqColors colors;
  final List<(double fraction, String label)> labels;
  final double nowFraction;
  final String nowLabel;

  /// The caret drawn before the "now" label, in logical pixels.
  static const double caretSize = 10;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final shown = _labelsFor(
          width,
          _labelStyle(),
          MediaQuery.textScalerOf(context),
        );
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            for (var i = 0; i < shown.length; i++)
              _positioned(
                width: width,
                fraction: shown[i].$1,
                // The first label is left-aligned and the last right-aligned,
                // so neither hangs off the end of the band; the rest are
                // centred on their own time.
                anchor: i == 0
                    ? _LabelAnchor.start
                    : (i == shown.length - 1
                          ? _LabelAnchor.end
                          : _LabelAnchor.centre),
                child: Text(
                  shown[i].$2,
                  style: _labelStyle(),
                  maxLines: 1,
                  softWrap: false,
                ),
              ),
            _positioned(
              width: width,
              fraction: nowFraction,
              anchor: _LabelAnchor.centre,
              top: NightBand.legendHeight - NightBand.nowRowHeight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  // A Lucide glyph, not "▲": neither bundled font carries
                  // U+25B2, and the first golden drew it as a tofu box.
                  Icon(
                    LucideIcons.chevronUp,
                    size: caretSize,
                    color: colors.brandWarm,
                  ),
                  Text(
                    nowLabel,
                    style: SkotiqTypography.monoCaption.copyWith(
                      color: colors.brandWarm,
                    ),
                    maxLines: 1,
                    softWrap: false,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// The smallest gap left between two event labels. Closer than this they
  /// read as one string ("21:14 sunset22:38 astro dark"), so the middle one is
  /// dropped instead.
  static const double labelGap = SkotiqTokens.spaceMd;

  TextStyle _labelStyle() =>
      SkotiqTypography.monoCaption.copyWith(color: colors.textMuted);

  /// The labels that fit in [width].
  ///
  /// Narrow, that is the first and the last — never all of them squeezed
  /// together. 07 is explicit: reduce content, do not shrink type.
  ///
  /// Wider, a middle label still goes when it would come within [labelGap] of
  /// a neighbor. How close sunset and astro dark sit depends on the date and
  /// the latitude, not only the width: at a 1536 px window an October night at
  /// 35° N put the two labels edge to edge. The canvas draws both moments as
  /// dashed verticals, so a dropped word loses nothing the picture lacks.
  List<(double, String)> _labelsFor(
    double width,
    TextStyle style,
    TextScaler textScaler,
  ) {
    if (labels.length <= 2) return labels;
    if (width < NightBand.legendCompactWidth) {
      return <(double, String)>[labels.first, labels.last];
    }

    double measure(String text) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
        maxLines: 1,
      )..layout();
      final measured = painter.width;
      painter.dispose();
      return measured;
    }

    final firstRight = measure(labels.first.$2);
    final lastLeft = width - measure(labels.last.$2);
    final kept = <(double, String)>[labels.first];
    var previousRight = firstRight;
    for (final label in labels.sublist(1, labels.length - 1)) {
      final labelWidth = measure(label.$2);
      final center = label.$1.clamp(0.0, 1.0) * width;
      final left = center - labelWidth / 2;
      final right = center + labelWidth / 2;
      if (left - previousRight < labelGap || lastLeft - right < labelGap) {
        continue;
      }
      kept.add(label);
      previousRight = right;
    }
    kept.add(labels.last);
    return kept;
  }

  Widget _positioned({
    required double width,
    required double fraction,
    required _LabelAnchor anchor,
    required Widget child,
    double top = 0,
  }) {
    final x = fraction.clamp(0.0, 1.0) * width;
    return switch (anchor) {
      _LabelAnchor.start => Positioned(left: 0, top: top, child: child),
      _LabelAnchor.end => Positioned(right: 0, top: top, child: child),
      // The label sizes itself, then slides half its own width left so its
      // CENTRE lands on the time. A fixed box cannot do that without clipping.
      _LabelAnchor.centre => Positioned(
        left: x,
        top: top,
        child: FractionalTranslation(
          translation: const Offset(-0.5, 0),
          child: child,
        ),
      ),
    };
  }
}
