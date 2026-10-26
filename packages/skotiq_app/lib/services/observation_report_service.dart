import 'dart:io';
import 'dart:math' as math;

import 'package:intl/intl.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:path/path.dart' as path;
import 'package:pdf/pdf.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:pdf/widgets.dart' as pw;

part 'observation_report_service/statistics.dart';

/// Generates comprehensive PDF observation reports from session and science data.
class ObservationReportService {
  final SessionsDao _sessionsDao;
  final ImagesDao _imagesDao;
  final ScienceDao _scienceDao;
  final Future<Directory> Function() _documentsDirectoryProvider;

  ObservationReportService({
    required SessionsDao sessionsDao,
    required ImagesDao imagesDao,
    required ScienceDao scienceDao,
    Future<Directory> Function()? documentsDirectoryProvider,
  })  : _sessionsDao = sessionsDao,
        _imagesDao = imagesDao,
        _scienceDao = scienceDao,
        _documentsDirectoryProvider =
            documentsDirectoryProvider ?? resolveSkotiqDocumentsDirectory;

  /// Generate a full observation report PDF for a session.
  ///
  /// Returns the file path of the saved PDF.
  Future<String> generateReport({
    required int sessionId,
    String? observerName,
    String? locationName,
    double? latitude,
    double? longitude,
    double? elevation,
    String? equipmentSummary,
  }) async {
    final session = await _sessionsDao.getSessionById(sessionId);
    if (session == null) {
      throw Exception('Session not found: $sessionId');
    }

    final images = await _imagesDao.getImagesForSession(sessionId);
    final photometry = await _scienceDao.getPhotometryForSession(sessionId);
    final calibrations = await _scienceDao.getCalibrationsForSession(sessionId);
    final transparency = await _scienceDao.getTransparencyForSession(sessionId);
    final psfTiles = await _scienceDao.getPsfTilesForSession(sessionId);
    final frameMetrics =
        await _scienceDao.getFrameQualityMetricsForSession(sessionId);
    final residuals = await _scienceDao.getResidualsForSession(sessionId);
    final movingObjects =
        await _scienceDao.getMovingObjectsForSession(sessionId);

    final pdf = pw.Document(
      title: 'Skotiq Observation Report',
      author: observerName ?? 'Skotiq',
      creator: 'Skotiq',
    );

    final dateFormat = DateFormat('yyyy-MM-dd HH:mm:ss');
    final acceptedImages = images.where((i) => i.isAccepted).toList();

    // Page 1: Header and session overview
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(40),
        header: (context) => _buildPageHeader(session, dateFormat),
        footer: (context) => _buildPageFooter(context),
        build: (context) => [
          _buildHeaderSection(
            session: session,
            dateFormat: dateFormat,
            observerName: observerName,
            locationName: locationName,
            latitude: latitude,
            longitude: longitude,
            elevation: elevation,
            equipmentSummary: equipmentSummary,
          ),
          pw.SizedBox(height: 20),
          _buildSessionSummarySection(session, SessionFrameGrading.of(images)),
          pw.SizedBox(height: 20),
          _buildImageQualitySection(session, acceptedImages),
          pw.SizedBox(height: 20),
          _buildFilterBreakdownSection(acceptedImages),
          if (frameMetrics.isNotEmpty) ...[
            pw.SizedBox(height: 20),
            _buildFrameQualityMetricsSection(frameMetrics),
          ],
          if (calibrations.isNotEmpty) ...[
            pw.SizedBox(height: 20),
            _buildPhotometricCalibrationSection(calibrations),
          ],
          if (transparency.isNotEmpty) ...[
            pw.SizedBox(height: 20),
            _buildTransparencySection(transparency),
          ],
          if (photometry.isNotEmpty) ...[
            pw.SizedBox(height: 20),
            _buildPhotometrySection(photometry),
          ],
          if (psfTiles.isNotEmpty) ...[
            pw.SizedBox(height: 20),
            _buildPsfSection(psfTiles),
          ],
          if (residuals.isNotEmpty) ...[
            pw.SizedBox(height: 20),
            _buildResidualsSection(residuals),
          ],
          if (movingObjects.isNotEmpty) ...[
            pw.SizedBox(height: 20),
            _buildMovingObjectsSection(movingObjects),
          ],
          if (session.avgTemperature != null ||
              session.avgHumidity != null ||
              session.avgSeeing != null) ...[
            pw.SizedBox(height: 20),
            _buildWeatherSection(session),
          ],
          if (session.notes != null && session.notes!.isNotEmpty) ...[
            pw.SizedBox(height: 20),
            _buildNotesSection(session),
          ],
        ],
      ),
    );

    // Save PDF
    final directory = await _getExportDirectory();
    final sessionName = session.name ?? 'session_$sessionId';
    final timestamp =
        DateTime.now().toIso8601String().replaceAll(':', '-').split('.')[0];
    final fileName = '${sessionName}_report_$timestamp.pdf';
    final filePath = path.join(directory.path, fileName);
    final file = File(filePath);
    await file.writeAsBytes(await pdf.save());

    return filePath;
  }

  pw.Widget _buildPageHeader(ImagingSession session, DateFormat dateFormat) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 8),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          bottom: pw.BorderSide(
            color: PdfColors.blueGrey300,
            width: 0.5,
          ),
        ),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            'Skotiq Observation Report',
            style: pw.TextStyle(
              fontSize: 10,
              color: PdfColors.blueGrey600,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          pw.Text(
            session.name ?? 'Session ${session.id}',
            style: const pw.TextStyle(
              fontSize: 10,
              color: PdfColors.blueGrey600,
            ),
          ),
        ],
      ),
    );
  }

  pw.Widget _buildPageFooter(pw.Context context) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(top: 8),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          top: pw.BorderSide(
            color: PdfColors.blueGrey300,
            width: 0.5,
          ),
        ),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            'Generated by Skotiq on ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}',
            style: const pw.TextStyle(
              fontSize: 8,
              color: PdfColors.blueGrey400,
            ),
          ),
          pw.Text(
            'Page ${context.pageNumber} of ${context.pagesCount}',
            style: const pw.TextStyle(
              fontSize: 8,
              color: PdfColors.blueGrey400,
            ),
          ),
        ],
      ),
    );
  }

  pw.Widget _buildHeaderSection({
    required ImagingSession session,
    required DateFormat dateFormat,
    String? observerName,
    String? locationName,
    double? latitude,
    double? longitude,
    double? elevation,
    String? equipmentSummary,
  }) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          session.name ?? 'Observation Session ${session.id}',
          style: pw.TextStyle(
            fontSize: 22,
            fontWeight: pw.FontWeight.bold,
            color: PdfColors.blueGrey900,
          ),
        ),
        pw.SizedBox(height: 8),
        pw.Container(
          padding: const pw.EdgeInsets.all(12),
          decoration: pw.BoxDecoration(
            color: PdfColors.blueGrey50,
            borderRadius: pw.BorderRadius.circular(SkotiqTokens.radiusXs),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              if (observerName != null) _headerRow('Observer', observerName),
              _headerRow('Date', dateFormat.format(session.startTime)),
              if (session.endTime != null)
                _headerRow('End Time', dateFormat.format(session.endTime!)),
              _headerRow(
                  'Duration',
                  DurationFormat.of(
                      (session.endTime ?? DateTime.now())
                          .difference(session.startTime),
                      style: DurationStyle.compact)),
              _headerRow('Status', session.status.toUpperCase()),
              if (locationName != null) _headerRow('Location', locationName),
              if (latitude != null && longitude != null)
                _headerRow(
                  'Coordinates',
                  '${latitude.toStringAsFixed(4)}, ${longitude.toStringAsFixed(4)}'
                      '${elevation != null ? " (${elevation.toStringAsFixed(0)}m)" : ""}',
                ),
              if (equipmentSummary != null)
                _headerRow('Equipment', equipmentSummary),
            ],
          ),
        ),
      ],
    );
  }

  pw.Widget _headerRow(String label, String value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(
            width: 100,
            child: pw.Text(
              label,
              style: pw.TextStyle(
                fontSize: 10,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.blueGrey700,
              ),
            ),
          ),
          pw.Expanded(
            child: pw.Text(
              value,
              style: const pw.TextStyle(
                fontSize: 10,
                color: PdfColors.blueGrey900,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The summary table, in the two accountings a night actually has.
  ///
  /// The top row is the CAMERA's: how many exposures the run asked for and how
  /// many came back. The second half of it used to end in a "Success Rate"
  /// computed from those two numbers alone, which on a night the grader threw
  /// out entirely printed 100.0% — in a signed observation report, above a
  /// filter breakdown listing no frames at all. [grading] is the culling's
  /// verdict over the same night's light frames, and it is what "kept" means.
  pw.Widget _buildSessionSummarySection(
      ImagingSession session, SessionFrameGrading grading) {
    final keptPercent = grading.keptPercent;

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _sectionTitle('Session Summary'),
        pw.Table(
          columnWidths: {
            0: const pw.FlexColumnWidth(1),
            1: const pw.FlexColumnWidth(1),
            2: const pw.FlexColumnWidth(1),
            3: const pw.FlexColumnWidth(1),
          },
          children: [
            pw.TableRow(children: [
              _statCell('Total Exposures', '${session.totalExposures}'),
              _statCell('Accepted', '${session.successfulExposures}'),
              _statCell('Failed or rejected', '${session.failedExposures}'),
              _statCell(
                'Integration',
                '${(session.totalIntegrationSecs / 3600).toStringAsFixed(2)}h',
              ),
            ]),
            pw.TableRow(children: [
              _statCell('Light Frames', '${grading.lights}'),
              _statCell('Frames Kept', '${grading.accepted}'),
              _statCell('Frames Rejected', '${grading.rejected}'),
              _statCell(
                'Kept Rate',
                keptPercent == null
                    ? 'no light frames'
                    : '${keptPercent.toStringAsFixed(1)}%',
              ),
            ]),
            pw.TableRow(children: [
              _statCell(
                'Autofocus Runs',
                '${session.autofocusCount}',
              ),
              _statCell(
                'Avg HFR',
                session.avgHfr?.toStringAsFixed(2) ?? '-',
              ),
              _statCell(
                'Avg Guiding RMS',
                session.avgGuidingRms != null
                    ? '${session.avgGuidingRms!.toStringAsFixed(2)}"'
                    : '-',
              ),
              _statCell(
                'Avg Seeing',
                session.avgSeeing != null
                    ? '${session.avgSeeing!.toStringAsFixed(2)}"'
                    : '-',
              ),
            ]),
          ],
        ),
      ],
    );
  }

  pw.Widget _buildImageQualitySection(
      ImagingSession session, List<DbCapturedImage> images) {
    if (images.isEmpty) {
      return pw.SizedBox.shrink();
    }

    final List<double> hfrValues =
        images.where((i) => i.hfr != null).map<double>((i) => i.hfr!).toList();
    final List<double> guidingValues = images
        .where((i) => i.guidingRmsTotal != null)
        .map<double>((i) => i.guidingRmsTotal!)
        .toList();

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _sectionTitle('Image Quality Statistics'),
        pw.Table(
          columnWidths: {
            0: const pw.FlexColumnWidth(1),
            1: const pw.FlexColumnWidth(1),
            2: const pw.FlexColumnWidth(1),
            3: const pw.FlexColumnWidth(1),
          },
          children: [
            if (hfrValues.isNotEmpty)
              pw.TableRow(children: [
                _statCell(
                    'HFR Min', '${_listMin(hfrValues).toStringAsFixed(2)} px'),
                _statCell(
                    'HFR Max', '${_listMax(hfrValues).toStringAsFixed(2)} px'),
                _statCell('HFR Mean',
                    '${_listMean(hfrValues).toStringAsFixed(2)} px'),
                _statCell('HFR Median',
                    '${_listMedian(hfrValues).toStringAsFixed(2)} px'),
              ]),
            if (guidingValues.isNotEmpty)
              pw.TableRow(children: [
                _statCell('RMS Min',
                    '${_listMin(guidingValues).toStringAsFixed(2)}"'),
                _statCell('RMS Max',
                    '${_listMax(guidingValues).toStringAsFixed(2)}"'),
                _statCell('RMS Mean',
                    '${_listMean(guidingValues).toStringAsFixed(2)}"'),
                _statCell('RMS Median',
                    '${_listMedian(guidingValues).toStringAsFixed(2)}"'),
              ]),
          ],
        ),
      ],
    );
  }

  pw.Widget _buildFilterBreakdownSection(List<DbCapturedImage> images) {
    if (images.isEmpty) {
      return pw.SizedBox.shrink();
    }

    final filterGroups = <String, List<DbCapturedImage>>{};
    for (final image in images) {
      final filter = image.filter ?? 'No Filter';
      filterGroups.putIfAbsent(filter, () => []).add(image);
    }

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _sectionTitle('Accepted Frames by Filter'),
        pw.Table(
          border: pw.TableBorder.all(
            color: PdfColors.blueGrey200,
            width: 0.5,
          ),
          columnWidths: {
            0: const pw.FlexColumnWidth(2),
            1: const pw.FlexColumnWidth(1),
            2: const pw.FlexColumnWidth(2),
            3: const pw.FlexColumnWidth(1.5),
          },
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(
                color: PdfColors.blueGrey100,
              ),
              children: [
                _tableHeader('Filter'),
                _tableHeader('Frames'),
                _tableHeader('Integration'),
                _tableHeader('Avg HFR'),
              ],
            ),
            for (final entry in filterGroups.entries)
              pw.TableRow(children: [
                _tableCell(entry.key),
                _tableCell('${entry.value.length}'),
                _tableCell(
                  '${(entry.value.fold<double>(0.0, (sum, img) => sum + img.exposureDuration) / 60).toStringAsFixed(1)} min',
                ),
                _tableCell(
                  _filterGroupAvgHfr(entry.value),
                ),
              ]),
          ],
        ),
      ],
    );
  }

  pw.Widget _buildFrameQualityMetricsSection(
      List<ScienceFrameQualityMetricsRow> metrics) {
    final latest = metrics.last;
    final List<double> snrValues = metrics.map<double>((m) => m.snr).toList();

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _sectionTitle('Frame Quality Metrics'),
        pw.Table(
          columnWidths: {
            0: const pw.FlexColumnWidth(1),
            1: const pw.FlexColumnWidth(1),
            2: const pw.FlexColumnWidth(1),
            3: const pw.FlexColumnWidth(1),
          },
          children: [
            pw.TableRow(children: [
              _statCell('Latest SNR', latest.snr.toStringAsFixed(1)),
              _statCell(
                'Avg SNR',
                _listMean(snrValues).toStringAsFixed(1),
              ),
              _statCell(
                'Uniformity CV',
                latest.uniformityCv.toStringAsFixed(3),
              ),
              _statCell(
                'Dynamic Range',
                latest.dynamicRangeP1P99.toStringAsFixed(1),
              ),
            ]),
            pw.TableRow(children: [
              _statCell(
                  'Low Clip', '${latest.lowClipPercent.toStringAsFixed(2)}%'),
              _statCell(
                  'High Clip', '${latest.highClipPercent.toStringAsFixed(2)}%'),
              _statCell('Background', latest.background.toStringAsFixed(1)),
              _statCell('Noise', latest.noise.toStringAsFixed(1)),
            ]),
          ],
        ),
      ],
    );
  }

  pw.Widget _buildPhotometricCalibrationSection(
      List<FramePhotometricCalibrationRow> calibrations) {
    final calibrated = calibrations.where((c) => c.isCalibrated).toList();
    if (calibrated.isEmpty) {
      return pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          _sectionTitle('Photometric Calibration'),
          pw.Text(
            '${calibrations.length} frames processed, none successfully calibrated.',
            style:
                const pw.TextStyle(fontSize: 10, color: PdfColors.blueGrey700),
          ),
        ],
      );
    }

    final List<double> zpValues =
        calibrated.map<double>((c) => c.zeroPoint ?? 0.0).toList();
    final List<double> limMagValues = calibrated
        .where((c) => c.limitingMag5Sigma != null)
        .map<double>((c) => c.limitingMag5Sigma!)
        .toList();

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _sectionTitle('Photometric Calibration'),
        pw.Table(
          columnWidths: {
            0: const pw.FlexColumnWidth(1),
            1: const pw.FlexColumnWidth(1),
            2: const pw.FlexColumnWidth(1),
            3: const pw.FlexColumnWidth(1),
          },
          children: [
            pw.TableRow(children: [
              _statCell(
                'Calibrated Frames',
                '${calibrated.length}/${calibrations.length}',
              ),
              _statCell(
                'Avg Zero Point',
                _listMean(zpValues).toStringAsFixed(2),
              ),
              _statCell(
                'Avg RMS',
                _listMean(calibrated
                        .map<double>((c) => c.calibrationRms)
                        .toList())
                    .toStringAsFixed(3),
              ),
              _statCell(
                'Avg Lim Mag (5-sigma)',
                limMagValues.isNotEmpty
                    ? _listMean(limMagValues).toStringAsFixed(2)
                    : '-',
              ),
            ]),
          ],
        ),
      ],
    );
  }

  pw.Widget _buildTransparencySection(List<TransparencySampleRow> samples) {
    final List<double> values =
        samples.map<double>((s) => s.transparencyPercent).toList();

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _sectionTitle('Sky Transparency'),
        pw.Table(
          columnWidths: {
            0: const pw.FlexColumnWidth(1),
            1: const pw.FlexColumnWidth(1),
            2: const pw.FlexColumnWidth(1),
            3: const pw.FlexColumnWidth(1),
          },
          children: [
            pw.TableRow(children: [
              _statCell('Samples', '${samples.length}'),
              _statCell(
                'Mean',
                '${_listMean(values).toStringAsFixed(1)}%',
              ),
              _statCell(
                'Min',
                '${_listMin(values).toStringAsFixed(1)}%',
              ),
              _statCell(
                'Max',
                '${_listMax(values).toStringAsFixed(1)}%',
              ),
            ]),
          ],
        ),
        pw.SizedBox(height: 4),
        pw.Text(
          'Latest quality: ${samples.last.qualityBucket} '
          '(extinction ${samples.last.extinctionCoefficient.toStringAsFixed(3)})',
          style: const pw.TextStyle(fontSize: 9, color: PdfColors.blueGrey600),
        ),
      ],
    );
  }

  pw.Widget _buildPhotometrySection(
      List<PhotometryMeasurementRow> measurements) {
    final List<String> objectIds =
        measurements.map<String>((m) => m.objectId).toSet().toList();

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _sectionTitle('Differential Photometry'),
        pw.Text(
          '${measurements.length} measurements across ${objectIds.length} '
          'object${objectIds.length == 1 ? '' : 's'}',
          style: const pw.TextStyle(fontSize: 10, color: PdfColors.blueGrey700),
        ),
        pw.SizedBox(height: 4),
        pw.Table(
          border: pw.TableBorder.all(
            color: PdfColors.blueGrey200,
            width: 0.5,
          ),
          columnWidths: {
            0: const pw.FlexColumnWidth(2),
            1: const pw.FlexColumnWidth(1),
            2: const pw.FlexColumnWidth(1.5),
            3: const pw.FlexColumnWidth(1.5),
            4: const pw.FlexColumnWidth(1),
          },
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(
                color: PdfColors.blueGrey100,
              ),
              children: [
                _tableHeader('Object'),
                _tableHeader('Points'),
                _tableHeader('Avg dMag'),
                _tableHeader('Avg SNR'),
                _tableHeader('Outliers'),
              ],
            ),
            for (final objectId in objectIds.take(10))
              _photometryObjectRow(objectId,
                  measurements.where((m) => m.objectId == objectId).toList()),
          ],
        ),
      ],
    );
  }

  pw.TableRow _photometryObjectRow(
      String objectId, List<PhotometryMeasurementRow> points) {
    final magValues = points
        .where((p) => p.differentialMagnitude != null)
        .map((p) => p.differentialMagnitude!)
        .toList();
    final snrValues =
        points.where((p) => p.snr != null).map((p) => p.snr!).toList();
    final outliers = points.where((p) => p.isOutlier).length;

    return pw.TableRow(children: [
      _tableCell(objectId),
      _tableCell('${points.length}'),
      _tableCell(
        magValues.isNotEmpty ? _listMean(magValues).toStringAsFixed(3) : '-',
      ),
      _tableCell(
        snrValues.isNotEmpty ? _listMean(snrValues).toStringAsFixed(1) : '-',
      ),
      _tableCell('$outliers'),
    ]);
  }

  pw.Widget _buildPsfSection(List<PsfFieldTileRow> tiles) {
    final validTiles = tiles.where((t) => t.starCount > 0).toList();
    if (validTiles.isEmpty) {
      return pw.SizedBox.shrink();
    }

    final List<double> fwhmValues =
        validTiles.map<double>((t) => t.medianFwhm).toList();
    final List<double> eccValues =
        validTiles.map<double>((t) => t.medianEccentricity).toList();

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _sectionTitle('PSF Field Analysis'),
        pw.Table(
          columnWidths: {
            0: const pw.FlexColumnWidth(1),
            1: const pw.FlexColumnWidth(1),
            2: const pw.FlexColumnWidth(1),
            3: const pw.FlexColumnWidth(1),
          },
          children: [
            pw.TableRow(children: [
              _statCell('Tiles Analyzed', '${validTiles.length}'),
              _statCell(
                'FWHM Range',
                '${_listMin(fwhmValues).toStringAsFixed(2)}-${_listMax(fwhmValues).toStringAsFixed(2)}',
              ),
              _statCell(
                'Avg FWHM',
                _listMean(fwhmValues).toStringAsFixed(2),
              ),
              _statCell(
                'Avg Eccentricity',
                _listMean(eccValues).toStringAsFixed(3),
              ),
            ]),
          ],
        ),
      ],
    );
  }

  pw.Widget _buildResidualsSection(
      List<AstrometryResidualVectorRow> residuals) {
    final List<double> magnitudes =
        residuals.map<double>((r) => r.magnitudeArcsec).toList();
    final rms = _rms(magnitudes);

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _sectionTitle('Astrometric Residuals'),
        pw.Table(
          columnWidths: {
            0: const pw.FlexColumnWidth(1),
            1: const pw.FlexColumnWidth(1),
            2: const pw.FlexColumnWidth(1),
            3: const pw.FlexColumnWidth(1),
          },
          children: [
            pw.TableRow(children: [
              _statCell('Samples', '${residuals.length}'),
              _statCell('RMS', '${rms.toStringAsFixed(3)}"'),
              _statCell(
                'Max Residual',
                '${_listMax(magnitudes).toStringAsFixed(3)}"',
              ),
              _statCell(
                'Pattern',
                residualSuggestionText(residuals.last.recommendationCode) ??
                    'No pattern',
              ),
            ]),
          ],
        ),
      ],
    );
  }

  pw.Widget _buildMovingObjectsSection(List<MovingObjectCandidateRow> objects) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _sectionTitle('Moving Object Candidates'),
        pw.Table(
          border: pw.TableBorder.all(
            color: PdfColors.blueGrey200,
            width: 0.5,
          ),
          columnWidths: {
            0: const pw.FlexColumnWidth(2),
            1: const pw.FlexColumnWidth(1.5),
            2: const pw.FlexColumnWidth(1.5),
            3: const pw.FlexColumnWidth(1),
            4: const pw.FlexColumnWidth(1),
          },
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(
                color: PdfColors.blueGrey100,
              ),
              children: [
                _tableHeader('Name/ID'),
                _tableHeader('RA'),
                _tableHeader('Dec'),
                _tableHeader('Motion'),
                _tableHeader('Confidence'),
              ],
            ),
            for (final obj in objects.take(20))
              pw.TableRow(children: [
                _tableCell(obj.objectName ?? obj.candidateId),
                _tableCell(obj.raDegrees.toStringAsFixed(4)),
                _tableCell(obj.decDegrees.toStringAsFixed(4)),
                _tableCell(
                    '${obj.motionArcsecPerMinute.toStringAsFixed(2)}"/m'),
                _tableCell('${(obj.confidence * 100).toStringAsFixed(0)}%'),
              ]),
          ],
        ),
      ],
    );
  }

  pw.Widget _buildWeatherSection(ImagingSession session) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _sectionTitle('Weather Conditions'),
        pw.Table(
          columnWidths: {
            0: const pw.FlexColumnWidth(1),
            1: const pw.FlexColumnWidth(1),
            2: const pw.FlexColumnWidth(1),
          },
          children: [
            pw.TableRow(children: [
              _statCell(
                'Temperature',
                session.avgTemperature != null
                    ? '${session.avgTemperature!.toStringAsFixed(1)} C'
                    : '-',
              ),
              _statCell(
                'Humidity',
                session.avgHumidity != null
                    ? '${session.avgHumidity!.toStringAsFixed(1)}%'
                    : '-',
              ),
              _statCell(
                'Seeing',
                session.avgSeeing != null
                    ? '${session.avgSeeing!.toStringAsFixed(1)}"'
                    : '-',
              ),
            ]),
          ],
        ),
      ],
    );
  }

  pw.Widget _buildNotesSection(ImagingSession session) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _sectionTitle('Observer Notes'),
        pw.Container(
          padding: const pw.EdgeInsets.all(8),
          decoration: pw.BoxDecoration(
            color: PdfColors.blueGrey50,
            borderRadius: pw.BorderRadius.circular(SkotiqTokens.radiusXs),
          ),
          child: pw.Text(
            session.notes!,
            style: const pw.TextStyle(
              fontSize: 10,
              color: PdfColors.blueGrey800,
            ),
          ),
        ),
      ],
    );
  }

  // Helpers

  pw.Widget _sectionTitle(String title) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 8),
      child: pw.Text(
        title,
        style: pw.TextStyle(
          fontSize: 14,
          fontWeight: pw.FontWeight.bold,
          color: PdfColors.blueGrey800,
        ),
      ),
    );
  }

  pw.Widget _statCell(String label, String value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.all(6),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            label,
            style: const pw.TextStyle(
              fontSize: 8,
              color: PdfColors.blueGrey500,
            ),
          ),
          pw.SizedBox(height: 2),
          pw.Text(
            value,
            style: pw.TextStyle(
              fontSize: 11,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.blueGrey900,
            ),
          ),
        ],
      ),
    );
  }

  pw.Widget _tableHeader(String text) {
    return pw.Padding(
      padding: const pw.EdgeInsets.all(6),
      child: pw.Text(
        text,
        style: pw.TextStyle(
          fontSize: 9,
          fontWeight: pw.FontWeight.bold,
          color: PdfColors.blueGrey700,
        ),
      ),
    );
  }

  pw.Widget _tableCell(String text) {
    return pw.Padding(
      padding: const pw.EdgeInsets.all(6),
      child: pw.Text(
        text,
        style: const pw.TextStyle(
          fontSize: 9,
          color: PdfColors.blueGrey800,
        ),
      ),
    );
  }

  String _filterGroupAvgHfr(List<DbCapturedImage> images) {
    final List<double> hfrValues =
        images.where((i) => i.hfr != null).map<double>((i) => i.hfr!).toList();
    if (hfrValues.isEmpty) return '-';
    return '${_listMean(hfrValues).toStringAsFixed(2)} px';
  }

  Future<Directory> _getExportDirectory() async {
    final docsDir = await _documentsDirectoryProvider();
    final exportDir = Directory(path.join(docsDir.path, 'Skotiq', 'exports'));
    if (!await exportDir.exists()) {
      await exportDir.create(recursive: true);
    }
    return exportDir;
  }
}
