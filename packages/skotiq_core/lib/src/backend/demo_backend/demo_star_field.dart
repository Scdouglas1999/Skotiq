import 'dart:math' as math;
import 'dart:typed_data';

/// What a demo exposure is taken with. Plain values only, so a request can
/// cross to a background isolate.
class DemoFrameRequest {
  const DemoFrameRequest({
    required this.width,
    required this.height,
    required this.exposureSeconds,
    required this.frameKind,
    required this.fieldSeed,
    required this.frameSeed,
    required this.starSigmaPx,
    required this.filterThroughput,
    required this.gain,
    required this.offset,
    required this.sensorTempC,
    required this.binning,
  });

  final int width;
  final int height;
  final double exposureSeconds;

  /// `light`, `dark`, `flat`, `bias`, `darkFlat` or `snapshot`.
  final String frameKind;

  /// Picks the star field: the same pointing gives the same stars.
  final int fieldSeed;

  /// Picks this frame's noise and its small offset from the last frame.
  final int frameSeed;

  /// Star profile width, from how far the focuser is from best focus.
  final double starSigmaPx;

  /// Fraction of the light the current filter lets through.
  final double filterThroughput;
  final int gain;
  final int offset;
  final double sensorTempC;
  final int binning;
}

/// A rendered demo frame: the camera's 16-bit samples, the screen stretch
/// of them as RGBA, and their measurements.
class DemoFrame {
  const DemoFrame({
    required this.width,
    required this.height,
    required this.raw,
    required this.displayRgba,
    required this.histogram,
    required this.min,
    required this.max,
    required this.mean,
    required this.median,
    required this.stdDev,
    required this.hfr,
    required this.fwhm,
    required this.starCount,
  });

  final int width;
  final int height;
  final Uint16List raw;
  final Uint8List displayRgba;
  final List<int> histogram;
  final double min;
  final double max;
  final double mean;
  final double median;
  final double stdDev;
  final double? hfr;
  final double? fwhm;
  final int starCount;
}

/// Render a deterministic star field with noise for [request]. Cheap enough
/// for a phone at the demo camera's size, and meant to run off the UI
/// isolate.
DemoFrame renderDemoFrame(DemoFrameRequest request) {
  final w = request.width;
  final h = request.height;
  final n = w * h;
  final kind = request.frameKind;
  final isLightLike = kind == 'light' || kind == 'snapshot';
  final isFlat = kind == 'flat';
  final isBias = kind == 'bias';
  final exposure = isBias ? 0.0 : request.exposureSeconds;
  final gainScale = 0.5 + request.gain / 100.0;
  final binArea = (request.binning * request.binning).toDouble();

  // Electrons per pixel, then a flat conversion to ADU.
  final pedestal = 300.0 + request.offset * 10.0;
  final darkPerSecond =
      0.02 * math.pow(2.0, (request.sensorTempC + 10.0) / 6.0) * binArea;
  final skyPerSecond = isLightLike
      ? 6.0 * request.filterThroughput * binArea
      : 0.0;
  final background =
      (skyPerSecond + darkPerSecond) * exposure * gainScale + pedestal;
  const readNoise = 6.0;

  final image = Float64List(n);
  final noise = math.Random(request.frameSeed);
  double gaussian() {
    // Box-Muller; one of the pair is enough here.
    final u1 = noise.nextDouble().clamp(1e-12, 1.0);
    final u2 = noise.nextDouble();
    return math.sqrt(-2.0 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  final shotSigma = math.sqrt(math.max(background - pedestal, 0.0));
  final sigma = math.sqrt(readNoise * readNoise + shotSigma * shotSigma);
  if (isFlat) {
    // An even field that falls off toward the corners, at about half scale.
    final cx = w / 2.0;
    final cy = h / 2.0;
    final r2max = cx * cx + cy * cy;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final dx = x - cx;
        final dy = y - cy;
        final vignette = 1.0 - 0.25 * (dx * dx + dy * dy) / r2max;
        final level = 30000.0 * vignette;
        image[y * w + x] = level + gaussian() * math.sqrt(level);
      }
    }
  } else {
    for (var i = 0; i < n; i++) {
      image[i] = background + gaussian() * sigma;
    }
  }

  var starCount = 0;
  if (isLightLike && exposure > 0) {
    final field = math.Random(request.fieldSeed);
    final jitter = math.Random(request.frameSeed ^ 0x5bd1e995);
    final shiftX = (jitter.nextDouble() - 0.5) * 3.0;
    final shiftY = (jitter.nextDouble() - 0.5) * 3.0;
    final s = request.starSigmaPx / request.binning;
    final twoS2 = 2 * s * s;
    final radius = (s * 4).ceil().clamp(2, 40);
    final stars = (w * h / 2600).round();
    for (var k = 0; k < stars; k++) {
      // Star brightness falls off as a power law: few bright, many faint.
      final x0 = field.nextDouble() * w + shiftX;
      final y0 = field.nextDouble() * h + shiftY;
      final magnitude = math.pow(field.nextDouble(), 3.0).toDouble();
      final flux =
          (400.0 + 90000.0 * magnitude) *
          exposure *
          request.filterThroughput *
          gainScale *
          binArea;
      final peak = flux / (math.pi * twoS2);
      if (peak > 5 * sigma) starCount++;
      final xi = x0.floor();
      final yi = y0.floor();
      for (var y = yi - radius; y <= yi + radius; y++) {
        if (y < 0 || y >= h) continue;
        final dy = y - y0;
        for (var x = xi - radius; x <= xi + radius; x++) {
          if (x < 0 || x >= w) continue;
          final dx = x - x0;
          image[y * w + x] += peak * math.exp(-(dx * dx + dy * dy) / twoS2);
        }
      }
    }
  }

  final raw = Uint16List(n);
  final counts = Uint32List(65536);
  var sum = 0.0;
  var sumSq = 0.0;
  var lo = 65535;
  var hi = 0;
  for (var i = 0; i < n; i++) {
    final v = image[i].round().clamp(0, 65535);
    raw[i] = v;
    counts[v]++;
    sum += v;
    sumSq += v.toDouble() * v;
    if (v < lo) lo = v;
    if (v > hi) hi = v;
  }
  final mean = sum / n;
  final variance = math.max(sumSq / n - mean * mean, 0.0);
  final median = _percentile(counts, n, 0.5).toDouble();

  // Median absolute deviation, read from the same counts.
  final deviations = Uint32List(65536);
  for (var v = 0; v < 65536; v++) {
    final c = counts[v];
    if (c == 0) continue;
    deviations[(v - median).abs().round().clamp(0, 65535)] += c;
  }
  final mad = math.max(_percentile(deviations, n, 0.5).toDouble(), 1.0);

  final display = Uint8List(n * 4);
  final histogram = List<int>.filled(256, 0);
  // The screen stretch: shadows a little under the background, midtones
  // chosen to put the background at a quarter of full scale.
  final shadows = math.max(median - 2.8 * 1.4826 * mad, 0.0);
  final range = math.max(65535.0 - shadows, 1.0);
  final m = _midtonesFor(((median - shadows) / range).clamp(0.0, 1.0), 0.25);
  final lut = Uint8List(65536);
  for (var v = 0; v < 65536; v++) {
    final x = ((v - shadows) / range).clamp(0.0, 1.0);
    lut[v] = (_mtf(m, x) * 255).round().clamp(0, 255);
  }
  for (var i = 0; i < n; i++) {
    final g = lut[raw[i]];
    final o = i * 4;
    display[o] = g;
    display[o + 1] = g;
    display[o + 2] = g;
    display[o + 3] = 255;
    histogram[g]++;
  }

  final hasStars = isLightLike && starCount > 0;
  final starSigma = request.starSigmaPx / request.binning;
  return DemoFrame(
    width: w,
    height: h,
    raw: raw,
    displayRgba: display,
    histogram: histogram,
    min: lo.toDouble(),
    max: hi.toDouble(),
    mean: mean,
    median: median,
    stdDev: math.sqrt(variance),
    // A Gaussian star's half-flux radius and full width at half maximum.
    hfr: hasStars ? 1.1774 * starSigma : null,
    fwhm: hasStars ? 2.3548 * starSigma : null,
    starCount: starCount,
  );
}

int _percentile(Uint32List counts, int total, double fraction) {
  final target = (total * fraction).ceil();
  var seen = 0;
  for (var v = 0; v < counts.length; v++) {
    seen += counts[v];
    if (seen >= target) return v;
  }
  return counts.length - 1;
}

double _mtf(double m, double x) {
  if (x <= 0) return 0;
  if (x >= 1) return 1;
  if (x == m) return 0.5;
  return ((m - 1) * x) / ((2 * m - 1) * x - m);
}

/// The midtones balance that maps [x] to [target].
double _midtonesFor(double x, double target) {
  if (x <= 0) return 0.5;
  return ((target - 1) * x) / ((2 * target - 1) * x - target);
}
