// ignore_for_file: unused_element, unused_field

part of '../sky_renderer.dart';

/// Planning overlays drawn on the animated overlay layer for the selected
/// target: a compact altitude track for tonight (anchored at the target), a
/// meridian-flip / transit marker, and a twilight (dusk/dawn) indicator.
///
/// These make the planetarium the visual front-end for the same astronomy the
/// sequencer's meridian-flip logic uses. They live on the overlay layer because
/// they depend on the selected target (already an overlay repaint trigger) and
/// must not force the expensive static base layer to repaint.
extension _SkyCanvasPainterPlanningOverlays on SkyCanvasPainter {
  // Schematic, precision-instrument palette (canvas-absolute over the sky).
  static const Color _trackColor = Color(0xFF64B5F6); // altitude curve
  static const Color _flipColor = Color(0xFFFFB74D); // meridian flip accent
  static const Color _twilightColor = Color(0xFF7E57C2); // twilight band

  /// Draw the selected target's altitude track for tonight plus its
  /// meridian-flip / transit marker, anchored at the target's projected
  /// position.
  void _drawTargetPlanningTrack(
    Canvas canvas,
    Size size,
    Offset center,
    double scale,
  ) {
    final target = selectedObject;
    if (target == null) return;

    final anchor = _celestialToScreen(target, center, scale);
    if (anchor == null || !_isInView(anchor, size)) return;

    final raDeg = target.ra * 15;
    final decDeg = target.dec;

    // Tonight's rise/transit/set, computed with the accurate body-aware
    // astronomy (feature 1). Catalog targets are fixed, so positionAt is null.
    final visibility = AstronomyCalculations.calculateObjectVisibility(
      raDeg: raDeg,
      decDeg: decDeg,
      // The night containing the clock, not its calendar day: after local
      // midnight those differ and the overlay would describe tomorrow night.
      date: AstronomyCalculations.nightDateOf(observationTime),
      latitudeDeg: latitude,
      longitudeDeg: longitude,
    );

    // Sample apparent altitude across the local night window (noon→noon), the
    // same 24h span the object-details altitude chart uses, so the on-sky track
    // and the side-panel chart agree.
    final localNoon = DateTime(
      observationTime.year,
      observationTime.month,
      observationTime.day,
      12,
    );
    const samples = 48; // every 30 minutes
    // Memoized on (target, day, site): this runs on the animated overlay layer,
    // so without the cache the 49 sidereal-time solves below ran every frame.
    final (altitudes, maxAlt) = _planningAstronomyCache.altitudeTrack(
      raDeg: raDeg,
      decDeg: decDeg,
      localNoon: localNoon,
      latitudeDeg: latitude,
      longitudeDeg: longitude,
      compute: () {
        final result = <double>[];
        var peak = -90.0;
        for (var i = 0; i <= samples; i++) {
          final t = localNoon.add(Duration(minutes: (24 * 60 * i ~/ samples)));
          final lst = AstronomyCalculations.localSiderealTime(t, longitude);
          final (alt, _) = AstronomyCalculations.equatorialToHorizontal(
            raDeg: raDeg,
            decDeg: decDeg,
            latitudeDeg: latitude,
            lstHours: lst,
          );
          result.add(alt);
          if (alt > peak) peak = alt;
        }
        return (result, peak);
      },
    );

    // Sparkline geometry: a small panel floating up-right of the target.
    const trackWidth = 96.0;
    const trackHeight = 34.0;
    final origin = Offset(anchor.dx + 16, anchor.dy - trackHeight - 16);
    final panel = Rect.fromLTWH(
      origin.dx - 6,
      origin.dy - 6,
      trackWidth + 12,
      trackHeight + 20,
    );
    // Keep the panel on screen.
    var dx = 0.0, dy = 0.0;
    if (panel.right > size.width) dx = size.width - panel.right;
    if (panel.left + dx < 0) dx = -panel.left;
    if (panel.top + dy < 0) dy = -panel.top;
    if (panel.bottom + dy > size.height) dy = size.height - panel.bottom;
    final shift = Offset(dx, dy);
    final o = origin + shift;

    // Panel background for readability over a busy star field.
    canvas.drawRRect(
      RRect.fromRectAndRadius(panel.shift(shift), const Radius.circular(4)),
      Paint()..color = const Color(0xCC0A0A12),
    );

    // Connector line from the target to the panel.
    canvas.drawLine(
      anchor,
      Offset(o.dx, o.dy + trackHeight),
      Paint()
        ..color = _trackColor.withValues(alpha: 0.5)
        ..strokeWidth = 1,
    );

    // Map altitude (0..90) to the track height; clamp below-horizon to the
    // baseline so the curve reads as "below horizon" rather than running off.
    double yFor(double alt) =>
        o.dy + trackHeight - (alt.clamp(0.0, 90.0) / 90.0) * trackHeight;
    double xFor(int i) => o.dx + (i / samples) * trackWidth;

    // Horizon baseline.
    canvas.drawLine(
      Offset(o.dx, o.dy + trackHeight),
      Offset(o.dx + trackWidth, o.dy + trackHeight),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.18)
        ..strokeWidth = 0.8,
    );

    // Altitude curve.
    final path = Path();
    var started = false;
    for (var i = 0; i < altitudes.length; i++) {
      final p = Offset(xFor(i), yFor(altitudes[i]));
      if (!started) {
        path.moveTo(p.dx, p.dy);
        started = true;
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = _trackColor
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );

    // "Now" marker on the curve.
    final nowFrac = observationTime.difference(localNoon).inMinutes / (24 * 60);
    if (nowFrac >= 0 && nowFrac <= 1) {
      final nowX = o.dx + nowFrac * trackWidth;
      canvas.drawLine(
        Offset(nowX, o.dy),
        Offset(nowX, o.dy + trackHeight),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.55)
          ..strokeWidth = 1,
      );
    }

    // Transit (meridian-flip) tick + label.
    final transit = visibility.transitTime;
    if (transit != null) {
      final tFrac = transit.difference(localNoon).inMinutes / (24 * 60);
      if (tFrac >= 0 && tFrac <= 1) {
        final tx = o.dx + tFrac * trackWidth;
        canvas.drawLine(
          Offset(tx, o.dy - 3),
          Offset(tx, o.dy + trackHeight),
          Paint()
            ..color = _flipColor
            ..strokeWidth = 1.2,
        );
        canvas.drawCircle(
          Offset(tx, yFor(visibility.transitAltitude ?? maxAlt)),
          2.0,
          Paint()..color = _flipColor,
        );
      }

      // Label: meridian flip / transit time.
      final label = visibility.isCircumpolar
          ? 'Flip ${_hhmm(transit)} (circumpolar)'
          : 'Flip ${_hhmm(transit)}';
      final tp = _TextCache.get(
        label,
        const TextStyle(
          color: _flipColor,
          fontSize: 9,
          fontWeight: FontWeight.w600,
        ),
      );
      tp.paint(canvas, Offset(o.dx, o.dy + trackHeight + 4));
    } else if (visibility.neverRises) {
      final tp = _TextCache.get(
        'Never rises',
        TextStyle(
          color: Colors.white.withValues(alpha: 0.7),
          fontSize: 9,
          fontWeight: FontWeight.w500,
        ),
      );
      tp.paint(canvas, Offset(o.dx, o.dy + trackHeight + 4));
    }
  }

  /// Draw the twilight indicator: a compact horizontal gauge (top-left) marking
  /// the night between dusk and dawn, with the current time and the
  /// astronomical dusk/dawn clock times — the "shaded twilight band".
  void _drawTwilightIndicator(Canvas canvas, Size size) {
    // Memoized on (day, site) — see [_PlanningAstronomyCache]. This overlay is
    // on the animated layer, and the solve is iterative.
    final twilight = _planningAstronomyCache.twilight(
      date: observationTime,
      latitudeDeg: latitude,
      longitudeDeg: longitude,
      compute: () => AstronomyCalculations.calculateTwilightTimes(
        date: observationTime,
        latitudeDeg: latitude,
        longitudeDeg: longitude,
      ),
    );

    final dusk = twilight.astronomicalDusk ?? twilight.nauticalDusk;
    final dawn = twilight.astronomicalDawn ?? twilight.nauticalDawn;
    if (dusk == null || dawn == null) return;

    // Gauge spans the local night window (noon→noon) so "now" and the band map
    // consistently with the altitude track.
    final localNoon = DateTime(
      observationTime.year,
      observationTime.month,
      observationTime.day,
      12,
    );
    const windowMinutes = 24 * 60;
    double frac(DateTime t) =>
        (t.difference(localNoon).inMinutes / windowMinutes).clamp(0.0, 1.0);

    const double left = 16;
    const double top = 16;
    const double width = 150;
    const double height = 6;

    // Track background (day).
    const track = Rect.fromLTWH(left, top, width, height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(track, const Radius.circular(3)),
      Paint()..color = const Color(0x66202840),
    );

    // Night band (dusk→dawn).
    final nx0 = left + frac(dusk) * width;
    final nx1 = left + frac(dawn) * width;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(nx0, top, nx1, top + height),
        const Radius.circular(3),
      ),
      Paint()..color = _twilightColor.withValues(alpha: 0.65),
    );

    // Current-time tick.
    final nowX = left + frac(observationTime) * width;
    canvas.drawLine(
      Offset(nowX, top - 3),
      Offset(nowX, top + height + 3),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.85)
        ..strokeWidth = 1.5,
    );

    // Dusk / dawn labels.
    final duskTp = _TextCache.get(
      'Dusk ${_hhmm(dusk)}',
      TextStyle(
        color: _twilightColor.withValues(alpha: 0.95),
        fontSize: 9,
        fontWeight: FontWeight.w500,
      ),
    );
    duskTp.paint(canvas, const Offset(left, top + height + 4));

    final dawnTp = _TextCache.get(
      'Dawn ${_hhmm(dawn)}',
      TextStyle(
        color: _twilightColor.withValues(alpha: 0.95),
        fontSize: 9,
        fontWeight: FontWeight.w500,
      ),
    );
    dawnTp.paint(canvas, Offset(left + width - dawnTp.width, top + height + 4));
  }

  /// Format a [DateTime] as zero-padded local HH:MM.
  String _hhmm(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
