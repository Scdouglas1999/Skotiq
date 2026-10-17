import 'dart:convert';

import 'autofocus_progress.dart';
import 'focuser_backlash_calibration.dart';

/// Where a backlash calibration run has got to.
///
/// The two scanning phases are separate states rather than one "scanning"
/// because the whole point of the run is the difference between them: the UI
/// draws two curves and has to know which one is growing.
enum FocuserBacklashPhase {
  idle,
  scanningFromBelow,
  scanningFromAbove,
  analysing,
  complete,
  refused,
  failed;

  /// Whether the run is still working. [analysing] counts: both scans are
  /// done but the focuser has not been released and no answer exists yet.
  bool get isActive =>
      this == scanningFromBelow ||
      this == scanningFromAbove ||
      this == analysing;
}

/// One progress frame from a running calibration.
class FocuserBacklashProgressData {
  const FocuserBacklashProgressData({
    required this.phase,
    required this.point,
    required this.totalPoints,
    required this.position,
    required this.hfr,
    required this.starCount,
    required this.scanRange,
    required this.points,
  });

  final FocuserBacklashPhase phase;

  /// 1-based index within the current scan, 0 on the `analysing` frame which
  /// carries no point at all.
  final int point;
  final int totalPoints;

  /// Null on the `analysing` frame.
  final int? position;
  final double? hfr;
  final int? starCount;

  /// The range both scans sample, so a chart can fix its axis before the
  /// points arrive. Null on the `analysing` frame.
  final FocusRange? scanRange;

  /// Every point of the CURRENT scan so far. A phase change starts this over.
  final List<VCurvePoint> points;

  /// Parse a `focuser_backlash_progress` frame. Returns null for anything
  /// else, including the `focuser_backlash_result` frame — that one is
  /// [tryParseResult]'s.
  static FocuserBacklashProgressData? tryParse(String detail) {
    final json = _decodeFrame(detail, 'focuser_backlash_progress');
    if (json == null) return null;
    final phase = switch (json['phase']) {
      'from_below' => FocuserBacklashPhase.scanningFromBelow,
      'from_above' => FocuserBacklashPhase.scanningFromAbove,
      'analysing' => FocuserBacklashPhase.analysing,
      _ => null,
    };
    if (phase == null) return null;

    // The analysing frame carries only its type and phase: both scans are in,
    // nothing is being exposed, and there is no point to report.
    if (phase == FocuserBacklashPhase.analysing) {
      return const FocuserBacklashProgressData(
        phase: FocuserBacklashPhase.analysing,
        point: 0,
        totalPoints: 0,
        position: null,
        hfr: null,
        starCount: null,
        scanRange: null,
        points: [],
      );
    }

    final point = json['point'];
    final totalPoints = json['total_points'];
    final position = json['position'];
    final hfr = json['hfr'];
    final starCount = json['star_count'];
    if (point is! int ||
        totalPoints is! int ||
        position is! int ||
        hfr is! num ||
        starCount is! int) {
      return null;
    }

    final rawRange = json['scan_range'];
    FocusRange? scanRange;
    if (rawRange is Map) {
      final min = rawRange['min'];
      final max = rawRange['max'];
      if (min is! int || max is! int) return null;
      scanRange = FocusRange(min: min, max: max);
    } else if (rawRange != null) {
      return null;
    }

    final rawPoints = json['points'];
    if (rawPoints is! List) return null;
    final points = <VCurvePoint>[];
    for (final raw in rawPoints) {
      if (raw is! Map) return null;
      final pointPosition = raw['position'];
      final pointHfr = raw['hfr'];
      if (pointPosition is! int || pointHfr is! num) return null;
      points.add(
        VCurvePoint(position: pointPosition, hfr: pointHfr.toDouble()),
      );
    }

    return FocuserBacklashProgressData(
      phase: phase,
      point: point,
      totalPoints: totalPoints,
      position: position,
      hfr: hfr.toDouble(),
      starCount: starCount,
      scanRange: scanRange,
      points: points,
    );
  }

  /// Parse the terminal `focuser_backlash_result` frame. Returns null for a
  /// progress frame, so a caller can try both and act on whichever matched.
  static FocuserBacklashResult? tryParseResult(String detail) {
    final json = _decodeFrame(detail, 'focuser_backlash_result');
    if (json == null) return null;
    return FocuserBacklashResult.fromJson(json['result']);
  }

  static Map<Object?, Object?>? _decodeFrame(String detail, String type) {
    Object? decoded;
    try {
      decoded = jsonDecode(detail);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    if (decoded['type'] != type) return null;
    return decoded;
  }
}
