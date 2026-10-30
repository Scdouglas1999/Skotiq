part of '../live_preview_area.dart';

extension _LivePreviewAreaFrameSelection on _LivePreviewAreaState {
  List<PsfFieldTileRow> _selectCurrentFramePsfTiles({
    required List<PsfFieldTileRow> sessionTiles,
    required int? capturedImageId,
  }) =>
      selectFrameScienceRows(
        sessionTiles,
        capturedImageId: capturedImageId,
        imageIdOf: (row) => row.capturedImageId,
        timestampOf: (row) => row.timestamp,
      );

  int? _resolveCurrentFrameImageId({
    required List<CapturedImage> sessionImages,
    required CapturedImageData? currentImage,
  }) {
    final filePath = currentImage?.filePath;
    if (filePath == null || filePath.isEmpty) {
      return null;
    }
    final normalizedCurrent = _normalizeImagePath(filePath);
    for (final image in sessionImages) {
      if (_normalizeImagePath(image.filePath) == normalizedCurrent) {
        final parsed = int.tryParse(image.id);
        if (parsed != null) {
          return parsed;
        }
      }
    }
    final currentBasename = _normalizeImagePath(p.basename(filePath));
    final basenameMatches = sessionImages.where((image) {
      return _normalizeImagePath(p.basename(image.filePath)) == currentBasename;
    }).toList(growable: false);
    if (basenameMatches.length == 1) {
      return int.tryParse(basenameMatches.single.id);
    }
    return null;
  }

  String _normalizeImagePath(String value) {
    return value
        .trim()
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+'), '/')
        .toLowerCase();
  }

  List<AstrometryResidualVectorRow> _selectCurrentFrameResidualVectors({
    required List<AstrometryResidualVectorRow> sessionVectors,
    required int? capturedImageId,
  }) =>
      selectFrameScienceRows(
        sessionVectors,
        capturedImageId: capturedImageId,
        imageIdOf: (row) => row.capturedImageId,
        timestampOf: (row) => row.timestamp,
      );

  List<ScienceTileMetricRow> _selectCurrentFrameTileMetrics({
    required List<ScienceTileMetricRow> sessionTiles,
    required int? capturedImageId,
  }) =>
      selectFrameScienceRows(
        sessionTiles,
        capturedImageId: capturedImageId,
        imageIdOf: (row) => row.capturedImageId,
        timestampOf: (row) => row.timestamp,
      );

  List<MovingObjectCandidateRow> _selectCurrentFrameMovingCandidates({
    required List<MovingObjectCandidateRow> sessionCandidates,
    required int? capturedImageId,
  }) =>
      selectFrameScienceRows(
        sessionCandidates,
        capturedImageId: capturedImageId,
        imageIdOf: (row) => row.capturedImageId,
        timestampOf: (row) => row.timestamp,
      );

  /// Median eccentricity across the current frame's eccentricity-layer tile
  /// metrics, or `null` when no such tiles exist for the frame.
  ///
  /// Consumes only the per-frame [ScienceTileMetricRow]s already watched in
  /// [build] (no extra query / analyzer). Each eccentricity tile reports its
  /// representative eccentricity in [ScienceTileMetricRow.value] — the same
  /// field the science overlay painters render — and the median across tiles
  /// yields a robust single frame verdict that ignores a few hot corners. Only
  /// finite values are considered so a malformed tile can never poison the
  /// result; if none remain, the badge honestly shows `ECC —`.
  double? _medianEccentricity(List<ScienceTileMetricRow> frameTileMetrics) {
    final values = <double>[];
    for (final tile in frameTileMetrics) {
      if (tile.layerType != ScienceLayerType.eccentricity.dbValue) {
        continue;
      }
      if (tile.value.isFinite) {
        values.add(tile.value);
      }
    }
    if (values.isEmpty) {
      return null;
    }
    values.sort();
    final mid = values.length ~/ 2;
    if (values.length.isOdd) {
      return values[mid];
    }
    return (values[mid - 1] + values[mid]) / 2.0;
  }

  List<ProjectedMovingTrack> _projectMovingTracks({
    required List<MovingObjectCandidateRow> candidates,
    required SolvedWcs? wcs,
    required double imageWidth,
    required double imageHeight,
  }) {
    if (candidates.isEmpty || wcs == null) {
      return const <ProjectedMovingTrack>[];
    }
    if (!wcs.isValid) {
      return const <ProjectedMovingTrack>[];
    }

    final tracks = <ProjectedMovingTrack>[];
    final projection = GnomonicProjection(wcs);
    for (final candidate in candidates.take(200)) {
      final point = projection.worldToPixel(
        raDegrees: candidate.raDegrees,
        decDegrees: candidate.decDegrees,
      );
      final projected =
          point == null ? null : Offset(point.pixel.x, point.pixel.y);
      if (projected == null) {
        continue;
      }
      tracks.add(
        ProjectedMovingTrack(
          imageX: projected.dx,
          imageY: projected.dy,
          positionAngleDegrees: candidate.positionAngleDegrees,
          motionArcsecPerMinute: candidate.motionArcsecPerMinute,
          confidence: candidate.confidence,
          imageDirection: _imageDirectionOf(projection, candidate, projected),
        ),
      );
    }
    return tracks;
  }

  /// The on-image direction of a candidate's motion: the pixel step toward a
  /// point 30" along its position angle, through the frame's WCS.
  Offset? _imageDirectionOf(
    GnomonicProjection projection,
    MovingObjectCandidateRow candidate,
    Offset at,
  ) {
    const stepDeg = 30.0 / 3600.0;
    final pa = candidate.positionAngleDegrees * math.pi / 180.0;
    final dec = candidate.decDegrees * math.pi / 180.0;
    final ahead = projection.worldToPixel(
      raDegrees: candidate.raDegrees + stepDeg * math.sin(pa) / math.cos(dec),
      decDegrees: candidate.decDegrees + stepDeg * math.cos(pa),
    );
    if (ahead == null) return null;
    final step = Offset(ahead.pixel.x - at.dx, ahead.pixel.y - at.dy);
    final length = step.distance;
    return length > 0 ? step / length : null;
  }
}
