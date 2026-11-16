part of '../network_backend.dart';

/// Science products a linked imaging host derives from its frames:
/// photometry, transforms, reports and their settings.
mixin HostScience on NetworkBackendTransport {
  Future<PhotometricTransformCoefficients?> computePhotometricTransform({
    required List<CatalogStarMatch> starMatches,
    required String filterName,
    int? equipmentProfileId,
  }) async {
    try {
      final response = await _post(
        ScienceApi.computePhotometricTransform,
        body: {
          'starMatches': starMatches.map((match) => match.toJson()).toList(),
          'filterName': filterName,
          if (equipmentProfileId != null)
            'equipmentProfileId': equipmentProfileId,
        },
      );
      return PhotometricTransformCoefficients.fromJson(
        _sessionScienceObject(
          response,
          'coefficients',
          'POST /api/science/calibration/compute-transform',
        ),
      );
    } on ServerError catch (error) {
      // A valid request whose fit could not converge is the one documented
      // nullable outcome. Auth, transport, and malformed-success failures must
      // still surface to the wizard.
      if (error.httpStatus == 422) return null;
      rethrow;
    }
  }

  Future<Uint8List> exportSessionAavso(
    int sessionId, {
    required String targetStarName,
    String? filterBand,
    String? chartId,
  }) async {
    return _postRawBytes(
      ScienceApi.exportAavso,
      path: {'sessionId': sessionId},
      body: {
        'targetStarName': targetStarName,
        if (filterBand != null && filterBand.isNotEmpty)
          'filterBand': filterBand,
        if (chartId != null && chartId.isNotEmpty) 'chartId': chartId,
      },
    );
  }

  Future<Uint8List> generateObservationReport(int sessionId) async {
    return _downloadBytes(
      ScienceApi.generateObservationReport,
      path: {'sessionId': sessionId},
    );
  }

  Future<String> scienceReport(int sessionId, {PeriodFinding? period}) async {
    final response = await _post(
      ScienceApi.scienceReport,
      path: {'sessionId': sessionId},
      body: {if (period != null) 'period': period.toJson()},
    );
    final markdown = response['markdown'];
    if (markdown is! String) {
      throw FormatException(
        'POST /api/science/session/$sessionId/report has no markdown',
      );
    }
    return markdown;
  }

  Future<int?> scienceDefaultSession() async {
    final response = await _get(ScienceApi.defaultSession);
    final sessionId = response['sessionId'];
    if (sessionId != null && sessionId is! int) {
      throw const FormatException(
        'GET /api/science/default-session: sessionId is not a number',
      );
    }
    return sessionId as int?;
  }

  Future<Map<String, dynamic>> generateSessionLineRatios(int sessionId) async {
    return _post(
      ScienceApi.generateLineRatios,
      path: {'sessionId': sessionId},
      body: {},
    );
  }

  /// True pixel dimensions of a host FITS file. Used by the photometric
  /// calibration wizard to size images exactly on a remote client instead of
  /// estimating from the detected-star bounding box. Returns null if the host
  /// has no such file.
  Future<({int width, int height})?> getFitsDimensions(String hostPath) async {
    try {
      final response = await _get(
        ImagingApi.getFitsDimensions,
        query: {'path': hostPath},
      );
      return (
        width: _sessionScienceNumber(
          response,
          'width',
          'GET /api/imaging/fits-dimensions',
        ).toInt(),
        height: _sessionScienceNumber(
          response,
          'height',
          'GET /api/imaging/fits-dimensions',
        ).toInt(),
      );
    } on ServerError catch (error) {
      if (error.httpStatus == 404 || error.code == 'fits_not_found') {
        return null;
      }
      rethrow;
    }
  }

  Future<List<PsfFieldTileRow>> getSessionPsfTiles(int sessionId) async {
    final endpoint = 'GET /api/sessions/$sessionId/psf-tiles';
    final response = await _get(
      AnalyticsApi.getSessionPsfTiles,
      path: {'id': sessionId},
    );
    final rows = _sessionScienceObjectList(response, 'psfTiles', endpoint);
    final seenIds = <int>{};
    final tiles = <PsfFieldTileRow>[];
    for (var index = 0; index < rows.length; index++) {
      final tile = _psfFieldTileFromJson(rows[index], endpoint, index);
      if (!seenIds.add(tile.id)) {
        throw FormatException(
          '$endpoint row $index field `id` duplicates id ${tile.id}',
        );
      }
      tiles.add(tile);
    }
    return tiles;
  }

  Future<RemoteScienceBundle> getSessionlessScienceBundle() async {
    final response = await _get(ScienceApi.getSessionlessBundle);
    return RemoteScienceBundle(
      photometry: _rowsFromJson<PhotometryMeasurementRow>(
        response['photometry'],
        PhotometryMeasurementRow.fromJson,
      ),
      calibrations: _rowsFromJson<FramePhotometricCalibrationRow>(
        response['calibrations'],
        FramePhotometricCalibrationRow.fromJson,
      ),
      transparency: _rowsFromJson<TransparencySampleRow>(
        response['transparency'],
        TransparencySampleRow.fromJson,
      ),
      psfTiles: _rowsFromJson<PsfFieldTileRow>(
        response['psfTiles'],
        PsfFieldTileRow.fromJson,
      ),
      frameQuality: _rowsFromJson<ScienceFrameQualityMetricsRow>(
        response['frameQuality'],
        ScienceFrameQualityMetricsRow.fromJson,
      ),
      tileMetrics: _rowsFromJson<ScienceTileMetricRow>(
        response['tileMetrics'],
        ScienceTileMetricRow.fromJson,
      ),
      residuals: _rowsFromJson<AstrometryResidualVectorRow>(
        response['residuals'],
        AstrometryResidualVectorRow.fromJson,
      ),
      movingObjects: _rowsFromJson<MovingObjectCandidateRow>(
        response['movingObjects'],
        MovingObjectCandidateRow.fromJson,
      ),
      lineRatios: _rowsFromJson<LineRatioProductRow>(
        response['lineRatios'],
        LineRatioProductRow.fromJson,
      ),
    );
  }

  Future<int> savePhotometricTransform(
    PhotometricTransformCoefficients coefficients,
  ) async {
    final response = await _post(
      ScienceApi.savePhotometricTransform,
      body: {'coefficients': coefficients.toJson()},
    );
    return _sessionScienceNumber(
      response,
      'id',
      'POST /api/science/calibration/save-transform',
    ).toInt();
  }
}

/// Every science table the host holds for one session (or for none), read
/// in one request.
class RemoteScienceBundle {
  final List<PhotometryMeasurementRow> photometry;
  final List<FramePhotometricCalibrationRow> calibrations;
  final List<TransparencySampleRow> transparency;
  final List<PsfFieldTileRow> psfTiles;
  final List<ScienceFrameQualityMetricsRow> frameQuality;
  final List<ScienceTileMetricRow> tileMetrics;
  final List<AstrometryResidualVectorRow> residuals;
  final List<MovingObjectCandidateRow> movingObjects;
  final List<LineRatioProductRow> lineRatios;

  const RemoteScienceBundle({
    required this.photometry,
    required this.calibrations,
    required this.transparency,
    required this.psfTiles,
    required this.frameQuality,
    required this.tileMetrics,
    required this.residuals,
    required this.movingObjects,
    required this.lineRatios,
  });
}
