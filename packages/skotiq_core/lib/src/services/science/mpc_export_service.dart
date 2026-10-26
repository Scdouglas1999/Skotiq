import 'dart:io';

import 'package:path/path.dart' as path;

import '../../database/database.dart' show MovingObjectCandidateRow;
import '../../utils/skotiq_data_directory.dart';

/// Service for generating Minor Planet Center (MPC) 80-column format reports
/// from Skotiq moving object candidate observations.
///
/// The MPC 80-column format is the standard submission format for asteroid and
/// comet astrometry. Each observation occupies exactly 80 columns with precise
/// positional data.
///
/// Reference: https://www.minorplanetcenter.net/iau/info/OpticalObs.html
/// The MPC/ADES photometric band a frame taken through [filter] reports, or
/// null when the filter stands for no broadband (narrowband, unknown), in
/// which case no magnitude is reported.
///
/// Unfiltered and luminance frames report `C` (clear), the MPC's band for
/// unfiltered CCD photometry. A green RGB filter is closest to Johnson V.
String? mpcBandForFilter(String? filter) {
  final f = (filter ?? '').trim().toLowerCase();
  switch (f) {
    case '':
    case 'l':
    case 'lum':
    case 'luminance':
    case 'clear':
    case 'c':
    case 'none':
    case 'uv/ir cut':
    case 'uvir':
      return 'C';
    case 'r':
    case 'red':
      return 'R';
    case 'v':
    case 'g':
    case 'green':
      return 'V';
    case 'b':
    case 'blue':
      return 'B';
    case 'i':
      return 'I';
    case "sloan g":
    case "g'":
    case 'sg':
      return 'g';
    case "sloan r":
    case "r'":
    case 'sr':
      return 'r';
    case "sloan i":
    case "i'":
    case 'si':
      return 'i';
  }
  return null;
}

/// Report formats the MPC accepts for optical astrometry.
enum MpcReportFormat {
  /// The legacy 80-column format (obs80).
  obs80,

  /// ADES 2017 in pipe-separated values, the MPC's current submission format.
  adesPsv,
}

/// Observer details an ADES report header carries. The MPC's validator
/// requires an observer, a measurer and the telescope; a report built with
/// any of them empty must be completed by hand before it is submitted.
class AdesReportHeader {
  const AdesReportHeader({
    required this.observatoryCode,
    this.submitter = '',
    this.observers = const [],
    this.measurers = const [],
    this.telescopeAperture,
    this.telescopeDesign = 'reflector',
    this.astCat = 'Gaia3',
  });

  final String observatoryCode;
  final String submitter;
  final List<String> observers;
  final List<String> measurers;

  /// Aperture in meters.
  final double? telescopeAperture;
  final String telescopeDesign;

  /// Astrometric reference catalog of the plate solves (ASTAP's star
  /// databases are built from Gaia DR3).
  final String astCat;
}

class MpcExportService {
  /// Generate an MPC 80-column format report from selected moving object
  /// observations.
  ///
  /// [candidates] - The moving object observations to include.
  /// [observatoryCode] - The 3-character MPC observatory code (e.g. "G40").
  /// [provisionalDesignations] - Optional map from candidateId to provisional
  ///   designation string. If not provided, candidates are grouped by candidateId
  ///   and auto-assigned designations.
  ///
  /// Returns the full MPC-formatted report as a string.
  ///
  /// Throws [ArgumentError] if observatoryCode is not exactly 3 characters.
  /// Throws [ArgumentError] if candidates is empty.
  String generateReport({
    required List<MovingObjectCandidateRow> candidates,
    required String observatoryCode,
    Map<String, String>? provisionalDesignations,
  }) {
    if (candidates.isEmpty) {
      throw ArgumentError('Cannot generate MPC report from empty candidates');
    }
    if (observatoryCode.length != 3) {
      throw ArgumentError(
        'MPC observatory code must be exactly 3 characters, '
        'got "$observatoryCode" (${observatoryCode.length} chars)',
      );
    }

    // Sort by timestamp for consistent output
    final sorted = List<MovingObjectCandidateRow>.from(candidates)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    // Build provisional designations if not provided
    final designations =
        provisionalDesignations ?? _assignProvisionalDesignations(sorted);

    final buffer = StringBuffer();
    for (final candidate in sorted) {
      final designation = designations[candidate.candidateId] ?? '';
      buffer.writeln(
        _formatObservationLine(
          candidate: candidate,
          provisionalDesignation: designation,
          observatoryCode: observatoryCode,
        ),
      );
    }

    return buffer.toString();
  }

  /// Group observations by candidateId for multi-night linking.
  ///
  /// Returns a map of candidateId to list of observations, sorted by timestamp.
  /// Only includes groups with observations spanning more than one distinct
  /// calendar night (UTC).
  Map<String, List<MovingObjectCandidateRow>> groupMultiNightObservations(
    List<MovingObjectCandidateRow> candidates,
  ) {
    final groups = <String, List<MovingObjectCandidateRow>>{};
    for (final candidate in candidates) {
      groups.putIfAbsent(candidate.candidateId, () => []).add(candidate);
    }

    // Sort each group by timestamp
    for (final group in groups.values) {
      group.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    }

    // Filter to only groups with observations spanning multiple nights
    final multiNight = <String, List<MovingObjectCandidateRow>>{};
    for (final entry in groups.entries) {
      final nights = entry.value.map((c) {
        final utc = c.timestamp.toUtc();
        return DateTime.utc(utc.year, utc.month, utc.day);
      }).toSet();
      if (nights.length > 1) {
        multiNight[entry.key] = entry.value;
      }
    }

    return multiNight;
  }

  /// Group all observations by candidateId (single or multi night).
  Map<String, List<MovingObjectCandidateRow>> groupAllObservations(
    List<MovingObjectCandidateRow> candidates,
  ) {
    final groups = <String, List<MovingObjectCandidateRow>>{};
    for (final candidate in candidates) {
      groups.putIfAbsent(candidate.candidateId, () => []).add(candidate);
    }

    for (final group in groups.values) {
      group.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    }

    return groups;
  }

  /// Build an ADES 2017 PSV report (one observation per row) for
  /// [candidates]. Rows of one tracklet share a `trkSub`. Magnitudes are
  /// written only with [photCat] (the photometric reference catalog),
  /// because ADES requires one with every magnitude.
  String generateAdesPsv({
    required List<MovingObjectCandidateRow> candidates,
    required AdesReportHeader header,
    Map<String, String>? provisionalDesignations,
    String? photCat,
  }) {
    if (candidates.isEmpty) {
      throw ArgumentError('Cannot generate ADES report from empty candidates');
    }
    if (header.observatoryCode.length != 3) {
      throw ArgumentError(
        'MPC observatory code must be exactly 3 characters, '
        'got "${header.observatoryCode}"',
      );
    }
    final sorted = List<MovingObjectCandidateRow>.from(candidates)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final designations =
        provisionalDesignations ?? _assignProvisionalDesignations(sorted);

    final out = StringBuffer()
      ..writeln('# version=2017')
      ..writeln('# observatory')
      ..writeln('! mpcCode ${header.observatoryCode}')
      ..writeln('# submitter')
      ..writeln('! name ${header.submitter}');
    out.writeln('# observers');
    for (final name in header.observers.isEmpty ? [''] : header.observers) {
      out.writeln('! name $name');
    }
    out.writeln('# measurers');
    for (final name in header.measurers.isEmpty ? [''] : header.measurers) {
      out.writeln('! name $name');
    }
    out
      ..writeln('# telescope')
      ..writeln('! design ${header.telescopeDesign}');
    final aperture = header.telescopeAperture;
    if (aperture != null && aperture > 0) {
      out.writeln('! aperture ${aperture.toStringAsFixed(3)}');
    }
    out.writeln('! detector CCD');

    final withMag = photCat != null && photCat.trim().isNotEmpty;
    final columns = [
      'trkSub',
      'mode',
      'stn',
      'obsTime',
      'ra',
      'dec',
      'astCat',
      if (withMag) ...['mag', 'band', 'photCat'],
    ];
    out.writeln(columns.join('|'));
    for (final c in sorted) {
      final trkSub = (designations[c.candidateId] ?? '').trim();
      final mag = c.magnitude;
      final band = c.magnitudeBand;
      final hasMag =
          withMag &&
          mag != null &&
          mag.isFinite &&
          mag > 0 &&
          mag < 35 &&
          band != null &&
          band.isNotEmpty;
      var ra = c.raDegrees % 360.0;
      if (ra < 0) ra += 360.0;
      final fields = [
        trkSub.length > 8 ? trkSub.substring(0, 8) : trkSub,
        'CCD',
        header.observatoryCode,
        _adesTime(c.timestamp),
        ra.toStringAsFixed(6),
        (c.decDegrees >= 0 ? '+' : '') + c.decDegrees.toStringAsFixed(6),
        header.astCat,
        if (withMag) ...[
          hasMag ? mag.toStringAsFixed(2) : '',
          hasMag ? band : '',
          hasMag ? photCat : '',
        ],
      ];
      out.writeln(fields.join('|'));
    }
    return out.toString();
  }

  static String _adesTime(DateTime t) {
    final u = t.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    final seconds = u.second + u.millisecond / 1000.0;
    return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-'
        '${two(u.day)}T${two(u.hour)}:${two(u.minute)}:'
        '${seconds.toStringAsFixed(2).padLeft(5, '0')}Z';
  }

  /// Export the MPC report to a file in the application documents directory.
  ///
  /// Returns the absolute path to the exported file.
  Future<String> exportToFile({
    required List<MovingObjectCandidateRow> candidates,
    required String observatoryCode,
    Map<String, String>? provisionalDesignations,
    MpcReportFormat format = MpcReportFormat.obs80,
  }) async {
    final report = switch (format) {
      MpcReportFormat.obs80 => generateReport(
        candidates: candidates,
        observatoryCode: observatoryCode,
        provisionalDesignations: provisionalDesignations,
      ),
      MpcReportFormat.adesPsv => generateAdesPsv(
        candidates: candidates,
        header: AdesReportHeader(observatoryCode: observatoryCode),
        provisionalDesignations: provisionalDesignations,
      ),
    };

    final docsDir = await resolveSkotiqDocumentsDirectory();
    final exportDir = Directory(path.join(docsDir.path, 'Skotiq', 'exports'));
    if (!exportDir.existsSync()) {
      exportDir.createSync(recursive: true);
    }

    final timestamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final fileName = format == MpcReportFormat.adesPsv
        ? 'ades_report_$timestamp.psv'
        : 'mpc_report_$timestamp.txt';
    final filePath = path.join(exportDir.path, fileName);

    await File(filePath).writeAsString(report);
    return filePath;
  }

  /// Format a single observation line in MPC 80-column format.
  ///
  /// MPC format columns (1-indexed):
  ///   1-5   : Minor planet number (packed, or blank for unnumbered)
  ///   6-12  : Provisional designation (or temporary designation)
  ///   13    : Discovery asterisk (blank or '*')
  ///   14    : Note 1 (program/publication note — blank for most submissions)
  ///   15    : Note 2 (observation type: C = CCD)
  ///   16-32 : Date of observation (YYYY MM DD.ddddd)
  ///   33-44 : RA (HH MM SS.ss)
  ///   45-56 : Dec (sDD MM SS.s)
  ///   57-65 : Blank (9 columns)
  ///   66-70 : Observed magnitude (with decimal)
  ///   71    : Band (V, R, C, etc.)
  ///   72-77 : Blank (6 columns)
  ///   78-80 : Observatory code (3 chars)
  String _formatObservationLine({
    required MovingObjectCandidateRow candidate,
    required String provisionalDesignation,
    required String observatoryCode,
  }) {
    // Columns 1-5: Minor planet number (blank for new discoveries)
    const numField = '     ';

    // Columns 6-12: Provisional designation (7 chars, left-padded)
    final desigField = provisionalDesignation.padRight(7).substring(0, 7);

    // Column 13: Discovery asterisk (blank for follow-up)
    const discoveryFlag = ' ';

    // Column 14: Note 1 — a program/publication note, NOT the observation
    // type. Blank for an ordinary submission.
    const note1 = ' ';

    // Column 15: Note 2 — observation type. 'C' = CCD. This is the column the
    // MPC reads to learn how the observation was made; putting it in column 14
    // meant every record arrived with no observation type at all.
    const note2 = 'C';

    // Columns 16-32: Date (YYYY MM DD.ddddd) — 17 characters
    final dateField = _formatMpcDate(candidate.timestamp);

    // Columns 33-44: RA (HH MM SS.ss) — 12 characters
    final raField = _formatRa(candidate.raDegrees);

    // Columns 45-56: Dec (sDD MM SS.s) — 12 characters
    final decField = _formatDec(candidate.decDegrees);

    // Columns 57-65: Blank (9 chars)
    const blank9 = '         ';

    // Columns 66-70: Magnitude — 5 chars (right-justified, e.g. " 18.5").
    // Populated since schema v47: the detection pipeline persists the
    // candidate's measured flux converted to an apparent magnitude via the
    // frame's photometric zero point. Rows from frames that produced no
    // calibration carry a null magnitude and the line stays
    // astrometry-only, which MPC guidelines explicitly allow.
    final magValue = candidate.magnitude;
    final hasMagnitude =
        magValue != null && magValue.isFinite && magValue > 0 && magValue < 35;
    final magField = hasMagnitude
        ? magValue.toStringAsFixed(1).padLeft(5)
        : '     ';

    // Column 71: Band — blank when no magnitude. Single character, from the
    // frame's filter (see mpcBandForFilter); rows stored before the band was
    // recorded read as V.
    final band = hasMagnitude
        ? (candidate.magnitudeBand ?? 'V').padRight(1).substring(0, 1)
        : ' ';

    // Columns 72-77: Blank (6 chars)
    const blank6 = '      ';

    // Columns 78-80: Observatory code
    final obsCode = observatoryCode.padRight(3).substring(0, 3);

    final line =
        '$numField$desigField$discoveryFlag$note1$note2'
        '$dateField$raField$decField$blank9$magField$band$blank6$obsCode';

    // Verify exact 80-column width
    if (line.length != 80) {
      throw StateError(
        'MPC line length is ${line.length}, expected 80. '
        'Line: "$line"',
      );
    }

    return line;
  }

  /// Format a DateTime as MPC date occupying exactly 17 columns.
  ///
  /// MPC columns 16-32 breakdown:
  ///   16-19: Year (4 chars)
  ///   20:    Space
  ///   21-22: Month (2 chars, zero-padded)
  ///   23:    Space
  ///   24-32: Day with decimal fraction (9 chars)
  ///
  /// Day field (9 chars): "DD.ddddd " — the fractional day to 5 decimal places,
  /// right-padded to fill the 9-column allocation.
  String _formatMpcDate(DateTime timestamp) {
    final utc = timestamp.toUtc();

    // Fractional day: hours/24 + minutes/(24*60) + seconds/(24*60*60) + ms/(24*60*60*1000)
    final fractionalDay =
        utc.hour / 24.0 +
        utc.minute / 1440.0 +
        utc.second / 86400.0 +
        utc.millisecond / 86400000.0;

    final year = utc.year.toString().padLeft(4, '0');
    final month = utc.month.toString().padLeft(2, '0');

    // DD.ddddd — day with 5 decimal places, padded to 9 chars for cols 24-32
    final dayWithFraction = utc.day + fractionalDay;
    final dayStr = dayWithFraction.toStringAsFixed(5).padLeft(8, '0');
    // Pad to 9 chars (MPC cols 24-32)
    final dayField = dayStr.padRight(9);

    // "YYYY MM DD.ddddd " — exactly 17 chars
    final result = '$year $month $dayField';
    assert(
      result.length == 17,
      'MPC date must be 17 chars, got ${result.length}',
    );
    return result;
  }

  /// Format RA in degrees to MPC RA field: exactly 12 characters.
  ///
  /// MPC columns 33-44 breakdown:
  ///   33-34: Hours (2 chars, zero-padded)
  ///   35:    Space
  ///   36-37: Minutes (2 chars, zero-padded)
  ///   38:    Space
  ///   39-44: Seconds with decimal (6 chars: SS.sss or SS.ss + space)
  ///
  /// RA precision: to 0.01s (2 decimal places) per MPC spec.
  String _formatRa(double raDegrees) {
    // Normalize to 0-360
    var ra = raDegrees % 360.0;
    if (ra < 0) ra += 360.0;

    // Convert degrees to hours
    final totalHours = ra / 15.0;
    final hours = totalHours.floor();
    final remainderMinutes = (totalHours - hours) * 60.0;
    final minutes = remainderMinutes.floor();
    final seconds = (remainderMinutes - minutes) * 60.0;

    // Clamp seconds to avoid 60.00 from rounding
    final clampedSeconds = seconds >= 59.995 ? 59.99 : seconds;

    final hoursStr = hours.toString().padLeft(2, '0');
    final minutesStr = minutes.toString().padLeft(2, '0');
    // SS.ss = 5 chars, padded to 6 for cols 39-44
    final secondsStr = clampedSeconds.toStringAsFixed(2).padLeft(5, '0');
    final secField = secondsStr.padRight(6);

    final result = '$hoursStr $minutesStr $secField';
    assert(
      result.length == 12,
      'MPC RA must be 12 chars, got ${result.length}',
    );
    return result;
  }

  /// Format Dec in degrees to MPC Dec field: exactly 12 characters.
  ///
  /// MPC columns 45-56 breakdown:
  ///   45:    Sign (+ or -)
  ///   46-47: Degrees (2 chars, zero-padded)
  ///   48:    Space
  ///   49-50: Arcminutes (2 chars, zero-padded)
  ///   51:    Space
  ///   52-56: Arcseconds with decimal (5 chars: SS.s + trailing space or SS.ss)
  ///
  /// Dec precision: to 0.1" (1 decimal place) per MPC spec.
  String _formatDec(double decDegrees) {
    final sign = decDegrees < 0 ? '-' : '+';
    final absDec = decDegrees.abs();

    final degrees = absDec.floor();
    final remainderMinutes = (absDec - degrees) * 60.0;
    final minutes = remainderMinutes.floor();
    final seconds = (remainderMinutes - minutes) * 60.0;

    // Clamp seconds to avoid 60.0 from rounding
    final clampedSeconds = seconds >= 59.95 ? 59.9 : seconds;

    final degStr = degrees.toString().padLeft(2, '0');
    final minStr = minutes.toString().padLeft(2, '0');
    // SS.s = 4 chars, padded to 5 for cols 52-56
    final secStr = clampedSeconds.toStringAsFixed(1).padLeft(4, '0');
    final secField = secStr.padRight(5);

    // "sDD MM SS.s " — exactly 12 chars
    final result = '$sign$degStr $minStr $secField';
    assert(
      result.length == 12,
      'MPC Dec must be 12 chars, got ${result.length}',
    );
    return result;
  }

  /// Assign provisional designations to candidates.
  ///
  /// Groups candidates by candidateId and assigns sequential provisional
  /// designations in the format used by MPC for temporary designations.
  ///
  /// For known objects with names, uses the known object name where it fits.
  /// For unknown objects, assigns sequential IDs like "NS0001", "NS0002", etc.
  Map<String, String> _assignProvisionalDesignations(
    List<MovingObjectCandidateRow> candidates,
  ) {
    final designations = <String, String>{};
    final uniqueIds = candidates.map((c) => c.candidateId).toSet().toList();
    var counter = 1;

    for (final candidateId in uniqueIds) {
      // Find the first observation for this candidate to check if it's known
      final firstObs = candidates.firstWhere(
        (c) => c.candidateId == candidateId,
      );

      if (firstObs.isKnownObject && firstObs.objectName != null) {
        // For known objects, use the name truncated to 7 chars
        designations[candidateId] = firstObs.objectName!
            .padRight(7)
            .substring(0, 7);
      } else {
        // For unknown objects, use Skotiq temporary designation
        final seqStr = counter.toString().padLeft(4, '0');
        designations[candidateId] = 'NS$seqStr ';
        counter++;
      }
    }

    return designations;
  }
}

/// Represents a group of observations for the same moving object candidate,
/// possibly spanning multiple nights.
class MpcObservationGroup {
  /// The candidate ID linking observations together
  final String candidateId;

  /// Human-readable name (from known object match, or provisional designation)
  final String displayName;

  /// Whether this object was matched to a known solar system body
  final bool isKnownObject;

  /// The provisional designation assigned for MPC reporting
  final String provisionalDesignation;

  /// All observations in this group, sorted by timestamp
  final List<MovingObjectCandidateRow> observations;

  /// Number of distinct observing nights, keyed noon-to-noon UT so a single
  /// night that straddles 00:00 UTC counts once rather than as two nights.
  int get nightCount {
    return observations
        .map((c) {
          final n = c.timestamp.toUtc().subtract(const Duration(hours: 12));
          return DateTime.utc(n.year, n.month, n.day);
        })
        .toSet()
        .length;
  }

  /// Time span from first to last observation
  Duration get timeSpan {
    if (observations.length < 2) return Duration.zero;
    return observations.last.timestamp.difference(observations.first.timestamp);
  }

  /// Average confidence across all observations
  double get averageConfidence {
    if (observations.isEmpty) return 0.0;
    return observations.map((c) => c.confidence).reduce((a, b) => a + b) /
        observations.length;
  }

  const MpcObservationGroup({
    required this.candidateId,
    required this.displayName,
    required this.isKnownObject,
    required this.provisionalDesignation,
    required this.observations,
  });
}

/// Build [MpcObservationGroup]s from a flat list of candidates.
///
/// Groups by candidateId, assigns provisional designations, and returns
/// groups sorted by first observation timestamp.
List<MpcObservationGroup> buildObservationGroups(
  List<MovingObjectCandidateRow> candidates,
) {
  if (candidates.isEmpty) return const [];

  final grouped = <String, List<MovingObjectCandidateRow>>{};
  for (final c in candidates) {
    grouped.putIfAbsent(c.candidateId, () => []).add(c);
  }

  // Sort each group internally by timestamp
  for (final group in grouped.values) {
    group.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  final groups = <MpcObservationGroup>[];
  var counter = 1;

  // Sort groups by first observation timestamp
  final sortedEntries = grouped.entries.toList()
    ..sort(
      (a, b) => a.value.first.timestamp.compareTo(b.value.first.timestamp),
    );

  for (final entry in sortedEntries) {
    final firstObs = entry.value.first;
    final isKnown = firstObs.isKnownObject;
    final name = firstObs.objectName;

    String displayName;
    String provisionalDesignation;

    if (isKnown && name != null && name.isNotEmpty) {
      displayName = name;
      provisionalDesignation = name.padRight(7).substring(0, 7);
    } else {
      final seqStr = counter.toString().padLeft(4, '0');
      provisionalDesignation = 'NS$seqStr ';
      displayName = 'Candidate $counter';
      counter++;
    }

    groups.add(
      MpcObservationGroup(
        candidateId: entry.key,
        displayName: displayName,
        isKnownObject: isKnown,
        provisionalDesignation: provisionalDesignation,
        observations: entry.value,
      ),
    );
  }

  return groups;
}
