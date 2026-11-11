import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

import '../catalogs/catalog_manager.dart';
import '../catalogs/minor_planet_catalog.dart';
import '../catalogs/mpcorb.dart';

/// Refresh cadence for live orbital-element data.
enum ElementRefreshSchedule {
  manual,
  daily,
  weekly,
  monthly;

  Duration? get interval => switch (this) {
    ElementRefreshSchedule.manual => null,
    ElementRefreshSchedule.daily => const Duration(days: 1),
    ElementRefreshSchedule.weekly => const Duration(days: 7),
    ElementRefreshSchedule.monthly => const Duration(days: 30),
  };

  String get displayName => switch (this) {
    ElementRefreshSchedule.manual => 'Manual only',
    ElementRefreshSchedule.daily => 'Daily',
    ElementRefreshSchedule.weekly => 'Weekly',
    ElementRefreshSchedule.monthly => 'Monthly',
  };
}

/// Persisted configuration for the element refresh service.
class ElementRefreshConfig {
  /// MPCORB-format minor-planet source. Defaults to the MPC's yearly
  /// "bright minor planets at opposition" subset (a few hundred objects,
  /// ~60 KB) — the full MPCORB.DAT also parses if pointed at it, filtered
  /// by [maxAsteroidAbsoluteMag]. `{year}` is substituted at fetch time.
  final String asteroidUrl;

  /// MPC current cometary elements source.
  final String cometUrl;

  /// Refresh cadence (default weekly).
  final ElementRefreshSchedule schedule;

  /// Keep only asteroids with H <= this when parsing (bounds memory when
  /// the source is the full MPCORB.DAT; the bright subset is unaffected).
  final double maxAsteroidAbsoluteMag;

  static const String defaultAsteroidUrl =
      'https://www.minorplanetcenter.net/iau/Ephemerides/Bright/{year}/Soft00Bright.txt';
  static const String defaultCometUrl =
      'https://www.minorplanetcenter.net/iau/MPCORB/CometEls.txt';
  static const double defaultMaxAsteroidAbsoluteMag = 14.0;

  /// Defensible bounds for the MPCORB brightness filter. Absolute magnitude
  /// H for minor planets spans roughly 3.3 (the largest, 1 Ceres) to ~33 for
  /// the faintest catalogued near-Earth objects, so `[-5, 40]` comfortably
  /// admits every realistic threshold while rejecting nonsense values
  /// (NaN/infinity, `1e9`, deeply negative) that would silently disable or
  /// balloon the parse.
  static const double minAbsoluteMag = -5.0;
  static const double maxAbsoluteMag = 40.0;

  /// A concrete year substituted for the asteroid URL's `{year}` placeholder
  /// purely to validate the templated form (the real value is filled at fetch
  /// time). Any 4-digit year works — the check only cares that the result is a
  /// well-formed absolute URL.
  static const String _urlValidationYear = '2000';

  const ElementRefreshConfig({
    this.asteroidUrl = defaultAsteroidUrl,
    this.cometUrl = defaultCometUrl,
    this.schedule = ElementRefreshSchedule.weekly,
    this.maxAsteroidAbsoluteMag = defaultMaxAsteroidAbsoluteMag,
  });

  ElementRefreshConfig copyWith({
    String? asteroidUrl,
    String? cometUrl,
    ElementRefreshSchedule? schedule,
    double? maxAsteroidAbsoluteMag,
  }) => ElementRefreshConfig(
    asteroidUrl: asteroidUrl ?? this.asteroidUrl,
    cometUrl: cometUrl ?? this.cometUrl,
    schedule: schedule ?? this.schedule,
    maxAsteroidAbsoluteMag:
        maxAsteroidAbsoluteMag ?? this.maxAsteroidAbsoluteMag,
  );

  Map<String, Object?> toJson() => {
    'asteroidUrl': asteroidUrl,
    'cometUrl': cometUrl,
    'schedule': schedule.name,
    'maxAsteroidAbsoluteMag': maxAsteroidAbsoluteMag,
  };

  /// Parse and **strictly validate** a persisted config.
  ///
  /// A genuinely missing (or explicitly null) optional key falls back to the
  /// constructor default so older config files keep loading, but a key that is
  /// *present* with the wrong type or an out-of-contract value throws a
  /// [FormatException]. Callers ([ElementRefreshService.loadConfig]) surface
  /// that as an unreadable config authority rather than silently manufacturing
  /// defaults over corrupt data.
  factory ElementRefreshConfig.fromJson(Map<String, Object?> json) {
    return ElementRefreshConfig(
      asteroidUrl: _readUrl(
        json,
        'asteroidUrl',
        defaultAsteroidUrl,
        allowYearPlaceholder: true,
      ),
      cometUrl: _readUrl(
        json,
        'cometUrl',
        defaultCometUrl,
        allowYearPlaceholder: false,
      ),
      schedule: _readSchedule(json),
      maxAsteroidAbsoluteMag: _readMag(json),
    );
  }

  /// Throws a [FormatException] if [config] holds a value that could not be
  /// persisted and reloaded (empty/non-http URL, non-finite or out-of-range
  /// H). Runs the same checks [fromJson] enforces so [saveConfig] and
  /// [loadConfig] agree on what "valid" means — we never write a config the
  /// next load would (correctly) reject.
  static void validate(ElementRefreshConfig config) {
    _validateUrl(config.asteroidUrl, 'asteroidUrl', allowYearPlaceholder: true);
    _validateUrl(config.cometUrl, 'cometUrl', allowYearPlaceholder: false);
    _validateMag(config.maxAsteroidAbsoluteMag);
    // `schedule` is a non-nullable enum, so it is always in-range here.
  }

  static bool _isMissing(Map<String, Object?> json, String key) =>
      !json.containsKey(key) || json[key] == null;

  static String _readUrl(
    Map<String, Object?> json,
    String key,
    String fallback, {
    required bool allowYearPlaceholder,
  }) {
    if (_isMissing(json, key)) return fallback;
    final value = json[key];
    if (value is! String) {
      throw FormatException(
        '$key must be a string URL (got ${value.runtimeType}).',
      );
    }
    _validateUrl(value, key, allowYearPlaceholder: allowYearPlaceholder);
    return value;
  }

  static void _validateUrl(
    String url,
    String field, {
    required bool allowYearPlaceholder,
  }) {
    if (url.isEmpty) {
      throw FormatException('$field must not be empty.');
    }
    // The asteroid source is templated with `{year}`; validate the substituted
    // form so a legitimate template is not rejected for the placeholder.
    final probe = allowYearPlaceholder
        ? url.replaceAll('{year}', _urlValidationYear)
        : url;
    final uri = Uri.tryParse(probe);
    if (uri == null ||
        probe.contains('{') ||
        probe.contains('}') ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw FormatException(
        '$field must be an absolute http(s) URL with a host (got "$url").',
      );
    }
  }

  static ElementRefreshSchedule _readSchedule(Map<String, Object?> json) {
    if (_isMissing(json, 'schedule')) return ElementRefreshSchedule.weekly;
    final value = json['schedule'];
    if (value is! String) {
      throw FormatException(
        'schedule must be a string enum name (got ${value.runtimeType}).',
      );
    }
    for (final s in ElementRefreshSchedule.values) {
      if (s.name == value) return s;
    }
    throw FormatException(
      'schedule "$value" is not one of '
      '${ElementRefreshSchedule.values.map((s) => s.name).join(', ')}.',
    );
  }

  static double _readMag(Map<String, Object?> json) {
    if (_isMissing(json, 'maxAsteroidAbsoluteMag')) {
      return defaultMaxAsteroidAbsoluteMag;
    }
    final value = json['maxAsteroidAbsoluteMag'];
    if (value is! num) {
      throw FormatException(
        'maxAsteroidAbsoluteMag must be numeric (got ${value.runtimeType}).',
      );
    }
    final mag = value.toDouble();
    _validateMag(mag);
    return mag;
  }

  static void _validateMag(double mag) {
    if (!mag.isFinite || mag < minAbsoluteMag || mag > maxAbsoluteMag) {
      throw FormatException(
        'maxAsteroidAbsoluteMag must be a finite magnitude within '
        '[$minAbsoluteMag, $maxAbsoluteMag] (got $mag).',
      );
    }
  }
}

/// The current refreshed element sets plus their provenance.
class RefreshedElements {
  final List<MinorBodyElements> asteroids;
  final List<MinorBodyElements> comets;
  final DateTime? asteroidsFetchedAt;
  final DateTime? cometsFetchedAt;
  final String? asteroidRefreshError;
  final String? cometRefreshError;

  const RefreshedElements({
    this.asteroids = const [],
    this.comets = const [],
    this.asteroidsFetchedAt,
    this.cometsFetchedAt,
    this.asteroidRefreshError,
    this.cometRefreshError,
  });

  bool get isEmpty => asteroids.isEmpty && comets.isEmpty;
  List<MinorBodyElements> get all => [...asteroids, ...comets];
  bool get hasRefreshFailures =>
      asteroidRefreshError != null || cometRefreshError != null;

  String? get refreshFailureSummary {
    final failures = <String>[
      if (asteroidRefreshError != null) 'Asteroids: $asteroidRefreshError',
      if (cometRefreshError != null) 'Comets: $cometRefreshError',
    ];
    return failures.isEmpty ? null : failures.join(' • ');
  }

  /// Oldest fetch time across the populated sets (for the staleness check
  /// and the "last updated" indicator).
  DateTime? get oldestFetch {
    final times = [
      if (asteroids.isNotEmpty && asteroidsFetchedAt != null)
        asteroidsFetchedAt!,
      if (comets.isNotEmpty && cometsFetchedAt != null) cometsFetchedAt!,
    ];
    if (times.isEmpty) return null;
    times.sort();
    return times.first;
  }
}

/// Fetches and caches live minor-planet (MPC) orbital elements on a
/// configurable schedule, offline-safe.
///
/// * Raw downloads are cached on disk (`mpc_asteroids.txt`,
///   `mpc_comets.txt`) next to the other catalogs, with fetch timestamps in
///   `element_refresh_metadata.json` — a failed refresh falls back to the
///   stale cache, and [loadCached] never touches the network.
/// * Satellite TLEs already have their own download/cache path
///   (`SatelliteCatalog`); this service only tracks/triggers it so one
///   "refresh" action covers all live element data.
class ElementRefreshService {
  final String _directory;
  final http.Client Function() _clientFactory;
  final DateTime Function() _now;
  final Duration _requestTimeout;

  /// Failed scheduled attempts are held off for an hour. This is short enough
  /// to recover during an observing day but prevents every app restart from
  /// hammering the MPC while it (or the network) is down.
  static const Duration autoRetryCooldown = Duration(hours: 1);

  ElementRefreshService({
    String? cacheDirectory,
    http.Client Function()? clientFactory,
    DateTime Function()? now,
    Duration requestTimeout = const Duration(seconds: 30),
  }) : _directory = cacheDirectory ?? CatalogManager.instance.catalogDirectory,
       _clientFactory = clientFactory ?? http.Client.new,
       _now = now ?? DateTime.now,
       _requestTimeout = requestTimeout {
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(
        requestTimeout,
        'requestTimeout',
        'must be positive',
      );
    }
  }

  String get _asteroidCachePath => path.join(_directory, 'mpc_asteroids.txt');
  String get _cometCachePath => path.join(_directory, 'mpc_comets.txt');
  String get _configPath =>
      path.join(_directory, 'element_refresh_config.json');
  String get _metaPath =>
      path.join(_directory, 'element_refresh_metadata.json');

  // Config + metadata

  /// Load the persisted refresh config.
  ///
  /// A **missing** config file is a legitimate first run and returns the
  /// default config. But an *existing* file that cannot be read, is not valid
  /// JSON, is not a JSON object, or fails schema validation throws
  /// ([StateError] for I/O, [FormatException] for content) instead of silently
  /// returning defaults — a corrupt config authority must be visible, not
  /// masqueraded as a legitimate weekly/default-source setup.
  Future<ElementRefreshConfig> loadConfig() async {
    final file = File(_configPath);
    if (!await file.exists()) {
      return const ElementRefreshConfig();
    }

    final String raw;
    try {
      raw = await file.readAsString();
    } catch (e) {
      throw StateError(
        'Unable to read element refresh config at $_configPath: $e',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw FormatException(
        'element_refresh_config.json is not valid JSON: ${e.message}',
      );
    }
    if (decoded is! Map) {
      throw const FormatException(
        'element_refresh_config.json must contain a JSON object.',
      );
    }
    return ElementRefreshConfig.fromJson(decoded.cast<String, Object?>());
  }

  /// Persist [config] atomically.
  ///
  /// Validates first so we never write a config the next [loadConfig] would
  /// reject. Writes to a same-directory temp file and renames it over the live
  /// path: `rename(2)` (POSIX) and `MoveFileEx(MOVEFILE_REPLACE_EXISTING)`
  /// (Windows, which is how dart:io implements [File.rename]) both swap the
  /// file in place, so an interruption mid-write can never leave a
  /// half-written `element_refresh_config.json` — the previous valid file
  /// survives untouched until the rename commits. A failed write cleans up the
  /// temp file and rethrows, leaving the prior config intact.
  Future<void> saveConfig(ElementRefreshConfig config) async {
    ElementRefreshConfig.validate(config);
    await _writeTextAtomically(_configPath, jsonEncode(config.toJson()));
  }

  Future<Map<String, Object?>> _loadMeta() async {
    try {
      final file = File(_metaPath);
      if (await file.exists()) {
        return (jsonDecode(await file.readAsString()) as Map)
            .cast<String, Object?>();
      }
    } catch (e) {
      // A corrupt meta file only loses the "last refreshed" bookkeeping; the
      // next save rewrites it. Log so repeated parse failures are visible.
      developer.log(
        'ElementRefreshService: failed to read refresh metadata: $e',
        name: 'skotiq.planetarium',
      );
    }
    return {};
  }

  Future<void> _saveMeta(Map<String, Object?> meta) async {
    await _writeTextAtomically(_metaPath, jsonEncode(meta));
  }

  /// When a refresh was last *attempted* (success or failure). Used to avoid
  /// hammering the MPC after a failure when auto-refresh re-checks.
  Future<DateTime?> lastAttempt() async {
    final meta = await _loadMeta();
    return DateTime.tryParse(meta['lastAttempt'] as String? ?? '');
  }

  bool isAutoRetryDue(DateTime? lastAttemptAt) {
    if (lastAttemptAt == null) return true;
    final elapsed = _now().difference(lastAttemptAt);
    // A future timestamp means the wall clock moved backwards or metadata is
    // bad. Do not suppress refresh indefinitely on that basis.
    return elapsed.isNegative || elapsed >= autoRetryCooldown;
  }

  // Load / refresh

  /// Load the cached element sets from disk. Never touches the network;
  /// returns an empty set when nothing is cached.
  Future<RefreshedElements> loadCached() async {
    final meta = await _loadMeta();
    // Cached element reads must stay offline-safe even when the config
    // authority is corrupt: only the parse threshold is needed here, so fall
    // back to defaults rather than failing the whole cache load. Config
    // corruption is surfaced separately by [loadConfig] / the config provider,
    // not conflated with cache availability.
    ElementRefreshConfig config;
    try {
      config = await loadConfig();
    } catch (e) {
      developer.log(
        '[ElementRefresh] config unreadable; using default parse threshold '
        'for cached elements: $e',
        name: 'ElementRefreshService',
        level: 900,
      );
      config = const ElementRefreshConfig();
    }

    Future<(List<MinorBodyElements>, DateTime?)> read(
      String filePath,
      String metaKey,
      List<MinorBodyElements> Function(String) parse,
    ) async {
      final file = File(filePath);
      if (!await file.exists()) return (const <MinorBodyElements>[], null);
      try {
        final parsed = parse(await file.readAsString());
        final fetched =
            DateTime.tryParse(meta[metaKey] as String? ?? '') ??
            (await file.stat()).modified;
        return (parsed, fetched);
      } catch (e) {
        developer.log(
          '[ElementRefresh] cache read error ($filePath): $e',
          name: 'ElementRefreshService',
          level: 900,
          error: e,
        );
        return (const <MinorBodyElements>[], null);
      }
    }

    final (asteroids, asteroidsAt) = await read(
      _asteroidCachePath,
      'asteroidsFetchedAt',
      (text) => MpcOrbParser.parseAsteroids(
        text,
        maxAbsoluteMag: config.maxAsteroidAbsoluteMag,
      ),
    );
    final (comets, cometsAt) = await read(
      _cometCachePath,
      'cometsFetchedAt',
      MpcOrbParser.parseComets,
    );

    return RefreshedElements(
      asteroids: asteroids,
      comets: comets,
      asteroidsFetchedAt: asteroidsAt,
      cometsFetchedAt: cometsAt,
    );
  }

  /// Whether the cached data is older than the configured schedule allows.
  /// Manual schedule never reports stale.
  bool isStale(RefreshedElements cached, ElementRefreshConfig config) {
    final interval = config.schedule.interval;
    if (interval == null) return false;
    final oldest = cached.oldestFetch;
    if (cached.isEmpty || oldest == null) return true;
    return _now().difference(oldest) > interval;
  }

  /// Download fresh element sets, update the disk cache, and return the
  /// merged result. On a download failure the stale cached set for that
  /// source is kept (offline-safe); throws only if BOTH sources fail AND
  /// nothing is cached.
  Future<RefreshedElements> refresh({ElementRefreshConfig? config}) async {
    final cfg = config ?? await loadConfig();
    final cached = await loadCached();
    final meta = await _loadMeta();
    meta['lastAttempt'] = _now().toIso8601String();

    var asteroids = cached.asteroids;
    var asteroidsAt = cached.asteroidsFetchedAt;
    var comets = cached.comets;
    var cometsAt = cached.cometsFetchedAt;
    Object? asteroidError;
    Object? cometError;

    final client = _clientFactory();
    try {
      // Asteroids (MPCORB 1-line format).
      try {
        final url = cfg.asteroidUrl.replaceAll(
          '{year}',
          _now().toUtc().year.toString(),
        );
        final text = await _fetchText(client, url);
        final parsed = MpcOrbParser.parseAsteroids(
          text,
          maxAbsoluteMag: cfg.maxAsteroidAbsoluteMag,
        );
        if (parsed.isEmpty) {
          throw FormatException('No parsable MPCORB records from $url');
        }
        await _writeTextAtomically(_asteroidCachePath, text);
        asteroids = parsed;
        asteroidsAt = _now();
        meta['asteroidsFetchedAt'] = asteroidsAt.toIso8601String();
        meta['asteroidsUrl'] = url;
        meta['asteroidsCount'] = parsed.length;
      } catch (e) {
        asteroidError = e;
        developer.log(
          '[ElementRefresh] asteroid refresh failed: $e',
          name: 'ElementRefreshService',
          level: 900,
          error: e,
        );
      }

      // Comets (CometEls.txt format).
      try {
        final text = await _fetchText(client, cfg.cometUrl);
        final parsed = MpcOrbParser.parseComets(text);
        if (parsed.isEmpty) {
          throw FormatException(
            'No parsable comet records from ${cfg.cometUrl}',
          );
        }
        await _writeTextAtomically(_cometCachePath, text);
        comets = parsed;
        cometsAt = _now();
        meta['cometsFetchedAt'] = cometsAt.toIso8601String();
        meta['cometsUrl'] = cfg.cometUrl;
        meta['cometsCount'] = parsed.length;
      } catch (e) {
        cometError = e;
        developer.log(
          '[ElementRefresh] comet refresh failed: $e',
          name: 'ElementRefreshService',
          level: 900,
          error: e,
        );
      }
    } finally {
      client.close();
      await _saveMeta(meta);
    }

    final result = RefreshedElements(
      asteroids: asteroids,
      comets: comets,
      asteroidsFetchedAt: asteroidsAt,
      cometsFetchedAt: cometsAt,
      asteroidRefreshError: asteroidError?.toString(),
      cometRefreshError: cometError?.toString(),
    );
    if (result.isEmpty && result.hasRefreshFailures) {
      throw Exception(
        'Element refresh failed: ${result.refreshFailureSummary}',
      );
    }
    return result;
  }

  Future<String> _fetchText(http.Client client, String url) async {
    final response = await client
        .get(Uri.parse(url), headers: {'User-Agent': 'Skotiq/5.0'})
        .timeout(_requestTimeout);
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
    }
    List<int> bytes = response.bodyBytes;
    if (url.endsWith('.gz')) {
      bytes = gzip.decode(bytes);
    }
    return utf8.decode(bytes);
  }

  Future<void> _writeTextAtomically(String destination, String contents) async {
    await Directory(path.dirname(destination)).create(recursive: true);
    final temp = File(
      '$destination.${pid}_${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temp.writeAsString(contents, flush: true);
      await temp.rename(destination);
    } finally {
      if (await temp.exists()) {
        try {
          await temp.delete();
        } catch (_) {
          // Best-effort cleanup. Readers never consider temporary files.
        }
      }
    }
  }
}
