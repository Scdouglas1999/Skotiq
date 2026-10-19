import 'package:flutter/material.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';

/// How far a [NightTimelineSpan] has got.
enum NightTimelineSpanState {
  /// Already imaged: a solid fill.
  done,

  /// The window being imaged now, drawn under its own done part.
  active,

  /// A window still to come.
  planned,
}

/// One window on a [NightTimelineStrip], e.g. the time a target is imaged.
@immutable
class NightTimelineSpan {
  const NightTimelineSpan({
    required this.start,
    required this.end,
    required this.state,
  });

  final DateTime start;
  final DateTime end;
  final NightTimelineSpanState state;

  @override
  bool operator ==(Object other) =>
      other is NightTimelineSpan &&
      other.start == start &&
      other.end == end &&
      other.state == state;

  @override
  int get hashCode => Object.hash(start, end, state);
}

/// One word group in the row under a [NightTimelineStrip].
@immutable
class NightTimelineLabel {
  /// Laid out left to right, spaced between. [emphasized] marks the "now"
  /// label, drawn in `textPrimary` and never dropped for width.
  const NightTimelineLabel(this.text, {this.emphasized = false});

  final String text;
  final bool emphasized;

  @override
  bool operator ==(Object other) =>
      other is NightTimelineLabel &&
      other.text == text &&
      other.emphasized == emphasized;

  @override
  int get hashCode => Object.hash(text, emphasized);
}

/// The compact night timeline in the Tonight header: sunset at the left edge,
/// sunrise at the right, the astronomical dark band, several imaging windows
/// and a "now" marker, with a row of labels beneath.
///
/// [NightBand] is the big picture of one target's night; this is the 14 px
/// strip that fits beside the run controls, and it takes any number of
/// windows. The strip itself carries no text, so the whole widget reads to
/// assistive technology as the one [semanticLabel] sentence.
class NightTimelineStrip extends StatelessWidget {
  const NightTimelineStrip({
    super.key,
    required this.start,
    required this.end,
    this.darkStart,
    this.darkEnd,
    required this.now,
    this.spans = const <NightTimelineSpan>[],
    this.labels = const <NightTimelineLabel>[],
    required this.semanticLabel,
    this.width,
  });

  /// Sunset: the left edge.
  final DateTime start;

  /// Sunrise: the right edge.
  final DateTime end;

  /// Astronomical dark, if the night reaches it. Both ends are needed to draw
  /// the band; with either missing there is no band.
  final DateTime? darkStart;
  final DateTime? darkEnd;

  /// The marker. Clamped to the strip, so a "now" before sunset sits at the
  /// left edge rather than off the widget.
  final DateTime now;

  /// The windows. Painted planned first, then active, then done, whatever the
  /// list order, so a done part always sits on top of its active window.
  final List<NightTimelineSpan> spans;

  /// The row under the strip.
  final List<NightTimelineLabel> labels;

  /// One sentence that says what the strip shows, built from the same data.
  final String semanticLabel;

  /// A fixed width. Null fills the width the parent offers.
  final double? width;

  /// The painted strip's height.
  static const double stripHeight = 14;

  /// The track's height, centered in the strip.
  static const double trackHeight = 8;

  /// A window's height, centered in the strip.
  static const double spanHeight = 6;

  /// A window's corner radius.
  static const double spanRadius = 2;

  /// The "now" marker's width. It spans the full [stripHeight].
  static const double nowWidth = 2;

  /// Gap between the strip and the labels row.
  static const double labelsGap = 3;

  /// The smallest gap between two labels. Closer than this a middle label is
  /// dropped instead.
  static const double labelGap = SkotiqTokens.spaceSm;

  /// Alpha of an active window's fill. The fill is only a tint; the window
  /// reads by its [activeEdgeWidth] outline in full `primary`. A tint strong
  /// enough to clear 3:1 on the light track could not also be told apart from
  /// the solid done fill, so the edge carries the contrast instead.
  static const double activeAlpha = 0.3;

  /// The active window's outline.
  static const double activeEdgeWidth = 1;

  /// The ground-colored halo either side of the "now" marker. The marker is
  /// `textPrimary` and the done fill beside it is `primary`, which measured
  /// 2.3:1 against each other on the dark and red-night palettes; the halo
  /// keeps the marker on a ground it clears.
  static const double nowHalo = 1;

  /// Alpha of a planned window.
  static const double plannedAlpha = 0.75;

  /// Where [instant] falls between [start] and [end], clamped to 0 to 1.
  double fractionOf(DateTime instant) {
    final span = end.difference(start).inMilliseconds;
    if (span <= 0) return 0;
    return (instant.difference(start).inMilliseconds / span).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final palette = NightTimelinePalette.of(colors);
    final dark = darkStart != null && darkEnd != null
        ? (fractionOf(darkStart!), fractionOf(darkEnd!))
        : null;

    Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        RepaintBoundary(
          child: SizedBox(
            height: stripHeight,
            child: CustomPaint(
              painter: _NightTimelinePainter(
                palette: palette,
                dark: dark,
                now: fractionOf(now),
                spans: <(double, double, NightTimelineSpanState)>[
                  for (final span in spans)
                    (fractionOf(span.start), fractionOf(span.end), span.state),
                ],
              ),
            ),
          ),
        ),
        if (labels.isNotEmpty) ...<Widget>[
          const SizedBox(height: labelsGap),
          _LabelsRow(labels: labels, colors: colors),
        ],
      ],
    );
    if (width != null) content = SizedBox(width: width, child: content);

    return Semantics(
      container: true,
      label: semanticLabel,
      child: ExcludeSemantics(child: content),
    );
  }
}

/// The colors a [NightTimelineStrip] paints with, resolved from a palette.
///
/// Public so the contrast test measures exactly what the painter draws.
@immutable
class NightTimelinePalette {
  const NightTimelinePalette({
    required this.track,
    required this.darkBand,
    required this.done,
    required this.active,
    required this.activeEdge,
    required this.planned,
    required this.now,
    required this.halo,
  });

  /// The track is the twilight part of the night and the dark band is the
  /// deeper part, which means DARKER on every palette. `bandDark` is that on
  /// the dark and red-night palettes; the light palette's `bandDark` is a
  /// navy that a violet window cannot be told apart from (2.7:1), so the
  /// light strip deepens to `borderHighlight` instead.
  factory NightTimelinePalette.of(SkotiqColors colors) {
    final lightGround =
        colors.background.computeLuminance() >
        colors.textPrimary.computeLuminance();
    final track = colors.surfaceHover;
    final darkBand = lightGround ? colors.borderHighlight : colors.bandDark;
    return NightTimelinePalette(
      track: track,
      darkBand: darkBand,
      done: colors.primary,
      active: colors.primary.withValues(alpha: NightTimelineStrip.activeAlpha),
      activeEdge: colors.primary,
      planned: colors.brandWarm.withValues(
        alpha: NightTimelineStrip.plannedAlpha,
      ),
      now: colors.textPrimary,
      halo: colors.background,
    );
  }

  final Color track;
  final Color darkBand;
  final Color done;

  /// The active window's tint.
  final Color active;

  /// The active window's outline.
  final Color activeEdge;
  final Color planned;
  final Color now;

  /// Drawn either side of [now].
  final Color halo;

  Color forState(NightTimelineSpanState state) => switch (state) {
    NightTimelineSpanState.done => done,
    NightTimelineSpanState.active => active,
    NightTimelineSpanState.planned => planned,
  };

  @override
  bool operator ==(Object other) =>
      other is NightTimelinePalette &&
      other.track == track &&
      other.darkBand == darkBand &&
      other.done == done &&
      other.active == active &&
      other.activeEdge == activeEdge &&
      other.planned == planned &&
      other.now == now &&
      other.halo == halo;

  @override
  int get hashCode => Object.hash(
    track,
    darkBand,
    done,
    active,
    activeEdge,
    planned,
    now,
    halo,
  );
}

class _NightTimelinePainter extends CustomPainter {
  _NightTimelinePainter({
    required this.palette,
    required this.dark,
    required this.now,
    required this.spans,
  });

  final NightTimelinePalette palette;
  final (double, double)? dark;
  final double now;
  final List<(double, double, NightTimelineSpanState)> spans;

  static const _paintOrder = <NightTimelineSpanState>[
    NightTimelineSpanState.planned,
    NightTimelineSpanState.active,
    NightTimelineSpanState.done,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final trackTop = (size.height - NightTimelineStrip.trackHeight) / 2;
    final trackRect = Rect.fromLTWH(
      0,
      trackTop,
      w,
      NightTimelineStrip.trackHeight,
    );
    final trackRRect = RRect.fromRectAndRadius(
      trackRect,
      const Radius.circular(NightTimelineStrip.trackHeight / 2),
    );
    canvas.drawRRect(trackRRect, Paint()..color = palette.track);

    final band = dark;
    if (band != null && band.$2 > band.$1) {
      canvas.save();
      canvas.clipRRect(trackRRect);
      canvas.drawRect(
        Rect.fromLTRB(
          band.$1 * w,
          trackRect.top,
          band.$2 * w,
          trackRect.bottom,
        ),
        Paint()..color = palette.darkBand,
      );
      canvas.restore();
    }

    final spanTop = (size.height - NightTimelineStrip.spanHeight) / 2;
    for (final state in _paintOrder) {
      final fill = Paint()..color = palette.forState(state);
      for (final span in spans) {
        if (span.$3 != state || span.$2 <= span.$1) continue;
        final rect = Rect.fromLTRB(
          span.$1 * w,
          spanTop,
          span.$2 * w,
          spanTop + NightTimelineStrip.spanHeight,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            rect,
            const Radius.circular(NightTimelineStrip.spanRadius),
          ),
          fill,
        );
        if (state == NightTimelineSpanState.active) {
          // Inset by half the stroke so the outline stays inside the bar.
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              rect.deflate(NightTimelineStrip.activeEdgeWidth / 2),
              const Radius.circular(NightTimelineStrip.spanRadius),
            ),
            Paint()
              ..color = palette.activeEdge
              ..style = PaintingStyle.stroke
              ..strokeWidth = NightTimelineStrip.activeEdgeWidth,
          );
        }
      }
    }

    // The marker is centered on its time but kept wholly inside the strip,
    // halo included.
    const halo = NightTimelineStrip.nowHalo;
    const marker = NightTimelineStrip.nowWidth;
    final x = (now * w - marker / 2).clamp(
      halo,
      (w - marker - halo).clamp(halo, double.infinity),
    );
    canvas.drawRect(
      Rect.fromLTWH(x - halo, 0, marker + 2 * halo, size.height),
      Paint()..color = palette.halo,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(x, 0, marker, size.height),
        const Radius.circular(marker / 2),
      ),
      Paint()..color = palette.now,
    );
  }

  @override
  bool shouldRepaint(_NightTimelinePainter oldDelegate) =>
      oldDelegate.palette != palette ||
      oldDelegate.dark != dark ||
      oldDelegate.now != now ||
      !_listEquals(oldDelegate.spans, spans);

  static bool _listEquals<T>(List<T> a, List<T> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The labels, spaced between. When they do not fit, middle labels go from
/// the right until they do; the first, the last and the emphasized label
/// stay. The type never shrinks.
class _LabelsRow extends StatelessWidget {
  const _LabelsRow({required this.labels, required this.colors});

  final List<NightTimelineLabel> labels;
  final SkotiqColors colors;

  TextStyle _style(NightTimelineLabel label) =>
      SkotiqTypography.captionSm.copyWith(
        color: label.emphasized ? colors.textPrimary : colors.textMuted,
      );

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final (shown, fits) = _fit(constraints.maxWidth, scaler);
        Widget text(NightTimelineLabel label) => Text(
          label.text,
          style: _style(label),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
        );
        return Row(
          mainAxisAlignment: shown.length == 1
              ? MainAxisAlignment.center
              : MainAxisAlignment.spaceBetween,
          children: <Widget>[
            // Flexible only when even the kept labels overflow, a width too
            // narrow for any honest layout; then they ellipsize. A Flexible
            // row splits the width EQUALLY, so using it when the labels fit
            // cut the longest one short while the short ones had room.
            for (final label in shown)
              fits ? text(label) : Flexible(child: text(label)),
          ],
        );
      },
    );
  }

  /// The labels to show in [width], and whether they fit at their own width.
  (List<NightTimelineLabel>, bool) _fit(double width, TextScaler scaler) {
    if (!width.isFinite) return (labels, true);
    double measure(NightTimelineLabel label) {
      final painter = TextPainter(
        text: TextSpan(text: label.text, style: _style(label)),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final measured = painter.width;
      painter.dispose();
      return measured;
    }

    final widths = <double>[for (final label in labels) measure(label)];
    final kept = List<int>.generate(labels.length, (i) => i);
    double needed() =>
        kept.fold<double>(0, (sum, i) => sum + widths[i]) +
        NightTimelineStrip.labelGap * (kept.length - 1);

    while (needed() > width) {
      final drop = kept.lastIndexWhere(
        (i) => i != 0 && i != labels.length - 1 && !labels[i].emphasized,
      );
      if (drop < 0) break;
      kept.removeAt(drop);
    }
    return (
      <NightTimelineLabel>[for (final i in kept) labels[i]],
      needed() <= width,
    );
  }
}
