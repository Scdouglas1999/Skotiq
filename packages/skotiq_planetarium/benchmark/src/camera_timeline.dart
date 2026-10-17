// Scripted, fully-deterministic camera timeline for the paint benchmark.
//
// A fixed list of keyframes describes a pan + zoom-in + zoom-out + time-advance
// path. The keyframes are sampled into N evenly-spaced frames with smooth
// (cosine-eased) interpolation. There is NO runtime randomness and NO wall-clock
// read: simulated time is expressed as a fixed offset (seconds) from the
// fixture's base time, so every frame's inputs are reproducible.

import 'dart:math' as math;

import 'package:skotiq_planetarium/src/rendering/sky_renderer.dart';

/// One sampled frame: the exact painter inputs for that step of the path.
class CameraFrame {
  final int index;
  final double centerRaHours;
  final double centerDecDeg;
  final double fieldOfViewDeg;

  /// Simulated time as a whole-second offset from the fixture base time.
  final int timeOffsetSeconds;

  const CameraFrame({
    required this.index,
    required this.centerRaHours,
    required this.centerDecDeg,
    required this.fieldOfViewDeg,
    required this.timeOffsetSeconds,
  });

  SkyViewState toViewState() => SkyViewState(
    centerRA: centerRaHours,
    centerDec: centerDecDeg,
    fieldOfView: fieldOfViewDeg,
  );
}

/// A keyframe on the scripted path. Frames are interpolated between adjacent
/// keyframes.
class _Keyframe {
  final double raHours;
  final double decDeg;
  final double fovDeg;
  final int timeOffsetSeconds;
  const _Keyframe(
    this.raHours,
    this.decDeg,
    this.fovDeg,
    this.timeOffsetSeconds,
  );
}

/// Builds the canonical benchmark timeline around [anchorRaHours]/[anchorDecDeg]
/// (the fixture anchor), sampled into [frameCount] frames.
///
/// Path: start wide -> pan across the field -> zoom deep in -> hold while time
/// advances -> zoom back out -> pan home. This drives the cull (wide), the dense
/// near-field (deep zoom) and the horizon/alt-az recompute (time advance).
List<CameraFrame> buildBenchmarkTimeline({
  required double anchorRaHours,
  required double anchorDecDeg,
  int frameCount = 180,
}) {
  // Keyframes are deltas around the anchor so the path stays centred on the
  // populated patch. Time advances ~30 minutes total (drives horizon/alt-az).
  final keys = <_Keyframe>[
    _Keyframe(anchorRaHours - 0.8, anchorDecDeg + 6, 70, 0),
    _Keyframe(anchorRaHours + 0.9, anchorDecDeg - 8, 55, 300),
    _Keyframe(anchorRaHours + 0.3, anchorDecDeg + 2, 12, 600),
    _Keyframe(anchorRaHours + 0.3, anchorDecDeg + 2, 4, 1200), // deep hold
    _Keyframe(anchorRaHours - 0.4, anchorDecDeg - 3, 30, 1500),
    _Keyframe(anchorRaHours, anchorDecDeg, 70, 1800),
  ];

  final frames = <CameraFrame>[];
  final segments = keys.length - 1;
  for (var i = 0; i < frameCount; i++) {
    // Global progress 0..1 across the whole path.
    final t = frameCount == 1 ? 0.0 : i / (frameCount - 1);
    final scaled = t * segments;
    var seg = scaled.floor();
    if (seg >= segments) seg = segments - 1;
    final local = _easeInOut((scaled - seg).clamp(0.0, 1.0));
    final a = keys[seg];
    final b = keys[seg + 1];

    frames.add(
      CameraFrame(
        index: i,
        centerRaHours: _lerp(a.raHours, b.raHours, local),
        centerDecDeg: _lerp(a.decDeg, b.decDeg, local),
        // Interpolate FOV geometrically so the zoom feels linear in perceived
        // magnification rather than in raw degrees.
        fieldOfViewDeg: _geomLerp(a.fovDeg, b.fovDeg, local),
        timeOffsetSeconds: _lerp(
          a.timeOffsetSeconds.toDouble(),
          b.timeOffsetSeconds.toDouble(),
          local,
        ).round(),
      ),
    );
  }
  return frames;
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

double _geomLerp(double a, double b, double t) =>
    a * math.pow(b / a, t).toDouble();

/// Smooth cosine ease so the camera doesn't jerk at keyframe boundaries.
double _easeInOut(double t) => 0.5 - 0.5 * math.cos(t * math.pi);
