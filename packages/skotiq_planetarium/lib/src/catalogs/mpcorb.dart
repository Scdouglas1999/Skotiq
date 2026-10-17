import 'dart:developer' as developer;

import 'minor_planet_catalog.dart';

/// Parsers for the Minor Planet Center's published element files:
///
/// * **MPCORB 1-line format** (MPCORB.DAT, the yearly `Soft00Bright.txt`
///   bright subset, Distant.txt, CritList.txt, ...) for minor planets —
///   format reference: https://www.minorplanetcenter.org/iau/info/MPOrbitFormat.html
/// * **CometEls.txt** (MPC cometary orbit format) for comets.
///
/// Both parse into the existing [MinorBodyElements] representation consumed
/// by [KeplerianPropagator]. The propagator only handles elliptical orbits,
/// so near-parabolic and hyperbolic comets (e >= [maxCometEccentricity]) are
/// skipped — this drops one-apparition C/ objects on escape trajectories,
/// which a Keplerian two-body solver could not place accurately anyway.
class MpcOrbParser {
  MpcOrbParser._();

  /// Comets at or above this eccentricity are skipped (near-parabolic /
  /// hyperbolic; outside what the elliptical Keplerian propagator supports).
  static const double maxCometEccentricity = 0.998;

  // Minor planets (MPCORB 1-line format)

  /// Parse an MPCORB-format text blob into elements.
  ///
  /// Header text (MPCORB.DAT carries ~40 lines of prose ending in a dashed
  /// rule) is skipped automatically: any line that fails the fixed-column
  /// numeric parse is ignored. [maxAbsoluteMag] keeps only bodies with
  /// H <= the limit (e.g. 12.0), bounding the in-memory set when pointed at
  /// the full MPCORB.DAT.
  static List<MinorBodyElements> parseAsteroids(
    String text, {
    double? maxAbsoluteMag,
  }) {
    final results = <MinorBodyElements>[];
    var failed = 0;
    for (final line in text.split('\n')) {
      if (line.trim().isEmpty) continue;
      final parsed = parseAsteroidLine(line);
      if (parsed == null) {
        failed++;
        continue;
      }
      if (maxAbsoluteMag != null && parsed.absoluteMag > maxAbsoluteMag) {
        continue;
      }
      results.add(parsed);
    }
    if (results.isEmpty && failed > 0) {
      developer.log(
        '[MPCORB] no parsable asteroid lines ($failed skipped)',
        name: 'MpcOrbParser',
        level: 900,
      );
    }
    return results;
  }

  /// Parse one MPCORB 1-line record. Returns null for non-record lines
  /// (header prose, blank, malformed).
  ///
  /// Fixed columns (1-indexed per the MPC spec; 0-indexed substrings here):
  /// ```
  ///   1-  7 designation (packed)     21- 25 epoch (packed)
  ///   9- 13 H                        27- 35 mean anomaly (deg)
  ///  15- 19 G                        38- 46 argument of perihelion (deg)
  ///  49- 57 node (deg)               60- 68 inclination (deg)
  ///  71- 79 eccentricity             93-103 semi-major axis (AU)
  /// 167-194 readable designation, e.g. "(1) Ceres"
  /// ```
  static MinorBodyElements? parseAsteroidLine(String line) {
    if (line.length < 103) return null;
    try {
      final designation = line.substring(0, 7).trim();
      final h = double.tryParse(line.substring(8, 13).trim());
      final g = double.tryParse(line.substring(14, 19).trim()) ?? 0.15;
      final epoch = _unpackEpoch(line.substring(20, 25).trim());
      final meanAnomaly = double.parse(line.substring(26, 35).trim());
      final argPeri = double.parse(line.substring(37, 46).trim());
      final node = double.parse(line.substring(48, 57).trim());
      final incl = double.parse(line.substring(59, 68).trim());
      final ecc = double.parse(line.substring(70, 79).trim());
      final a = double.parse(line.substring(92, 103).trim());
      if (epoch == null || ecc < 0 || ecc >= 1.0 || a <= 0) return null;

      // Readable designation, e.g. "(1) Ceres" or "2024 AB123".
      String name = designation;
      String? commonName;
      if (line.length > 166) {
        final readable = line
            .substring(166, line.length < 194 ? line.length : 194)
            .trim();
        if (readable.isNotEmpty) {
          final match = RegExp(r'^\((\d+)\)\s*(.*)$').firstMatch(readable);
          if (match != null) {
            final number = match.group(1)!;
            final properName = match.group(2)!.trim();
            name = properName.isEmpty ? number : '$number $properName';
            if (properName.isNotEmpty) commonName = properName;
          } else {
            name = readable;
          }
        }
      }

      return MinorBodyElements(
        name: name,
        commonName: commonName,
        type: MinorBodyType.asteroid,
        epoch: epoch,
        semiMajorAxis: a,
        eccentricity: ecc,
        inclination: incl,
        longitudeOfNode: node,
        argumentOfPerihelion: argPeri,
        meanAnomaly: meanAnomaly,
        absoluteMag: h ?? 18.0,
        slopeParam: g,
      );
    } catch (_) {
      return null;
    }
  }

  // Comets (MPC CometEls.txt format)

  /// Parse the MPC `CometEls.txt` file into elements.
  ///
  /// Near-parabolic/hyperbolic comets (e >= [maxCometEccentricity]) are
  /// skipped; see the class comment.
  static List<MinorBodyElements> parseComets(String text) {
    final results = <MinorBodyElements>[];
    for (final line in text.split('\n')) {
      if (line.trim().isEmpty) continue;
      final parsed = parseCometLine(line);
      if (parsed != null) results.add(parsed);
    }
    return results;
  }

  /// Parse one CometEls.txt record. Returns null for malformed lines and
  /// for orbits the propagator cannot represent (e >= ~1).
  ///
  /// Fixed columns (1-indexed):
  /// ```
  ///   1-  4 periodic number          31- 39 q, perihelion distance (AU)
  ///      5  orbit type C/P/D/I/A     41- 49 eccentricity
  ///   6- 12 provisional desig.       52- 59 argument of perihelion (deg)
  ///  15- 18 perihelion year          62- 69 node (deg)
  ///  20- 21 perihelion month         72- 79 inclination (deg)
  ///  23- 29 perihelion day (TT)      92- 95 H (total magnitude)
  /// 103-158 designation and name     97-100 G (slope)
  /// ```
  static MinorBodyElements? parseCometLine(String line) {
    if (line.length < 80) return null;
    try {
      final year = int.parse(line.substring(14, 18).trim());
      final month = int.parse(line.substring(19, 21).trim());
      final day = double.parse(line.substring(22, 29).trim());
      final q = double.parse(line.substring(30, 39).trim());
      final ecc = double.parse(line.substring(40, 49).trim());
      final argPeri = double.parse(line.substring(51, 59).trim());
      final node = double.parse(line.substring(61, 69).trim());
      final incl = double.parse(line.substring(71, 79).trim());

      if (q <= 0 || ecc < 0 || ecc >= maxCometEccentricity) return null;

      double h = 10.0;
      double g = 4.0;
      if (line.length >= 95) {
        h = double.tryParse(line.substring(91, 95).trim()) ?? 10.0;
      }
      if (line.length >= 100) {
        g = double.tryParse(line.substring(96, 100).trim()) ?? 4.0;
      }

      String name = '';
      if (line.length > 102) {
        final end = line.length < 158 ? line.length : 158;
        name = line.substring(102, end).trim();
      }
      if (name.isEmpty) {
        name =
            '${line.substring(0, 4).trim()}'
            '${line.substring(4, 5).trim()}/'
            '${line.substring(5, 12).trim()}';
      }

      // Common name from "C/1995 O1 (Hale-Bopp)" / "1P/Halley" forms.
      String? commonName;
      final paren = RegExp(r'\(([^)]+)\)\s*$').firstMatch(name);
      if (paren != null) {
        commonName = paren.group(1);
      } else {
        final slash = name.indexOf('/');
        if (slash > 0 && slash < name.length - 1) {
          final tail = name.substring(slash + 1).trim();
          if (tail.isNotEmpty && !RegExp(r'^\d').hasMatch(tail)) {
            commonName = tail;
          }
        }
      }

      // The propagator wants (a, M at epoch). Perihelion passage T is exact:
      // use epoch = JD(T), M = 0 — the same convention the embedded comet
      // elements use.
      final a = q / (1 - ecc);
      final epochJd = _julianDateFromYmd(year, month, day);

      return MinorBodyElements(
        name: name,
        commonName: commonName,
        type: MinorBodyType.comet,
        epoch: epochJd,
        semiMajorAxis: a,
        eccentricity: ecc,
        inclination: incl,
        longitudeOfNode: node,
        argumentOfPerihelion: argPeri,
        meanAnomaly: 0.0,
        absoluteMag: h,
        slopeParam: g,
      );
    } catch (_) {
      return null;
    }
  }

  // Packed-date helpers

  /// Unpack an MPC packed epoch like `K2669` (2026-06-09.0 TT) to a Julian
  /// Date. Century letter: I=18, J=19, K=20. Month/day digits: 1-9, then
  /// A=10 ... V=31.
  static double? _unpackEpoch(String packed) {
    if (packed.length != 5) return null;
    final century = switch (packed[0]) {
      'I' => 18,
      'J' => 19,
      'K' => 20,
      'L' => 21,
      _ => -1,
    };
    if (century < 0) return null;
    final yy = int.tryParse(packed.substring(1, 3));
    final month = _unpackDigit(packed[3]);
    final day = _unpackDigit(packed[4]);
    if (yy == null || month == null || day == null) return null;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return _julianDateFromYmd(century * 100 + yy, month, day.toDouble());
  }

  static int? _unpackDigit(String c) {
    final code = c.codeUnitAt(0);
    if (code >= 0x31 && code <= 0x39) return code - 0x30; // '1'-'9'
    if (code >= 0x41 && code <= 0x56) return code - 0x41 + 10; // 'A'-'V'
    return null;
  }

  /// Julian Date at 0h UT of (year, month, fractional day). TT-vs-UTC
  /// (~69 s) is negligible at the propagator's accuracy.
  static double _julianDateFromYmd(int year, int month, double day) {
    var y = year;
    var m = month;
    if (m <= 2) {
      y -= 1;
      m += 12;
    }
    final a = y ~/ 100;
    final b = 2 - a + a ~/ 4;
    return (365.25 * (y + 4716)).floor() +
        (30.6001 * (m + 1)).floor() +
        day +
        b -
        1524.5;
  }
}
