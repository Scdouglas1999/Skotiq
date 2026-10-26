import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as path;

import '../../database/daos/images_dao.dart';
import '../../database/daos/science_dao.dart';
import '../../database/daos/settings_dao.dart';
import '../../database/database.dart';
import 'airmass.dart';
import 'photometric_bands.dart';
import '../../utils/skotiq_data_directory.dart';

// Surfaced through the science-services barrel, which already exports this
// library, so every consumer reaches the one airmass model by importing
// skotiq_core rather than re-deriving the formula locally.
export 'airmass.dart';

/// Generates AAVSO Extended Format (Version 1.11) text files from photometry
/// measurements stored in the Skotiq database.
///
/// Reference: https://www.aavso.org/aavso-extended-file-format
///
/// The Extended Format consists of a header block followed by data lines.
/// Each data line represents one photometric measurement of a variable star.
class AavsoExportService {
  final ScienceDao _scienceDao;
  final SettingsDao _settingsDao;
  final ImagesDao _imagesDao;
  final Future<Directory> Function() _documentsDirectoryProvider;

  /// Written to the #SOFTWARE header line. Callers should pass
  /// `ref.read(appVersionLabelProvider)` so the reported version tracks
  /// version.yaml instead of a hard-coded constant.
  final String _softwareLabel;

  AavsoExportService({
    required ScienceDao scienceDao,
    required SettingsDao settingsDao,
    required ImagesDao imagesDao,
    String softwareLabel = 'Skotiq',
    Future<Directory> Function()? documentsDirectoryProvider,
  }) : _scienceDao = scienceDao,
       _settingsDao = settingsDao,
       _imagesDao = imagesDao,
       _softwareLabel = softwareLabel,
       _documentsDirectoryProvider =
           documentsDirectoryProvider ?? resolveSkotiqDocumentsDirectory;

  /// Export photometry data for a session to AAVSO Extended Format.
  ///
  /// [sessionId] — the imaging session containing photometry measurements.
  /// [targetStarName] — the AAVSO star designation (e.g., "SS CYG").
  /// [filterBand] — AAVSO filter code for frames whose filter was never
  ///   recorded. Frames with a recorded filter use that filter's code (TB,
  ///   TG, TR, V, CV); frames in a filter AAVSO has no code for are left out.
  /// [chartId] — optional AAVSO chart ID used for comparison stars.
  ///
  /// Returns the path to the saved file.
  ///
  /// Throws if no photometry data is found or if the observer code is not set.
  Future<String> exportSession({
    required int sessionId,
    required String targetStarName,
    String? filterBand,
    String? chartId,
  }) async {
    final observerCode = await _settingsDao.getSetting(
      'science.aavso.observer_code',
    );
    if (observerCode == null || observerCode.trim().isEmpty) {
      throw const AavsoExportError(
        'AAVSO observer code is not set. '
        'Please set your observer code in Settings > Science before exporting.',
      );
    }
    if (observerCode.trim().length > 5) {
      throw AavsoExportError(
        'AAVSO observer code "${observerCode.trim()}" exceeds 5 characters. '
        'Please correct it in Settings > Science.',
      );
    }

    final measurements = await _scienceDao.getPhotometryForSession(sessionId);
    if (measurements.isEmpty) {
      throw AavsoExportError(
        'No photometry measurements found for session $sessionId.',
      );
    }

    final byFrame = <int, List<PhotometryMeasurementRow>>{};
    final targetMeasurements = <PhotometryMeasurementRow>[];
    for (final m in measurements) {
      if (m.role == 'target') targetMeasurements.add(m);
      if (m.capturedImageId != null) {
        byFrame.putIfAbsent(m.capturedImageId!, () => []).add(m);
      }
    }

    if (targetMeasurements.isEmpty) {
      throw AavsoExportError(
        'No target star measurements found in session $sessionId. '
        'Ensure a target star is designated in the photometry setup.',
      );
    }

    // MTYPE=DIF reports the target against ONE named comparison star, with
    // its instrumental magnitude in CMAG. The comparison measured in the most
    // frames is used for the whole file.
    final compFrames = <String, int>{};
    for (final m in measurements.where((m) => m.role == 'comparison')) {
      compFrames[m.objectId] = (compFrames[m.objectId] ?? 0) + 1;
    }
    if (compFrames.isEmpty) {
      throw AavsoExportError(
        'No comparison star measurements found in session $sessionId. '
        'A differential (DIF) report needs a comparison star.',
      );
    }
    final compName = compFrames.entries
        .reduce((a, b) => b.value > a.value ? b : a)
        .key;

    final buffer = StringBuffer();

    // Header
    buffer.writeln('#TYPE=Extended');
    buffer.writeln('#OBSCODE=$observerCode');
    buffer.writeln('#SOFTWARE=$_softwareLabel');
    buffer.writeln('#DELIM=,');
    buffer.writeln('#DATE=JD');
    buffer.writeln('#OBSTYPE=CCD');

    // Data lines
    // Extended format columns:
    // NAME,DATE,MAG,MERR,FILT,TRANS,MTYPE,CNAME,CMAG,KNAME,KMAG,AMASS,GROUP,CHART,NOTES
    for (final m in targetMeasurements) {
      final frameId = m.capturedImageId;
      if (frameId == null) continue;
      final frameRows = byFrame[frameId] ?? const [];
      PhotometryMeasurementRow? rowFor(
        bool Function(PhotometryMeasurementRow) test,
      ) {
        for (final row in frameRows) {
          if (test(row)) return row;
        }
        return null;
      }

      final comp = rowFor(
        (r) => r.role == 'comparison' && r.objectId == compName,
      );
      final targetMag = _instrumentalMagnitude(m);
      final compMag = comp == null ? null : _instrumentalMagnitude(comp);
      if (targetMag == null || compMag == null) continue;

      final capturedImage = await _imagesDao.getImageById(frameId);

      // FILT: the frame's own filter, as an AAVSO filter code.
      final filterName = m.filter ?? capturedImage?.filter;
      final String? filt = filterName != null && filterName.trim().isNotEmpty
          ? filterBandFor(filterName).aavsoFilterCode
          : filterBand;
      if (filt == null) continue;

      // DATE: mid-exposure. The row's timestamp is when the frame was
      // recorded, at the end of the exposure.
      final exposure = capturedImage?.exposureDuration;
      final mid = exposure != null && exposure.isFinite && exposure > 0
          ? m.timestamp.subtract(
              Duration(microseconds: (exposure * 1e6 / 2).round()),
            )
          : m.timestamp;
      final jd = _dateTimeToJd(mid);

      final mag = (targetMag - compMag).toStringAsFixed(4);
      // Target error (which already includes the ensemble's) combined with the
      // comparison's own: an upper bound on the error of target − comparison.
      final tErr = m.uncertainty;
      final cErr = comp!.uncertainty;
      final merr = tErr != null && tErr > 0 && cErr != null && cErr >= 0
          ? math.sqrt(tErr * tErr + cErr * cErr).toStringAsFixed(4)
          : 'na';

      const trans = 'NO';
      const mtype = 'DIF';
      final cmag = compMag.toStringAsFixed(4);

      final check = rowFor((r) => r.role == 'check');
      final checkMag = check == null ? null : _instrumentalMagnitude(check);
      final kname = check == null || checkMag == null ? 'na' : check.objectId;
      final kmag = checkMag == null ? 'na' : checkMag.toStringAsFixed(4);

      // Derive AMASS only from the frame's recorded altitude with the canonical
      // model. Missing or sub-horizon altitude is represented as AAVSO `na`.
      String amass = 'na';
      final altitudeDeg = capturedImage?.mountAltitude;
      final airmass = altitudeDeg == null
          ? null
          : airmassForTrueAltitude(altitudeDeg);
      if (airmass != null) {
        amass = airmass.toStringAsFixed(3);
      }

      // GROUP is at most 5 characters; the frame id ties a line to its frame.
      final groupId = '$frameId';
      final group = groupId.length <= 5 ? groupId : 'na';

      final chartRef = chartId ?? 'na';
      final notes = m.snr != null ? 'SNR=${m.snr!.toStringAsFixed(1)}' : 'na';

      buffer.writeln(
        '${_sanitize(targetStarName)},'
        '${jd.toStringAsFixed(5)},'
        '$mag,'
        '$merr,'
        '$filt,'
        '$trans,'
        '$mtype,'
        '${_sanitize(compName)},'
        '$cmag,'
        '${_sanitize(kname)},'
        '$kmag,'
        '$amass,'
        '$group,'
        '$chartRef,'
        '$notes',
      );
    }

    final content = buffer.toString();

    // Validate we produced at least one data line (header is 6 lines)
    final lineCount = content
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .length;
    if (lineCount <= 6) {
      throw const AavsoExportError(
        'No exportable measurements found: no frame has both the target '
        'and the comparison star measured in a filter AAVSO has a code for.',
      );
    }

    // Write to file
    final directory = await _getExportDirectory();
    final sanitizedName = targetStarName
        .replaceAll(RegExp(r'[^\w\s-]'), '')
        .replaceAll(' ', '_');
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')[0];
    final fileName = 'AAVSO_${sanitizedName}_$timestamp.txt';
    final filePath = path.join(directory.path, fileName);

    final file = File(filePath);
    await file.writeAsString(content);

    return filePath;
  }

  /// Convert a DateTime to Julian Date.
  ///
  /// Uses the standard algorithm for the proleptic Gregorian calendar.
  /// Accurate for dates after March 1, 4801 BCE.
  static double _dateTimeToJd(DateTime dt) {
    final utc = dt.toUtc();
    final y = utc.year;
    final m = utc.month;
    final d = utc.day;
    final h = utc.hour;
    final min = utc.minute;
    final s = utc.second;
    final ms = utc.millisecond;

    // Julian Day Number (integer part) using the standard formula
    final a = (14 - m) ~/ 12;
    final adjustedY = y + 4800 - a;
    final adjustedM = m + 12 * a - 3;

    final jdn =
        d +
        (153 * adjustedM + 2) ~/ 5 +
        365 * adjustedY +
        adjustedY ~/ 4 -
        adjustedY ~/ 100 +
        adjustedY ~/ 400 -
        32045;

    // Fractional day
    final dayFraction =
        (h - 12) / 24.0 + min / 1440.0 + s / 86400.0 + ms / 86400000.0;

    return jdn.toDouble() + dayFraction;
  }

  /// Instrumental magnitude, −2.5·log10(flux), or null when the flux is
  /// unusable so the line is left out rather than given a bogus value.
  static double? _instrumentalMagnitude(PhotometryMeasurementRow row) {
    if (row.flux.isFinite && row.flux > 0) {
      return -2.5 * math.log(row.flux) / math.ln10;
    }
    return null;
  }

  /// Sanitize a string for use in AAVSO CSV fields.
  /// Removes commas and trims whitespace.
  static String _sanitize(String value) {
    return value.replaceAll(',', ' ').trim();
  }

  Future<Directory> _getExportDirectory() async {
    final docs = await _documentsDirectoryProvider();
    final exportDir = Directory(path.join(docs.path, 'Skotiq', 'exports'));
    if (!await exportDir.exists()) {
      await exportDir.create(recursive: true);
    }
    return exportDir;
  }
}

/// Error thrown when AAVSO export fails due to missing data or configuration.
class AavsoExportError implements Exception {
  final String message;
  const AavsoExportError(this.message);

  @override
  String toString() => 'AavsoExportError: $message';
}
