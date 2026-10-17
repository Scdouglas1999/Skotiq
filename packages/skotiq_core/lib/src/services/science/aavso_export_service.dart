import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as path;

import '../../database/daos/images_dao.dart';
import '../../database/daos/science_dao.dart';
import '../../database/daos/settings_dao.dart';
import '../../database/database.dart';
import 'airmass.dart';
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
  /// [filterBand] — the photometric filter band (e.g., "V", "B", "R", "I",
  ///   "CV", "CR", "TG"). If null, defaults to "CV" (clear with V zeropoint).
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

    final calibrations = await _scienceDao.getCalibrationsForSession(sessionId);

    // Build a lookup from capturedImageId -> calibration for zero-point access
    final calibrationByImage = <int, FramePhotometricCalibrationRow>{};
    for (final cal in calibrations) {
      if (cal.capturedImageId != null && cal.isCalibrated) {
        calibrationByImage[cal.capturedImageId!] = cal;
      }
    }

    // Partition measurements by role
    final targetMeasurements = <PhotometryMeasurementRow>[];
    final compStars = <String, PhotometryMeasurementRow>{};
    final checkStars = <String, PhotometryMeasurementRow>{};

    for (final m in measurements) {
      switch (m.role) {
        case 'target':
          targetMeasurements.add(m);
          break;
        case 'comparison':
          compStars.putIfAbsent(m.objectId, () => m);
          break;
        case 'check':
          checkStars.putIfAbsent(m.objectId, () => m);
          break;
      }
    }

    if (targetMeasurements.isEmpty) {
      throw AavsoExportError(
        'No target star measurements found in session $sessionId. '
        'Ensure a target star is designated in the photometry setup.',
      );
    }

    final effectiveFilter = filterBand ?? 'CV';

    // Determine comparison/check star labels from the first occurrence
    final compLabel = compStars.isNotEmpty ? compStars.keys.first : 'na';
    final checkLabel = checkStars.isNotEmpty ? checkStars.keys.first : 'na';

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
      final jd = _dateTimeToJd(m.timestamp);

      // Magnitude: use differential magnitude if available, otherwise skip
      if (m.differentialMagnitude == null) {
        continue;
      }
      final mag = m.differentialMagnitude!.toStringAsFixed(4);

      // Magnitude error from uncertainty field
      final merr = m.uncertainty != null && m.uncertainty! > 0
          ? m.uncertainty!.toStringAsFixed(4)
          : 'na';

      // Transformation status: NO = untransformed (we report raw differential)
      const trans = 'NO';

      // Measurement type: STD = standardized, DIFF = differential
      // Our photometry is differential by default
      const mtype = 'DIFF';

      // Comparison star magnitude — find a comp measurement for the same
      // capturedImageId to get a frame-matched value. Per the Extended
      // Format spec, for MTYPE=DIFF the CMAG/KMAG columns carry the
      // *instrumental* magnitude of the comp/check star. The pipeline
      // stores comparison rows with a null differentialMagnitude (only the
      // target gets one), so derive the instrumental magnitude from the
      // stored flux instead of reading a field that is always null.
      String cmag = 'na';
      if (compStars.isNotEmpty) {
        final compForFrame = measurements
            .where(
              (row) =>
                  row.role == 'comparison' &&
                  row.capturedImageId == m.capturedImageId,
            )
            .toList();
        if (compForFrame.isNotEmpty) {
          final instMag = _instrumentalMagnitude(compForFrame.first);
          if (instMag != null) {
            cmag = instMag.toStringAsFixed(4);
          }
        }
      }

      // Check star magnitude — same logic
      String kmag = 'na';
      if (checkStars.isNotEmpty) {
        final checkForFrame = measurements
            .where(
              (row) =>
                  row.role == 'check' &&
                  row.capturedImageId == m.capturedImageId,
            )
            .toList();
        if (checkForFrame.isNotEmpty) {
          final instMag = _instrumentalMagnitude(checkForFrame.first);
          if (instMag != null) {
            kmag = instMag.toStringAsFixed(4);
          }
        }
      }

      // Derive AMASS only from the frame's recorded altitude with the canonical
      // model. Missing or sub-horizon altitude is represented as AAVSO `na`.
      String amass = 'na';
      if (m.capturedImageId != null) {
        final capturedImage = await _imagesDao.getImageById(m.capturedImageId!);
        final altitudeDeg = capturedImage?.mountAltitude;
        final airmass = altitudeDeg == null
            ? null
            : airmassForTrueAltitude(altitudeDeg);
        if (airmass != null) {
          amass = airmass.toStringAsFixed(3);
        }
      }

      // Group: all measurements from the same frame get the same group number.
      // Use the capturedImageId as the group identifier.
      final group = m.capturedImageId?.toString() ?? 'na';

      // Chart reference
      final chartRef = chartId ?? 'na';

      // Notes: include SNR if available
      final notes = m.snr != null ? 'SNR=${m.snr!.toStringAsFixed(1)}' : 'na';

      buffer.writeln(
        '${_sanitize(targetStarName)},'
        '${jd.toStringAsFixed(5)},'
        '$mag,'
        '$merr,'
        '$effectiveFilter,'
        '$trans,'
        '$mtype,'
        '${_sanitize(compLabel)},'
        '$cmag,'
        '${_sanitize(checkLabel)},'
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
        'No exportable measurements found. All target measurements lack '
        'differential magnitude values.',
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

  /// Instrumental magnitude of a comp/check measurement, preferring an
  /// explicit differential magnitude when a future pipeline version stores
  /// one, otherwise -2.5·log10(flux). Returns null when the flux is
  /// unusable so the column falls back to 'na' rather than a bogus value.
  static double? _instrumentalMagnitude(PhotometryMeasurementRow row) {
    final differential = row.differentialMagnitude;
    if (differential != null && differential.isFinite) {
      return differential;
    }
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
