import 'dart:convert';
import 'dart:io';
import 'package:csv/csv.dart';
import 'package:path/path.dart' as path;
import '../utils/fwhm_conversion.dart';
import '../database/daos/sessions_dao.dart';
import '../database/daos/images_dao.dart';
import '../database/database.dart';
import '../utils/skotiq_data_directory.dart';

/// What the culling decided about a night's light frames.
///
/// `imaging_sessions.successful_exposures` answers a different question — did
/// the camera return the frame — and answers it about every frame the run
/// asked for. On a night the grader threw out entirely, that column reads 4 of
/// 4 and the session record's `failed_exposures` reads 0, so a document built
/// from it alone announces a 100% success rate over a night with nothing worth
/// stacking. The list and stats endpoints already publish this verdict beside
/// the camera counts; this is the same verdict for the DOCUMENT, counted from
/// the same rows (`captured_images`, light frames, by `is_accepted`) so the
/// three cannot drift.
class SessionFrameGrading {
  /// Light frames on record for the session.
  final int lights;

  /// Light frames the grader kept.
  final int accepted;

  const SessionFrameGrading({required this.lights, required this.accepted});

  /// The verdict over [images], counting light frames only.
  factory SessionFrameGrading.of(List<CapturedImage> images) {
    var lights = 0;
    var accepted = 0;
    for (final image in images) {
      if (image.frameType != 'light') continue;
      lights++;
      if (image.isAccepted) accepted++;
    }
    return SessionFrameGrading(lights: lights, accepted: accepted);
  }

  /// Light frames the grader rejected.
  int get rejected => lights - accepted;

  /// Percentage kept, or null when there is no light frame to have an opinion
  /// about — never 0.0 or 100.0 over an empty population.
  double? get keptPercent => lights == 0 ? null : accepted / lights * 100.0;
}

/// Service for exporting session data to various formats
class SessionExportService {
  final SessionsDao _sessionsDao;
  final ImagesDao _imagesDao;
  final Future<Directory> Function() _documentsDirectoryProvider;
  final DateTime Function() _now;

  /// [nowProvider] supplies the timestamp stamped onto export filenames and
  /// inside diagnostic dumps. Defaults to [DateTime.now] for backwards
  /// compatibility; the desktop wiring overrides it with the user's
  /// chosen [Clock] so exports labelled in the operator's timezone match
  /// the rest of the session records
  SessionExportService({
    required SessionsDao sessionsDao,
    required ImagesDao imagesDao,
    Future<Directory> Function()? documentsDirectoryProvider,
    DateTime Function()? nowProvider,
  }) : _sessionsDao = sessionsDao,
       _imagesDao = imagesDao,
       _documentsDirectoryProvider =
           documentsDirectoryProvider ?? resolveSkotiqDocumentsDirectory,
       _now = nowProvider ?? DateTime.now;

  /// Export session images to CSV format
  ///
  /// Exports filename, exposure time, filter, HFR, FWHM, stars detected,
  /// temperature, and timestamp for each image in the session.
  ///
  /// Returns the path to the saved CSV file.
  Future<String> exportToCsv(int sessionId) async {
    final session = await _sessionsDao.getSessionById(sessionId);
    if (session == null) {
      throw Exception('Session not found: $sessionId');
    }

    final images = await _imagesDao.getImagesForSession(sessionId);
    final measuredFwhm = await _imagesDao.getFwhmForSession(sessionId);

    // CSV header
    final List<List<dynamic>> rows = [
      [
        'Filename',
        'Exposure Time (s)',
        'Filter',
        'HFR (px)',
        'FWHM (px, measured or 2x HFR)',
        'Stars Detected',
        'Sensor Temp (C)',
        'Timestamp',
        'Frame Type',
        'Gain',
        'Offset',
        'Binning',
        'Guiding RMS Total',
        'Accepted',
      ],
    ];

    // Add image data rows
    for (final image in images) {
      // Prefer the MEASURED fwhm column when the pipeline recorded one;
      // only derive from HFR when it did not.
      final fwhm =
          measuredFwhm[image.id] ??
          (image.hfr != null ? image.hfr! * kFwhmPerHfr : null);

      rows.add([
        image.fileName,
        image.exposureDuration,
        image.filter ?? '',
        image.hfr?.toStringAsFixed(2) ?? '',
        fwhm?.toStringAsFixed(2) ?? '',
        image.starCount ?? '',
        image.sensorTemp?.toStringAsFixed(1) ?? '',
        image.capturedAt.toIso8601String(),
        image.frameType,
        image.gain ?? '',
        image.offset ?? '',
        '${image.binX}x${image.binY}',
        image.guidingRmsTotal?.toStringAsFixed(2) ?? '',
        image.isAccepted ? 'Yes' : 'No',
      ]);
    }

    // Convert to CSV
    final csv = const ListToCsvConverter().convert(rows);

    // Save to file
    final directory = await _getExportDirectory();
    final sessionName = session.name ?? 'session_$sessionId';
    final timestamp = _now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')[0];
    final fileName = '${sessionName}_$timestamp.csv';
    final filePath = path.join(directory.path, fileName);

    final file = File(filePath);
    await file.writeAsString(csv);

    return filePath;
  }

  /// Export session data to JSON format
  ///
  /// Exports full session metadata including all images and equipment profiles.
  /// Returns the path to the saved JSON file.
  Future<String> exportToJson(int sessionId) async {
    final session = await _sessionsDao.getSessionById(sessionId);
    if (session == null) {
      throw Exception('Session not found: $sessionId');
    }

    final images = await _imagesDao.getImagesForSession(sessionId);
    final measuredFwhm = await _imagesDao.getFwhmForSession(sessionId);
    final grading = SessionFrameGrading.of(images);

    // Build JSON structure
    final data = {
      'session': {
        'id': session.id,
        'name': session.name,
        'startTime': session.startTime.toIso8601String(),
        'endTime': session.endTime?.toIso8601String(),
        'status': session.status,
        'profileId': session.profileId,
        'targetId': session.targetId,
        'statistics': {
          'totalExposures': session.totalExposures,
          'successfulExposures': session.successfulExposures,
          'failedExposures': session.failedExposures,
          // What the culling decided, beside what the camera returned. A
          // consumer that reads only the three counters above cannot tell a
          // clean night from one whose every sub was thrown away.
          'lightFrames': grading.lights,
          'acceptedLights': grading.accepted,
          'rejectedLights': grading.rejected,
          'totalIntegrationSecs': session.totalIntegrationSecs,
          'totalIntegrationHours': session.totalIntegrationSecs / 3600.0,
          'avgHfr': session.avgHfr,
          'avgGuidingRms': session.avgGuidingRms,
          'autofocusCount': session.autofocusCount,
        },
        'conditions': {
          'avgTemperature': session.avgTemperature,
          'avgHumidity': session.avgHumidity,
          'avgSeeing': session.avgSeeing,
        },
        'notes': session.notes,
      },
      'images': images.map((image) {
        return {
          'id': image.id,
          'fileName': image.fileName,
          'filePath': image.filePath,
          'fileFormat': image.fileFormat,
          'fileSize': image.fileSize,
          'frameType': image.frameType,
          'capturedAt': image.capturedAt.toIso8601String(),
          'exposure': {
            'duration': image.exposureDuration,
            'gain': image.gain,
            'offset': image.offset,
            'binX': image.binX,
            'binY': image.binY,
            'filter': image.filter,
          },
          'camera': {
            'sensorTemp': image.sensorTemp,
            'coolerPower': image.coolerPower,
          },
          'quality': {
            'hfr': image.hfr,
            'fwhm':
                measuredFwhm[image.id] ??
                (image.hfr != null ? image.hfr! * kFwhmPerHfr : null),
            'starCount': image.starCount,
            'background': image.background,
            'noise': image.noise,
          },
          'guiding': {
            'rmsRa': image.guidingRmsRa,
            'rmsDec': image.guidingRmsDec,
            'rmsTotal': image.guidingRmsTotal,
          },
          'mount': {
            'ra': image.mountRa,
            'dec': image.mountDec,
            'altitude': image.mountAltitude,
            'azimuth': image.mountAzimuth,
            'pierSide': image.pierSide,
          },
          'focuser': {
            'position': image.focuserPosition,
            'temp': image.focuserTemp,
          },
          'plateSolve': image.isPlateSolved
              ? {
                  'ra': image.solvedRa,
                  'dec': image.solvedDec,
                  'rotation': image.solvedRotation,
                  'pixelScale': image.solvedPixelScale,
                }
              : null,
          'isAccepted': image.isAccepted,
          'rejectionReason': image.rejectionReason,
        };
      }).toList(),
      'exportedAt': _now().toIso8601String(),
      'exportVersion': '1.0',
    };

    // Convert to JSON
    final jsonString = const JsonEncoder.withIndent('  ').convert(data);

    // Save to file
    final directory = await _getExportDirectory();
    final sessionName = session.name ?? 'session_$sessionId';
    final timestamp = _now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')[0];
    final fileName = '${sessionName}_$timestamp.json';
    final filePath = path.join(directory.path, fileName);

    final file = File(filePath);
    await file.writeAsString(jsonString);

    return filePath;
  }

  /// Non-null values of [pick] across [images] — the population a report
  /// aggregate is computed over.
  static List<double> _values(
    List<CapturedImage> images,
    double? Function(CapturedImage image) pick,
  ) {
    final out = <double>[];
    for (final image in images) {
      final v = pick(image);
      if (v != null) out.add(v);
    }
    return out;
  }

  /// Arithmetic mean, or null for an empty population (never 0.0 — a zero would
  /// read as a measurement).
  static double? _mean(List<double> values) {
    if (values.isEmpty) return null;
    var sum = 0.0;
    for (final v in values) {
      sum += v;
    }
    return sum / values.length;
  }

  /// A report metric cell: the formatted value with its unit, or an em dash
  /// with NO unit when the value is missing — a `-%` placeholder reads like a
  /// measurement of nothing.
  static String _metric(double? value, int digits, String unit) =>
      value == null ? '&mdash;' : '${value.toStringAsFixed(digits)}$unit';

  /// A muted provenance line under a metric ("mean of 8 accepted frames",
  /// "not recorded"), or nothing when there is no note to make.
  static String _source(String? note) => note == null
      ? ''
      : '<div class="muted" style="font-size:11px;margin-top:4px">$note</div>';

  /// Get or create the export directory
  Future<Directory> _getExportDirectory() async {
    final docsDir = await _documentsDirectoryProvider();
    final exportDir = Directory(path.join(docsDir.path, 'Skotiq', 'exports'));

    if (!await exportDir.exists()) {
      await exportDir.create(recursive: true);
    }

    return exportDir;
  }

  /// Export session summary (lightweight text format)
  ///
  /// Returns a formatted string summary of the session.
  Future<String> exportSummary(int sessionId) async {
    final session = await _sessionsDao.getSessionById(sessionId);
    if (session == null) {
      throw Exception('Session not found: $sessionId');
    }

    final images = await _imagesDao.getImagesForSession(sessionId);
    final acceptedImages = images.where((img) => img.isAccepted).toList();
    final grading = SessionFrameGrading.of(images);

    final buffer = StringBuffer();
    buffer.writeln('=' * 60);
    buffer.writeln('Skotiq Imaging Session Summary');
    buffer.writeln('=' * 60);
    buffer.writeln();
    buffer.writeln('Session: ${session.name ?? "Unnamed Session"}');
    buffer.writeln('Started: ${session.startTime}');
    buffer.writeln('Ended: ${session.endTime ?? "In Progress"}');
    buffer.writeln('Status: ${session.status}');
    buffer.writeln();
    buffer.writeln('-' * 60);
    buffer.writeln('Statistics');
    buffer.writeln('-' * 60);
    // Two accountings, each labelled with the question it answers. The camera's
    // is first because it is the run's own record; the grader's is what decides
    // whether the night produced anything, and a summary that printed only the
    // first called a night whose every sub was rejected a 100% success.
    buffer.writeln(
      'Frames the camera returned: '
      '${session.successfulExposures} of ${session.totalExposures} '
      '(${session.failedExposures} failed)',
    );
    buffer.writeln('Light frames graded: ${grading.lights}');
    buffer.writeln('Kept: ${grading.accepted}');
    buffer.writeln('Rejected: ${grading.rejected}');
    final keptPercent = grading.keptPercent;
    buffer.writeln(
      keptPercent == null
          ? 'Kept Rate: no light frames recorded'
          : 'Kept Rate: ${keptPercent.toStringAsFixed(1)}%',
    );
    buffer.writeln(
      'Total Integration: ${(session.totalIntegrationSecs / 3600).toStringAsFixed(2)} hours',
    );

    // Same aggregate rule as the HTML report: prefer the session record, else
    // the mean over the accepted frames this summary already lists.
    final summaryHfr =
        session.avgHfr ?? _mean(_values(acceptedImages, (i) => i.hfr));
    if (summaryHfr != null) {
      buffer.writeln('Average HFR: ${summaryHfr.toStringAsFixed(2)} px');
    }

    final summaryRms =
        session.avgGuidingRms ??
        _mean(_values(acceptedImages, (i) => i.guidingRmsTotal));
    if (summaryRms != null) {
      buffer.writeln('Average Guiding RMS: ${summaryRms.toStringAsFixed(2)} "');
    }

    buffer.writeln('Autofocus Runs: ${session.autofocusCount}');
    buffer.writeln();

    if (session.avgTemperature != null ||
        session.avgHumidity != null ||
        session.avgSeeing != null) {
      buffer.writeln('-' * 60);
      buffer.writeln('Conditions');
      buffer.writeln('-' * 60);

      if (session.avgTemperature != null) {
        buffer.writeln(
          'Avg Temperature: ${session.avgTemperature!.toStringAsFixed(1)} °C',
        );
      }

      if (session.avgHumidity != null) {
        buffer.writeln(
          'Avg Humidity: ${session.avgHumidity!.toStringAsFixed(1)} %',
        );
      }

      if (session.avgSeeing != null) {
        buffer.writeln(
          'Avg Seeing: ${session.avgSeeing!.toStringAsFixed(1)} "',
        );
      }

      buffer.writeln();
    }

    buffer.writeln('-' * 60);
    buffer.writeln('Images Breakdown');
    buffer.writeln('-' * 60);
    buffer.writeln('Total Images: ${images.length}');
    buffer.writeln('Accepted: ${acceptedImages.length}');
    buffer.writeln('Rejected: ${images.length - acceptedImages.length}');
    buffer.writeln();

    // Group by filter
    final filterGroups = <String, List<CapturedImage>>{};
    for (final image in acceptedImages) {
      final filter = image.filter ?? 'No Filter';
      filterGroups.putIfAbsent(filter, () => []).add(image);
    }

    if (filterGroups.isNotEmpty) {
      buffer.writeln('By Filter:');
      for (final entry in filterGroups.entries) {
        final totalExp = entry.value.fold<double>(
          0,
          (sum, img) => sum + img.exposureDuration,
        );
        buffer.writeln(
          '  ${entry.key}: ${entry.value.length} images, ${(totalExp / 60).toStringAsFixed(1)} min',
        );
      }
      buffer.writeln();
    }

    if (session.notes != null && session.notes!.isNotEmpty) {
      buffer.writeln('-' * 60);
      buffer.writeln('Notes');
      buffer.writeln('-' * 60);
      buffer.writeln(session.notes);
      buffer.writeln();
    }

    buffer.writeln('=' * 60);
    buffer.writeln('Exported: ${_now()}');
    buffer.writeln('=' * 60);

    return buffer.toString();
  }

  /// Export a styled HTML session report.
  Future<String> exportToHtml(int sessionId) async {
    final session = await _sessionsDao.getSessionById(sessionId);
    if (session == null) {
      throw Exception('Session not found: $sessionId');
    }

    final images = await _imagesDao.getImagesForSession(sessionId);
    final acceptedImages = images.where((image) => image.isAccepted).toList();
    final totalIntegrationHours = session.totalIntegrationSecs / 3600.0;
    final grading = SessionFrameGrading.of(images);
    final keptPercent = grading.keptPercent;

    final filterGroups = <String, List<CapturedImage>>{};
    for (final image in acceptedImages) {
      final filter = image.filter ?? 'No Filter';
      filterGroups.putIfAbsent(filter, () => <CapturedImage>[]).add(image);
    }

    final filterRows = filterGroups.entries.map((entry) {
      final totalExp = entry.value.fold<double>(
        0.0,
        (sum, img) => sum + img.exposureDuration,
      );
      return '''
        <tr>
          <td>${entry.key}</td>
          <td>${entry.value.length}</td>
          <td>${(totalExp / 60).toStringAsFixed(1)} min</td>
        </tr>
      ''';
    }).join();

    // Summary aggregates. `imaging_sessions.avg_hfr` / `avg_guiding_rms` are
    // only written by some run paths, so a report could show "Average HFR -"
    // directly above a frame table listing an HFR for every frame. Fall back to
    // the mean over the frames the report itself is built from, and say where
    // the number came from. Ambient humidity/temperature have no per-frame
    // source (the per-frame temperature is the camera sensor, not the sky), so
    // they stay blank rather than borrowing an unrelated reading.
    final hfrValues = _values(acceptedImages, (image) => image.hfr);
    final rmsValues = _values(acceptedImages, (image) => image.guidingRmsTotal);
    final avgHfr = session.avgHfr ?? _mean(hfrValues);
    final avgHfrSource = session.avgHfr != null
        ? 'session record'
        : (hfrValues.isEmpty
              ? null
              : 'mean of ${hfrValues.length} accepted '
                    '${hfrValues.length == 1 ? 'frame' : 'frames'}');
    final avgRms = session.avgGuidingRms ?? _mean(rmsValues);
    final avgRmsSource = session.avgGuidingRms != null
        ? 'session record'
        : (rmsValues.isEmpty
              ? null
              : 'mean of ${rmsValues.length} accepted '
                    '${rmsValues.length == 1 ? 'frame' : 'frames'}');

    final imageRows = acceptedImages.take(20).map((image) {
      return '''
        <tr>
          <td>${image.fileName}</td>
          <td>${image.frameType}</td>
          <td>${image.filter ?? '-'}</td>
          <td>${image.exposureDuration.toStringAsFixed(1)} s</td>
          <td>${image.hfr?.toStringAsFixed(2) ?? '-'}</td>
          <td>${image.guidingRmsTotal?.toStringAsFixed(2) ?? '-'}</td>
        </tr>
      ''';
    }).join();

    final html =
        '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>Skotiq Session Report</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 32px; color: #1f2937; background: #f6f7fb; }
    .hero { background: linear-gradient(135deg, #0f172a, #1d4ed8); color: white; padding: 28px; border-radius: 18px; }
    .grid { display: grid; grid-template-columns: repeat(4, minmax(120px, 1fr)); gap: 12px; margin: 20px 0; }
    .card { background: white; border-radius: 14px; padding: 16px; box-shadow: 0 10px 30px rgba(15, 23, 42, 0.08); }
    h1, h2 { margin: 0 0 12px; }
    h2 { margin-top: 24px; }
    table { width: 100%; border-collapse: collapse; background: white; border-radius: 14px; overflow: hidden; box-shadow: 0 10px 30px rgba(15, 23, 42, 0.08); }
    th, td { text-align: left; padding: 12px 14px; border-bottom: 1px solid #e5e7eb; }
    th { background: #e0e7ff; font-size: 12px; text-transform: uppercase; letter-spacing: 0.05em; }
    .muted { color: #6b7280; }
    .notes { white-space: pre-wrap; }
  </style>
</head>
<body>
  <section class="hero">
    <h1>${session.name ?? "Unnamed Session"}</h1>
    <div>Started ${session.startTime.toLocal()}</div>
    <div>Ended ${session.endTime?.toLocal() ?? "In progress"} · Status ${session.status}</div>
  </section>

  <section class="grid">
    <div class="card"><div class="muted">Integration</div><strong>${totalIntegrationHours.toStringAsFixed(2)} h</strong></div>
    <div class="card"><div class="muted">Exposures</div><strong>${session.successfulExposures}/${session.totalExposures}</strong>${_source('returned by the camera')}</div>
    <div class="card"><div class="muted">Frames Kept</div><strong>${grading.accepted}/${grading.lights}</strong>${_source(keptPercent == null ? 'no light frames recorded' : '${keptPercent.toStringAsFixed(1)}% kept, ${grading.rejected} rejected')}</div>
    <div class="card"><div class="muted">Autofocus Runs</div><strong>${session.autofocusCount}</strong></div>
  </section>

  <h2>Session Summary</h2>
  <div class="grid">
    <div class="card"><div class="muted">Average HFR</div><strong>${_metric(avgHfr, 2, ' px')}</strong>${_source(avgHfrSource)}</div>
    <div class="card"><div class="muted">Guiding RMS</div><strong>${_metric(avgRms, 2, '"')}</strong>${_source(avgRmsSource)}</div>
    <div class="card"><div class="muted">Humidity</div><strong>${_metric(session.avgHumidity, 1, '%')}</strong>${_source(session.avgHumidity == null ? 'not recorded' : null)}</div>
    <div class="card"><div class="muted">Temperature</div><strong>${_metric(session.avgTemperature, 1, ' C')}</strong>${_source(session.avgTemperature == null ? 'not recorded' : null)}</div>
  </div>

  <h2>Accepted Frames by Filter</h2>
  <table>
    <thead>
      <tr><th>Filter</th><th>Frames</th><th>Integration</th></tr>
    </thead>
    <tbody>
      ${filterRows.isEmpty ? '<tr><td colspan="3">No accepted frames recorded.</td></tr>' : filterRows}
    </tbody>
  </table>

  <h2>Accepted Frame Sample</h2>
  <table>
    <thead>
      <tr><th>Filename</th><th>Type</th><th>Filter</th><th>Exposure</th><th>HFR</th><th>Guiding RMS</th></tr>
    </thead>
    <tbody>
      ${imageRows.isEmpty ? '<tr><td colspan="6">No accepted frames recorded.</td></tr>' : imageRows}
    </tbody>
  </table>

  ${session.notes != null && session.notes!.isNotEmpty ? '<h2>Notes</h2><div class="card notes">${session.notes}</div>' : ''}
</body>
</html>
''';

    final directory = await _getExportDirectory();
    final sessionName = session.name ?? 'session_$sessionId';
    final timestamp = _now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')[0];
    final fileName = '${sessionName}_$timestamp.html';
    final filePath = path.join(directory.path, fileName);
    final file = File(filePath);
    await file.writeAsString(html);
    return filePath;
  }
}
