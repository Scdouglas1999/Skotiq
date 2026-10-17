import 'dart:math' as math;

import '../../models/weather/weather_models.dart';

/// Why a cloud-motion analysis could not produce a real result.
///
/// These are surfaced loudly (rather than silently returning a fabricated
/// uniform-field motion) so the UI / sequencer can say *why* prediction is
/// unavailable instead of acting on garbage data.
enum CloudMotionUnavailableReason {
  /// Fewer than two frames were supplied — motion needs a before/after pair.
  insufficientFrames,

  /// No grid cell in the analysis area reached the cloud-density threshold,
  /// i.e. the sky is clear. (Not an error — there is simply nothing to track.)
  noCloudsDetected,

  /// The supplied frames carry no per-cell spatial structure: every frame is a
  /// single uniform-density box (e.g. a whole-world radar tile with a constant
  /// animation opacity, or a single-point cloud-cover scalar). Optical-flow /
  /// centroid tracking across such frames is meaningless because the centroid
  /// can never move, so no genuine arrival ETA or direction can be derived.
  noSpatialData,

  /// Spatial structure existed but the tracked cloud mass did not move enough
  /// between frames to yield a stable, physically-plausible motion vector.
  noResolvableMotion,
}

/// Result of a detailed cloud-motion analysis.
///
/// Carries either a real [CloudMotion] or an explicit [unavailableReason].
/// Exactly one of [motion] / [unavailableReason] is non-null.
class CloudMotionResult {
  const CloudMotionResult.available(CloudMotion this.motion)
    : unavailableReason = null;

  const CloudMotionResult.unavailable(
    CloudMotionUnavailableReason this.unavailableReason,
  ) : motion = null;

  /// The computed motion, or null when [unavailableReason] is set.
  final CloudMotion? motion;

  /// Why motion could not be computed, or null when [motion] is set.
  final CloudMotionUnavailableReason? unavailableReason;

  /// True when a real motion estimate is present.
  bool get isAvailable => motion != null;
}

/// Analyzes cloud motion from radar frame sequences to predict movement
/// patterns and estimate time of arrival at user location.
class CloudMotionAnalyzer {
  /// Earth's mean radius in kilometers
  static const double _earthRadiusKm = 6371.0;

  /// Minimum number of frames required for motion analysis
  static const int _minFramesRequired = 2;

  /// Default spacing between analysis grid points in kilometers
  static const double _defaultGridSpacingKm = 10.0;

  /// Minimum cloud density threshold (opacity) to consider as significant
  static const double _defaultDensityThreshold = 0.3;

  /// Maximum reasonable cloud speed in km/h for sanity checks
  static const double _maxReasonableSpeedKmh = 200.0;

  /// Frames captured within this tolerance of each other are treated as one
  /// snapshot (a single point in time delivered as a geographic tiling).
  static const Duration _snapshotBucketTolerance = Duration(seconds: 1);

  /// Minimum centroid displacement (km) between two snapshots for the motion to
  /// be considered resolvable. A shift below this — half the grid spacing — is
  /// at or below the sampling resolution and is treated as stationary rather
  /// than fabricating an arbitrary-direction vector.
  static const double _minResolvableDisplacementKm = _defaultGridSpacingKm / 2;

  /// Fraction of grid cells that significant, single-valued cloud must cover for
  /// the field to count as spatially uniform (untrackable). A single whole-area
  /// box covers ~all cells; any genuine cloud structure covers only part.
  static const double _uniformCoverageFraction = 0.95;

  /// Analyze cloud motion from a sequence of radar frames.
  ///
  /// Returns [CloudMotion] with speed, direction, and ETA to user location,
  /// or null if a real motion estimate cannot be produced (insufficient data,
  /// no clouds, no spatial structure, or unresolvable motion). When the caller
  /// needs to know *why* prediction is unavailable, use [analyzeMotionDetailed]
  /// instead — it returns an explicit [CloudMotionUnavailableReason] rather
  /// than collapsing every failure mode to null.
  ///
  /// Parameters:
  /// - [frames]: List of radar frames in chronological order (minimum 2)
  /// - [userLatitude]: User's latitude in degrees
  /// - [userLongitude]: User's longitude in degrees
  /// - [analysisRadiusKm]: Radius around user to analyze (default 100 km)
  CloudMotion? analyzeMotion({
    required List<RadarFrame> frames,
    required double userLatitude,
    required double userLongitude,
    double analysisRadiusKm = 100.0,
  }) {
    return analyzeMotionDetailed(
      frames: frames,
      userLatitude: userLatitude,
      userLongitude: userLongitude,
      analysisRadiusKm: analysisRadiusKm,
    ).motion;
  }

  /// Analyze cloud motion, returning an explicit availability result.
  ///
  /// Unlike [analyzeMotion], this never fabricates a motion vector from a
  /// spatially-uniform field. If the supplied frames carry no per-cell spatial
  /// structure — every frame is a single uniform-density box, which is the case
  /// for whole-world radar tiles (constant animation opacity) and single-point
  /// cloud-cover scalars — it returns
  /// [CloudMotionUnavailableReason.noSpatialData] so the caller can surface a
  /// clear "cloud-motion unavailable: no spatial data" state.
  CloudMotionResult analyzeMotionDetailed({
    required List<RadarFrame> frames,
    required double userLatitude,
    required double userLongitude,
    double analysisRadiusKm = 100.0,
  }) {
    // Validate input
    if (frames.length < _minFramesRequired) {
      return const CloudMotionResult.unavailable(
        CloudMotionUnavailableReason.insufficientFrames,
      );
    }

    // Sort frames by timestamp to ensure chronological order
    final sortedFrames = List<RadarFrame>.from(frames)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    // Group frames by capture time. A real spatial snapshot may be delivered as
    // several frames sharing one timestamp but covering different geographic
    // bounds (a radar tiling). We track the density field of each *snapshot*
    // through time, mapping every grid point to the most-specific (smallest)
    // frame that encloses it. With only whole-frame boxes this collapses to a
    // single uniform value per snapshot — which we detect below and reject.
    final snapshots = _groupFramesByTimestamp(sortedFrames);

    // Find nearest cloud mass in the most recent snapshot.
    final cloudMassResult = findNearestCloudMass(
      frames: sortedFrames,
      userLatitude: userLatitude,
      userLongitude: userLongitude,
    );

    if (cloudMassResult == null) {
      // No significant clouds detected within the analysis area.
      return const CloudMotionResult.unavailable(
        CloudMotionUnavailableReason.noCloudsDetected,
      );
    }

    final (cloudLat, cloudLon, cloudDistance) = cloudMassResult;

    // Track cloud centroid movement across successive snapshots. We also record
    // whether ANY snapshot pair carried genuine spatial structure (a non-uniform
    // density field). Optical-flow / centroid tracking on a uniform field is
    // meaningless — the centroid is pinned to the geometric centre and can never
    // move — so without spatial structure we must NOT report motion.
    final motionVectors = <_MotionVector>[];
    var sawSpatialStructure = false;

    for (int i = 1; i < snapshots.length; i++) {
      final prevSnapshot = snapshots[i - 1];
      final currentSnapshot = snapshots[i];

      final prevField = _buildDensityField(
        snapshot: prevSnapshot.frames,
        centerLat: userLatitude,
        centerLon: userLongitude,
        radiusKm: analysisRadiusKm,
      );
      final currentField = _buildDensityField(
        snapshot: currentSnapshot.frames,
        centerLat: userLatitude,
        centerLon: userLongitude,
        radiusKm: analysisRadiusKm,
      );

      // A snapshot pair can only yield real motion if at least one side has a
      // spatially-varying (non-uniform) cloud field. Record this regardless of
      // whether a vector is ultimately produced, so we can distinguish "no
      // spatial data at all" from "had structure but clouds didn't move".
      if (!prevField.isUniform || !currentField.isUniform) {
        sawSpatialStructure = true;
      }

      final prevCentroid = prevField.centroid;
      final currentCentroid = currentField.centroid;

      if (prevCentroid == null || currentCentroid == null) {
        continue;
      }

      // Skip pairs with no spatial structure — their centroids are both pinned
      // to the geometric centre, so any "displacement" would be an artefact.
      if (prevField.isUniform && currentField.isUniform) {
        continue;
      }

      final timeDiff = currentSnapshot.timestamp.difference(
        prevSnapshot.timestamp,
      );
      if (timeDiff.inSeconds <= 0) {
        continue;
      }

      final distance = calculateDistance(
        prevCentroid.$1,
        prevCentroid.$2,
        currentCentroid.$1,
        currentCentroid.$2,
      );

      // Reject sub-resolution displacement: a centroid shift smaller than the
      // grid spacing is indistinguishable from a stationary mass and would
      // fabricate a spurious (and arbitrarily-directed) motion vector. Such
      // snapshot pairs simply do not contribute — if no pair clears the bar the
      // result is reported as [CloudMotionUnavailableReason.noResolvableMotion].
      if (distance < _minResolvableDisplacementKm) {
        continue;
      }

      final direction = calculateBearing(
        prevCentroid.$1,
        prevCentroid.$2,
        currentCentroid.$1,
        currentCentroid.$2,
      );
      final speedKmh = (distance / timeDiff.inSeconds) * 3600.0;

      // Sanity check: ignore unrealistic speeds.
      if (speedKmh <= _maxReasonableSpeedKmh) {
        motionVectors.add(
          _MotionVector(speedKmh: speedKmh, directionDegrees: direction),
        );
      }
    }

    if (!sawSpatialStructure) {
      // Every frame was a single uniform box: the data structure carries no
      // per-cell information, so motion genuinely cannot be computed. Fail loud
      // rather than returning a fabricated constant-field motion.
      return const CloudMotionResult.unavailable(
        CloudMotionUnavailableReason.noSpatialData,
      );
    }

    if (motionVectors.isEmpty) {
      // Spatial structure existed but no resolvable displacement was found.
      return const CloudMotionResult.unavailable(
        CloudMotionUnavailableReason.noResolvableMotion,
      );
    }

    // Average the motion vectors to smooth out noise
    final avgSpeed =
        motionVectors.map((v) => v.speedKmh).reduce((a, b) => a + b) /
        motionVectors.length;

    // Average direction using circular mean to handle 0/360 wraparound
    final avgDirection = _averageDirection(
      motionVectors.map((v) => v.directionDegrees).toList(),
    );

    // Calculate ETA if clouds are approaching
    final eta = calculateEta(
      cloudDistanceKm: cloudDistance,
      cloudSpeedKmh: avgSpeed,
      cloudDirectionDeg: avgDirection,
      userLatitude: userLatitude,
      userLongitude: userLongitude,
      cloudLatitude: cloudLat,
      cloudLongitude: cloudLon,
    );

    return CloudMotionResult.available(
      CloudMotion(
        speedKmh: avgSpeed,
        directionDegrees: avgDirection,
        etaToLocation: eta,
        distanceKm: cloudDistance,
        calculatedAt: DateTime.now(),
      ),
    );
  }

  /// Find the nearest significant cloud mass to user location.
  ///
  /// Returns (latitude, longitude, distanceKm) or null if no significant
  /// clouds detected within analysis area.
  ///
  /// Uses the most recent non-forecast frame for analysis.
  (double lat, double lon, double distance)? findNearestCloudMass({
    required List<RadarFrame> frames,
    required double userLatitude,
    required double userLongitude,
    double densityThreshold = _defaultDensityThreshold,
  }) {
    if (frames.isEmpty) {
      return null;
    }

    // Use the most recent snapshot, preferring non-forecast data. A snapshot is
    // the set of frames sharing the most recent capture time (a tiling), so the
    // most-specific-enclosing-frame density lookup sees the whole coverage.
    final sortedFrames = List<RadarFrame>.from(frames)
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

    final recentFrame = sortedFrames.firstWhere(
      (f) => !f.isForecast,
      orElse: () => sortedFrames.first,
    );
    final recentSnapshot = sortedFrames
        .where(
          (f) =>
              f.timestamp.difference(recentFrame.timestamp).abs() <=
              _snapshotBucketTolerance,
        )
        .toList();

    // Sample grid points in a circular pattern around user
    final gridPoints = _generateGridPoints(
      centerLat: userLatitude,
      centerLon: userLongitude,
      radiusKm: 100.0,
      spacingKm: _defaultGridSpacingKm,
    );

    // Find grid points with significant cloud density
    final cloudPoints = <({double lat, double lon, double distance})>[];

    for (final point in gridPoints) {
      // Density = opacity of the most-specific frame in the snapshot that
      // encloses the point (0.0 if none cover it).
      final density = _estimateCloudDensity(recentSnapshot, point.$1, point.$2);

      if (density >= densityThreshold) {
        final distance = calculateDistance(
          userLatitude,
          userLongitude,
          point.$1,
          point.$2,
        );
        cloudPoints.add((lat: point.$1, lon: point.$2, distance: distance));
      }
    }

    if (cloudPoints.isEmpty) {
      return null;
    }

    // Return the nearest cloud point
    cloudPoints.sort((a, b) => a.distance.compareTo(b.distance));
    final nearest = cloudPoints.first;
    return (nearest.lat, nearest.lon, nearest.distance);
  }

  /// Calculate estimated time of arrival for clouds at user location.
  ///
  /// Returns null if clouds are moving away, stationary, or not approaching
  /// the user's location.
  Duration? calculateEta({
    required double cloudDistanceKm,
    required double cloudSpeedKmh,
    required double cloudDirectionDeg,
    required double userLatitude,
    required double userLongitude,
    required double cloudLatitude,
    required double cloudLongitude,
  }) {
    // Check for stationary clouds
    if (cloudSpeedKmh < 0.1) {
      return null;
    }

    // Calculate bearing from cloud to user
    final bearingToUser = calculateBearing(
      cloudLatitude,
      cloudLongitude,
      userLatitude,
      userLongitude,
    );

    // Check if clouds are approaching
    if (!areCloudsApproaching(
      cloudDirectionDeg: cloudDirectionDeg,
      bearingToUser: bearingToUser,
    )) {
      return null;
    }

    // Calculate effective approach speed using dot product
    // This accounts for clouds moving at an angle
    final angleDiff = _normalizeAngle(cloudDirectionDeg - bearingToUser);
    final approachSpeed =
        cloudSpeedKmh * math.cos(_degreesToRadians(angleDiff));

    if (approachSpeed <= 0) {
      return null;
    }

    // Calculate time = distance / speed
    final hoursToArrival = cloudDistanceKm / approachSpeed;
    final minutesToArrival = (hoursToArrival * 60).round();

    return Duration(minutes: minutesToArrival);
  }

  /// Calculate distance between two lat/lon points using Haversine formula.
  ///
  /// Returns distance in kilometers.
  double calculateDistance(double lat1, double lon1, double lat2, double lon2) {
    final lat1Rad = _degreesToRadians(lat1);
    final lat2Rad = _degreesToRadians(lat2);
    final deltaLatRad = _degreesToRadians(lat2 - lat1);
    final deltaLonRad = _degreesToRadians(lon2 - lon1);

    final a =
        math.sin(deltaLatRad / 2) * math.sin(deltaLatRad / 2) +
        math.cos(lat1Rad) *
            math.cos(lat2Rad) *
            math.sin(deltaLonRad / 2) *
            math.sin(deltaLonRad / 2);

    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));

    return _earthRadiusKm * c;
  }

  /// Calculate bearing from point 1 to point 2.
  ///
  /// Returns bearing in degrees (0-360, where 0=N, 90=E, 180=S, 270=W).
  double calculateBearing(double lat1, double lon1, double lat2, double lon2) {
    final lat1Rad = _degreesToRadians(lat1);
    final lat2Rad = _degreesToRadians(lat2);
    final deltaLonRad = _degreesToRadians(lon2 - lon1);

    final y = math.sin(deltaLonRad) * math.cos(lat2Rad);
    final x =
        math.cos(lat1Rad) * math.sin(lat2Rad) -
        math.sin(lat1Rad) * math.cos(lat2Rad) * math.cos(deltaLonRad);

    final bearingRad = math.atan2(y, x);
    final bearingDeg = _radiansToDegrees(bearingRad);

    // Normalize to 0-360
    return (bearingDeg + 360) % 360;
  }

  /// Check if clouds are approaching user (vs moving away).
  ///
  /// Clouds are considered approaching if their direction of movement is
  /// within 90 degrees of the bearing to the user.
  bool areCloudsApproaching({
    required double cloudDirectionDeg,
    required double bearingToUser,
  }) {
    final angleDiff = _normalizeAngle(cloudDirectionDeg - bearingToUser).abs();
    // Within 90 degrees means approaching (cos > 0)
    return angleDiff <= 90;
  }

  // Private helper methods

  /// Generate grid of sampling points in a circular pattern.
  List<(double lat, double lon)> _generateGridPoints({
    required double centerLat,
    required double centerLon,
    required double radiusKm,
    required double spacingKm,
  }) {
    final points = <(double, double)>[];
    final numRings = (radiusKm / spacingKm).ceil();

    // Center point
    points.add((centerLat, centerLon));

    // Concentric rings
    for (int ring = 1; ring <= numRings; ring++) {
      final ringRadiusKm = ring * spacingKm;
      if (ringRadiusKm > radiusKm) break;

      // Number of points in this ring (proportional to circumference)
      final numPoints = math.max(8, (2 * math.pi * ring).round());

      for (int i = 0; i < numPoints; i++) {
        final bearing = (i * 360.0) / numPoints;
        final point = _destinationPoint(
          centerLat,
          centerLon,
          ringRadiusKm,
          bearing,
        );
        points.add(point);
      }
    }

    return points;
  }

  /// Calculate destination point given start point, distance, and bearing.
  (double lat, double lon) _destinationPoint(
    double lat,
    double lon,
    double distanceKm,
    double bearingDeg,
  ) {
    final latRad = _degreesToRadians(lat);
    final lonRad = _degreesToRadians(lon);
    final bearingRad = _degreesToRadians(bearingDeg);
    final angularDistance = distanceKm / _earthRadiusKm;

    final destLatRad = math.asin(
      math.sin(latRad) * math.cos(angularDistance) +
          math.cos(latRad) * math.sin(angularDistance) * math.cos(bearingRad),
    );

    final destLonRad =
        lonRad +
        math.atan2(
          math.sin(bearingRad) * math.sin(angularDistance) * math.cos(latRad),
          math.cos(angularDistance) - math.sin(latRad) * math.sin(destLatRad),
        );

    return (_radiansToDegrees(destLatRad), _radiansToDegrees(destLonRad));
  }

  /// Group chronologically-sorted frames into per-timestamp snapshots.
  ///
  /// A single point in time may be represented by several frames covering
  /// different geographic bounds (a tiling). Frames whose timestamps fall
  /// within [_snapshotBucketTolerance] of each other are treated as one
  /// snapshot. The returned list preserves chronological order.
  List<_Snapshot> _groupFramesByTimestamp(List<RadarFrame> sortedFrames) {
    final snapshots = <_Snapshot>[];
    for (final frame in sortedFrames) {
      if (snapshots.isNotEmpty &&
          frame.timestamp.difference(snapshots.last.timestamp).abs() <=
              _snapshotBucketTolerance) {
        snapshots.last.frames.add(frame);
      } else {
        snapshots.add(_Snapshot(timestamp: frame.timestamp, frames: [frame]));
      }
    }
    return snapshots;
  }

  /// Build the cloud-density field for one snapshot over the analysis grid.
  ///
  /// Each grid point's density is the opacity of the most-specific (smallest
  /// bounding-box area) frame in the snapshot that encloses it. The field is
  /// flagged [_DensityField.isUniform] when it carries no trackable spatial
  /// structure — significant cloud fills (almost) the entire grid with a single
  /// density value, so its centroid is pinned to the geometric centre and can
  /// never move. That is exactly the real-world whole-area-tile / single-point
  /// cloud-cover case. A field where significant cloud covers only PART of the
  /// grid (e.g. a cloud band) has an off-centre centroid that genuinely moves,
  /// so it is NOT uniform even if every cloudy cell shares one opacity value.
  _DensityField _buildDensityField({
    required List<RadarFrame> snapshot,
    required double centerLat,
    required double centerLon,
    required double radiusKm,
  }) {
    final gridPoints = _generateGridPoints(
      centerLat: centerLat,
      centerLon: centerLon,
      radiusKm: radiusKm,
      spacingKm: _defaultGridSpacingKm,
    );

    double sumLat = 0.0;
    double sumLon = 0.0;
    double sumDensity = 0.0;

    double? firstSignificantDensity;
    var allSignificantEqual = true;
    var significantCount = 0;

    for (final point in gridPoints) {
      final density = _estimateCloudDensity(snapshot, point.$1, point.$2);
      if (density > _defaultDensityThreshold) {
        sumLat += point.$1 * density;
        sumLon += point.$2 * density;
        sumDensity += density;

        significantCount++;
        if (firstSignificantDensity == null) {
          firstSignificantDensity = density;
        } else if ((density - firstSignificantDensity).abs() > 1e-9) {
          allSignificantEqual = false;
        }
      }
    }

    if (sumDensity == 0.0) {
      // No clouds in this snapshot. Treat as uniform (nothing to track) so it
      // never contributes spurious motion structure.
      return const _DensityField(centroid: null, isUniform: true);
    }

    final centroid = (sumLat / sumDensity, sumLon / sumDensity);

    // Coverage fraction of significant cloud over the sampled grid.
    final coverage = significantCount / gridPoints.length;

    // A field is "uniform" (untrackable) only when significant cloud blankets
    // essentially the whole grid AND every cloudy cell shares one density value.
    // Such a field has a centre-pinned centroid with no gradient to follow — the
    // signature of a single whole-area box. Partial coverage means the centroid
    // is offset and can move between snapshots, so it IS trackable.
    final isUniform =
        allSignificantEqual && coverage >= _uniformCoverageFraction;

    return _DensityField(centroid: centroid, isUniform: isUniform);
  }

  /// Estimate cloud density at a specific location from a snapshot.
  ///
  /// Returns the radar intensity of the most-specific (smallest-area) frame in
  /// [snapshot] whose geographic bounds enclose ([lat], [lon]), or 0.0 when no
  /// frame covers the point. Using the smallest enclosing frame means a tiling
  /// of small bounded frames produces a real per-cell field.
  ///
  /// When the enclosing frame carries a per-cell [RadarFrame.intensityGrid]
  /// (real spatial radar decoded from the provider's tiles), the density is the
  /// intensity of the grid cell containing the point — so a single whole-FOV
  /// frame now yields a genuinely spatially-varying field whose cloud centroid
  /// moves between snapshots. A frame with no grid falls back to its single
  /// [RadarFrame.opacity] value (a uniform box, flagged as such upstream).
  ///
  /// No-data frames ([RadarFrame.isNoData]) contribute nothing: they signal a
  /// failed tile fetch/decode and must never masquerade as cloud cover.
  double _estimateCloudDensity(
    List<RadarFrame> snapshot,
    double lat,
    double lon,
  ) {
    double? bestDensity;
    double bestArea = double.infinity;

    for (final frame in snapshot) {
      // A no-data frame carries no usable radar signal — skip it entirely so it
      // never fabricates density at any point.
      if (frame.isNoData) {
        continue;
      }

      // Skip frames that do not cover this point.
      if (lat < frame.south ||
          lat > frame.north ||
          lon < frame.west ||
          lon > frame.east) {
        continue;
      }

      // Prefer the frame with the smallest bounding box (most spatially
      // specific) so a fine tile overrides a coarse whole-area frame.
      final area =
          (frame.north - frame.south).abs() * (frame.east - frame.west).abs();
      if (area < bestArea) {
        bestArea = area;
        bestDensity = _frameDensityAt(frame, lat, lon);
      }
    }

    return bestDensity ?? 0.0;
  }

  /// Density of a single frame at ([lat], [lon]).
  ///
  /// Reads the per-cell [RadarFrame.intensityGrid] when present (row-major,
  /// rows N→S, columns W→E), mapping the point to its grid cell. Falls back to
  /// the frame's scalar [RadarFrame.opacity] when no grid is available.
  double _frameDensityAt(RadarFrame frame, double lat, double lon) {
    final grid = frame.intensityGrid;
    if (grid == null || grid.isEmpty || grid.first.isEmpty) {
      // No per-cell data: the whole frame is a single uniform box.
      return frame.opacity;
    }

    final rows = grid.length;
    final cols = grid.first.length;

    final latSpan = frame.north - frame.south;
    final lonSpan = frame.east - frame.west;
    if (latSpan <= 0 || lonSpan <= 0) {
      return frame.opacity;
    }

    // Rows run NORTH→SOUTH: fraction from the north edge.
    final rowFrac = (frame.north - lat) / latSpan;
    // Columns run WEST→EAST: fraction from the west edge.
    final colFrac = (lon - frame.west) / lonSpan;

    final row = (rowFrac * rows).floor().clamp(0, rows - 1);
    final col = (colFrac * cols).floor().clamp(0, cols - 1);

    return grid[row][col];
  }

  /// Calculate circular mean of angles to handle 0/360 wraparound.
  double _averageDirection(List<double> directions) {
    if (directions.isEmpty) {
      return 0.0;
    }

    double sumSin = 0.0;
    double sumCos = 0.0;

    for (final dir in directions) {
      final rad = _degreesToRadians(dir);
      sumSin += math.sin(rad);
      sumCos += math.cos(rad);
    }

    final avgRad = math.atan2(
      sumSin / directions.length,
      sumCos / directions.length,
    );
    final avgDeg = _radiansToDegrees(avgRad);

    return (avgDeg + 360) % 360;
  }

  /// Normalize angle to -180 to +180 range.
  double _normalizeAngle(double degrees) {
    double normalized = degrees % 360;
    if (normalized > 180) {
      normalized -= 360;
    } else if (normalized < -180) {
      normalized += 360;
    }
    return normalized;
  }

  /// Convert degrees to radians.
  double _degreesToRadians(double degrees) => degrees * math.pi / 180.0;

  /// Convert radians to degrees.
  double _radiansToDegrees(double radians) => radians * 180.0 / math.pi;
}

/// Internal motion vector representation.
class _MotionVector {
  final double speedKmh;
  final double directionDegrees;

  _MotionVector({required this.speedKmh, required this.directionDegrees});
}

/// A single point in time, possibly represented by several frames covering
/// different geographic bounds (a tiling).
class _Snapshot {
  _Snapshot({required this.timestamp, required this.frames});

  /// Capture time of this snapshot (the timestamp of its first frame).
  final DateTime timestamp;

  /// Frames that make up this snapshot.
  final List<RadarFrame> frames;
}

/// The cloud-density field of one snapshot over the analysis grid.
class _DensityField {
  const _DensityField({required this.centroid, required this.isUniform});

  /// Density-weighted centroid of significant cloud cells, or null when the
  /// snapshot contains no significant clouds.
  final (double lat, double lon)? centroid;

  /// True when every significant cloud cell shares the same density value —
  /// i.e. the field carries no spatial gradient (a single whole-area box, or no
  /// clouds at all). A uniform field cannot yield a meaningful motion vector.
  final bool isUniform;
}
