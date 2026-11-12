// The run's frame watch settings and the obstructions it has learned.
//
// The frame watch is native: after each saved frame it compares the solved
// center with the target and checks for an obstruction. Dart owns its
// settings (how far off a frame may be before the run recenters, whether
// obstruction detection runs) and the obstruction points it reported, which
// are kept per site and merged into the horizon every planner uses.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/site/learned_obstruction.dart';
import '../services/logging_service.dart';
import '../settings/store_settings.dart';
import 'database_provider.dart';
import '../database/daos/settings_dao.dart';

/// Bounds of how far the solved center may drift from the target before the
/// run recenters, in arcseconds.
const double frameWatchDriftLimitMinArcsec = 10;
const double frameWatchDriftLimitMaxArcsec = 600;

/// The frame watch's settings and the learned obstructions of every site.
class FrameWatchSettings {
  const FrameWatchSettings({
    required this.recenterEnabled,
    required this.driftLimitArcsec,
    required this.obstructionDetection,
    this.learnedPoints = const [],
  });

  /// The settings as declared, before anything is stored.
  static final FrameWatchSettings initial = FrameWatchSettings(
    recenterEnabled: StoreSettings.frameWatchRecenter.fallback,
    driftLimitArcsec: StoreSettings.frameWatchDriftLimit.fallback,
    obstructionDetection: StoreSettings.frameWatchObstructionDetection.fallback,
  );

  final bool recenterEnabled;
  final double driftLimitArcsec;
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
    'drift_limit_arcsec': recenterEnabled ? driftLimitArcsec : 0,
    'use_first_frame_reference': true,
    'obstruction_detection': obstructionDetection,
    'learned_horizon': [
      for (final p in pointsForSite(latitude, longitude))
        {'azimuth_deg': p.azimuthDeg, 'altitude_deg': p.altitudeDeg},
    ],
  };

  FrameWatchSettings copyWith({
    bool? recenterEnabled,
    double? driftLimitArcsec,
    bool? obstructionDetection,
    List<LearnedObstructionPoint>? learnedPoints,
  }) => FrameWatchSettings(
    recenterEnabled: recenterEnabled ?? this.recenterEnabled,
    driftLimitArcsec: driftLimitArcsec ?? this.driftLimitArcsec,
    obstructionDetection: obstructionDetection ?? this.obstructionDetection,
    learnedPoints: learnedPoints ?? this.learnedPoints,
  );
}

double clampFrameWatchDriftLimitArcsec(double value) => value.isFinite
    ? value.clamp(frameWatchDriftLimitMinArcsec, frameWatchDriftLimitMaxArcsec)
    : StoreSettings.frameWatchDriftLimit.fallback;

final frameWatchSettingsProvider =
    AsyncNotifierProvider<FrameWatchSettingsNotifier, FrameWatchSettings>(
      FrameWatchSettingsNotifier.new,
    );

class FrameWatchSettingsNotifier extends AsyncNotifier<FrameWatchSettings> {
  @override
  Future<FrameWatchSettings> build() async {
    final dao = ref.watch(settingsDaoProvider);
    return FrameWatchSettings(
      recenterEnabled: await dao.read(StoreSettings.frameWatchRecenter),
      driftLimitArcsec: clampFrameWatchDriftLimitArcsec(
        await dao.read(StoreSettings.frameWatchDriftLimit),
      ),
      obstructionDetection: await dao.read(
        StoreSettings.frameWatchObstructionDetection,
      ),
      learnedPoints: decodeLearnedObstructionPoints(
        await dao.read(StoreSettings.learnedHorizonPoints),
      ),
    );
  }

  Future<FrameWatchSettings> _current() async =>
      state.valueOrNull ?? await future;

  Future<void> setRecenterEnabled(bool enabled) async {
    final current = await _current();
    await ref
        .read(settingsDaoProvider)
        .write(StoreSettings.frameWatchRecenter, enabled);
    state = AsyncData(
      (state.valueOrNull ?? current).copyWith(recenterEnabled: enabled),
    );
  }

  Future<void> setDriftLimitArcsec(double arcsec) async {
    final current = await _current();
    final clamped = clampFrameWatchDriftLimitArcsec(arcsec);
    await ref
        .read(settingsDaoProvider)
        .write(StoreSettings.frameWatchDriftLimit, clamped);
    state = AsyncData(
      (state.valueOrNull ?? current).copyWith(driftLimitArcsec: clamped),
    );
  }

  Future<void> setObstructionDetection(bool enabled) async {
    final current = await _current();
    await ref
        .read(settingsDaoProvider)
        .write(StoreSettings.frameWatchObstructionDetection, enabled);
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
          .write(
            StoreSettings.learnedHorizonPoints,
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
