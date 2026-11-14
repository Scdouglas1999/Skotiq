// Owner report 2026-11-08: dusk sky flats converged, then "as the flat
// exposures are taken it looks like I left my ±5% band of histogram tolerance
// but the app isn't increasing exposure". The frames were all taken at the
// calibrated exposure. These tests run the follower against a modeled
// twilight sky: brightness halving every few minutes, a bias pedestal, and a
// few seconds between frames for download and save.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/flat_exposure_follower.dart';

/// Mean ADU of a frame from a sky that halves every [halfLife] seconds
/// (negative: doubles, dawn), starting at [rate0] ADU per second.
class _Twilight {
  _Twilight({required this.rate0, required this.halfLife});
  final double rate0;
  final double halfLife;
  static const double pedestal = 500;

  double rateAt(double t) => rate0 * math.pow(0.5, t / halfLife);

  double frame(double start, double exposure) {
    // Integrate the light over the exposure.
    const steps = 20;
    var light = 0.0;
    for (var i = 0; i < steps; i++) {
      light += rateAt(start + exposure * (i + 0.5) / steps) * exposure / steps;
    }
    return math.min(65535, pedestal + light);
  }
}

final _t0 = DateTime.utc(2026, 11, 8, 22);
DateTime _at(double seconds) =>
    _t0.add(Duration(microseconds: (seconds * 1e6).round()));

/// Run [frames] frames after a calibration that landed on the target at
/// [startExposure]. Returns each frame's (exposure, adu); stops early on an
/// out-of-range plan.
({List<(double, double)> frames, FlatExposureOutOfRange? stopped}) _run({
  required _Twilight sky,
  required double startExposure,
  required int frames,
  bool changingLight = true,
  bool follow = true,
  double overhead = 3,
  double maxExposure = 30,
}) {
  final follower = FlatExposureFollower(
    targetAdu: 32768,
    tolerancePercent: 5,
    minExposure: 0.01,
    maxExposure: maxExposure,
    changingLight: changingLight,
  );
  var t = 0.0;
  // The calibration's last test frame.
  follower.record(
    exposure: startExposure,
    adu: sky.frame(t, startExposure),
    start: _at(t),
  );
  t += startExposure + overhead;
  var exposure = startExposure;
  final out = <(double, double)>[];
  for (var i = 0; i < frames; i++) {
    if (follow) {
      final plan = follower.next(plannedStart: _at(t));
      switch (plan) {
        case FlatExposureNext(exposure: final planned):
          exposure = planned;
        case FlatExposureOutOfRange():
          return (frames: out, stopped: plan);
      }
    }
    final adu = sky.frame(t, exposure);
    follower.record(exposure: exposure, adu: adu, start: _at(t));
    out.add((exposure, adu));
    t += exposure + overhead;
  }
  return (frames: out, stopped: null);
}

bool _inBand(double adu) => (adu - 32768).abs() <= 32768 * 0.05;

void main() {
  // A dusk sky at the target with a 3 s exposure, halving every 4 minutes.
  final dusk = _Twilight(rate0: (32768 - 500) / 3, halfLife: 240);

  test('without feedback, dusk frames leave the ±5% band', () {
    final run = _run(sky: dusk, startExposure: 3, frames: 20, follow: false);
    expect(run.frames.where((f) => !_inBand(f.$2)), isNotEmpty);
  });

  test('dusk frames stay inside ±5% as the exposure rises', () {
    final run = _run(sky: dusk, startExposure: 3, frames: 30);
    expect(run.stopped, isNull);
    for (final (exposure, adu) in run.frames) {
      expect(_inBand(adu), isTrue, reason: '$exposure s read $adu ADU');
    }
    expect(run.frames.last.$1, greaterThan(run.frames.first.$1 * 1.3));
  });

  test('dawn frames stay inside ±5% as the exposure falls', () {
    final dawn = _Twilight(rate0: (32768 - 500) / 3, halfLife: -240);
    final run = _run(sky: dawn, startExposure: 3, frames: 30);
    expect(run.stopped, isNull);
    for (final (exposure, adu) in run.frames) {
      expect(_inBand(adu), isTrue, reason: '$exposure s read $adu ADU');
    }
    expect(run.frames.last.$1, lessThan(run.frames.first.$1 / 1.3));
  });

  test('a sky too dark for the longest exposure stops the filter', () {
    final fast = _Twilight(rate0: (32768 - 500) / 10, halfLife: 60);
    final run = _run(
      sky: fast,
      startExposure: 10,
      frames: 100,
      maxExposure: 20,
    );
    final stop = run.stopped;
    expect(stop, isNotNull);
    expect(stop!.tooDark, isTrue);
    expect(stop.neededExposure, greaterThan(20));
    // A plain figure for the message, not a runaway extrapolation (the
    // simulator run first printed 2189671392.5 s).
    expect(stop.neededExposure, lessThan(200));
    // A sky this fast moves the first frame out of the band before the
    // follower has a trend; the run loop discards that frame. From then on
    // every frame is inside.
    for (final (_, adu) in run.frames.skip(1)) {
      expect(_inBand(adu), isTrue, reason: '${run.frames}');
    }
  });

  test('a steady panel keeps one exposure for every frame', () {
    final panel = _Twilight(rate0: (32768 - 500) / 2, halfLife: 1e12);
    final run = _run(
      sky: panel,
      startExposure: 2,
      frames: 20,
      changingLight: false,
    );
    expect(run.frames.map((f) => f.$1).toSet(), {2.0});
  });

  test('a drifting panel is corrected once a frame leaves the band', () {
    // A panel dimming slowly as it warms: 10% over a few minutes.
    final panel = _Twilight(rate0: (32768 - 500) / 2, halfLife: 1800);
    final run = _run(
      sky: panel,
      startExposure: 2,
      frames: 60,
      changingLight: false,
    );
    final exposures = run.frames.map((f) => f.$1).toList();
    expect(exposures.toSet().length, greaterThan(1));
    // Every frame after a correction is back inside.
    for (var i = 1; i < run.frames.length; i++) {
      if (exposures[i] != exposures[i - 1]) {
        expect(_inBand(run.frames[i].$2), isTrue);
      }
    }
  });
}
