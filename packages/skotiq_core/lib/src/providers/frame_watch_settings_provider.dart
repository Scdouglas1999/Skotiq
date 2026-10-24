// The run's frame watch settings and the obstructions it has learned.
//
// The frame watch is native: after each saved frame it compares the solved
// center with the target and checks for an obstruction. Dart owns its
// settings (how far off a frame may be before the run recenters, whether
// obstruction detection runs) and the obstruction points it reported, which
// are kept per site and merged into the horizon every planner uses.
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/logging_service.dart';
import 'database_provider.dart';

/// Settings keys in `app_settings`.
const String frameWatchDriftLimitPercentKey = 'frame_watch_drift_limit_percent';
const String frameWatchObstructionDetectionKey =
    'frame_watch_obstruction_detection';
const String learnedHorizonPointsKey = 'learned_horizon_points_json';

/// How far the solved center may drift from the target before the run
/// recenters, in percent of the frame's shorter side.
const double frameWatchDriftLimitDefaultPercent = 10;
const double frameWatchDriftLimitMinPercent = 2;
const double frameWatchDriftLimitMaxPercent = 50;

/// A learned point blocks the sky within this many degrees of azimuth on
/// either side of it.
const double learnedObstructionHalfWidthDeg = 6;

/// A learned point blocks the sky up to this many degrees above it.
const double learnedObstructionMarginDeg = 1;

/// A point belongs to a site when its latitude and longitude are each within
/// this many degrees of the site's.
const double learnedObstructionSiteToleranceDeg = 0.05;

/// One obstruction the run met: where on the sky it began, at which site,
/// when, and on which target.
class LearnedObstructionPoint {
  const LearnedObstructionPoint({
    required this.azimuthDeg,
    required this.altitudeDeg,
    required this.recordedAt,
    this.latitude,
    this.longitude,
    this.targetName,
  });

  final double azimuthDeg;
  final double altitudeDeg;
  final double? latitude;
  final double? longitude;
  final DateTime recordedAt;
  final String? targetName;

  /// Whether the point was recorded at the site at [latitude], [longitude].
  /// A point recorded with no site belongs to none.
  bool belongsToSite(double latitude, double longitude) {
    final lat = this.latitude;
    final lon = this.longitude;
    if (lat == null || lon == null) return false;
    var dLon = (lon - longitude).abs() % 360;
    if (dLon > 180) dLon = 360 - dLon;
    return (lat - latitude).abs() <= learnedObstructionSiteToleranceDeg &&
        dLon <= learnedObstructionSiteToleranceDeg;
  }

  /// Whether this point's azimuth band covers [azimuthDeg].
  bool covers(double azimuthDeg) =>
      azimuthDistanceDeg(this.azimuthDeg, azimuthDeg) <=
      learnedObstructionHalfWidthDeg;

  /// The highest blocked altitude.
  double get blockedUpToDeg => altitudeDeg + learnedObstructionMarginDeg;

  Map<String, Object?> toJson() => {
    'az': azimuthDeg,
    'alt': altitudeDeg,
    'lat': latitude,
    'lon': longitude,
    'at': recordedAt.toUtc().toIso8601String(),
    'target': targetName,
  };

  static LearnedObstructionPoint? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final az = raw['az'];
    final alt = raw['alt'];
    if (az is! num || alt is! num) return null;
    final lat = raw['lat'];
    final lon = raw['lon'];
    final at = raw['at'];
    final target = raw['target'];
    return LearnedObstructionPoint(
      azimuthDeg: _wrap360(az.toDouble()),
      altitudeDeg: alt.toDouble(),
      latitude: lat is num ? lat.toDouble() : null,
      longitude: lon is num ? lon.toDouble() : null,
      recordedAt: (at is String ? DateTime.tryParse(at) : null) ?? DateTime(0),
      targetName: target is String && target.isNotEmpty ? target : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LearnedObstructionPoint &&
      other.azimuthDeg == azimuthDeg &&
      other.altitudeDeg == altitudeDeg &&
      other.latitude == latitude &&
      other.longitude == longitude &&
      other.recordedAt == recordedAt &&
      other.targetName == targetName;

  @override
  int get hashCode => Object.hash(
    azimuthDeg,
    altitudeDeg,
    latitude,
    longitude,
    recordedAt,
    targetName,
  );
}

/// Smallest angle between two azimuths, 0 to 180 degrees.
double azimuthDistanceDeg(double a, double b) {
  final d = (_wrap360(a) - _wrap360(b)).abs();
  return d > 180 ? 360 - d : d;
}

double _wrap360(double az) {
  final v = az % 360.0;
  return v < 0 ? v + 360.0 : v;
}

/// The altitude the learned [points] block at [azimuthDeg], or null when none
/// covers it.
double? learnedObstructionAltitudeAt(
  Iterable<LearnedObstructionPoint> points,
  double azimuthDeg,
) {
  double? blocked;
  for (final p in points) {
    if (!p.covers(azimuthDeg)) continue;
    blocked = blocked == null
        ? p.blockedUpToDeg
        : math.max(blocked, p.blockedUpToDeg);
  }
  return blocked;
}

List<LearnedObstructionPoint> decodeLearnedObstructionPoints(String? json) {
  if (json == null || json.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return const [];
    return List.unmodifiable(
      decoded
          .map(LearnedObstructionPoint.fromJson)
          .whereType<LearnedObstructionPoint>(),
    );
  } on FormatException {
    return const [];
  }
}

String encodeLearnedObstructionPoints(List<LearnedObstructionPoint> points) =>
    jsonEncode(points.map((p) => p.toJson()).toList());

/// The frame watch's settings and the learned obstructions of every site.
class FrameWatchSettings {
  const FrameWatchSettings({
    this.driftLimitPercent = frameWatchDriftLimitDefaultPercent,
    this.obstructionDetection = true,
    this.learnedPoints = const [],
  });

  final double driftLimitPercent;
  final bool obstructionDetection;
  final List<LearnedObstructionPoint> learnedPoints;

  /// The learned points of the site at [latitude], [longitude]; none when the
  /// site is not known.
  List<LearnedObstructionPoint> pointsForSite(
    double? latitude,
    double? longitude,
  ) {
    if (latitude == null || longitude == null) return const [];
    return learnedPoints
        .where((p) => p.belongsToSite(latitude, longitude))
        .toList(growable: false);
  }

  /// The `frame_watch` entry of a sequence's metadata, for the run at the site
  /// at [latitude], [longitude].
  Map<String, Object?> sequenceMetadata({
    required double? latitude,
    required double? longitude,
  }) => {
    'drift_limit_fraction': driftLimitPercent / 100,
    'obstruction_detection': obstructionDetection,
    'learned_horizon': [
      for (final p in pointsForSite(latitude, longitude))
        {'azimuth_deg': p.azimuthDeg, 'altitude_deg': p.altitudeDeg},
    ],
  };

  FrameWatchSettings copyWith({
    double? driftLimitPercent,
    bool? obstructionDetection,
    List<LearnedObstructionPoint>? learnedPoints,
  }) => FrameWatchSettings(
    driftLimitPercent: driftLimitPercent ?? this.driftLimitPercent,
    obstructionDetection: obstructionDetection ?? this.obstructionDetection,
    learnedPoints: learnedPoints ?? this.learnedPoints,
  );
}

double clampFrameWatchDriftLimitPercent(double value) => value.isFinite
    ? value.clamp(
        frameWatchDriftLimitMinPercent,
        frameWatchDriftLimitMaxPercent,
      )
    : frameWatchDriftLimitDefaultPercent;

final frameWatchSettingsProvider =
    AsyncNotifierProvider<FrameWatchSettingsNotifier, FrameWatchSettings>(
      FrameWatchSettingsNotifier.new,
    );

class FrameWatchSettingsNotifier extends AsyncNotifier<FrameWatchSettings> {
  @override
  Future<FrameWatchSettings> build() async {
    final dao = ref.watch(settingsDaoProvider);
    final drift = double.tryParse(
      await dao.getSetting(frameWatchDriftLimitPercentKey) ?? '',
    );
    final detection = await dao.getSetting(frameWatchObstructionDetectionKey);
    final points = decodeLearnedObstructionPoints(
      await dao.getSetting(learnedHorizonPointsKey),
    );
    return FrameWatchSettings(
      driftLimitPercent: drift == null
          ? frameWatchDriftLimitDefaultPercent
          : clampFrameWatchDriftLimitPercent(drift),
      obstructionDetection: detection == null ? true : detection != 'false',
      learnedPoints: points,
    );
  }

  Future<FrameWatchSettings> _current() async =>
      state.valueOrNull ?? await future;

  Future<void> setDriftLimitPercent(double percent) async {
    final clamped = clampFrameWatchDriftLimitPercent(percent);
    final current = await _current();
    await ref
        .read(settingsDaoProvider)
        .setSetting(frameWatchDriftLimitPercentKey, clamped.toString());
    state = AsyncData(current.copyWith(driftLimitPercent: clamped));
  }

  Future<void> setObstructionDetection(bool enabled) async {
    final current = await _current();
    await ref
        .read(settingsDaoProvider)
        .setSetting(frameWatchObstructionDetectionKey, enabled.toString());
    state = AsyncData(current.copyWith(obstructionDetection: enabled));
  }

  /// Add a learned point. A point within a degree of one already learned at
  /// the same site replaces it, so one tree line seen on many nights stays one
  /// entry.
  Future<void> addLearnedPoint(LearnedObstructionPoint point) async {
    final current = await _current();
    final lat = point.latitude;
    final lon = point.longitude;
    final kept = current.learnedPoints.where((p) {
      final sameSite = lat != null && lon != null && p.belongsToSite(lat, lon);
      return !(sameSite &&
          azimuthDistanceDeg(p.azimuthDeg, point.azimuthDeg) <= 1 &&
          (p.altitudeDeg - point.altitudeDeg).abs() <= 1);
    });
    await _savePoints(current, [...kept, point]);
  }

  Future<void> removeLearnedPoint(LearnedObstructionPoint point) async {
    final current = await _current();
    await _savePoints(current, [
      for (final p in current.learnedPoints)
        if (p != point) p,
    ]);
  }

  /// Forget every point learned at the site at [latitude], [longitude];
  /// other sites keep theirs.
  Future<void> clearLearnedPointsForSite(
    double latitude,
    double longitude,
  ) async {
    final current = await _current();
    await _savePoints(current, [
      for (final p in current.learnedPoints)
        if (!p.belongsToSite(latitude, longitude)) p,
    ]);
  }

  Future<void> _savePoints(
    FrameWatchSettings current,
    List<LearnedObstructionPoint> points,
  ) async {
    try {
      await ref
          .read(settingsDaoProvider)
          .setSetting(
            learnedHorizonPointsKey,
            encodeLearnedObstructionPoints(points),
          );
    } catch (e) {
      ref
          .read(loggingServiceProvider)
          .warning(
            'Could not save the learned obstructions: $e',
            source: 'FrameWatchSettings',
          );
      rethrow;
    }
    state = AsyncData(
      current.copyWith(learnedPoints: List.unmodifiable(points)),
    );
  }
}
