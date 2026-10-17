import 'dart:developer' as developer;
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../celestial_object.dart';
import '../coordinate_system.dart';
import 'catalog_manager.dart';
import 'constellation_names.dart';

/// Base class for star/DSO catalogs
abstract class Catalog<T extends CelestialObject> {
  String get name;
  Future<List<T>> loadObjects();
  Future<T?> findById(String id);
  Future<List<T>> search(String query);
}

/// Deep Sky Object catalog that loads from OpenNGC database
///
/// OpenNGC is an open source database containing all NGC and IC objects
/// with ~13,000+ objects total. Source: github.com/mattiaverga/OpenNGC
class OpenNgcDsoCatalog extends Catalog<DeepSkyObject> {
  final String? catalogPath;
  final double magnitudeLimit;

  List<DeepSkyObject>? _cachedObjects;
  bool _isLoading = false;

  /// Create a DSO catalog
  ///
  /// [catalogPath] - Path to the NGC.csv file, or null to use CatalogManager
  /// [magnitudeLimit] - Maximum magnitude to load (fainter objects have higher values)
  OpenNgcDsoCatalog({this.catalogPath, this.magnitudeLimit = 20.0});

  @override
  String get name => 'OpenNGC';

  /// Check if catalog data is available
  Future<bool> get isAvailable async {
    final path = catalogPath ?? CatalogManager.instance.dsoCatalogPath;
    return File(path).exists();
  }

  /// Get the number of loaded objects
  int get objectCount => _cachedObjects?.length ?? 0;

  @override
  Future<List<DeepSkyObject>> loadObjects() async {
    if (_cachedObjects != null) return _cachedObjects!;
    if (_isLoading) {
      // Wait for loading to complete
      while (_isLoading) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      return _cachedObjects ?? [];
    }

    _isLoading = true;

    try {
      final path = catalogPath ?? CatalogManager.instance.dsoCatalogPath;
      final file = File(path);

      if (!await file.exists()) {
        // Return empty list if catalog not installed - user should download catalog
        developer.log(
          '[Catalog] DSO catalog not found at $path. Download the catalog in Settings > Catalogs.',
          name: 'Catalog',
          level: 900,
        );
        _cachedObjects = [];
        return _cachedObjects!;
      }

      // Use compute to load in background isolate
      try {
        final objects = await compute(
          _loadDsosInIsolate,
          _LoadDsosArgs(path, magnitudeLimit),
        );
        _cachedObjects = objects;
        return objects;
      } catch (e) {
        developer.log(
          '[Catalog] Error loading DSOs in isolate: $e',
          name: 'Catalog',
          level: 1000,
          error: e,
        );
        return [];
      }
    } finally {
      _isLoading = false;
    }
  }

  static Future<List<DeepSkyObject>> _loadDsosInIsolate(
    _LoadDsosArgs args,
  ) async {
    final file = File(args.path);
    if (!file.existsSync()) return [];

    final objects = <DeepSkyObject>[];
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
        final dso = _parseOpenNgcLine(line);
        // Include objects if magnitude is known and within limit, OR if magnitude is unknown (null)
        // Many nebulae (like IC 410) have no magnitude listed but should be included.
        if (dso != null &&
            (dso.magnitude == null || dso.magnitude! <= args.magnitudeLimit)) {
          objects.add(dso);
        }
      } catch (e) {
        // OpenNGC CSV has 14k+ rows; a single malformed line (truncated
        // export, missing field, locale-dependent decimal separator) must not
        // abort the load — the rest of the catalog is still useful. FINE keeps
        // a systemic format change visible without spamming the user-facing
        // pipeline.
        developer.log(
          'OpenNGC line parse failed; skipping: $e',
          name: 'OpenNgcCatalog',
          level: 500,
        );
      }
    }

    // Sort by magnitude (brightest first)
    objects.sort((a, b) => (a.magnitude ?? 99).compareTo(b.magnitude ?? 99));

    return objects;
  }

  /// Parse a line from the OpenNGC CSV file
  /// Format (semicolon separated):
  /// Name;Type;RA;Dec;Const;MajAx;MinAx;PosAng;B-Mag;V-Mag;J-Mag;H-Mag;K-Mag;SurfBr;
  /// Hubble;Cstar U-Mag;Cstar B-Mag;Cstar V-Mag;M;NGC;IC;Cstar Names;Identifiers;
  /// Common names;NED notes;OpenNGC notes
  static DeepSkyObject? _parseOpenNgcLine(String line) {
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

    return DeepSkyObject(
      id: ngcName,
      name: displayName,
      coordinates: CelestialCoordinate(ra: ra, dec: dec),
      type: _parseDsoType(typeCode),
      magnitude: magnitude,
      sizeArcMin: size,
      constellation: _getConstellationName(constellation),
      catalogIds: catalogIds,
      positionAngle: positionAngle,
      minorAxisArcMin: minorAxis,
      commonNames: commonNames,
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

  /// Convert OpenNGC type code to DsoType
  static DsoType _parseDsoType(String typeCode) {
    switch (typeCode) {
      case '*':
        return DsoType.star;
      case '**':
        return DsoType.doubleStar;
      case '*Ass':
        return DsoType.association;
      case 'OCl':
        return DsoType.openCluster;
      case 'GCl':
        return DsoType.globularCluster;
      case 'Cl+N':
        return DsoType.clusterWithNebulosity;
      case 'G':
        return DsoType.galaxy;
      case 'GPair':
        return DsoType.galaxyPair;
      case 'GTrpl':
        return DsoType.galaxyTriplet;
      case 'GGroup':
        return DsoType.galaxyGroup;
      case 'PN':
        return DsoType.planetaryNebula;
      case 'HII':
        return DsoType.hiiRegion;
      case 'DrkN':
        return DsoType.darkNebula;
      case 'EmN':
        return DsoType.emissionNebula;
      case 'Neb':
        return DsoType.nebula;
      case 'RfN':
        return DsoType.reflectionNebula;
      case 'SNR':
        return DsoType.supernova;
      case 'Nova':
        return DsoType.nova;
      default:
        return DsoType.other;
    }
  }

  /// Get full constellation name from abbreviation.
  ///
  /// Delegates to the shared table in constellation_names.dart so the catalog
  /// and every UI that spells a constellation out agree letter for letter.
  static String _getConstellationName(String abbr) {
    return constellationFullName(abbr);
  }

  @override
  Future<DeepSkyObject?> findById(String id) async {
    final objects = await loadObjects();
    final normalizedId = id.toUpperCase().replaceAll(' ', '');

    return objects.where((o) {
      if (o.id.toUpperCase().replaceAll(' ', '') == normalizedId) return true;
      if (o.name.toUpperCase().replaceAll(' ', '') == normalizedId) return true;
      return o.catalogIds.any(
        (c) => c.toUpperCase().replaceAll(' ', '') == normalizedId,
      );
    }).firstOrNull;
  }

  @override
  Future<List<DeepSkyObject>> search(String query) async {
    final q = query.toLowerCase();
    final normalizedQuery = q.replaceAll(RegExp(r'\s+'), '');
    final objects = await loadObjects();

    return objects.where((o) {
      final idLower = o.id.toLowerCase();
      final nameLower = o.name.toLowerCase();

      // Direct matches
      if (idLower.contains(q) || nameLower.contains(q)) return true;
      if (o.catalogIds.any((c) => c.toLowerCase().contains(q))) return true;
      if (o.constellation?.toLowerCase().contains(q) ?? false) return true;

      // Normalized matches
      final normalizedId = idLower.replaceAll(RegExp(r'\s+'), '');
      if (normalizedId.contains(normalizedQuery)) return true;

      final normalizedName = nameLower.replaceAll(RegExp(r'\s+'), '');
      if (normalizedName.contains(normalizedQuery)) return true;

      if (o.catalogIds.any((c) {
        final cNormalized = c.toLowerCase().replaceAll(RegExp(r'\s+'), '');
        return cNormalized.contains(normalizedQuery);
      })) {
        return true;
      }

      return false;
    }).toList();
  }

  /// Get DSOs by type
  Future<List<DeepSkyObject>> getByType(DsoType type) async {
    final objects = await loadObjects();
    return objects.where((o) => o.type == type).toList();
  }

  /// Get DSOs by magnitude limit
  Future<List<DeepSkyObject>> getByMagnitude(double maxMagnitude) async {
    final objects = await loadObjects();
    return objects.where((o) => (o.magnitude ?? 99) <= maxMagnitude).toList();
  }

  /// Get only Messier objects
  Future<List<DeepSkyObject>> getMessierObjects() async {
    final objects = await loadObjects();
    return objects
        .where(
          (o) =>
              o.catalogIds.any((c) => c.startsWith('M')) ||
              o.name.startsWith('M') && RegExp(r'^M\d+$').hasMatch(o.name),
        )
        .toList();
  }

  /// Get DSOs in a constellation
  Future<List<DeepSkyObject>> getByConstellation(String constellation) async {
    final objects = await loadObjects();
    return objects
        .where(
          (o) => o.constellation?.toLowerCase() == constellation.toLowerCase(),
        )
        .toList();
  }

  /// Get DSOs near a position (cone search)
  Future<List<DeepSkyObject>> getDsosNear(
    CelestialCoordinate center,
    double radiusDegrees, {
    double? maxMagnitude,
  }) async {
    final objects = await loadObjects();

    return objects.where((o) {
      if (maxMagnitude != null && (o.magnitude ?? 99) > maxMagnitude) {
        return false;
      }

      // Simple angular distance (good enough for small radii)
      final dRa = (o.coordinates.ra - center.ra).abs();
      final dDec = (o.coordinates.dec - center.dec).abs();
      final approxDist = dRa * dRa + dDec * dDec;

      return approxDist <= radiusDegrees * radiusDegrees;
    }).toList();
  }

  /// Clear the cache
  void clearCache() {
    _cachedObjects = null;
  }
}

/// Legacy Messier catalog that uses OpenNGC internally
class MessierCatalog extends Catalog<DeepSkyObject> {
  final OpenNgcDsoCatalog _ngcCatalog = OpenNgcDsoCatalog();

  @override
  String get name => 'Messier';

  @override
  Future<List<DeepSkyObject>> loadObjects() async {
    return _ngcCatalog.getMessierObjects();
  }

  @override
  Future<DeepSkyObject?> findById(String id) async {
    final objects = await loadObjects();
    final normalizedId = id.toUpperCase().replaceAll(' ', '');

    return objects
        .where(
          (o) =>
              o.id.toUpperCase().replaceAll(' ', '') == normalizedId ||
              o.name.toUpperCase().replaceAll(' ', '') == normalizedId ||
              o.catalogIds.any(
                (c) => c.toUpperCase().replaceAll(' ', '') == normalizedId,
              ),
        )
        .firstOrNull;
  }

  @override
  Future<List<DeepSkyObject>> search(String query) async {
    final q = query.toLowerCase();
    final objects = await loadObjects();

    return objects
        .where(
          (o) =>
              o.id.toLowerCase().contains(q) ||
              o.name.toLowerCase().contains(q) ||
              o.catalogIds.any((c) => c.toLowerCase().contains(q)),
        )
        .toList();
  }
}

class _LoadDsosArgs {
  final String path;
  final double magnitudeLimit;

  _LoadDsosArgs(this.path, this.magnitudeLimit);
}
