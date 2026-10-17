part of '../live_preview_area.dart';

extension _LivePreviewAreaFrameSelection on _LivePreviewAreaState {
  List<PsfFieldTileRow> _selectCurrentFramePsfTiles({
    required List<PsfFieldTileRow> sessionTiles,
    required int? capturedImageId,
  }) {
    if (sessionTiles.isEmpty) {
      return const <PsfFieldTileRow>[];
    }
    if (capturedImageId != null) {
      final matched = sessionTiles
          .where((tile) => tile.capturedImageId == capturedImageId)
          .toList(growable: false);
      if (matched.isNotEmpty) {
        return matched;
      }
    }
    final latestImageId = sessionTiles
        .where((tile) => tile.capturedImageId != null)
        .map((tile) => tile.capturedImageId!)
        .fold<int?>(null, (latest, id) {
      if (latest == null) {
        return id;
      }
      final latestTimestamp = sessionTiles
          .where((tile) => tile.capturedImageId == latest)
          .map((tile) => tile.timestamp)
          .fold<DateTime>(DateTime.fromMillisecondsSinceEpoch(0),
              (a, b) => a.isAfter(b) ? a : b);
      final idTimestamp = sessionTiles
          .where((tile) => tile.capturedImageId == id)
          .map((tile) => tile.timestamp)
          .fold<DateTime>(DateTime.fromMillisecondsSinceEpoch(0),
              (a, b) => a.isAfter(b) ? a : b);
      return idTimestamp.isAfter(latestTimestamp) ? id : latest;
    });
    if (latestImageId == null) {
      return sessionTiles;
    }
    return sessionTiles
        .where((tile) => tile.capturedImageId == latestImageId)
        .toList(growable: false);
  }

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
  }) {
    if (sessionVectors.isEmpty) {
      return const <AstrometryResidualVectorRow>[];
    }
    if (capturedImageId != null) {
      final matched = sessionVectors
          .where((vector) => vector.capturedImageId == capturedImageId)
          .toList(growable: false);
      if (matched.isNotEmpty) {
        return matched;
      }
    }
    final latestImageId = sessionVectors
        .where((vector) => vector.capturedImageId != null)
        .map((vector) => vector.capturedImageId!)
        .fold<int?>(null, (latest, id) {
      if (latest == null) {
        return id;
      }
      final latestTimestamp = sessionVectors
          .where((vector) => vector.capturedImageId == latest)
          .map((vector) => vector.timestamp)
          .fold<DateTime>(DateTime.fromMillisecondsSinceEpoch(0),
              (a, b) => a.isAfter(b) ? a : b);
      final idTimestamp = sessionVectors
          .where((vector) => vector.capturedImageId == id)
          .map((vector) => vector.timestamp)
          .fold<DateTime>(DateTime.fromMillisecondsSinceEpoch(0),
              (a, b) => a.isAfter(b) ? a : b);
      return idTimestamp.isAfter(latestTimestamp) ? id : latest;
    });
    if (latestImageId == null) {
      return sessionVectors;
    }
    return sessionVectors
        .where((vector) => vector.capturedImageId == latestImageId)
        .toList(growable: false);
  }

  List<ScienceTileMetricRow> _selectCurrentFrameTileMetrics({
    required List<ScienceTileMetricRow> sessionTiles,
    required int? capturedImageId,
  }) {
    if (sessionTiles.isEmpty) {
      return const <ScienceTileMetricRow>[];
    }
    if (capturedImageId != null) {
      final matched = sessionTiles
          .where((tile) => tile.capturedImageId == capturedImageId)
          .toList(growable: false);
      if (matched.isNotEmpty) {
        return matched;
      }
    }
    final latestImageId = sessionTiles
        .where((tile) => tile.capturedImageId != null)
        .map((tile) => tile.capturedImageId!)
        .fold<int?>(null, (latest, id) {
      if (latest == null) {
        return id;
      }
      final latestTimestamp = sessionTiles
          .where((tile) => tile.capturedImageId == latest)
          .map((tile) => tile.timestamp)
          .fold<DateTime>(DateTime.fromMillisecondsSinceEpoch(0),
              (a, b) => a.isAfter(b) ? a : b);
      final idTimestamp = sessionTiles
          .where((tile) => tile.capturedImageId == id)
          .map((tile) => tile.timestamp)
          .fold<DateTime>(DateTime.fromMillisecondsSinceEpoch(0),
              (a, b) => a.isAfter(b) ? a : b);
      return idTimestamp.isAfter(latestTimestamp) ? id : latest;
    });
    if (latestImageId == null) {
      return sessionTiles;
    }
    return sessionTiles
        .where((tile) => tile.capturedImageId == latestImageId)
        .toList(growable: false);
  }

  List<MovingObjectCandidateRow> _selectCurrentFrameMovingCandidates({
    required List<MovingObjectCandidateRow> sessionCandidates,
    required int? capturedImageId,
  }) {
    if (sessionCandidates.isEmpty) {
      return const <MovingObjectCandidateRow>[];
    }
    if (capturedImageId != null) {
      final matched = sessionCandidates
          .where((candidate) => candidate.capturedImageId == capturedImageId)
          .toList(growable: false);
      if (matched.isNotEmpty) {
        return matched;
      }
    }
    final latestImageId = sessionCandidates
        .where((candidate) => candidate.capturedImageId != null)
        .map((candidate) => candidate.capturedImageId!)
        .fold<int?>(null, (latest, id) {
      if (latest == null) {
        return id;
      }
      final latestTimestamp = sessionCandidates
          .where((candidate) => candidate.capturedImageId == latest)
          .map((candidate) => candidate.timestamp)
          .fold<DateTime>(DateTime.fromMillisecondsSinceEpoch(0),
              (a, b) => a.isAfter(b) ? a : b);
      final idTimestamp = sessionCandidates
          .where((candidate) => candidate.capturedImageId == id)
          .map((candidate) => candidate.timestamp)
          .fold<DateTime>(DateTime.fromMillisecondsSinceEpoch(0),
              (a, b) => a.isAfter(b) ? a : b);
      return idTimestamp.isAfter(latestTimestamp) ? id : latest;
    });
    if (latestImageId == null) {
      return sessionCandidates;
    }
    return sessionCandidates
        .where((candidate) => candidate.capturedImageId == latestImageId)
        .toList(growable: false);
  }

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
    final centerRaDeg = wcs.raHours * 15.0;
    for (final candidate in candidates.take(200)) {
      final projected = _skyToPixel(
        raDegrees: candidate.raDegrees,
        decDegrees: candidate.decDegrees,
        centerRaDegrees: centerRaDeg,
        centerDecDegrees: wcs.decDegrees,
        rotationDegrees: wcs.rotationDeg,
        pixelScaleArcsecPerPixel: wcs.pixelScaleArcsec,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
      );
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
        ),
      );
    }
    return tracks;
  }

  Offset? _skyToPixel({
    required double raDegrees,
    required double decDegrees,
    required double centerRaDegrees,
    required double centerDecDegrees,
    required double rotationDegrees,
    required double pixelScaleArcsecPerPixel,
    required double imageWidth,
    required double imageHeight,
  }) {
    final raRad = raDegrees * math.pi / 180.0;
    final decRad = decDegrees * math.pi / 180.0;
    final centerRaRad = centerRaDegrees * math.pi / 180.0;
    final centerDecRad = centerDecDegrees * math.pi / 180.0;

    var dRa = raRad - centerRaRad;
    while (dRa > math.pi) {
      dRa -= 2 * math.pi;
    }
    while (dRa < -math.pi) {
      dRa += 2 * math.pi;
    }

    final cosDec = math.cos(decRad);
    final sinDec = math.sin(decRad);
    final cosCenterDec = math.cos(centerDecRad);
    final sinCenterDec = math.sin(centerDecRad);
    final denom = sinCenterDec * sinDec + cosCenterDec * cosDec * math.cos(dRa);
    if (denom <= 0) {
      return null;
    }

    final xi = cosDec * math.sin(dRa) / denom;
    final eta =
        (cosCenterDec * sinDec - sinCenterDec * cosDec * math.cos(dRa)) / denom;
    final xiDeg = xi * 180.0 / math.pi;
    final etaDeg = eta * 180.0 / math.pi;
    final rot = rotationDegrees * math.pi / 180.0;
    final xr = xiDeg * math.cos(rot) - etaDeg * math.sin(rot);
    final yr = xiDeg * math.sin(rot) + etaDeg * math.cos(rot);
    final x = xr * 3600.0 / pixelScaleArcsecPerPixel + imageWidth / 2.0;
    final y = imageHeight / 2.0 - yr * 3600.0 / pixelScaleArcsecPerPixel;
    if (!x.isFinite || !y.isFinite) {
      return null;
    }
    return Offset(x, y);
  }
}
