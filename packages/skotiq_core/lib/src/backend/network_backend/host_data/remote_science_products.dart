import 'package:flutter/foundation.dart' show listEquals, mapEquals;

import '../../../database/database.dart'
    show AstrometryResidualVectorRow,
        FramePhotometricCalibrationRow,
        LineRatioProductRow,
        MovingObjectCandidateRow,
        PhotometryMeasurementRow,
        PsfFieldTileRow,
        ScienceFrameQualityMetricsRow,
        ScienceTileMetricRow,
        TransparencySampleRow;
import '../../../models/science/frame_science_rows.dart';
import '../../../models/science/science_models.dart' show ScienceSessionConfig;
import '../../network_backend.dart';
import '../../roles/host_data/science_products.dart';
import 'host_poll.dart';
import '../../../models/backend/remote_science_bundle.dart';

/// Science measurements on a linked host.
///
/// The host serves one bundle per session (and one for captures outside any
/// session) holding every kind of row. Each bundle is polled once however
/// many kinds are being watched, and each read is a slice of it.
final class RemoteScienceProducts implements ScienceProducts {
  RemoteScienceProducts(this._host, {required Duration pollInterval})
    : _interval = pollInterval;

  final NetworkBackend _host;
  final Duration _interval;
  final _poll = HostPoll('science products');

  final _sessionBundles = <int, SharedLatest<RemoteScienceBundle>>{};

  late final _sessionlessBundle = SharedLatest<RemoteScienceBundle>(
    () => _poll.watch(
      _host.getSessionlessScienceBundle,
      _bundlesEqual,
      interval: _interval,
    ),
    _bundlesEqual,
  );

  Stream<T> _session<T>(
    int sessionId,
    T Function(RemoteScienceBundle bundle) slice,
  ) => _sessionBundles
      .putIfAbsent(
        sessionId,
        () => SharedLatest(
          () => _poll.watch(
            () => _host.getScienceSessionBundle(sessionId),
            _bundlesEqual,
            interval: _interval,
          ),
          _bundlesEqual,
        ),
      )
      .stream
      .map(slice);

  Stream<T> _sessionless<T>(T Function(RemoteScienceBundle bundle) slice) =>
      _sessionlessBundle.stream.map(slice);

  @override
  Stream<ScienceSessionConfig?> watchSessionScienceConfig(int sessionId) =>
      _poll.watch(
        () => _host.getScienceSessionConfig(sessionId),
        _sessionConfigsEqual,
        interval: _interval,
      );

  @override
  Future<void> upsertSessionConfig(ScienceSessionConfig config) async {
    final sessionId = config.sessionId;
    if (sessionId == null) return;
    try {
      await _host.updateScienceSessionConfig(sessionId, config);
    } finally {
      _poll.refresh();
    }
  }

  @override
  Stream<List<PhotometryMeasurementRow>> watchPhotometryForSession(
    int sessionId,
  ) => _session(sessionId, (bundle) => bundle.photometry);

  @override
  Stream<List<PhotometryMeasurementRow>> watchPhotometryForTarget({
    required int targetId,
    required String objectId,
  }) => Stream.value(const <PhotometryMeasurementRow>[]);

  @override
  Stream<List<FramePhotometricCalibrationRow>> watchCalibrationsForSession(
    int sessionId,
  ) => _session(sessionId, (bundle) => bundle.calibrations);

  @override
  Stream<List<TransparencySampleRow>> watchTransparencyForSession(
    int sessionId,
  ) => _session(sessionId, (bundle) => bundle.transparency);

  @override
  Stream<List<PsfFieldTileRow>> watchPsfTilesForSession(int sessionId) =>
      _session(sessionId, (bundle) => bundle.psfTiles);

  @override
  Stream<List<ScienceFrameQualityMetricsRow>>
  watchFrameQualityMetricsForSession(int sessionId) =>
      _session(sessionId, (bundle) => bundle.frameQuality);

  @override
  Stream<List<ScienceTileMetricRow>> watchFrameTileMetrics(
    int sessionId, {
    int? capturedImageId,
  }) => _session(
    sessionId,
    (bundle) => selectFrameScienceRows(
      bundle.tileMetrics,
      capturedImageId: capturedImageId,
      imageIdOf: (row) => row.capturedImageId,
      timestampOf: (row) => row.timestamp,
    ),
  );

  @override
  Stream<List<AstrometryResidualVectorRow>> watchResidualsForSession(
    int sessionId,
  ) => _session(sessionId, (bundle) => bundle.residuals);

  @override
  Stream<List<MovingObjectCandidateRow>> watchMovingObjectsForSession(
    int sessionId,
  ) => _session(sessionId, (bundle) => bundle.movingObjects);

  @override
  Stream<List<LineRatioProductRow>> watchLineRatiosForSession(int sessionId) =>
      _session(sessionId, (bundle) => bundle.lineRatios);

  @override
  Stream<List<FramePhotometricCalibrationRow>>
  watchSessionlessCalibrationsRecent() =>
      _sessionless((bundle) => bundle.calibrations);

  @override
  Stream<List<TransparencySampleRow>> watchSessionlessTransparencyRecent() =>
      _sessionless((bundle) => bundle.transparency);

  @override
  Stream<List<PsfFieldTileRow>> watchSessionlessPsfTilesRecent() =>
      _sessionless((bundle) => bundle.psfTiles);

  @override
  Stream<List<ScienceFrameQualityMetricsRow>>
  watchSessionlessFrameQualityMetricsRecent() =>
      _sessionless((bundle) => bundle.frameQuality);

  @override
  Stream<List<ScienceTileMetricRow>> watchSessionlessTileMetricsRecent() =>
      _sessionless((bundle) => bundle.tileMetrics);

  @override
  Stream<List<AstrometryResidualVectorRow>> watchSessionlessResidualsRecent() =>
      _sessionless((bundle) => bundle.residuals);

  @override
  Stream<List<MovingObjectCandidateRow>>
  watchSessionlessMovingObjectsRecent() =>
      _sessionless((bundle) => bundle.movingObjects);

  @override
  Stream<List<PhotometryMeasurementRow>> watchSessionlessPhotometryRecent() =>
      _sessionless((bundle) => bundle.photometry);

  @override
  Stream<List<LineRatioProductRow>> watchSessionlessLineRatiosRecent() =>
      _sessionless((bundle) => bundle.lineRatios);

  @override
  Future<List<PhotometryMeasurementRow>> getAllSessionlessPhotometry() =>
      watchSessionlessPhotometryRecent().first;

  @override
  Future<List<ScienceFrameQualityMetricsRow>>
  getAllSessionlessFrameQualityMetrics() =>
      watchSessionlessFrameQualityMetricsRecent().first;

  @override
  Future<List<TransparencySampleRow>> getAllSessionlessTransparency() =>
      watchSessionlessTransparencyRecent().first;

  @override
  Future<List<PsfFieldTileRow>> getAllSessionlessPsfTiles() =>
      watchSessionlessPsfTilesRecent().first;

  @override
  Future<List<AstrometryResidualVectorRow>> getAllSessionlessResiduals() =>
      watchSessionlessResidualsRecent().first;

  @override
  Future<List<FramePhotometricCalibrationRow>>
  getAllSessionlessCalibrations() => watchSessionlessCalibrationsRecent().first;

  @override
  Future<List<MovingObjectCandidateRow>> getAllSessionlessMovingObjects() =>
      watchSessionlessMovingObjectsRecent().first;
}

/// The `science.*` settings of a linked host, through its science settings
/// endpoint.
final class RemoteScienceSettingRows implements SettingRows {
  RemoteScienceSettingRows(this._host);

  final NetworkBackend _host;

  @override
  Future<Map<String, String>> getAllSettings() => _host.getScienceSettings();

  @override
  Future<void> setSettings(Map<String, String> settings) =>
      _host.updateScienceSettings(settings);
}

bool _bundlesEqual(RemoteScienceBundle previous, RemoteScienceBundle next) =>
    listEquals(previous.photometry, next.photometry) &&
    listEquals(previous.calibrations, next.calibrations) &&
    listEquals(previous.transparency, next.transparency) &&
    listEquals(previous.psfTiles, next.psfTiles) &&
    listEquals(previous.frameQuality, next.frameQuality) &&
    listEquals(previous.tileMetrics, next.tileMetrics) &&
    listEquals(previous.residuals, next.residuals) &&
    listEquals(previous.movingObjects, next.movingObjects) &&
    listEquals(previous.lineRatios, next.lineRatios);

bool _sessionConfigsEqual(
  ScienceSessionConfig? previous,
  ScienceSessionConfig? next,
) {
  if (previous == null || next == null) {
    return previous == next;
  }
  return mapEquals(previous.toJson(), next.toJson());
}
