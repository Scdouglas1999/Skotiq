import 'package:flutter/material.dart';

/// HFR-over-time sparkline for the Run dashboard.
///
/// One painter for every dashboard surface that plots the run's HFR trend (the
/// quality panel's tile and the live-frame badge), so two tiles on one
/// dashboard cannot disagree about the flat-series clamp, the stroke width or
/// which way up the trend is drawn.
///
/// Orientation is the invariant worth stating: **lower HFR is better focus, so
/// it is drawn HIGHER on screen.** No axes — the caller's min–max label carries
/// the scale.
class HfrSparklinePainter extends CustomPainter {
  const HfrSparklinePainter({
    required this.values,
    required this.color,
    this.accepted = const [],
    this.rejectColor,
    this.fillColor,
    this.showLatestMarker = false,
  });

  /// Per-frame HFR, oldest → newest.
  final List<double> values;

  final Color color;

  /// Per-frame accept/reject, parallel to [values]. A rejected frame gets a
  /// [rejectColor] dot so a focus-collapse episode stays visible in the trend
  /// instead of disappearing with the rejections. Ignored unless it is the
  /// same length as [values] and [rejectColor] is set.
  final List<bool> accepted;
  final Color? rejectColor;

  /// When set, the area under the line is filled — the compact badge variant.
  final Color? fillColor;

  /// Draws a dot on the newest point, so the compact variant reads as "where
  /// the run is now" rather than as an anonymous trend.
  final bool showLatestMarker;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;

    var min = values.first;
    var max = values.first;
    for (final value in values) {
      if (value < min) min = value;
      if (value > max) max = value;
    }
    final range = max - min;
    // Flat series: draw a level line rather than dividing by zero.
    final span = range < 1e-3 ? 1.0 : range;

    double xAt(int i) => size.width * (i / (values.length - 1));
    double yAt(int i) {
      final normalized = (values[i] - min) / span;
      // Lower HFR is better focus → smaller y → higher on screen.
      return size.height * normalized;
    }

    final line = Path();
    for (var i = 0; i < values.length; i++) {
      if (i == 0) {
        line.moveTo(xAt(i), yAt(i));
      } else {
        line.lineTo(xAt(i), yAt(i));
      }
    }

    if (fillColor != null) {
      final fill = Path.from(line)
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
      canvas.drawPath(fill, Paint()..color = fillColor!);
    }

    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round,
    );

    if (rejectColor != null && accepted.length == values.length) {
      final dot = Paint()
        ..color = rejectColor!
        ..style = PaintingStyle.fill;
      for (var i = 0; i < values.length; i++) {
        if (!accepted[i]) {
          canvas.drawCircle(Offset(xAt(i), yAt(i)), 2.5, dot);
        }
      }
    }

    if (showLatestMarker) {
      final last = values.length - 1;
      canvas.drawCircle(
        Offset(xAt(last), yAt(last)),
        1.8,
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(covariant HfrSparklinePainter old) =>
      old.values != values ||
      old.accepted != accepted ||
      old.color != color ||
      old.rejectColor != rejectColor ||
      old.fillColor != fillColor ||
      old.showLatestMarker != showLatestMarker;
}
