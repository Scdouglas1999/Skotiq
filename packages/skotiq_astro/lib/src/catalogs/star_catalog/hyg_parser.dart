part of '../star_catalog.dart';

Future<List<Star>> _loadStarsInIsolate(_LoadStarsArgs args) async {
  final file = File(args.path);
  if (!file.existsSync()) return [];

  final rows = <_HygRow>[];
  final stream = file
      .openRead()
      .transform(utf8.decoder)
      .transform(const LineSplitter());

  var isHeader = true;
  await for (final line in stream) {
    if (isHeader) {
      isHeader = false;
      continue;
    }

    try {
      final row = _parseHygLine(line);
      if (row != null && (row.star.magnitude ?? 99) <= args.magnitudeLimit) {
        rows.add(row);
      }
    } catch (e) {
      // HYG CSV contains ~120k rows; a single malformed line (truncated
      // export, encoding glitch, unexpected NaN in a numeric column) must not
      // abort the whole load — the catalog is still useful with one row
      // missing. FINE surfaces a systemic format change (e.g. an upstream
      // column reorder) without spamming the user.
      developer.log(
        'HYG line parse failed; skipping: $e',
        name: 'HygStarCatalog',
        level: 500,
      );
    }
  }

  _nameComponentStars(rows);
  final stars = [for (final row in rows) row.star];

  // Sort by magnitude (brightest first)
  stars.sort((a, b) => (a.magnitude ?? 99).compareTo(b.magnitude ?? 99));

  return stars;
}

/// Name the unnamed secondary components of a multiple star after their
/// primary ("Capella B") instead of letting them fall back to the raw
/// catalogue id ("HYG118360").
///
/// HYG carries each component of a multiple system as its own row, and a
/// secondary usually has no HIP number, no proper name and no Bayer or
/// Flamsteed designation — only `comp` (which component it is) and
/// `comp_primary` (the id of the row it belongs to). Capella's Ab row is one
/// of those, 9 arcsec from Capella itself, so the chart labels the pair
/// "Capella" while the catalogue held an entry called "HYG118360" that search
/// and the object panel would happily show.
///
/// Only rows that HYG itself marks as components are touched, and only when
/// the primary row carries a real name, so nothing is invented.
void _nameComponentStars(List<_HygRow> rows) {
  final wantedPrimaries = <int>{};
  for (final row in rows) {
    if (_isUnnamedComponent(row)) wantedPrimaries.add(row.compPrimary);
  }
  if (wantedPrimaries.isEmpty) return;

  final primaryNames = <int, String>{};
  for (final row in rows) {
    if (row.named && wantedPrimaries.contains(row.hygId)) {
      primaryNames[row.hygId] = row.star.name;
    }
  }

  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    if (!_isUnnamedComponent(row)) continue;
    final primaryName = primaryNames[row.compPrimary];
    if (primaryName == null) continue;
    final s = row.star;
    rows[i] = (
      star: Star(
        id: s.id,
        name: '$primaryName ${_componentLetter(row.comp)}',
        coordinates: s.coordinates,
        magnitude: s.magnitude,
        spectralType: s.spectralType,
        constellation: s.constellation,
        colorIndex: s.colorIndex,
        catalogIds: s.catalogIds,
      ),
      hygId: row.hygId,
      comp: row.comp,
      compPrimary: row.compPrimary,
      named: true,
    );
  }
}

bool _isUnnamedComponent(_HygRow row) =>
    !row.named &&
    row.comp >= 2 &&
    row.compPrimary != 0 &&
    row.compPrimary != row.hygId;

/// HYG's `comp` is 1-based, and component 1 is the primary — so component 2
/// is the "B" of the system.
String _componentLetter(int comp) {
  const letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  final index = comp - 1;
  return index >= 0 && index < letters.length ? letters[index] : 'comp $comp';
}

/// Parse a line from the HYG CSV file
/// HYG v3.8 format columns:
/// 0:id, 1:hip, 2:hd, 3:hr, 4:gl, 5:bf, 6:proper, 7:ra, 8:dec, 9:dist,
/// 10:pmra, 11:pmdec, 12:rv, 13:mag, 14:absmag, 15:spect, 16:ci,
/// 17:x, 18:y, 19:z, 20:vx, 21:vy, 22:vz, 23:rarad, 24:decrad,
/// 25:pmrarad, 26:pmdecrad, 27:bayer, 28:flam, 29:con, ...
_HygRow? _parseHygLine(String line) {
  final parts = _parseCsvLine(line);
  if (parts.length < 30) return null;

  final hygId = int.tryParse(parts[0]) ?? 0;

  // HYG row id 0 is the SUN, carried as a placeholder at RA 0h / Dec 0 with
  // magnitude -26.7 because the catalogue's cartesian coordinates are
  // heliocentric. That is not a sky position, and as the brightest entry it
  // would win every brightest-object-in-view query touching RA 0h / Dec 0. The
  // real Sun is drawn from its computed ephemeris.
  if (hygId == 0) return null;

  final hipId = int.tryParse(parts[1]);
  final hdId = int.tryParse(parts[2]);
  final hrId = int.tryParse(parts[3]);
  final properName = parts.length > 6 ? parts[6] : '';
  // A row whose ra/dec column will not parse carries no sky position at all.
  // Coercing it to 0 put the star at RA 0h / Dec 0 — the same phantom position
  // the id-0 Sun row above is dropped for — where it renders in Pisces, wins
  // brightest-object-in-view queries over that region and can be slewed to.
  // Throwing hands the row to the loader's log-and-skip path instead, which is
  // exactly what the caller's catch already documents for a malformed numeric
  // column.
  final raHoursJ2000 = _requireSkyAngle(parts[7], 'ra');
  final decJ2000 = _requireSkyAngle(parts[8], 'dec');
  final pmra = double.tryParse(parts[10]); // mas/yr on sky (includes cos(dec))
  final pmdec = double.tryParse(parts[11]); // mas/yr
  final magnitude = double.tryParse(parts[13]);
  final spectralType = parts.length > 15 ? parts[15] : null;
  final colorIndex = parts.length > 16 ? double.tryParse(parts[16]) : null;
  final bayerDesignation = parts.length > 27 ? parts[27] : null;
  final flamsteedNumber = parts.length > 28 ? parts[28] : null;
  final constellation = parts.length > 29 ? parts[29] : null;

  double raHours = raHoursJ2000;
  double dec = decJ2000;

  // Apply proper motion for stars with significant motion (>5 mas/yr).
  // Most stars have pmra/pmdec < 1 mas/yr where the correction over 26 years
  // is sub-arcsecond — completely invisible. Only ~2% of stars have motion
  // large enough to matter visually (>5 mas/yr = >0.13" over 26 years).
  // Skipping low-motion stars avoids floating point noise in the division
  // by cos(dec) that corrupts positions for the majority of the catalog.
  if (pmra != null && pmdec != null) {
    final pmTotal = pmra.abs() + pmdec.abs();
    if (pmTotal > 5.0) {
      // Only correct if total motion > 5 mas/yr
      final now = DateTime.now();
      final yearsSinceJ2000 =
          (now.year - 2000) + (now.month - 1) / 12.0 + (now.day - 1) / 365.25;

      // Convert mas/yr to degrees/yr: 1 mas = 1/3,600,000 degrees
      final pmraDegreesPerYear = pmra / 3600000.0;
      final pmdecDegreesPerYear = pmdec / 3600000.0;

      // pmra from HYG is "proper motion in RA * cos(dec)" (mas/yr),
      // so to get the actual RA change, divide by cos(dec).
      // Use dart:math cos() for accuracy.
      final cosDec = math
          .cos(decJ2000 * math.pi / 180.0)
          .abs()
          .clamp(0.01, 1.0);

      final raCorrectionHours =
          (pmraDegreesPerYear / cosDec) * yearsSinceJ2000 / 15.0;
      final decCorrectionDeg = pmdecDegreesPerYear * yearsSinceJ2000;

      // Safety clamp: no star moves more than 0.1h RA (~1.5°) or 1° Dec in 50 years
      raHours += raCorrectionHours.clamp(-0.1, 0.1);
      dec += decCorrectionDeg.clamp(-1.0, 1.0);

      // Normalize RA to [0, 24)
      if (raHours < 0) raHours += 24.0;
      if (raHours >= 24) raHours -= 24.0;

      // Clamp dec to [-90, 90]
      dec = dec.clamp(-90.0, 90.0);
    }
  }

  // Build the star ID (prefer HIP, then HD, then HYG)
  String id;
  if (hipId != null && hipId > 0) {
    id = 'HIP$hipId';
  } else if (hdId != null && hdId > 0) {
    id = 'HD$hdId';
  } else {
    id = 'HYG$hygId';
  }

  // Build the name (prefer proper name, then Bayer, then Flamsteed, then catalog ID)
  String starName = properName;
  if (starName.isEmpty &&
      bayerDesignation != null &&
      bayerDesignation.isNotEmpty) {
    starName =
        '$bayerDesignation ${_getConstellationGenitive(constellation ?? '')}';
  }
  if (starName.isEmpty &&
      flamsteedNumber != null &&
      flamsteedNumber.isNotEmpty) {
    starName = '$flamsteedNumber ${constellationFullName(constellation ?? '')}';
  }
  // Whether the name above came from a real designation. When it did not,
  // [_nameComponentStars] gets a chance to derive one from the multiple-star
  // system this row belongs to before the raw id stands as the star's name.
  final named = starName.isNotEmpty;
  if (starName.isEmpty) {
    starName = id;
  }

  // Build alternate catalog IDs
  final catalogIds = <String>[];
  if (hipId != null && hipId > 0) catalogIds.add('HIP $hipId');
  if (hdId != null && hdId > 0) catalogIds.add('HD $hdId');
  if (hrId != null && hrId > 0) catalogIds.add('HR $hrId');

  // 30:comp (which component of a multiple system this row is, 1-based),
  // 31:comp_primary (id of the system's primary row).
  final comp = parts.length > 30 ? (int.tryParse(parts[30]) ?? 1) : 1;
  final compPrimary = parts.length > 31 ? (int.tryParse(parts[31]) ?? 0) : 0;

  return (
    star: Star(
      id: id,
      name: starName.trim(),
      coordinates: CelestialCoordinate(ra: raHours, dec: dec),
      magnitude: magnitude,
      spectralType: spectralType?.isNotEmpty == true ? spectralType : null,
      colorIndex: colorIndex,
      constellation: constellation?.isNotEmpty == true ? constellation : null,
      catalogIds: catalogIds,
    ),
    hygId: hygId,
    comp: comp,
    compPrimary: compPrimary,
    named: named,
  );
}

/// The one thing a star row cannot be missing: where the star is.
///
/// `NaN` is rejected alongside an unparseable field because `double.tryParse`
/// accepts the literal "NaN", and a NaN coordinate propagates silently through
/// every projection into a star that is drawn nowhere and matches nothing.
double _requireSkyAngle(String raw, String column) {
  final value = double.tryParse(raw);
  if (value == null || !value.isFinite) {
    throw FormatException('HYG $column column is not a finite number', raw);
  }
  return value;
}

/// Parse a CSV line handling quoted fields
List<String> _parseCsvLine(String line) {
  final parts = <String>[];
  var current = StringBuffer();
  var inQuotes = false;

  for (var i = 0; i < line.length; i++) {
    final char = line[i];

    if (char == '"') {
      inQuotes = !inQuotes;
    } else if (char == ',' && !inQuotes) {
      parts.add(current.toString().trim());
      current = StringBuffer();
    } else {
      current.write(char);
    }
  }

  parts.add(current.toString().trim());
  return parts;
}
