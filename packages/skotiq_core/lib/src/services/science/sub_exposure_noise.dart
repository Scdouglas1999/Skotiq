import 'dart:math' as math;

/// Sky (plus dark) noise in a sub over the camera's read noise.
///
/// The measured background noise of a light frame is the quadrature sum of
/// sky and dark shot noise and read noise. In electrons:
/// `noise_e^2 = sky_e + dark_e + RN^2`, so the sky-and-dark part is
/// `sqrt(noise_e^2 - RN^2)`. Dividing it by the read noise says how much the
/// read noise matters: at 3 the read noise adds 5% to the total noise and the
/// sub is sky-limited (longer subs barely improve a night's result); at 1 it
/// adds 41% and longer subs help.
///
/// Returns null when the noise, the gain (e-/ADU) or the read noise (e-) is
/// unknown or not positive, and 0 when the measured noise is no larger than
/// the read noise alone.
double? skyToReadNoiseRatio({
  required double noiseAdu,
  required double? gainEPerAdu,
  required double? readNoiseE,
}) {
  if (!noiseAdu.isFinite || noiseAdu <= 0) return null;
  if (gainEPerAdu == null || !gainEPerAdu.isFinite || gainEPerAdu <= 0) {
    return null;
  }
  if (readNoiseE == null || !readNoiseE.isFinite || readNoiseE <= 0) {
    return null;
  }
  final totalE = noiseAdu * gainEPerAdu;
  final skyVariance = totalE * totalE - readNoiseE * readNoiseE;
  if (skyVariance <= 0) return 0.0;
  return math.sqrt(skyVariance) / readNoiseE;
}

/// At or above this ratio a sub is sky-limited: read noise adds at most about
/// 5% to its noise.
const double kSkyLimitedNoiseRatio = 3.0;

/// How much read noise adds to the total noise of a sub with sky-to-read-noise
/// ratio [ratio], as a fraction (0.05 = 5%).
double readNoisePenalty(double ratio) {
  if (ratio <= 0) return double.infinity;
  return math.sqrt(1 + 1 / (ratio * ratio)) - 1;
}
