import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import '../../models/science/science_models.dart';
import '../../utils/utc_timestamp.dart';

/// Image size and timing from a FITS primary header, read without decoding
/// the pixels.
class FitsFrameSummary {
  const FitsFrameSummary({
    required this.width,
    required this.height,
    this.dateObs,
    this.exposureSeconds,
    this.filter,
  });

  final int width;
  final int height;
  final DateTime? dateObs;
  final double? exposureSeconds;
  final String? filter;

  /// DATE-OBS (exposure start) plus half the exposure, or null without
  /// DATE-OBS.
  DateTime? get midExposureUtc {
    final start = dateObs;
    if (start == null) return null;
    final exposure = exposureSeconds;
    if (exposure == null) return start;
    return start.add(Duration(milliseconds: (exposure * 500).round()));
  }
}

/// Read the primary header of the FITS file at [path]; null when the file is
/// not a readable FITS image.
Future<FitsFrameSummary?> readFitsFrameSummary(String path) async {
  RandomAccessFile? file;
  try {
    file = await File(path).open();
    final cards = <String, String>{};
    for (var block = 0; block < 64; block++) {
      final bytes = await file.read(2880);
      if (bytes.length < 2880) return null;
      final text = latin1.decode(bytes);
      for (var c = 0; c < 36; c++) {
        final card = text.substring(c * 80, c * 80 + 80);
        final key = card.substring(0, 8).trim();
        if (key == 'END') {
          final w = _parseCard(cards['NAXIS1'], int.tryParse);
          final h = _parseCard(cards['NAXIS2'], int.tryParse);
          if (w == null || h == null) return null;
          final exp =
              _parseCard(cards['EXPTIME'], double.tryParse) ??
              _parseCard(cards['EXPOSURE'], double.tryParse);
          return FitsFrameSummary(
            width: w,
            height: h,
            dateObs: tryParseUtcTimestamp(cards['DATE-OBS']),
            exposureSeconds: exp,
            filter: cards['FILTER'],
          );
        }
        if (card.length > 10 && card.substring(8, 10) == '= ') {
          var value = card.substring(10);
          final slash = value.indexOf(" /");
          if (!value.trimLeft().startsWith("'") && slash >= 0) {
            value = value.substring(0, slash);
          }
          value = value.trim();
          if (value.startsWith("'")) {
            final end = value.indexOf("'", 1);
            value = value.substring(1, end < 0 ? value.length : end).trim();
          }
          cards.putIfAbsent(key, () => value);
        }
      }
    }
    return null;
  } on FileSystemException {
    return null;
  } finally {
    await file?.close();
  }
}

T? _parseCard<T>(String? raw, T? Function(String) parse) =>
    raw == null ? null : parse(raw);

/// One source detected in one frame, already placed on the sky through that
/// frame's own plate solve.
class MovingObjectDetection {
  const MovingObjectDetection({
    required this.raDegrees,
    required this.decDegrees,
    required this.x,
    required this.y,
    required this.flux,
    required this.snr,
  });

  final double raDegrees;
  final double decDegrees;

  /// Detector pixel position, kept to recognize a sensor defect: a hot pixel
  /// sits at the same pixel in every frame and only appears to move on the
  /// sky because the frames are dithered.
  final double x;
  final double y;
  final double flux;
  final double snr;
}

/// All detections of one frame and the mid-exposure time they belong to.
class MovingObjectFrameDetections {
  const MovingObjectFrameDetections({
    required this.midExposureUtc,
    required this.detections,
  });

  final DateTime midExposureUtc;
  final List<MovingObjectDetection> detections;
}

class _Point {
  _Point(this.frame, this.index, this.xi, this.eta, this.det);

  final int frame;
  final int index;

  /// Tangent-plane offsets (arcsec) from the window's reference point, xi
  /// toward increasing RA (east), eta toward north.
  final double xi;
  final double eta;
  final MovingObjectDetection det;
  bool isStatic = false;
  bool used = false;
}

/// Link a frame window without blocking the UI isolate.
Future<List<MovingObjectMatch>> linkMovingObjectsInBackground(
  List<MovingObjectFrameDetections> frames,
  MovingObjectOptions options,
) => Isolate.run(() => linkMovingObjects(frames, options));

/// Links detections into moving-object tracklets in sky coordinates.
///
/// Every detection is compared on the sky, never by pixel, so dithers and
/// drift between frames do not read as motion. A detection that reappears at
/// the same sky position in a frame taken at least half the window apart is a
/// fixed source and is removed before linking. A tracklet needs detections in
/// at least three frames (and in most frames of a longer window) that fit one
/// straight line at constant rate within [MovingObjectOptions.matchToleranceArcsec],
/// moves at least three tolerances over its span, includes the newest frame,
/// and does not stay on one detector pixel.
///
/// Each returned match is the measured position in the newest frame, at that
/// frame's mid-exposure time.
List<MovingObjectMatch> linkMovingObjects(
  List<MovingObjectFrameDetections> input,
  MovingObjectOptions options,
) {
  final frames = input.toList(growable: false)
    ..sort((a, b) => a.midExposureUtc.compareTo(b.midExposureUtc));
  final n = frames.length;
  if (n < options.minFrames) return const [];

  final t0 = frames.first.midExposureUtc;
  final times = [
    for (final f in frames)
      f.midExposureUtc.difference(t0).inMilliseconds / 60000.0,
  ];
  final windowSpan = times.last - times.first;
  if (windowSpan <= 0) return const [];

  // Reference point: the mean direction of the newest frame's detections.
  final ref = _meanDirection(frames.last.detections);
  if (ref == null) return const [];

  final tol = options.matchToleranceArcsec;
  final points = <List<_Point>>[];
  for (var f = 0; f < n; f++) {
    final list = <_Point>[];
    final dets = frames[f].detections;
    for (var i = 0; i < dets.length; i++) {
      final d = dets[i];
      final tp = _tangent(ref.$1, ref.$2, d.raDegrees, d.decDegrees);
      if (tp == null) continue;
      list.add(_Point(f, i, tp.$1, tp.$2, d));
    }
    points.add(list);
  }
  final grids = [for (final list in points) _Grid(list, tol)];

  // Fixed sources: matched at the same sky position in a frame at least half
  // the window away. A mover fast enough to be detected over this window has
  // left that position by then.
  for (var f = 0; f < n; f++) {
    for (final p in points[f]) {
      for (var g = 0; g < n; g++) {
        if (g == f || (times[g] - times[f]).abs() < 0.5 * windowSpan) continue;
        if (grids[g].nearest(p.xi, p.eta, tol, (_) => true) != null) {
          p.isStatic = true;
          break;
        }
      }
    }
  }

  final minHits = math.max(options.minFrames, (0.6 * n).ceil());
  final newest = n - 1;
  final matches = <MovingObjectMatch>[];

  // Anchor pairs: widest time baselines first; the newest frame must be in
  // every accepted tracklet, so pairs end there or at most one frame earlier.
  final anchorPairs = <(int, int)>[];
  for (var k = newest; k >= newest - 1 && k >= 2; k--) {
    for (var i = 0; i <= k - 2; i++) {
      anchorPairs.add((i, k));
    }
  }
  anchorPairs.sort(
    (a, b) => (times[b.$2] - times[b.$1]).compareTo(times[a.$2] - times[a.$1]),
  );

  for (final (i, k) in anchorPairs) {
    final dt = times[k] - times[i];
    if (dt <= 0) continue;
    final reach = options.maxRateArcsecPerMinute * dt;
    for (final a in points[i]) {
      if (a.isStatic || a.used) continue;
      for (final b in grids[k].within(a.xi, a.eta, reach)) {
        if (b.isStatic || b.used) continue;
        final vx = (b.xi - a.xi) / dt;
        final vy = (b.eta - a.eta) / dt;
        final hits = <_Point>[a, b];
        for (var j = 0; j < n; j++) {
          if (j == i || j == k) continue;
          final px = a.xi + vx * (times[j] - times[i]);
          final py = a.eta + vy * (times[j] - times[i]);
          final hit = grids[j].nearest(
            px,
            py,
            tol,
            (p) => !p.isStatic && !p.used,
          );
          if (hit != null) hits.add(hit);
        }
        if (hits.length < minHits) continue;
        if (!hits.any((h) => h.frame == newest)) continue;
        final fit = _fitLine(hits, times);
        if (fit == null || fit.rms > 0.75 * tol) continue;
        final rate = math.sqrt(fit.vx * fit.vx + fit.vy * fit.vy);
        if (rate > options.maxRateArcsecPerMinute) continue;
        if (rate * fit.span < 3.0 * tol) continue;
        if (_pixelStatic(hits, options.pixelStaticTolerance)) continue;

        for (final h in hits) {
          h.used = true;
        }
        final current = hits.firstWhere((h) => h.frame == newest);
        final pa = (math.atan2(fit.vx, fit.vy) * 180.0 / math.pi + 360.0) % 360;
        final meanSnr =
            hits.map((h) => h.det.snr).reduce((s, v) => s + v) / hits.length;
        final coverage = hits.length / n;
        final snrScore = (meanSnr / 20.0).clamp(0.2, 1.0).toDouble();
        final fitScore = (1.0 - fit.rms / tol).clamp(0.0, 1.0).toDouble();
        final confidence = (0.4 * snrScore + 0.35 * coverage + 0.25 * fitScore)
            .clamp(0.15, 0.95)
            .toDouble();
        matches.add(
          MovingObjectMatch(
            candidateId: _candidateIdFor(current.det, frames.last),
            raDegrees: current.det.raDegrees,
            decDegrees: current.det.decDegrees,
            motionArcsecPerMinute: rate,
            positionAngleDegrees: pa,
            confidence: confidence,
            epochUtc: frames.last.midExposureUtc,
            fluxEstimate: current.det.flux,
            frameCount: hits.length,
          ),
        );
        break;
      }
    }
  }

  matches.sort((a, b) => b.confidence.compareTo(a.confidence));
  return matches.take(options.maxCandidates).toList(growable: false);
}

/// Reuse the id of a tracklet reported on an earlier frame of the session
/// when [match] continues it, so one object keeps one id across frames.
///
/// An earlier row continues the tracklet when its position, carried forward
/// at its own rate and direction to [match]'s epoch, lands within
/// [toleranceArcsec] and its rate agrees within 30%.
String continuedCandidateId(
  MovingObjectMatch match,
  Iterable<
    ({
      String candidateId,
      double raDegrees,
      double decDegrees,
      double rateArcsecPerMinute,
      double positionAngleDegrees,
      DateTime timestamp,
    })
  >
  earlier, {
  double toleranceArcsec = 6.0,
}) {
  final epoch = match.epochUtc;
  if (epoch == null) return match.candidateId;
  String? best;
  var bestSep = double.infinity;
  for (final row in earlier) {
    final minutes = epoch.difference(row.timestamp).inMilliseconds / 60000.0;
    if (minutes <= 0 || minutes > 120) continue;
    final rate = row.rateArcsecPerMinute;
    if (rate <= 0 || (match.motionArcsecPerMinute - rate).abs() > 0.3 * rate) {
      continue;
    }
    final pa = row.positionAngleDegrees * math.pi / 180.0;
    final dist = rate * minutes / 3600.0;
    final dec = row.decDegrees + dist * math.cos(pa);
    final cosDec = math.cos(row.decDegrees * math.pi / 180.0);
    final ra = row.raDegrees + dist * math.sin(pa) / math.max(cosDec, 1e-6);
    final sep = _separationArcsec(ra, dec, match.raDegrees, match.decDegrees);
    if (sep <= toleranceArcsec && sep < bestSep) {
      bestSep = sep;
      best = row.candidateId;
    }
  }
  return best ?? match.candidateId;
}

String _candidateIdFor(MovingObjectDetection d, MovingObjectFrameDetections f) {
  final seconds = f.midExposureUtc.millisecondsSinceEpoch ~/ 1000;
  return 'mo_${seconds}_${d.raDegrees.toStringAsFixed(5)}_'
      '${d.decDegrees.toStringAsFixed(5)}';
}

bool _pixelStatic(List<_Point> hits, double tolerancePx) {
  final mx = hits.map((h) => h.det.x).reduce((a, b) => a + b) / hits.length;
  final my = hits.map((h) => h.det.y).reduce((a, b) => a + b) / hits.length;
  return hits.every((h) {
    final dx = h.det.x - mx;
    final dy = h.det.y - my;
    return math.sqrt(dx * dx + dy * dy) < tolerancePx;
  });
}

class _LineFit {
  _LineFit(this.vx, this.vy, this.rms, this.span);
  final double vx;
  final double vy;
  final double rms;
  final double span;
}

_LineFit? _fitLine(List<_Point> hits, List<double> times) {
  final ts = [for (final h in hits) times[h.frame]];
  final mt = ts.reduce((a, b) => a + b) / ts.length;
  final mx = hits.map((h) => h.xi).reduce((a, b) => a + b) / hits.length;
  final my = hits.map((h) => h.eta).reduce((a, b) => a + b) / hits.length;
  var stt = 0.0;
  var stx = 0.0;
  var sty = 0.0;
  for (var i = 0; i < hits.length; i++) {
    final dt = ts[i] - mt;
    stt += dt * dt;
    stx += dt * (hits[i].xi - mx);
    sty += dt * (hits[i].eta - my);
  }
  if (stt <= 0) return null;
  final vx = stx / stt;
  final vy = sty / stt;
  var ss = 0.0;
  for (var i = 0; i < hits.length; i++) {
    final dt = ts[i] - mt;
    final rx = hits[i].xi - (mx + vx * dt);
    final ry = hits[i].eta - (my + vy * dt);
    ss += rx * rx + ry * ry;
  }
  final span = ts.reduce(math.max) - ts.reduce(math.min);
  return _LineFit(vx, vy, math.sqrt(ss / hits.length), span);
}

(double, double)? _meanDirection(List<MovingObjectDetection> dets) {
  if (dets.isEmpty) return null;
  var x = 0.0, y = 0.0, z = 0.0;
  for (final d in dets) {
    final ra = d.raDegrees * math.pi / 180.0;
    final dec = d.decDegrees * math.pi / 180.0;
    x += math.cos(dec) * math.cos(ra);
    y += math.cos(dec) * math.sin(ra);
    z += math.sin(dec);
  }
  final r = math.sqrt(x * x + y * y + z * z);
  if (r == 0) return null;
  final ra = (math.atan2(y, x) * 180.0 / math.pi + 360.0) % 360.0;
  final dec = math.asin(z / r) * 180.0 / math.pi;
  return (ra, dec);
}

/// Gnomonic offsets (arcsec) of (ra, dec) about (ra0, dec0); xi toward
/// increasing RA, eta toward north.
(double, double)? _tangent(double ra0, double dec0, double ra, double dec) {
  const d2r = math.pi / 180.0;
  final a0 = ra0 * d2r, d0 = dec0 * d2r, a = ra * d2r, d = dec * d2r;
  final cosc =
      math.sin(d0) * math.sin(d) +
      math.cos(d0) * math.cos(d) * math.cos(a - a0);
  if (cosc <= 0) return null;
  final xi = math.cos(d) * math.sin(a - a0) / cosc;
  final eta =
      (math.cos(d0) * math.sin(d) -
          math.sin(d0) * math.cos(d) * math.cos(a - a0)) /
      cosc;
  const r2as = 180.0 / math.pi * 3600.0;
  return (xi * r2as, eta * r2as);
}

double _separationArcsec(double ra1, double dec1, double ra2, double dec2) {
  const d2r = math.pi / 180.0;
  final dLat = (dec2 - dec1) * d2r;
  final dLon = (ra2 - ra1) * d2r;
  final h =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(dec1 * d2r) *
          math.cos(dec2 * d2r) *
          math.pow(math.sin(dLon / 2), 2);
  return 2 * math.asin(math.sqrt(h).clamp(0.0, 1.0)) / d2r * 3600.0;
}

/// Uniform spatial hash over one frame's tangent-plane points.
class _Grid {
  _Grid(List<_Point> points, this.cell) {
    for (final p in points) {
      _cells.putIfAbsent(_key(p.xi, p.eta), () => []).add(p);
    }
  }

  final double cell;
  final Map<int, List<_Point>> _cells = {};

  int _ix(double v) => (v / cell).floor();
  int _key(double x, double y) => _pack(_ix(x), _ix(y));
  int _pack(int ix, int iy) => (ix + 1048576) * 2097152 + (iy + 1048576);

  Iterable<_Point> within(double x, double y, double radius) sync* {
    final r = (radius / cell).ceil();
    final cx = _ix(x), cy = _ix(y);
    for (var ix = cx - r; ix <= cx + r; ix++) {
      for (var iy = cy - r; iy <= cy + r; iy++) {
        final list = _cells[_pack(ix, iy)];
        if (list == null) continue;
        for (final p in list) {
          final dx = p.xi - x, dy = p.eta - y;
          if (dx * dx + dy * dy <= radius * radius) yield p;
        }
      }
    }
  }

  _Point? nearest(double x, double y, double radius, bool Function(_Point) ok) {
    _Point? best;
    var bestD = double.infinity;
    for (final p in within(x, y, radius)) {
      if (!ok(p)) continue;
      final dx = p.xi - x, dy = p.eta - y;
      final d = dx * dx + dy * dy;
      if (d < bestD) {
        bestD = d;
        best = p;
      }
    }
    return best;
  }
}
