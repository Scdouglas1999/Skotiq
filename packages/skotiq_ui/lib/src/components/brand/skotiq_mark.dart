import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../theme/skotiq_colors.dart';
import '../../utils/animation_duration.dart';
import '../../utils/on_screen_animation_gate.dart';
import 'trails_geometry.dart';

/// What the mark is doing, mirroring the approved motion set in
/// `brand-ref/motion_reference.html`.
enum SkotiqMarkMotion {
  /// The still mark.
  none,

  /// Startup: each trail draws on in turn, staggered 90 ms apart with
  /// cubic-bezier(.22,.7,.2,1), then the pole star pops in. Plays once.
  draw,

  /// Indeterminate wait: lanes rest at 16% opacity while a dash 24% of the
  /// path travels each lane on a 2.2 s cycle, phase-offset per lane.
  loading,

  /// A run in progress: the still mark plus a white highlight, 10% of the
  /// path at up to 75% opacity, sweeping every lane in sync on a 2.6 s cycle.
  working,
}

/// Motion timings, ported from the CSS keyframes in
/// `brand-ref/motion_reference.html`. The reference wraps its one-shot in a
/// 4.2 s demo loop; the values below are the unwrapped absolute timings —
/// lanes draw for 1176 ms (the loop's 28%), staggered 90 ms, and the pole
/// pop lands at 1092/1386/1596 ms (26/33/38%).
abstract final class TrailsMotion {
  TrailsMotion._();

  /// Delay between one lane's draw-on and the next.
  static const Duration drawStagger = Duration(milliseconds: 90);

  /// How long one lane takes to draw on.
  static const Duration drawLane = Duration(milliseconds: 1176);

  /// cubic-bezier(.22,.7,.2,1) — the draw-on easing.
  static const Cubic drawCurve = Cubic(0.22, 0.7, 0.2, 1);

  /// Pole-star pop: invisible until 1092 ms, overshoots to 1.25× by 1386 ms,
  /// settles at 1× by 1596 ms.
  static const int drawPoleStartMs = 1092;
  static const int drawPolePeakMs = 1386;
  static const int drawPoleSettleMs = 1596;
  static const double drawPoleOvershoot = 1.25;

  /// Loading: 2.2 s linear cycle, a dash 0.24 of the path long, lanes
  /// resting at 16% opacity underneath.
  static const Duration loadingCycle = Duration(milliseconds: 2200);
  static const double loadingDashFraction = 0.24;
  static const double loadingBaseOpacity = 0.16;

  /// Working: 2.6 s cycle, a white dash 0.1 of the path long, stroke 1.6,
  /// peaking at 75% opacity, eased by cubic-bezier(.45,0,.25,1).
  static const Duration workingCycle = Duration(milliseconds: 2600);
  static const double glintDashFraction = 0.1;
  static const double glintStrokeWidth = 1.6;
  static const double glintPeakOpacity = 0.75;
  static const Cubic glintCurve = Cubic(0.45, 0, 0.25, 1);

  /// The glint's dash offset eases from .1 to -.95 over the first 88% of the
  /// cycle — one full sweep of every lane — then it is invisible for the
  /// remainder.
  static const double glintTravelEnd = 0.88;
  static const Color glintColor = Color(0xFFFFFFFF);

  /// Total duration of one [SkotiqMarkMotion.draw] pass for [spec]: the
  /// pole pop's settle time when the level has a pole star, otherwise the
  /// last lane's draw end.
  static Duration drawDuration(TrailsLevelSpec spec) {
    if (spec.poleRadius > 0) {
      return const Duration(milliseconds: drawPoleSettleMs);
    }
    return Duration(
      milliseconds:
          (spec.lanes.length - 1) * drawStagger.inMilliseconds +
          drawLane.inMilliseconds,
    );
  }

  /// Fraction of lane [index] drawn at [ms] into the draw pass.
  static double drawLaneFraction(int index, double ms) {
    final u =
        ((ms - index * drawStagger.inMilliseconds) / drawLane.inMilliseconds)
            .clamp(0.0, 1.0);
    return u <= 0 || u >= 1 ? u : drawCurve.transform(u);
  }

  /// (scale, opacity) of the pole star at [ms] into the draw pass.
  static (double, double) drawPole(double ms) {
    if (ms <= drawPoleStartMs) return (0, 0);
    if (ms <= drawPolePeakMs) {
      final u = Curves.easeOut.transform(
        (ms - drawPoleStartMs) / (drawPolePeakMs - drawPoleStartMs),
      );
      return (drawPoleOvershoot * u, u);
    }
    if (ms <= drawPoleSettleMs) {
      final u = Curves.easeOut.transform(
        (ms - drawPolePeakMs) / (drawPoleSettleMs - drawPolePeakMs),
      );
      return (drawPoleOvershoot - (drawPoleOvershoot - 1) * u, 1);
    }
    return (1, 1);
  }

  /// Start of lane [index]'s travelling dash, as a fraction of the lane's
  /// length, at cycle position [t] ∈ [0,1). Phase offsets follow the
  /// reference demo: −0.25 s per lane at `full`, −0.5 s at `mid`/`flat`.
  static double loadingDashStart(int index, TrailsLevelSpec spec, double t) {
    final step =
        spec.loadingPhaseStep.inMilliseconds / loadingCycle.inMilliseconds;
    return (t + index * step) % 1.0;
  }

  /// Opacity of the `working` glint at cycle position [t] ∈ [0,1): 0 → .75
  /// over the first 12%, held to 70%, back to 0 by 88%.
  static double glintOpacity(double t) {
    if (t <= 0.12) return glintPeakOpacity * glintCurve.transform(t / 0.12);
    if (t <= 0.70) return glintPeakOpacity;
    if (t <= glintTravelEnd) {
      return glintPeakOpacity *
          (1 - glintCurve.transform((t - 0.70) / (glintTravelEnd - 0.70)));
    }
    return 0;
  }

  /// Start of the `working` glint, as a fraction of the lane's length, at
  /// cycle position [t] ∈ [0,1). The dash's leading edge sweeps the whole
  /// path once — offset .1 → -.95 with pathLength 1.
  static double glintStart(double t) {
    final u = (t / glintTravelEnd).clamp(0.0, 1.0);
    return (1.05 * glintCurve.transform(u) - 0.1) % 1.0;
  }
}

/// The Skotiq "Trails" mark — the S drawn by five star trails.
///
/// Flat vector only, round line caps, no gradients or glows. Geometry comes
/// from `trails_geometry.dart`, motion from [TrailsMotion]; both are exact
/// ports of the approved references.
///
/// [SkotiqMarkMotion.loading] and [SkotiqMarkMotion.working] are looping
/// animations; they run only while the mark is actually painted
/// ([OnScreenAnimationGate]) and render as the still mark when
/// [MediaQuery.disableAnimations] is set. In red night mode the
/// accent-following [SkotiqMarkTone.theme] and the fixed
/// [SkotiqMarkTone.violet] both render as [SkotiqMarkTone.red].
class SkotiqMark extends StatefulWidget {
  const SkotiqMark({
    super.key,
    this.size = 64,
    this.motion = SkotiqMarkMotion.none,
    this.tone = SkotiqMarkTone.theme,
    this.color,
    this.themeAccent,
    this.tile = false,
    this.semanticLabel,
    this.onDrawComplete,
  });

  /// Width and height in logical pixels; picks the detail level
  /// ([trailsLevelForSize]).
  final double size;

  /// The mark's motion; all of them fall back to the still mark when
  /// animations are disabled.
  final SkotiqMarkMotion motion;

  /// The colorway. In red night mode, [SkotiqMarkTone.theme] and
  /// [SkotiqMarkTone.violet] both render as [SkotiqMarkTone.red].
  final SkotiqMarkTone tone;

  /// One color for every lane — the `currentColor` behavior the `mono` tone
  /// exists for. When null, `mono` resolves its color from
  /// [IconTheme]/[DefaultTextStyle]; other tones use their palette.
  final Color? color;

  /// The accent [SkotiqMarkTone.theme] derives its cool lanes from —
  /// the ambient [SkotiqColors.primary] when null. Settings' accent
  /// swatches set it so each swatch previews the mark in ITS accent.
  final Color? themeAccent;

  /// Whether to draw the rounded app-icon tile behind the mark (`#0E0C16`,
  /// corner radius 22.5% of the side; `#000` under the red colorway).
  final bool tile;

  /// Accessibility label. When null the mark is decorative and publishes no
  /// semantics.
  final String? semanticLabel;

  /// Called once when a [SkotiqMarkMotion.draw] pass completes — the splash
  /// screen's hand-off signal. Also fires when animations are disabled and
  /// the still mark stands in for the draw.
  final VoidCallback? onDrawComplete;

  @override
  State<SkotiqMark> createState() => _SkotiqMarkState();
}

class _SkotiqMarkState extends State<SkotiqMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _animationsDisabled = false;
  bool _drawCompleteFired = false;

  /// The motion inputs the controller was last configured for, so a routine
  /// dependency change doesn't restart a draw or a loop mid-flight.
  (SkotiqMarkMotion, bool, TrailsLevel)? _appliedMotion;

  /// Test-only view of the motion controller.
  @visibleForTesting
  AnimationController get debugControllerForTesting => _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this)
      ..addStatusListener(_handleStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final disabled = animationsDisabled(context);
    if (disabled != _animationsDisabled) {
      _animationsDisabled = disabled;
    }
    _syncMotion();
  }

  @override
  void didUpdateWidget(SkotiqMark oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMotion();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _syncMotion() {
    final key = (
      widget.motion,
      _animationsDisabled,
      trailsLevelForSize(widget.size),
    );
    if (key == _appliedMotion) return;
    _appliedMotion = key;
    _controller.stop();
    switch (widget.motion) {
      case SkotiqMarkMotion.draw:
        _controller.duration = TrailsMotion.drawDuration(trailsLevels[key.$3]!);
        if (_animationsDisabled) {
          // The still mark stands in for the draw, but the splash hand-off
          // must not be swallowed — report completion after this frame.
          _controller.value = 1;
          _scheduleDrawComplete();
        } else {
          _drawCompleteFired = false;
          _controller.forward(from: 0);
        }
      case SkotiqMarkMotion.loading:
        _controller.duration = TrailsMotion.loadingCycle;
      case SkotiqMarkMotion.working:
        _controller.duration = TrailsMotion.workingCycle;
      case SkotiqMarkMotion.none:
    }
  }

  void _handleStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed &&
        widget.motion == SkotiqMarkMotion.draw) {
      _fireDrawComplete();
    }
  }

  void _scheduleDrawComplete() {
    if (_drawCompleteFired) return;
    _drawCompleteFired = true;
    // Firing inside a status listener is fine, but this path also runs from
    // didChangeDependencies — post the call so a subscriber can safely
    // setState in it.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.motion == SkotiqMarkMotion.draw) {
        widget.onDrawComplete?.call();
      }
    });
  }

  void _fireDrawComplete() {
    if (_drawCompleteFired) return;
    _drawCompleteFired = true;
    widget.onDrawComplete?.call();
  }

  @override
  Widget build(BuildContext context) {
    final spec = trailsLevels[trailsLevelForSize(widget.size)]!;
    final colors = context.skotiqColors;
    var tone = widget.tone;
    // Red night is a wavelength constraint, not a palette: violet would leak
    // blue light into a dark-adapted UI, and so would the accent-derived
    // `theme` ramp — both map to the red colorway.
    if ((tone == SkotiqMarkTone.violet || tone == SkotiqMarkTone.theme) &&
        colors.isRedNight) {
      tone = SkotiqMarkTone.red;
    }

    final List<Color> laneColors;
    final Color poleColor;
    final monoColor =
        widget.color ??
        IconTheme.of(context).color ??
        DefaultTextStyle.of(context).style.color;
    if (tone == SkotiqMarkTone.mono || widget.color != null) {
      final c = monoColor ?? trailsPalettes[SkotiqMarkTone.mono]![0];
      laneColors = List<Color>.filled(spec.lanes.length, c);
      poleColor = c;
    } else if (tone == SkotiqMarkTone.theme) {
      // The app-icon tile is always dark, so the lane stops and the warm
      // lane are the dark-ground recipe even when the ambient theme is
      // light — the tile renders the mark's icon look, not its panel look.
      final lightGround =
          !widget.tile && colors.surface.computeLuminance() > 0.5;
      final ramp = themeTrailsRamp(
        widget.themeAccent ?? colors.primary,
        brandWarm: lightGround ? colors.brandWarm : SkotiqColors.dark.brandWarm,
        lightGround: lightGround,
      );
      laneColors = [for (final k in spec.pick) ramp[k]];
      poleColor = ramp[4];
    } else {
      final palette = trailsPalettes[tone]!;
      laneColors = [for (final k in spec.pick) palette[k]];
      poleColor = palette[3];
    }

    final effectiveMotion = _animationsDisabled
        ? SkotiqMarkMotion.none
        : widget.motion;
    final animated = effectiveMotion != SkotiqMarkMotion.none;

    Widget mark = SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: TrailsMarkPainter(
          spec: spec,
          laneColors: laneColors,
          poleColor: poleColor,
          tile: widget.tile,
          tileGround: tone == SkotiqMarkTone.red
              ? TrailsGeometry.tileGroundRed
              : TrailsGeometry.tileGround,
          motion: effectiveMotion,
          progress: animated ? _controller : null,
        ),
        isComplex: true,
        willChange: animated,
      ),
    );

    // The boundary stays OUTSIDE the gate: a repaint boundary inside it would
    // swallow the repaints the gate counts as proof the child is on screen.
    mark = switch (effectiveMotion) {
      SkotiqMarkMotion.loading || SkotiqMarkMotion.working => RepaintBoundary(
        child: OnScreenAnimationGate(
          controller: _controller,
          repeating: true,
          child: mark,
        ),
      ),
      _ => RepaintBoundary(child: mark),
    };

    if (widget.semanticLabel != null) {
      mark = Semantics(image: true, label: widget.semanticLabel, child: mark);
    }
    return mark;
  }
}

/// Paints the mark. Owns the lane paths and their metrics; per frame it
/// allocates nothing but the `extractPath` sub-paths the dash motions are
/// defined by.
class TrailsMarkPainter extends CustomPainter {
  TrailsMarkPainter({
    required this.spec,
    required this.laneColors,
    required this.poleColor,
    required this.tile,
    required this.tileGround,
    required this.motion,
    this.progress,
  }) : super(repaint: progress);

  /// Which detail level's lanes, stroke and pole to paint.
  final TrailsLevelSpec spec;

  /// Resolved lane colors, outermost to innermost.
  final List<Color> laneColors;

  /// Pole-star color — the palette's index 3, or the mono color.
  final Color poleColor;

  /// Whether to draw the rounded app-icon tile behind the mark.
  final bool tile;

  /// Tile fill — `#0E0C16`, or `#000` under the red colorway.
  final Color tileGround;

  /// Which motion to paint; `none` paints the still mark.
  final SkotiqMarkMotion motion;

  /// Cycle position: draw fraction for `draw` (0–1 over the draw duration),
  /// loop phase for `loading`/`working`. Also the repaint listenable — when
  /// set, the painter repaints every tick without rebuilding the widget.
  final Animation<double>? progress;

  late final List<Path> _paths = [
    for (final lane in spec.lanes) trailsLanePath(lane),
  ];
  late final List<ui.PathMetric> _metrics = [
    for (final path in _paths) path.computeMetrics().first,
  ];

  final Paint _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  final Paint _fill = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / TrailsGeometry.viewBox);
    if (tile) {
      _fill.color = tileGround;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(
            0,
            0,
            TrailsGeometry.viewBox,
            TrailsGeometry.viewBox,
          ),
          const Radius.circular(
            TrailsGeometry.viewBox * TrailsGeometry.tileRadiusFraction,
          ),
        ),
        _fill,
      );
    }
    // The reference's icon transform: the S zoomed to fill the tile.
    canvas
      ..translate(50, 50)
      ..scale(TrailsGeometry.markScale)
      ..translate(-50, -50.5);
    switch (motion) {
      case SkotiqMarkMotion.draw:
        _paintDraw(
          canvas,
          (progress?.value ?? 1) *
              TrailsMotion.drawDuration(spec).inMilliseconds,
        );
      case SkotiqMarkMotion.loading:
        _paintLoading(canvas, progress?.value ?? 0);
      case SkotiqMarkMotion.working:
        _paintWorking(canvas, progress?.value ?? 0);
      case SkotiqMarkMotion.none:
        _paintStill(canvas);
    }
    canvas.restore();
  }

  void _paintStill(Canvas canvas) {
    for (var i = 0; i < _paths.length; i++) {
      _stroke
        ..color = laneColors[i]
        ..strokeWidth = spec.strokeWidth;
      canvas.drawPath(_paths[i], _stroke);
    }
    _paintPole(canvas, 1, 1);
  }

  void _paintDraw(Canvas canvas, double ms) {
    for (var i = 0; i < _paths.length; i++) {
      final fraction = TrailsMotion.drawLaneFraction(i, ms);
      if (fraction <= 0) continue;
      _stroke
        ..color = laneColors[i]
        ..strokeWidth = spec.strokeWidth;
      if (fraction >= 1) {
        canvas.drawPath(_paths[i], _stroke);
      } else {
        canvas.drawPath(
          _metrics[i].extractPath(0, fraction * _metrics[i].length),
          _stroke,
        );
      }
    }
    final (scale, opacity) = TrailsMotion.drawPole(ms);
    _paintPole(canvas, scale, opacity);
  }

  void _paintLoading(Canvas canvas, double t) {
    _stroke.strokeWidth = spec.strokeWidth;
    for (var i = 0; i < _paths.length; i++) {
      _stroke.color = laneColors[i].withValues(
        alpha: laneColors[i].a * TrailsMotion.loadingBaseOpacity,
      );
      canvas.drawPath(_paths[i], _stroke);
    }
    for (var i = 0; i < _paths.length; i++) {
      _stroke.color = laneColors[i];
      _drawDash(
        canvas,
        i,
        TrailsMotion.loadingDashStart(i, spec, t) * _metrics[i].length,
        TrailsMotion.loadingDashFraction * _metrics[i].length,
      );
    }
    _paintPole(canvas, 1, 1);
  }

  void _paintWorking(Canvas canvas, double t) {
    _paintStill(canvas);
    final opacity = TrailsMotion.glintOpacity(t);
    if (opacity <= 0) return;
    _stroke
      ..color = TrailsMotion.glintColor.withValues(alpha: opacity)
      ..strokeWidth = TrailsMotion.glintStrokeWidth;
    final start = TrailsMotion.glintStart(t);
    for (var i = 0; i < _paths.length; i++) {
      _drawDash(
        canvas,
        i,
        start * _metrics[i].length,
        TrailsMotion.glintDashFraction * _metrics[i].length,
      );
    }
  }

  /// Paints the [start, start + length] slice of lane [index], wrapping
  /// around the path end — a travelling dash is a circular window on the
  /// lane, not a clamp.
  void _drawDash(Canvas canvas, int index, double start, double length) {
    final metric = _metrics[index];
    final total = metric.length;
    final s = start % total;
    final end = s + length;
    if (end <= total) {
      canvas.drawPath(metric.extractPath(s, end), _stroke);
    } else {
      canvas
        ..drawPath(metric.extractPath(s, total), _stroke)
        ..drawPath(metric.extractPath(0, end - total), _stroke);
    }
  }

  void _paintPole(Canvas canvas, double scale, double opacity) {
    if (spec.poleRadius <= 0 || scale <= 0 || opacity <= 0) return;
    _fill.color = poleColor.withValues(alpha: poleColor.a * opacity);
    canvas
      ..save()
      ..translate(TrailsGeometry.poleCenter.dx, TrailsGeometry.poleCenter.dy)
      ..scale(scale);
    canvas.drawCircle(Offset.zero, spec.poleRadius, _fill);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant TrailsMarkPainter old) {
    return spec != old.spec ||
        motion != old.motion ||
        tile != old.tile ||
        tileGround != old.tileGround ||
        poleColor != old.poleColor ||
        !_listEquals(laneColors, old.laneColors) ||
        progress != old.progress;
  }

  static bool _listEquals(List<Color> a, List<Color> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
