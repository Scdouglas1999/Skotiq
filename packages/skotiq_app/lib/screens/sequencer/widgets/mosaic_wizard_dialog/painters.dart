part of '../mosaic_wizard_dialog.dart';

class _StarFieldPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rng = math.Random(42);
    final paint = Paint();
    for (var i = 0; i < 200; i++) {
      final x = rng.nextDouble() * size.width;
      final y = rng.nextDouble() * size.height;
      final brightness = rng.nextDouble() * 0.4 + 0.1;
      final radius = rng.nextDouble() * 1.2 + 0.3;
      // absolute: stars rendered over the dark sky canvas
      paint.color = Colors.white.withValues(alpha: brightness);
      canvas.drawCircle(Offset(x, y), radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _StarFieldPainter oldDelegate) => false;
}

class _RaDecGridPainter extends CustomPainter {
  final double pxPerDeg;

  _RaDecGridPainter({required this.pxPerDeg});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      // absolute: RA/Dec grid drawn over the dark sky canvas
      ..color = Colors.white.withValues(alpha: 0.08)
      ..strokeWidth = 0.5;
    final cx = size.width / 2;
    final cy = size.height / 2;
    for (var d = 1.0; d * pxPerDeg < size.width; d += 1.0) {
      canvas.drawLine(Offset(cx - d * pxPerDeg, 0),
          Offset(cx - d * pxPerDeg, size.height), paint);
      canvas.drawLine(Offset(cx + d * pxPerDeg, 0),
          Offset(cx + d * pxPerDeg, size.height), paint);
    }
    for (var d = 1.0; d * pxPerDeg < size.height; d += 1.0) {
      canvas.drawLine(Offset(0, cy - d * pxPerDeg),
          Offset(size.width, cy - d * pxPerDeg), paint);
      canvas.drawLine(Offset(0, cy + d * pxPerDeg),
          Offset(size.width, cy + d * pxPerDeg), paint);
    }
    // absolute: RA/Dec centre axes drawn over the dark sky canvas
    paint.color = Colors.white.withValues(alpha: 0.18);
    paint.strokeWidth = 1.0;
    canvas.drawLine(Offset(cx, 0), Offset(cx, size.height), paint);
    canvas.drawLine(Offset(0, cy), Offset(size.width, cy), paint);
  }

  @override
  bool shouldRepaint(covariant _RaDecGridPainter oldDelegate) =>
      oldDelegate.pxPerDeg != pxPerDeg;
}
