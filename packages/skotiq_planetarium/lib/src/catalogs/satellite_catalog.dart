import 'dart:io';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'package:path/path.dart' as path;
import '../astronomy/sgp4.dart';
import 'catalog_manager.dart';

/// Satellite data with current computed position.
class SatelliteData {
  final OrbitalElements elements;

  /// Current RA in hours (0-24), updated by provider
  double ra;

  /// Current Dec in degrees (-90 to +90), updated by provider
  double dec;

  /// Current altitude above Earth surface in km
  double altitudeKm;

  /// Current range from observer in km
  double rangeKm;

  /// Whether satellite is currently in Earth's shadow
  bool isEclipsed;

  /// Current elevation from observer in degrees
  double elevation;

  /// Current azimuth from observer in degrees
  double azimuth;

  /// Whether satellite is above the observer's horizon
  bool get isVisible => elevation > 0 && !isEclipsed;

  String get name => elements.name;
  int get catalogNumber => elements.catalogNumber;

  SatelliteData({
    required this.elements,
    this.ra = 0,
    this.dec = 0,
    this.altitudeKm = 0,
    this.rangeKm = 0,
    this.isEclipsed = false,
    this.elevation = 0,
    this.azimuth = 0,
  });
}

/// A predicted satellite pass over the observer's location.
class SatellitePass {
  final OrbitalElements elements;

  /// Rise time (above horizon)
  final DateTime riseTime;

  /// Rise azimuth in degrees
  final double riseAzimuth;

  /// Maximum elevation time
  final DateTime maxElevationTime;

  /// Maximum elevation in degrees
  final double maxElevation;

  /// Maximum elevation azimuth in degrees
  final double maxElevationAzimuth;

  /// Set time (below horizon)
  final DateTime setTime;

  /// Set azimuth in degrees
  final double setAzimuth;

  /// Duration of the pass
  Duration get duration => setTime.difference(riseTime);

  /// Whether this is a bright/good pass (max elevation > 30 degrees)
  bool get isBrightPass => maxElevation > 30;

  String get name => elements.name;

  const SatellitePass({
    required this.elements,
    required this.riseTime,
    required this.riseAzimuth,
    required this.maxElevationTime,
    required this.maxElevation,
    required this.maxElevationAzimuth,
    required this.setTime,
    required this.setAzimuth,
  });
}

/// TLE data source URLs from CelesTrak.
class TleSource {
  final String name;
  final String url;
  final String description;

  const TleSource({
    required this.name,
    required this.url,
    required this.description,
  });

  /// Standard TLE sources from CelesTrak
  static const List<TleSource> defaultSources = [
    TleSource(
      name: 'Brightest',
      url:
          'https://celestrak.org/NORAD/elements/gp.php?GROUP=visual&FORMAT=tle',
      description: 'Visually bright satellites (~160)',
    ),
    TleSource(
      name: 'Space Stations',
      url:
          'https://celestrak.org/NORAD/elements/gp.php?GROUP=stations&FORMAT=tle',
      description: 'ISS and other stations',
    ),
    TleSource(
      name: 'Active Satellites',
      url:
          'https://celestrak.org/NORAD/elements/gp.php?GROUP=active&FORMAT=tle',
      description: 'All active satellites (~8000)',
    ),
    TleSource(
      name: 'Starlink',
      url:
          'https://celestrak.org/NORAD/elements/gp.php?GROUP=starlink&FORMAT=tle',
      description: 'SpaceX Starlink constellation',
    ),
  ];
}

/// Parses Two-Line Element sets into OrbitalElements.
class TleParser {
  TleParser._();

  /// Parse a TLE string containing multiple 3-line element sets.
  ///
  /// Format:
  /// ```
  /// ISS (ZARYA)             [line 0: name]
  /// 1 25544U 98067A   ...   [line 1]
  /// 2 25544  51.6416 ...    [line 2]
  /// ```
  ///
  /// Returns list of parsed orbital elements. Lines that fail to parse
  /// are skipped with a debug message.
  static List<OrbitalElements> parse(String tleText) {
    final lines = tleText
        .split('\n')
        .map((l) => l.trimRight())
        .where((l) => l.isNotEmpty)
        .toList();
    final elements = <OrbitalElements>[];

    int i = 0;
    while (i < lines.length) {
      // Determine if current line is line 0 (name), line 1, or line 2
      if (i + 2 < lines.length &&
          _isLine1(lines[i + 1]) &&
          _isLine2(lines[i + 2])) {
        // Three-line format: name + line1 + line2
        final parsed = _parseThreeLines(lines[i], lines[i + 1], lines[i + 2]);
        if (parsed != null) {
          elements.add(parsed);
        } else {
          developer.log(
            '[TLE] Failed to parse: ${lines[i].trim()}',
            name: 'SatelliteCatalog',
            level: 900,
          );
        }
        i += 3;
      } else if (i + 1 < lines.length &&
          _isLine1(lines[i]) &&
          _isLine2(lines[i + 1])) {
        // Two-line format: line1 + line2 (no name line)
        final parsed = _parseTwoLines(lines[i], lines[i + 1]);
        if (parsed != null) {
          elements.add(parsed);
        } else {
          developer.log(
            '[TLE] Failed to parse 2-line at index $i',
            name: 'SatelliteCatalog',
            level: 900,
          );
        }
        i += 2;
      } else {
        // Skip unrecognized line
        i++;
      }
    }

    return elements;
  }

  static bool _isLine1(String line) {
    return line.length >= 69 && line[0] == '1' && line[1] == ' ';
  }

  static bool _isLine2(String line) {
    return line.length >= 69 && line[0] == '2' && line[1] == ' ';
  }

  static OrbitalElements? _parseThreeLines(
    String name,
    String line1,
    String line2,
  ) {
    final cleanName = name.trim();
    return _parseTwoLinesWithName(cleanName, line1, line2);
  }

  static OrbitalElements? _parseTwoLines(String line1, String line2) {
    // Extract catalog number for name
    final catStr = line1.substring(2, 7).trim();
    return _parseTwoLinesWithName('SAT $catStr', line1, line2);
  }

  static OrbitalElements? _parseTwoLinesWithName(
    String name,
    String line1,
    String line2,
  ) {
    try {
      // Verify checksums
      if (!_verifyChecksum(line1) || !_verifyChecksum(line2)) {
        developer.log(
          '[TLE] Checksum mismatch for $name',
          name: 'SatelliteCatalog',
          level: 900,
        );
        // Continue anyway - some sources have bad checksums
      }

      // Line 1 parsing
      final catalogNumber = int.parse(line1.substring(2, 7).trim());
      final intlDesignator = line1.substring(9, 17).trim();
      final epochYear = int.parse(line1.substring(18, 20).trim());
      final epochDay = double.parse(line1.substring(20, 32).trim());

      // B* drag term - special format: +/-NNNNN+/-N meaning N.NNNNN * 10^N
      final bstar = _parseBstar(line1.substring(53, 61).trim());

      // Line 2 parsing
      final inclination = double.parse(line2.substring(8, 16).trim());
      final raan = double.parse(line2.substring(17, 25).trim());

      // Eccentricity has implicit decimal point
      final eccStr = '0.${line2.substring(26, 33).trim()}';
      final eccentricity = double.parse(eccStr);

      final argumentOfPerigee = double.parse(line2.substring(34, 42).trim());
      final meanAnomaly = double.parse(line2.substring(43, 51).trim());
      final meanMotion = double.parse(line2.substring(52, 63).trim());

      int revolutionNumber = 0;
      if (line2.length >= 68) {
        final revStr = line2.substring(63, 68).trim();
        if (revStr.isNotEmpty) {
          revolutionNumber = int.tryParse(revStr) ?? 0;
        }
      }

      return OrbitalElements(
        catalogNumber: catalogNumber,
        name: name,
        intlDesignator: intlDesignator,
        epochYear: epochYear,
        epochDay: epochDay,
        bstar: bstar,
        inclination: inclination,
        raan: raan,
        eccentricity: eccentricity,
        argumentOfPerigee: argumentOfPerigee,
        meanAnomaly: meanAnomaly,
        meanMotion: meanMotion,
        revolutionNumber: revolutionNumber,
      );
    } catch (e) {
      developer.log(
        '[TLE] Parse error for "$name": $e',
        name: 'SatelliteCatalog',
        level: 900,
        error: e,
      );
      return null;
    }
  }

  /// Parse B* drag term from TLE format.
  ///
  /// Format examples: " 24339-4" means 0.24339 * 10^-4
  ///                  "-11606-4" means -0.11606 * 10^-4
  ///                  " 00000+0" means 0.0
  static double _parseBstar(String bstarStr) {
    if (bstarStr.isEmpty) return 0.0;

    // Normalize: replace spaces, handle sign
    var s = bstarStr.replaceAll(' ', '');
    if (s == '00000-0' || s == '00000+0' || s.isEmpty) return 0.0;

    // Parse sign
    double sign = 1.0;
    if (s.startsWith('-')) {
      sign = -1.0;
      s = s.substring(1);
    } else if (s.startsWith('+')) {
      s = s.substring(1);
    }

    // Find the exponent separator (+ or -)
    int expIdx = -1;
    for (int i = 1; i < s.length; i++) {
      if (s[i] == '+' || s[i] == '-') {
        expIdx = i;
        break;
      }
    }

    if (expIdx == -1) {
      // No exponent found, try direct parse
      final val = double.tryParse(s);
      return val != null ? sign * val : 0.0;
    }

    final mantissa = double.tryParse('0.${s.substring(0, expIdx)}');
    final exponent = int.tryParse(s.substring(expIdx));
    if (mantissa == null || exponent == null) return 0.0;

    return sign * mantissa * math.pow(10.0, exponent.toDouble()).toDouble();
  }

  static bool _verifyChecksum(String line) {
    if (line.length < 69) return false;
    int sum = 0;
    for (int i = 0; i < 68; i++) {
      final c = line[i];
      if (c == '-') {
        sum += 1;
      } else if (c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57) {
        // '0' to '9'
        sum += c.codeUnitAt(0) - 48;
      }
    }
    final expected = int.tryParse(line[68]);
    return expected == (sum % 10);
  }
}

/// Manages satellite TLE data: download, cache, and access.
class SatelliteCatalog {
  final HttpClient _httpClient = HttpClient();
  final Map<String, List<OrbitalElements>> _cachedGroups = {};
  DateTime? _lastDownloadTime;

  /// How old TLE data can be before we re-download (default: 24 hours)
  final Duration maxAge;

  /// Cache directory for TLE files
  final String? cacheDirectory;

  SatelliteCatalog({
    this.maxAge = const Duration(hours: 24),
    this.cacheDirectory,
  });

  /// Get the cache file path for a TLE source.
  String _cacheFilePath(String sourceName) {
    final dir = cacheDirectory ?? CatalogManager.instance.catalogDirectory;
    return path.join(
      dir,
      'tle_${sourceName.toLowerCase().replaceAll(' ', '_')}.txt',
    );
  }

  /// Download TLE data from a source URL.
  ///
  /// Returns the raw TLE text, or throws on failure.
  Future<String> _downloadTle(String url) async {
    final request = await _httpClient.getUrl(Uri.parse(url));
    request.headers.set('User-Agent', 'Skotiq/2.5');
    final response = await request.close();

    if (response.statusCode != 200) {
      throw HttpException(
        'Failed to download TLE data: HTTP ${response.statusCode}',
        uri: Uri.parse(url),
      );
    }

    return await response.transform(utf8.decoder).join();
  }

  /// Load TLE data for a source, using cache if fresh enough.
  ///
  /// Tries cache first, falls back to network download.
  /// Throws if both cache and network fail.
  Future<List<OrbitalElements>> loadSource(TleSource source) async {
    // Check memory cache
    if (_cachedGroups.containsKey(source.name) &&
        _lastDownloadTime != null &&
        DateTime.now().difference(_lastDownloadTime!) < maxAge) {
      return _cachedGroups[source.name]!;
    }

    // Check disk cache
    final cacheFile = File(_cacheFilePath(source.name));
    if (await cacheFile.exists()) {
      final stat = await cacheFile.stat();
      if (DateTime.now().difference(stat.modified) < maxAge) {
        try {
          final text = await cacheFile.readAsString();
          final elements = TleParser.parse(text);
          if (elements.isNotEmpty) {
            _cachedGroups[source.name] = elements;
            _lastDownloadTime = stat.modified;
            developer.log(
              '[Satellite] Loaded ${elements.length} TLEs from cache for ${source.name}',
              name: 'SatelliteCatalog',
              level: 800,
            );
            return elements;
          }
        } catch (e) {
          developer.log(
            '[Satellite] Cache read error for ${source.name}: $e',
            name: 'SatelliteCatalog',
            level: 900,
            error: e,
          );
        }
      }
    }

    // Download from network
    try {
      final text = await _downloadTle(source.url);
      final elements = TleParser.parse(text);

      if (elements.isEmpty) {
        throw FormatException(
          'Downloaded TLE data for ${source.name} contained no valid elements',
        );
      }

      // Save to disk cache
      try {
        final dir = Directory(path.dirname(cacheFile.path));
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        await cacheFile.writeAsString(text);
      } catch (e) {
        developer.log(
          '[Satellite] Cache write error for ${source.name}: $e',
          name: 'SatelliteCatalog',
          level: 900,
          error: e,
        );
      }

      _cachedGroups[source.name] = elements;
      _lastDownloadTime = DateTime.now();
      developer.log(
        '[Satellite] Downloaded ${elements.length} TLEs for ${source.name}',
        name: 'SatelliteCatalog',
        level: 800,
      );
      return elements;
    } catch (e) {
      // If download fails, try stale cache as last resort
      if (await cacheFile.exists()) {
        try {
          final text = await cacheFile.readAsString();
          final elements = TleParser.parse(text);
          if (elements.isNotEmpty) {
            _cachedGroups[source.name] = elements;
            developer.log(
              '[Satellite] Using stale cache for ${source.name} (${elements.length} TLEs)',
              name: 'SatelliteCatalog',
              level: 900,
            );
            return elements;
          }
        } catch (e) {
          // Why: stale-cache last-resort path. The download already failed;
          // if the cache file is also unreadable/corrupt we fall through to
          // the `rethrow` below so the original download error reaches the
          // caller (which is the actionable one). Logging here surfaces the
          // cache corruption distinctly from the network failure.
          developer.log(
            '[Satellite] Stale-cache fallback failed for ${source.name}: $e',
            name: 'SatelliteCatalog',
            level: 1000,
            error: e,
          );
        }
      }
      rethrow;
    }
  }

  /// Load the default bright satellites + space stations.
  Future<List<OrbitalElements>> loadBrightSatellites() async {
    final results = <OrbitalElements>[];
    final seen = <int>{};

    for (final source in [
      TleSource.defaultSources[0],
      TleSource.defaultSources[1],
    ]) {
      try {
        final elements = await loadSource(source);
        for (final elem in elements) {
          if (seen.add(elem.catalogNumber)) {
            results.add(elem);
          }
        }
      } catch (e) {
        developer.log(
          '[Satellite] Failed to load ${source.name}: $e',
          name: 'SatelliteCatalog',
          level: 900,
          error: e,
        );
      }
    }

    if (results.isEmpty) {
      throw StateError(
        'Failed to load any satellite TLE data. Check network connection.',
      );
    }

    return results;
  }

  /// Clear all cached TLE data.
  void clearCache() {
    _cachedGroups.clear();
    _lastDownloadTime = null;
  }

  /// Predict visible passes for a satellite from an observer location.
  ///
  /// [elements] - Satellite orbital elements
  /// [latitude] - Observer latitude (degrees)
  /// [longitude] - Observer longitude (degrees)
  /// [altitude] - Observer altitude (km)
  /// [startTime] - Start of prediction window
  /// [duration] - Length of prediction window
  /// [minElevation] - Minimum peak elevation for a pass to be included (degrees)
  ///
  /// Returns list of predicted passes, sorted by rise time.
  static List<SatellitePass> predictPasses({
    required OrbitalElements elements,
    required double latitude,
    required double longitude,
    double altitude = 0,
    required DateTime startTime,
    Duration duration = const Duration(hours: 72),
    double minElevation = 5.0,
  }) {
    final passes = <SatellitePass>[];
    final endTime = startTime.add(duration);

    // Step through time in 30-second increments to find horizon crossings
    const stepSeconds = 30;
    var currentTime = startTime.toUtc();

    DateTime? riseTime;
    double riseAz = 0;
    double maxEl = 0;
    DateTime maxElTime = currentTime;
    double maxElAz = 0;
    bool wasAboveHorizon = false;

    while (currentTime.isBefore(endTime)) {
      final result = Sgp4.propagateAt(elements, currentTime);
      if (result == null) {
        currentTime = currentTime.add(const Duration(seconds: stepSeconds));
        continue;
      }

      final jd = Sgp4.julianDate(currentTime);
      final gmst = Sgp4.gstime(jd);

      final look = Sgp4.eciToLookAngles(
        result.position,
        result.velocity,
        latitude,
        longitude,
        altitude,
        gmst,
      );

      final isAbove = look.elevation > 0;

      if (isAbove && !wasAboveHorizon) {
        // Satellite just rose above horizon
        riseTime = currentTime;
        riseAz = look.azimuth;
        maxEl = look.elevation;
        maxElTime = currentTime;
        maxElAz = look.azimuth;
      }

      if (isAbove) {
        if (look.elevation > maxEl) {
          maxEl = look.elevation;
          maxElTime = currentTime;
          maxElAz = look.azimuth;
        }
      }

      if (!isAbove && wasAboveHorizon && riseTime != null) {
        // Satellite just set below horizon - record pass
        if (maxEl >= minElevation) {
          passes.add(
            SatellitePass(
              elements: elements,
              riseTime: riseTime,
              riseAzimuth: riseAz,
              maxElevationTime: maxElTime,
              maxElevation: maxEl,
              maxElevationAzimuth: maxElAz,
              setTime: currentTime,
              setAzimuth: look.azimuth,
            ),
          );
        }
        riseTime = null;
        maxEl = 0;
      }

      wasAboveHorizon = isAbove;
      currentTime = currentTime.add(const Duration(seconds: stepSeconds));
    }

    passes.sort((a, b) => a.riseTime.compareTo(b.riseTime));
    return passes;
  }

  /// Compute current positions for a list of satellites.
  ///
  /// This is designed to be called frequently (every few seconds) and is
  /// optimized for batch computation.
  static List<SatelliteData> computePositions({
    required List<OrbitalElements> elements,
    required DateTime time,
    required double observerLatitude,
    required double observerLongitude,
    double observerAltitude = 0,
  }) {
    final utcTime = time.toUtc();
    final jd = Sgp4.julianDate(utcTime);
    final gmst = Sgp4.gstime(jd);
    final sunEci = Sgp4.sunPositionEci(utcTime);

    final results = <SatelliteData>[];

    for (final elem in elements) {
      final result = Sgp4.propagateAt(elem, utcTime);
      if (result == null) continue;

      final geodetic = Sgp4.eciToGeodetic(result.position, gmst);
      final look = Sgp4.eciToLookAngles(
        result.position,
        result.velocity,
        observerLatitude,
        observerLongitude,
        observerAltitude,
        gmst,
      );
      final eclipsed = Sgp4.isEclipsed(result.position, sunEci);
      final (raHours, decDeg) = Sgp4.eciToRaDec(result.position, gmst);

      results.add(
        SatelliteData(
          elements: elem,
          ra: raHours,
          dec: decDeg,
          altitudeKm: geodetic.altitude,
          rangeKm: look.range,
          isEclipsed: eclipsed,
          elevation: look.elevation,
          azimuth: look.azimuth,
        ),
      );
    }

    return results;
  }
}
