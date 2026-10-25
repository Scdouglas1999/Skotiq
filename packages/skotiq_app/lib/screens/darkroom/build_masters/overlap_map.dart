import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Height of the overlap map; the field is scaled to fit inside it.
const double _mapHeight = 360;

/// How footprints are grouped by color on the overlap map.
enum OverlapColorBy { night, pierSide }

/// The night a frame's group belongs to, from its group label.
String nightOfGroup(String label) =>
    RegExp(r'^Night of (\S+)').firstMatch(label)?.group(1) ?? label;

/// The pier side of a frame: as recorded, else from its rotation against the
/// reference (about 180 degrees means the other side).
String sideOfFrame(DarkroomFramePreview f) {
  final side = f.side?.trim().toLowerCase();
  if (side != null && side.contains('east')) return 'East';
  if (side != null && side.contains('west')) return 'West';
  final r = f.rotationDeg;
  if (r == null) return 'Unknown side';
  return r.abs() > 90 ? 'Flipped from reference' : 'Same as reference';
}

/// Category of [f] under [by].
String overlapCategory(DarkroomFramePreview f, OverlapColorBy by) =>
    by == OverlapColorBy.night ? nightOfGroup(f.group) : sideOfFrame(f);

/// Every light's footprint on the reference grid, colored by night or pier
/// side, with the common crop filled. Pixel axes on both sides.
class OverlapMap extends StatelessWidget {
  const OverlapMap({
    super.key,
    required this.preview,
    required this.colorBy,
    this.highlighted,
  });

  final DarkroomRegistrationPreview preview;
  final OverlapColorBy colorBy;

  /// A light to draw on top, emphasized.
  final String? highlighted;

  static List<String> categories(
    DarkroomRegistrationPreview preview,
    OverlapColorBy by,
  ) =>
      {for (final f in preview.included) overlapCategory(f, by)}.toList()
        ..sort();

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final keys = categories(preview, colorBy);
    final palette = {
      for (var i = 0; i < keys.length; i++)
        keys[i]: SkotiqChartColors.forTheme(
          SkotiqChartColors.series[i % SkotiqChartColors.series.length],
          colors,
        ),
    };
    final retained = (preview.retainedArea * 100).toStringAsFixed(1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          label: 'Overlap map of ${preview.included.length} frames on a '
              '${preview.width} by ${preview.height} pixel grid. '
              'The common crop keeps $retained percent of the field.',
          child: SizedBox(
            height: _mapHeight,
            child: CustomPaint(
              painter: _OverlapMapPainter(
                preview: preview,
                colorBy: colorBy,
                palette: palette,
                highlighted: highlighted,
                colors: colors,
                labelStyle: SkotiqTypography.monoCaption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        Wrap(
          spacing: SkotiqTokens.spaceLg,
          runSpacing: SkotiqTokens.spaceXs,
          children: [
            for (final key in keys)
              _LegendItem(
                color: palette[key]!,
                label:
                    '$key (${preview.included.where((f) => overlapCategory(f, colorBy) == key).length})',
              ),
            _LegendItem(
                color: colors.primary, label: 'Common crop', filled: true),
          ],
        ),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({
    required this.color,
    required this.label,
    this.filled = false,
  });
  final Color color;
  final String label;
  final bool filled;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: SkotiqTokens.spaceMd,
            height: SkotiqTokens.spaceMd,
            decoration: BoxDecoration(
              color: filled ? color.withValues(alpha: .25) : null,
              border: Border.all(color: color, width: 2),
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceXs),
          Text(
            label,
            style: SkotiqTypography.bodySm.copyWith(
              color: context.skotiqColors.textSecondary,
            ),
          ),
        ],
      );
}

class _OverlapMapPainter extends CustomPainter {
  _OverlapMapPainter({
    required this.preview,
    required this.colorBy,
    required this.palette,
    required this.highlighted,
    required this.colors,
    required this.labelStyle,
  });

  final DarkroomRegistrationPreview preview;
  final OverlapColorBy colorBy;
  final Map<String, Color> palette;
  final String? highlighted;
  final SkotiqColors colors;
  final TextStyle labelStyle;

  static const double _left = 52;
  static const double _bottom = 36;
  static const double _top = 8;
  static const double _right = 12;

  @override
  void paint(Canvas canvas, Size size) {
    final w = preview.width.toDouble();
    final h = preview.height.toDouble();
    // View: the grid plus any footprint corner, limited to half a field
    // beyond it so one wild frame cannot shrink the map to a dot.
    var minX = 0.0, minY = 0.0, maxX = w, maxY = h;
    for (final f in preview.frames) {
      for (final c in f.corners ?? const <Offset>[]) {
        minX = math.min(minX, c.dx);
        minY = math.min(minY, c.dy);
        maxX = math.max(maxX, c.dx);
        maxY = math.max(maxY, c.dy);
      }
    }
    minX = math.max(minX, -w / 2);
    minY = math.max(minY, -h / 2);
    maxX = math.min(maxX, w * 1.5);
    maxY = math.min(maxY, h * 1.5);
    final plot = Rect.fromLTRB(
      _left,
      _top,
      size.width - _right,
      size.height - _bottom,
    );
    final scale = math.min(
      plot.width / (maxX - minX),
      plot.height / (maxY - minY),
    );
    final origin = Offset(
      plot.left + (plot.width - (maxX - minX) * scale) / 2 - minX * scale,
      plot.top + (plot.height - (maxY - minY) * scale) / 2 - minY * scale,
    );
    Offset map(Offset p) => origin + p * scale;

    canvas.save();
    canvas.clipRect(plot);
    final grid = Rect.fromPoints(map(Offset.zero), map(Offset(w, h)));
    canvas.drawRect(grid, Paint()..color = colors.well);
    final crop = preview.crop;
    if (crop != null) {
      final r = Rect.fromPoints(
        map(Offset(crop[0].toDouble(), crop[1].toDouble())),
        map(Offset(crop[2].toDouble(), crop[3].toDouble())),
      );
      canvas.drawRect(
          r, Paint()..color = colors.primary.withValues(alpha: .18));
      canvas.drawRect(
        r,
        Paint()
          ..color = colors.primary
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    Path outline(List<Offset> corners) =>
        Path()..addPolygon([for (final c in corners) map(c)], true);
    for (final f in preview.notIncluded) {
      if (f.corners == null) continue;
      canvas.drawPath(
        outline(f.corners!),
        Paint()
          ..color = colors.textMuted.withValues(alpha: .6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
    for (final f in preview.included) {
      if (f.corners == null || f.path == highlighted) continue;
      canvas.drawPath(
        outline(f.corners!),
        Paint()
          ..color = palette[overlapCategory(f, colorBy)]!.withValues(alpha: .7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
    final emphasized = preview.frames
        .where((f) => f.path == highlighted && f.corners != null)
        .firstOrNull;
    if (emphasized != null) {
      canvas.drawPath(
        outline(emphasized.corners!),
        Paint()
          ..color = colors.warning
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }
    canvas.restore();

    // Axes in grid pixels.
    final axis = Paint()
      ..color = colors.border
      ..strokeWidth = 1;
    canvas.drawLine(plot.bottomLeft, plot.bottomRight, axis);
    canvas.drawLine(plot.topLeft, plot.bottomLeft, axis);
    void label(String text, Offset at,
        {bool alignRight = false, bool center = false}) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      var dx = at.dx;
      if (alignRight) dx -= tp.width;
      if (center) dx -= tp.width / 2;
      tp.paint(canvas, Offset(dx, at.dy - tp.height / 2));
    }

    for (final v in _ticks(0, w)) {
      final x = map(Offset(v, 0)).dx;
      if (x < plot.left - 1 || x > plot.right + 1) continue;
      canvas.drawLine(Offset(x, plot.bottom), Offset(x, plot.bottom + 4), axis);
      label(v.round().toString(), Offset(x, plot.bottom + 12), center: true);
    }
    for (final v in _ticks(0, h)) {
      final y = map(Offset(0, v)).dy;
      if (y < plot.top - 1 || y > plot.bottom + 1) continue;
      canvas.drawLine(Offset(plot.left - 4, y), Offset(plot.left, y), axis);
      label(v.round().toString(), Offset(plot.left - 6, y), alignRight: true);
    }
    label('x (px)', Offset(plot.center.dx, size.height - 8), center: true);
    canvas.save();
    canvas.translate(10, plot.center.dy);
    canvas.rotate(-math.pi / 2);
    label('y (px)', Offset.zero, center: true);
    canvas.restore();
  }

  /// About five round tick values from [low] to [high].
  static List<double> _ticks(double low, double high) {
    final span = high - low;
    if (span <= 0) return [low];
    final raw = span / 5;
    final magnitude =
        math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    final step =
        [1, 2, 5, 10].map((m) => m * magnitude).firstWhere((s) => s >= raw);
    return [
      for (var v = (low / step).ceil() * step; v <= high + 1e-9; v += step) v,
    ];
  }

  @override
  bool shouldRepaint(_OverlapMapPainter old) =>
      old.preview != preview ||
      old.colorBy != colorBy ||
      old.highlighted != highlighted ||
      old.colors != colors;
}
