import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'narrator_detail_sheet.dart';

/// Shared visual language for Night Narrator events.
///
/// This file is the foundation the other Narrator surfaces (the imaging ticker
/// and the Analytics "Night Story" timeline) import: [NarratorVisuals] resolves
/// the category icon + severity accent, [NarratorEvidenceViz] renders any of
/// the four evidence payloads generically, and [NarratorCard] is the compact
/// feed row.
///
/// Design language (see `docs/night_narrator_design.md`):
///   * Category icon: discovery `sparkles`, milestone `trophy`, conditions
///     `cloudMoon`, equipment `wrench`, quality `gauge`.
///   * Severity is a *subtle* left-edge accent — never a filled alarm box.
///   * `celebrate` gets a distinct treatment: an accent gradient edge and a
///     slightly emphasised micro-viz. Tasteful, not gaudy.
class NarratorVisuals {
  const NarratorVisuals._();

  /// The lucide category icon for [category].
  static IconData iconFor(NarratorCategory category) {
    return switch (category) {
      NarratorCategory.discovery => LucideIcons.sparkles,
      NarratorCategory.milestone => LucideIcons.trophy,
      NarratorCategory.conditions => LucideIcons.cloudMoon,
      NarratorCategory.equipment => LucideIcons.wrench,
      NarratorCategory.quality => LucideIcons.gauge,
    };
  }

  /// The accent colour for [severity], drawn from the active palette. Used for
  /// the left-edge accent, the category icon tint, and the evidence viz.
  static Color accentFor(NarratorSeverity severity, SkotiqColors colors) {
    return switch (severity) {
      // `celebrate` leans on the brand accent — the most "special" tint we
      // have — rather than success-green, so discoveries read as a moment.
      NarratorSeverity.celebrate => colors.accent,
      NarratorSeverity.success => colors.success,
      NarratorSeverity.info => colors.info,
      NarratorSeverity.warning => colors.warning,
      NarratorSeverity.critical => colors.error,
    };
  }
}

/// Compact Night Narrator feed row.
///
/// Layout: a thin severity accent rail on the left, the category icon, the
/// headline (max 2 lines) with a relative timestamp beneath it, and a
/// right-aligned micro-visualization of the event's evidence. Tapping the card
/// opens [showNarratorDetailSheet].
///
/// The relative timestamp text is passed in ([relativeTime]) rather than
/// computed here so a feed can tick a single shared [Timer] and rebuild all of
/// its cards at once — no per-card timers.
class NarratorCard extends StatelessWidget {
  final NarratorEvent event;

  /// Pre-formatted relative time, e.g. "4m ago". Supplied by the feed so a
  /// single timer drives every card.
  final String relativeTime;

  /// Tap handler. Defaults to opening the detail sheet for [event].
  final VoidCallback? onTap;

  const NarratorCard({
    super.key,
    required this.event,
    required this.relativeTime,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final accent = NarratorVisuals.accentFor(event.severity, colors);
    final isCelebrate = event.severity == NarratorSeverity.celebrate;
    final icon = NarratorVisuals.iconFor(event.category);

    // The left edge accent. For `celebrate` it's a vertical gradient (accent →
    // primary) so a discovery quietly shimmers; otherwise a flat, restrained
    // bar. Never a filled box behind the whole card.
    final Widget edge = Container(
      width: 3,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
        color: isCelebrate ? null : accent.withValues(alpha: 0.85),
        gradient: isCelebrate
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [colors.accent, colors.primary],
              )
            : null,
      ),
    );

    return SkotiqCard(
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.spaceSm,
        SkotiqTokens.spaceMd,
        SkotiqTokens.spaceMd,
        SkotiqTokens.spaceMd,
      ),
      onTap: onTap ?? () => showNarratorDetailSheet(context, event),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            edge,
            const SizedBox(width: SkotiqTokens.spaceMd),
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(icon, size: 16, color: accent),
            ),
            const SizedBox(width: SkotiqTokens.spaceMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    event.headline,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: SkotiqTypography.fontSize12_5,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    relativeTime,
                    style: SkotiqTypography.withTabular(
                      SkotiqTypography.labelQuiet.copyWith(
                        color: colors.textMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (event.evidence != null) ...[
              const SizedBox(width: SkotiqTokens.spaceMd),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 116),
                child: NarratorEvidenceViz(
                  evidence: event.evidence!,
                  accent: accent,
                  emphasized: isCelebrate,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Generic renderer for any [NarratorEvidence] payload. Dispatches on
/// [NarratorEvidence.kind] to one of four compact visualizations:
///   * sparkline → a mini line chart ([_SparklinePainter]).
///   * delta → a from→to pair with a direction arrow.
///   * vector → a small compass-style direction indicator with a label.
///   * scalar → a big value + unit with a context caption.
///
/// [emphasized] (set for `celebrate` events) bumps sizes/weights a touch.
/// Reusable across the card, detail sheet (via [large]), ticker, and timeline.
class NarratorEvidenceViz extends StatelessWidget {
  final NarratorEvidence evidence;
  final Color accent;
  final bool emphasized;

  /// Larger, more detailed rendering for the detail sheet.
  final bool large;

  const NarratorEvidenceViz({
    super.key,
    required this.evidence,
    required this.accent,
    this.emphasized = false,
    this.large = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return switch (evidence.kind) {
      NarratorEvidenceKind.sparkline => _sparkline(colors),
      NarratorEvidenceKind.delta => _delta(colors),
      NarratorEvidenceKind.vector => _vector(colors),
      NarratorEvidenceKind.scalar => _scalar(colors),
    };
  }

  Widget _sparkline(SkotiqColors colors) {
    final points = evidence.points ?? const <double>[];
    final height = large ? 56.0 : (emphasized ? 34.0 : 30.0);
    if (points.length < 2) {
      // Not enough to draw a line — fall back to the latest value as a chip.
      final last = points.isEmpty ? null : points.last;
      return _MiniChip(
        text: last == null ? '—' : '${_fmt(last)}${evidence.unit ?? ''}',
        color: accent,
        colors: colors,
        large: large,
      );
    }
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _SparklinePainter(
          values: points,
          color: accent,
          highlightLast: evidence.highlightLast,
          strokeWidth: emphasized || large ? 2.0 : 1.5,
        ),
        size: Size.infinite,
      ),
    );
  }

  Widget _delta(SkotiqColors colors) {
    final from = evidence.from;
    final to = evidence.to;
    final unit = evidence.unit ?? '';
    final dir = evidence.direction ?? 'flat';
    final arrow = switch (dir) {
      'up' => LucideIcons.arrowUp,
      'down' => LucideIcons.arrowDown,
      _ => LucideIcons.arrowRight,
    };
    final valueStyle = SkotiqTypography.withTabular(
      TextStyle(
        color: colors.textPrimary,
        fontSize: large
            ? SkotiqTypography.fontSize14
            : SkotiqTypography.fontSize12,
        fontWeight: FontWeight.w700,
      ),
    );
    final fadedStyle = SkotiqTypography.withTabular(
      TextStyle(
        color: colors.textMuted,
        fontSize: large
            ? SkotiqTypography.fontSize13
            : SkotiqTypography.fontSize11,
        fontWeight: FontWeight.w600,
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Flexible(
          child: Text(
            '${_fmt(from)}$unit',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: fadedStyle,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Icon(arrow, size: large ? 16 : 12, color: accent),
        ),
        Flexible(
          child: Text(
            '${_fmt(to)}$unit',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: valueStyle,
          ),
        ),
      ],
    );
  }

  Widget _vector(SkotiqColors colors) {
    final size = large ? 56.0 : (emphasized ? 32.0 : 28.0);
    final label = evidence.label;
    final compass = SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _VectorPainter(
          directionDeg: evidence.directionDeg ?? 0,
          magnitude: (evidence.magnitude ?? 0).clamp(0.0, 1.0),
          color: accent,
          ringColor: colors.border,
        ),
      ),
    );
    if (label == null || label.isEmpty) return compass;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        compass,
        const SizedBox(height: 2),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.end,
          style: SkotiqTypography.labelQuiet.copyWith(
            color: colors.textMuted,
            fontSize: large
                ? SkotiqTypography.fontSize11
                : SkotiqTypography.fontSize10,
          ),
        ),
      ],
    );
  }

  Widget _scalar(SkotiqColors colors) {
    final value = evidence.value;
    final unit = evidence.unit ?? '';
    final context = evidence.context;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        RichText(
          textAlign: TextAlign.end,
          text: TextSpan(
            children: [
              TextSpan(
                text: _fmt(value),
                style: SkotiqTypography.withTabular(
                  TextStyle(
                    color: emphasized ? accent : colors.textPrimary,
                    fontSize: large
                        ? 28
                        : (emphasized
                            ? SkotiqTypography.fontSize14
                            : SkotiqTypography.fontSize13),
                    fontWeight: FontWeight.w700,
                    height: 1.0,
                  ),
                ),
              ),
              if (unit.isNotEmpty)
                TextSpan(
                  text: unit,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: large
                        ? SkotiqTypography.fontSize14
                        : SkotiqTypography.fontSize11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
        if (context != null && context.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(
              context,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: SkotiqTypography.labelQuiet.copyWith(
                color: colors.textMuted,
                fontSize: large
                    ? SkotiqTypography.fontSize12
                    : SkotiqTypography.fontSize10,
              ),
            ),
          ),
      ],
    );
  }

  /// Compact, locale-free number formatting: drop a trailing `.0`, otherwise
  /// keep up to two significant decimals.
  static String _fmt(double? v) {
    if (v == null) return '—';
    if (!v.isFinite) return '—';
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    final abs = v.abs();
    final decimals = abs >= 100 ? 0 : (abs >= 10 ? 1 : 2);
    var s = v.toStringAsFixed(decimals);
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    }
    return s;
  }
}

/// Small rounded value chip used as a sparkline fallback.
class _MiniChip extends StatelessWidget {
  final String text;
  final Color color;
  final SkotiqColors colors;
  final bool large;

  const _MiniChip({
    required this.text,
    required this.color,
    required this.colors,
    required this.large,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
      ),
      child: Text(
        text,
        style: SkotiqTypography.withTabular(
          TextStyle(
            color: colors.textPrimary,
            fontSize: large
                ? SkotiqTypography.fontSize14
                : SkotiqTypography.fontSize12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// Mini line chart. No axes — the trend shape carries the meaning, and the
/// context (unit, last value) lives in the surrounding copy. Optionally dots
/// the most recent point in the accent colour.
class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.values,
    required this.color,
    this.highlightLast = true,
    this.strokeWidth = 1.5,
  });

  final List<double> values;
  final Color color;
  final bool highlightLast;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    var min = values[0];
    var max = values[0];
    for (final v in values) {
      if (v < min) min = v;
      if (v > max) max = v;
    }
    final range = max - min;
    final span = range < 1e-9 ? 1.0 : range;
    // Inset vertically so the dot + stroke aren't clipped at the edges.
    const padY = 3.0;
    final usableH = math.max(size.height - padY * 2, 1.0);

    double xAt(int i) => size.width * (i / (values.length - 1));
    double yAt(int i) {
      final normalized = (values[i] - min) / span;
      return padY + usableH * (1 - normalized);
    }

    final line = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    final path = Path()..moveTo(xAt(0), yAt(0));
    for (var i = 1; i < values.length; i++) {
      path.lineTo(xAt(i), yAt(i));
    }
    canvas.drawPath(path, line);

    if (highlightLast) {
      final dot = Paint()
        ..color = color
        ..style = PaintingStyle.fill;
      canvas.drawCircle(
        Offset(xAt(values.length - 1), yAt(values.length - 1)),
        strokeWidth + 1.0,
        dot,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter old) =>
      old.values != values ||
      old.color != color ||
      old.highlightLast != highlightLast ||
      old.strokeWidth != strokeWidth;
}

/// Compass-style direction indicator: a faint ring with an arrow pointing in
/// the evidence direction, its length scaled by magnitude. 0° points up
/// (north / top of frame), increasing clockwise.
class _VectorPainter extends CustomPainter {
  _VectorPainter({
    required this.directionDeg,
    required this.magnitude,
    required this.color,
    required this.ringColor,
  });

  final double directionDeg;
  final double magnitude;
  final Color color;
  final Color ringColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 1;
    if (radius <= 0) return;

    final ring = Paint()
      ..color = ringColor.withValues(alpha: 0.7)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(center, radius, ring);

    // 0° = up, clockwise. Screen y grows downward, so up is -y.
    final theta = directionDeg * math.pi / 180.0;
    final len = radius * (0.35 + 0.6 * magnitude.clamp(0.0, 1.0));
    final tip = Offset(
      center.dx + len * math.sin(theta),
      center.dy - len * math.cos(theta),
    );

    final arrow = Paint()
      ..color = color
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawLine(center, tip, arrow);

    // Arrowhead: two short barbs.
    const barb = 4.0;
    final back = theta + math.pi;
    for (final spread in [0.45, -0.45]) {
      final a = back + spread;
      canvas.drawLine(
        tip,
        Offset(tip.dx + barb * math.sin(a), tip.dy - barb * math.cos(a)),
        arrow,
      );
    }

    final hub = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 1.6, hub);
  }

  @override
  bool shouldRepaint(covariant _VectorPainter old) =>
      old.directionDeg != directionDeg ||
      old.magnitude != magnitude ||
      old.color != color ||
      old.ringColor != ringColor;
}
