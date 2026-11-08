import 'dart:math' as math;

/// What the next flat frame should be, or why the filter has to stop.
sealed class FlatExposurePlan {
  const FlatExposurePlan();
}

/// Take the next frame at [exposure] seconds.
final class FlatExposureNext extends FlatExposurePlan {
  const FlatExposureNext(this.exposure);
  final double exposure;
}

/// The light has gone beyond what the exposure range can reach: too dark for
/// the longest exposure ([tooDark]) or too bright for the shortest.
final class FlatExposureOutOfRange extends FlatExposurePlan {
  const FlatExposureOutOfRange({
    required this.tooDark,
    required this.neededExposure,
  });
  final bool tooDark;

  /// The exposure the target would need now, outside the allowed range.
  final double neededExposure;
}

/// Keeps flat frames inside the tolerance band while the light changes.
///
/// The calibration finds one exposure, and the frames used to be taken at it
/// for the whole filter. In twilight the sky darkens (dusk) or brightens
/// (dawn) every frame, so the frames walked out of the band: the owner's ±5%
/// dusk flats on 2026-11-08 left the band while the exposure never moved.
///
/// Every frame now feeds back. The next exposure is what the last frame would
/// have needed to land on the target, carried forward along the light's
/// measured trend to the middle of the next exposure. The trend is the slope
/// of log(ADU per second) against time over recent frames, which suits
/// twilight (the sky's brightness changes by a roughly constant factor per
/// minute) and, unlike a slope of ADU per second against time, is not thrown
/// off by the bias pedestal when the exposures being compared differ.
///
/// A panel's light is steady: its frames keep one exposure, so they match a
/// single dark flat, and the exposure is corrected only when a frame leaves
/// the band.
class FlatExposureFollower {
  FlatExposureFollower({
    required this.targetAdu,
    required this.tolerancePercent,
    required this.minExposure,
    required this.maxExposure,
    required this.changingLight,
  });

  final double targetAdu;
  final double tolerancePercent;
  final double minExposure;
  final double maxExposure;

  /// Sky flats: predict along the trend. Panel flats: hold the exposure.
  final bool changingLight;

  /// Frames older than this say nothing about the light now.
  static const Duration trendWindow = Duration(minutes: 5);

  /// Most frames the trend is fitted over.
  static const int trendFrames = 6;

  /// Largest change of exposure from one frame to the next.
  static const double maxStepRatio = 3.0;

  final List<_Frame> _frames = [];

  double get _toleranceAdu => targetAdu * tolerancePercent / 100.0;

  /// Whether a frame's mean ADU is inside the tolerance band.
  bool inBand(double adu) => (adu - targetAdu).abs() <= _toleranceAdu;

  /// A frame (or the calibration's last test frame) and when it was exposed.
  void record({
    required double exposure,
    required double adu,
    required DateTime start,
  }) {
    if (exposure <= 0 || adu <= 0 || !adu.isFinite) return;
    final midpoint = start.add(
      Duration(microseconds: (exposure * 1e6 / 2).round()),
    );
    _frames.add(_Frame(exposure: exposure, adu: adu, midpoint: midpoint));
    final cutoff = midpoint.subtract(trendWindow);
    _frames.removeWhere((f) => f.midpoint.isBefore(cutoff));
    while (_frames.length > trendFrames) {
      _frames.removeAt(0);
    }
  }

  /// The light's trend: d ln(ADU per second) / dt, per second. Null until two
  /// frames at least a second apart exist.
  double? get trendPerSecond {
    if (_frames.length < 2) return null;
    final t0 = _frames.first.midpoint;
    final xs = [
      for (final f in _frames) f.midpoint.difference(t0).inMicroseconds / 1e6,
    ];
    final ys = [for (final f in _frames) math.log(f.adu / f.exposure)];
    final n = xs.length;
    final meanX = xs.reduce((a, b) => a + b) / n;
    final meanY = ys.reduce((a, b) => a + b) / n;
    var sxx = 0.0;
    var sxy = 0.0;
    for (var i = 0; i < n; i++) {
      sxx += (xs[i] - meanX) * (xs[i] - meanX);
      sxy += (xs[i] - meanX) * (ys[i] - meanY);
    }
    if (sxx < 1.0) return null;
    return sxy / sxx;
  }

  /// The exposure for a frame that starts at [plannedStart].
  FlatExposurePlan next({required DateTime plannedStart}) {
    if (_frames.isEmpty) {
      throw StateError('FlatExposureFollower.next before any frame');
    }
    final last = _frames.last;
    final double needed;
    if (!changingLight && inBand(last.adu)) {
      needed = last.exposure;
    } else {
      // What the last frame needed to land on the target.
      final atLast = last.exposure * targetAdu / last.adu;
      final trend = changingLight ? trendPerSecond : null;
      if (trend == null) {
        needed = atLast;
      } else {
        // Carry it to the middle of the next exposure. The midpoint depends
        // on the exposure, so settle it in a couple of passes.
        var exposure = atLast;
        for (var i = 0; i < 3; i++) {
          final mid = plannedStart.add(
            Duration(microseconds: (exposure * 1e6 / 2).round()),
          );
          final dt = mid.difference(last.midpoint).inMicroseconds / 1e6;
          exposure = atLast / math.exp(trend * dt);
        }
        needed = exposure;
      }
    }

    final stepped = needed.clamp(
      last.exposure / maxStepRatio,
      last.exposure * maxStepRatio,
    );
    if (needed > maxExposure) {
      // At the longest exposure the frame would fall short of the band.
      if (targetAdu * maxExposure / needed < targetAdu - _toleranceAdu) {
        return FlatExposureOutOfRange(tooDark: true, neededExposure: needed);
      }
    } else if (needed < minExposure) {
      if (targetAdu * minExposure / needed > targetAdu + _toleranceAdu) {
        return FlatExposureOutOfRange(tooDark: false, neededExposure: needed);
      }
    }
    return FlatExposureNext(stepped.clamp(minExposure, maxExposure));
  }
}

class _Frame {
  const _Frame({
    required this.exposure,
    required this.adu,
    required this.midpoint,
  });
  final double exposure;
  final double adu;
  final DateTime midpoint;
}
