part of '../sequence_time_estimator.dart';

/// Optional location context for astronomical calculations
class _LocationContext {
  final double latitude;
  final double longitude;
  final DateTime date;

  const _LocationContext({
    required this.latitude,
    required this.longitude,
    required this.date,
  });
}

/// Timing information for a single sequence node
class NodeTiming {
  /// Unique identifier of the node
  final String nodeId;

  /// Display name of the node
  final String nodeName;

  /// Type identifier of the node (e.g., 'TakeExposure', 'Autofocus')
  final String nodeType;

  /// Estimated start time of this node
  final DateTime estimatedStart;

  /// Estimated end time of this node
  final DateTime estimatedEnd;

  /// Estimated duration of this node
  final Duration duration;

  /// Warning messages for timing conflicts (e.g., target below horizon)
  final List<String>? warnings;

  /// ID of the parent target header node, if any
  final String? targetHeaderId;

  NodeTiming({
    required this.nodeId,
    required this.nodeName,
    required this.nodeType,
    required this.estimatedStart,
    required this.estimatedEnd,
    required this.duration,
    this.warnings,
    this.targetHeaderId,
  });

  /// Create a copy with updated warnings
  NodeTiming copyWithWarnings(List<String> newWarnings) {
    return NodeTiming(
      nodeId: nodeId,
      nodeName: nodeName,
      nodeType: nodeType,
      estimatedStart: estimatedStart,
      estimatedEnd: estimatedEnd,
      duration: duration,
      warnings: newWarnings.isNotEmpty ? newWarnings : null,
      targetHeaderId: targetHeaderId,
    );
  }

  @override
  String toString() {
    return 'NodeTiming(nodeId: $nodeId, nodeName: $nodeName, nodeType: $nodeType, '
        'start: $estimatedStart, end: $estimatedEnd, duration: $duration, '
        'warnings: $warnings, targetHeaderId: $targetHeaderId)';
  }
}

/// Visibility window information for a target
class TargetWindow {
  /// Database ID of the target (from TargetHeaderNode)
  final String targetId;

  /// Display name of the target
  final String targetName;

  /// Time when the target rises above the minimum altitude
  final DateTime? riseTime;

  /// Time when the target crosses the meridian (highest altitude)
  final DateTime? transitTime;

  /// Time when the target sets below the minimum altitude
  final DateTime? setTime;

  /// Altitude at transit in degrees
  final double? transitAltitude;

  /// True if the target never sets below the minimum altitude
  final bool isCircumpolar;

  /// True if the target never rises above the minimum altitude
  final bool neverRises;

  /// Sky geometry this window was solved from, in degrees. Populated by
  /// [SequenceTimeEstimator.calculateTargetWindows]; null on windows built
  /// directly (fixtures, callers that only have rise/set instants).
  final double? raDeg;
  final double? decDeg;
  final double? latitudeDeg;
  final double? longitudeDeg;

  /// Altitude that defines "up" for this window, in degrees.
  final double? minAltitudeDeg;

  TargetWindow({
    required this.targetId,
    required this.targetName,
    this.riseTime,
    this.transitTime,
    this.setTime,
    this.transitAltitude,
    this.isCircumpolar = false,
    this.neverRises = false,
    this.raDeg,
    this.decDeg,
    this.latitudeDeg,
    this.longitudeDeg,
    this.minAltitudeDeg,
  });

  /// Apparent altitude of the target at [time], in degrees, or null when this
  /// window carries no geometry.
  double? altitudeAt(DateTime time) {
    final ra = raDeg;
    final dec = decDeg;
    final lat = latitudeDeg;
    final lon = longitudeDeg;
    if (ra == null || dec == null || lat == null || lon == null) return null;

    final (trueAlt, _) = AstronomyCalculations.equatorialToHorizontal(
      raDeg: ra,
      decDeg: dec,
      latitudeDeg: lat,
      lstHours: AstronomyCalculations.localSiderealTime(time, lon),
    );
    return AstronomyCalculations.trueToApparentAltitude(trueAlt);
  }

  /// Check if a given time falls within the visibility window.
  ///
  /// When geometry is available this asks the sky directly: is the target
  /// above the altitude floor AT `time`. The rise/set pair cannot answer that
  /// on its own, because the solver scans one noon-to-noon window and so
  /// reports the NEXT rise for a target that is already up at the anchor — a
  /// target at the zenith at 12:47 came back as "rises at 03:41" (tomorrow)
  /// and every membership test against that interval said "not up yet".
  bool isVisibleAt(DateTime time) {
    if (neverRises) return false;
    if (isCircumpolar) return true;

    final altitude = altitudeAt(time);
    if (altitude != null) {
      return altitude >= (minAltitudeDeg ?? 0);
    }

    if (riseTime == null || setTime == null) return false;

    // Handle window that crosses midnight
    if (setTime!.isBefore(riseTime!)) {
      // Window crosses midnight: visible if after rise OR before set
      return time.isAfter(riseTime!) || time.isBefore(setTime!);
    }

    return time.isAfter(riseTime!) && time.isBefore(setTime!);
  }

  @override
  String toString() {
    return 'TargetWindow(targetId: $targetId, targetName: $targetName, '
        'rise: $riseTime, transit: $transitTime, set: $setTime, '
        'transitAlt: $transitAltitude, circumpolar: $isCircumpolar, neverRises: $neverRises)';
  }
}
