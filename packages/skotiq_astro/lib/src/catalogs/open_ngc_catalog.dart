import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import '../astronomy/astronomy_calculations.dart';
import '../celestial_object.dart';
import '../coordinate_system.dart';
import '../util/isolate_run.dart';
import 'catalog_name_search.dart';
import 'constellation_names.dart';

typedef _DsoRow = ({DeepSkyObject dso, List<String> names});
typedef _DsoLoad = ({List<DeepSkyObject> objects, CatalogNameKeys nameKeys});

/// The reader for the OpenNGC file (every NGC and IC object, about 13,000;
/// github.com/mattiaverga/OpenNGC).
///
/// One instance per installed file, owned by the catalog manager, so the CSV
/// is parsed once (in a background isolate) and every consumer shares the
/// list.
class OpenNgcDsoCatalog {
  /// Path of the `NGC.csv` file.
  final String path;

  List<DeepSkyObject>? _objects;
  CatalogNameKeys _nameKeys = CatalogNameKeys.empty;
  Future<List<DeepSkyObject>>? _inFlight;

  OpenNgcDsoCatalog(this.path);

  /// Every object in the file, brightest first (objects with no magnitude
  /// last); empty when the file is missing. A failed parse throws and is
  /// retried by the next call.
  Future<List<DeepSkyObject>> load() async {
    final cached = _objects;
    if (cached != null) return cached;
    return _inFlight ??= _load().whenComplete(() => _inFlight = null);
  }

  /// Search names parallel to [load]'s list.
  Future<CatalogNameKeys> nameKeys() async {
    await load();
    return _nameKeys;
  }

  Future<List<DeepSkyObject>> _load() async {
    if (path.isEmpty) {
      throw StateError(
        'CatalogManager not initialized. Call initialize() first.',
      );
    }
    if (!await File(path).exists()) {
      developer.log(
        '[Catalog] DSO catalog not found at $path. Download the catalog in Settings > Catalogs.',
        name: 'Catalog',
        level: 900,
      );
      // Not cached: a catalog copied into place later is picked up by the
      // next load.
      return const [];
    }
    final loaded = await runInIsolate(_loadDsosInIsolate, path);
    _nameKeys = loaded.nameKeys;
    return _objects = loaded.objects;
  }

  /// Objects no fainter than [maxMagnitude], plus those with no magnitude at
  /// all (many nebulae, IC 410 among them, list none), brightest first.
  Future<List<DeepSkyObject>> brighterThan(double maxMagnitude) async {
    final objects = await load();
    return [
      for (final o in objects)
        if (o.magnitude == null || o.magnitude! <= maxMagnitude) o,
    ];
  }

  /// Objects within [radiusDegrees] of ([raDegrees], [decDegrees]) on the
  /// sky, brightest first. With [maxMagnitude], objects with no magnitude are
  /// left out.
  Future<List<DeepSkyObject>> near({
    required double raDegrees,
    required double decDegrees,
    required double radiusDegrees,
    double? maxMagnitude,
  }) async {
    final objects = await load();
    final found = <DeepSkyObject>[];
    for (final o in objects) {
      if (maxMagnitude != null && (o.magnitude ?? 99) > maxMagnitude) break;
      if ((o.coordinates.dec - decDegrees).abs() > radiusDegrees) continue;
      final separation = AstronomyCalculations.angularSeparation(
        ra1Deg: raDegrees,
        dec1Deg: decDegrees,
        ra2Deg: o.coordinates.raDegrees,
        dec2Deg: o.coordinates.dec,
      );
      if (separation <= radiusDegrees) found.add(o);
    }
    return found;
  }

  static Future<_DsoLoad> _loadDsosInIsolate(String path) async {
    final rows = <_DsoRow>[];
    final stream = File(
      path,
    ).openRead().transform(utf8.decoder).transform(const LineSplitter());

    var isHeader = true;
    await for (final line in stream) {
      if (isHeader) {
        isHeader = false;
        continue;
      }
      try {
        final row = _parseOpenNgcLine(line);
        if (row != null) rows.add(row);
      } catch (e) {
        // One malformed line (truncated export, missing field) must not abort
        // the load of the other 14k. FINE keeps a systemic format change
        // visible without spamming the user-facing pipeline.
        developer.log(
          'OpenNGC line parse failed; skipping: $e',
          name: 'OpenNgcCatalog',
          level: 500,
        );
      }
    }

    rows.sort(
      (a, b) => (a.dso.magnitude ?? 99).compareTo(b.dso.magnitude ?? 99),
    );
    final lower = <String>[];
    final normalized = <String>[];
    for (final row in rows) {
      CatalogNameKeys.add(lower, normalized, row.names);
    }
    return (
      objects: [for (final row in rows) row.dso],
      nameKeys: CatalogNameKeys(lower, normalized),
    );
  }

  /// Parse a line from the OpenNGC CSV file
  /// Format (semicolon separated):
  /// Name;Type;RA;Dec;Const;MajAx;MinAx;PosAng;B-Mag;V-Mag;J-Mag;H-Mag;K-Mag;SurfBr;
  /// Hubble;Cstar U-Mag;Cstar B-Mag;Cstar V-Mag;M;NGC;IC;Cstar Names;Identifiers;
  /// Common names;NED notes;OpenNGC notes
  static _DsoRow? _parseOpenNgcLine(String line) {
    final parts = line.split(';');
    if (parts.length < 10) return null;

    var ngcName = parts[0].trim();
    final typeCode = parts[1].trim();

    // Skip non-existent and duplicate entries
    if (typeCode == 'NonEx' || typeCode == 'Dup') return null;

    // Remove leading zeros from NGC/IC numbers (e.g., NGC0628 -> NGC628)
    ngcName = _normalizeCatalogName(ngcName);

    // Parse RA (format: HH:MM:SS.ss)
    final ra = _parseRa(parts[2]);
    if (ra == null) return null;

    // Parse Dec (format: +/-DD:MM:SS.s)
    final dec = _parseDec(parts[3]);
    if (dec == null) return null;

    final constellation = parts[4].trim();
    final majorAxis = double.tryParse(parts[5]);
    final minorAxis = double.tryParse(parts[6]);
    final positionAngle = double.tryParse(parts[7]);
    final bMag = double.tryParse(parts[8]);
    final vMag = double.tryParse(parts[9]);

    // Use V magnitude if available, otherwise B magnitude
    final magnitude = vMag ?? bMag;

    // Get Messier number if available - validate it's a real Messier number (1-110)
    // Column 23 is Messier number (M)
    String? messier;
    if (parts.length > 23 && parts[23].isNotEmpty) {
      final messierNum = int.tryParse(parts[23].trim());
      // Only accept valid Messier numbers (1-110)
      if (messierNum != null && messierNum >= 1 && messierNum <= 110) {
        messier = 'M$messierNum';
      }
    }

    // Get common names
    // Column 28 is Common names
    String? commonNames;
    if (parts.length > 28 && parts[28].isNotEmpty) {
      commonNames = parts[28];
    }

    // Get identifiers for catalog IDs
    // Column 27 is Identifiers
    final catalogIds = <String>[];
    if (parts.length > 27 && parts[27].isNotEmpty) {
      catalogIds.addAll(
        parts[27].split(',').map((s) => s.trim()).where((s) => s.isNotEmpty),
      );
    }
    if (messier != null) {
      catalogIds.add(messier);
    }

    // Determine display name
    String displayName;
    if (messier != null) {
      displayName = messier;
    } else if (commonNames != null && commonNames.isNotEmpty) {
      displayName = commonNames.split(',').first.trim();
    } else {
      displayName = ngcName;
    }

    // Calculate size in arcminutes (use major axis)
    final size = majorAxis;

    // NGC and IC cross-references (an IC object that is also an NGC one).
    final crossIds = [
      if (parts.length > 24 && parts[24].trim().isNotEmpty)
        'NGC ${parts[24].trim()}',
      if (parts.length > 25 && parts[25].trim().isNotEmpty)
        'IC ${parts[25].trim()}',
    ];

    final dso = DeepSkyObject(
      id: ngcName,
      name: displayName,
      coordinates: CelestialCoordinate(ra: ra, dec: dec),
      type: dsoTypeFromOpenNgcCode(typeCode),
      magnitude: magnitude,
      sizeArcMin: size,
      constellation: constellationFullName(constellation),
      catalogIds: catalogIds,
      positionAngle: positionAngle,
      minorAxisArcMin: minorAxis,
      commonNames: commonNames,
    );
    return (
      dso: dso,
      names: [
        ngcName,
        displayName,
        if (messier != null) messier,
        ...crossIds,
        if (commonNames != null)
          for (final name in commonNames.split(',')) name.trim(),
      ],
    );
  }

  /// Normalize catalog name by removing leading zeros (e.g., NGC0628 -> NGC628)
  static String _normalizeCatalogName(String name) {
    // Match NGC or IC followed by optional space, optional leading zeros and digits
    final match = RegExp(
      r'^(NGC|IC)\s*(0*)(\d+)$',
      caseSensitive: false,
    ).firstMatch(name);
    if (match != null) {
      final prefix = match.group(1)!.toUpperCase();
      final number = match.group(3)!;
      return '$prefix$number';
    }
    return name;
  }

  /// Parse RA string (HH:MM:SS.ss) to hours
  static double? _parseRa(String raStr) {
    if (raStr.isEmpty) return null;
    final parts = raStr.split(':');
    if (parts.length != 3) return null;

    final h = double.tryParse(parts[0]);
    final m = double.tryParse(parts[1]);
    final s = double.tryParse(parts[2]);

    if (h == null || m == null || s == null) return null;

    return h + m / 60 + s / 3600; // Return RA in hours (0-24)
  }

  /// Parse Dec string (+/-DD:MM:SS.s) to degrees
  static double? _parseDec(String decStr) {
    if (decStr.isEmpty) return null;

    final sign = decStr.startsWith('-') ? -1 : 1;
    final clean = decStr.replaceAll('+', '').replaceAll('-', '');
    final parts = clean.split(':');
    if (parts.length != 3) return null;

    final d = double.tryParse(parts[0]);
    final m = double.tryParse(parts[1]);
    final s = double.tryParse(parts[2]);

    if (d == null || m == null || s == null) return null;

    return sign * (d + m / 60 + s / 3600);
  }
}
