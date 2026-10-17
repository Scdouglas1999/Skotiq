import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../models/alerts/transient_alert.dart';
import 'logging_service.dart';

/// An enabled transient-alert source could not provide a trustworthy result.
class TransientAlertFetchException implements Exception {
  const TransientAlertFetchException(this.source, this.message, [this.cause]);

  final String source;
  final String message;
  final Object? cause;

  @override
  String toString() {
    final causeText = cause == null ? '' : ' ($cause)';
    return 'Transient alert fetch failed for $source: $message$causeText';
  }
}

class _TransientFetchOutcome {
  const _TransientFetchOutcome.success(this.source, this.alerts) : error = null;

  const _TransientFetchOutcome.failure(this.source, this.error) : alerts = null;

  final TransientSource source;
  final List<TransientAlert>? alerts;
  final Object? error;

  bool get succeeded => error == null;
}

class _TnsObjectOutcome {
  const _TnsObjectOutcome.success(this.alert) : error = null;

  const _TnsObjectOutcome.failure(this.error) : alert = null;

  final TransientAlert? alert;
  final Object? error;
}

/// Service for fetching astronomical transient alerts from external APIs.
///
/// Transient alerts notify astronomers of time-critical events like novae,
/// supernovae, and other variable star outbursts that require prompt observation.
///
/// Supported source:
/// - TNS (Transient Name Server) - uses the authenticated Search/Get APIs.
///   It is the ONLY source this service fetches; see the note in the class
///   body for why AAVSO/VSX is not one, and [TransientSource] for the rest.
///
/// Usage:
/// ```dart
/// final service = TransientAlertService(httpClient: http.Client(), logger: loggingService);
/// final alerts = await service.getAllAlerts(settings);
/// ```
class TransientAlertService {
  /// HTTP client for making API requests.
  final http.Client _httpClient;

  /// Logging service for error and debug logging.
  final LoggingService _logger;

  /// Cached alerts from the last fetch.
  List<TransientAlert>? _cachedAlerts;

  /// Expiration time of the current cache.
  DateTime? _cacheExpiry;

  /// The enabled upstreams and TNS bot identity the cache was populated from.
  /// Filtering-only changes can reuse a cache, but enabling a new source or
  /// changing credentials must fetch again instead of serving a stale
  /// snapshot for another 15 minutes.
  String? _cacheFetchSignature;

  /// Cache time-to-live duration (15 minutes).
  static const Duration _cacheTtl = Duration(minutes: 15);

  /// Creates a new transient alert service instance.
  ///
  /// Parameters:
  /// - [httpClient]: HTTP client for API requests
  /// - [logger]: Logging service for error reporting
  TransientAlertService({
    required http.Client httpClient,
    required LoggingService logger,
  }) : _httpClient = httpClient,
       _logger = logger;

  /// Whether the cache is still valid and has not expired.
  bool get isCacheValid {
    if (_cachedAlerts == null || _cacheExpiry == null) {
      return false;
    }
    return DateTime.now().isBefore(_cacheExpiry!);
  }

  /// Clears the cached alerts, forcing a fresh fetch on next request.
  void clearCache() {
    _cachedAlerts = null;
    _cacheExpiry = null;
    _cacheFetchSignature = null;
    _logger.debug(
      'Transient alert cache cleared',
      source: 'TransientAlertService',
    );
  }

  // AAVSO/VSX is intentionally not fetchable here: it has no supported recent
  // alert-notice endpoint. TNS is the sole external feed and requires bot
  // credentials; manual and imported alerts remain local sources.

  double? _finiteDoubleOrNull(String? raw) {
    if (raw == null) return null;
    final value = double.tryParse(raw.trim());
    return value != null && value.isFinite ? value : null;
  }

  /// Parses RA string in HMS format (e.g., "18:23:54.67") to hours.
  double? _parseRaString(String raStr) {
    try {
      final parts = raStr.trim().split(':');
      if (parts.length < 2) {
        // Try parsing as decimal hours
        final value = double.tryParse(raStr.trim());
        return value != null && value.isFinite && value >= 0 && value < 24
            ? value
            : null;
      }
      if (parts.length > 3) return null;

      final hours = double.parse(parts[0]);
      final minutes = double.parse(parts[1]);
      final seconds = parts.length > 2 ? double.parse(parts[2]) : 0.0;

      if (!hours.isFinite ||
          !minutes.isFinite ||
          !seconds.isFinite ||
          hours < 0 ||
          hours >= 24 ||
          minutes < 0 ||
          minutes >= 60 ||
          seconds < 0 ||
          seconds >= 60) {
        return null;
      }

      return hours + minutes / 60.0 + seconds / 3600.0;
    } catch (e) {
      return null;
    }
  }

  /// Parses Dec string in DMS format (e.g., "+23:45:12.3") to degrees.
  double? _parseDecString(String decStr) {
    try {
      // Handle sign
      final trimmed = decStr.trim();
      final isNegative = trimmed.startsWith('-');
      final cleanStr = trimmed.replaceFirst('+', '').replaceFirst('-', '');

      final parts = cleanStr.split(':');
      if (parts.length < 2) {
        // Try parsing as decimal degrees
        final value = double.tryParse(trimmed);
        return value != null && value.isFinite && value >= -90 && value <= 90
            ? value
            : null;
      }
      if (parts.length > 3) return null;

      final degrees = double.parse(parts[0]).abs();
      final arcminutes = double.parse(parts[1]);
      final arcseconds = parts.length > 2 ? double.parse(parts[2]) : 0.0;

      if (!degrees.isFinite ||
          !arcminutes.isFinite ||
          !arcseconds.isFinite ||
          degrees > 90 ||
          arcminutes < 0 ||
          arcminutes >= 60 ||
          arcseconds < 0 ||
          arcseconds >= 60 ||
          (degrees == 90 && (arcminutes != 0 || arcseconds != 0))) {
        return null;
      }

      final result = degrees + arcminutes / 60.0 + arcseconds / 3600.0;
      return isNegative ? -result : result;
    } catch (e) {
      return null;
    }
  }

  /// Calculates alert priority (1-10, 1=highest) based on type and magnitude.
  int _calculatePriority(TransientType type, double? magnitude) {
    int basePriority;

    // Type-based priority
    switch (type) {
      case TransientType.supernova:
        basePriority = 1;
      case TransientType.gammaRayBurst:
        basePriority = 2;
      case TransientType.nova:
        basePriority = 3;
      case TransientType.cataclysmic:
        basePriority = 4;
      case TransientType.comet:
        basePriority = 5;
      case TransientType.asteroid:
        basePriority = 6;
      case TransientType.variableStar:
        basePriority = 7;
      case TransientType.other:
        basePriority = 8;
    }

    // Adjust for brightness (brighter objects are higher priority)
    if (magnitude != null) {
      if (magnitude < 8.0) {
        basePriority = (basePriority - 2).clamp(1, 10);
      } else if (magnitude < 12.0) {
        basePriority = (basePriority - 1).clamp(1, 10);
      } else if (magnitude > 16.0) {
        basePriority = (basePriority + 1).clamp(1, 10);
      }
    }

    return basePriority;
  }

  /// Fetches recent transient alerts from TNS (Transient Name Server).
  ///
  /// TNS requires a complete bot identity and API key. Direct calls with no
  /// credentials return an empty list because the source is disabled. A
  /// configured request that fails throws [TransientAlertFetchException].
  ///
  /// To obtain an API key:
  /// 1. Create an account at https://www.wis-tns.org/
  /// 2. Request API access in your account settings
  /// 3. Configure the key in Skotiq settings
  ///
  /// See: https://www.wis-tns.org/content/tns-api-overview
  Future<List<TransientAlert>> fetchTnsAlerts({
    String? apiKey,
    int? botId,
    String? botName,
    bool useSandbox = false,
  }) async {
    // TNS Search/Get requires the API key plus the mandatory tns_marker
    // identity header. An API key alone is not a usable configuration.
    final trimmedKey = apiKey?.trim() ?? '';
    final trimmedName = botName?.trim() ?? '';
    final noCredentials =
        trimmedKey.isEmpty && botId == null && trimmedName.isEmpty;
    if (noCredentials) {
      _logger.warning(
        'TNS credentials are not configured - TNS alerts disabled.',
        source: 'TransientAlertService',
      );
      return [];
    }
    if (trimmedKey.isEmpty ||
        botId == null ||
        botId <= 0 ||
        trimmedName.isEmpty) {
      throw const TransientAlertFetchException(
        'TNS',
        'bot credentials are incomplete; configure the bot id, bot name, '
            'and API key in Science settings',
      );
    }

    _logger.debug(
      'Fetching transients from TNS',
      source: 'TransientAlertService',
    );

    try {
      final base = useSandbox
          ? 'https://sandbox.wis-tns.org/api'
          : 'https://www.wis-tns.org/api';
      final marker =
          'tns_marker'
          '{"tns_id":$botId,"type":"bot",'
          '"name":"${trimmedName.replaceAll('"', r'\"')}"}';
      final headers = {'User-Agent': marker};

      // Search returns object identifiers only. Request a bounded recent page,
      // then resolve each object through Get Object for coordinates,
      // classification, discovery magnitude, and timestamps.
      final response = await _httpClient
          .post(
            Uri.parse('$base/get/search'),
            headers: headers,
            body: {
              'api_key': trimmedKey,
              'data': json.encode({
                'discovered_period_value': '30',
                'discovered_period_units': 'days',
                'num_page': '20',
                'page': '0',
              }),
            },
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final names = _parseTnsSearchResponse(json.decode(response.body));
        final alerts = <TransientAlert>[];
        var failedObjects = 0;
        // Keep concurrency modest so one refresh does not consume the bot's
        // entire per-minute Search/Get quota at once.
        for (var start = 0; start < names.length; start += 4) {
          final end = start + 4 < names.length ? start + 4 : names.length;
          final batch = await Future.wait(
            names.sublist(start, end).map((name) async {
              try {
                return _TnsObjectOutcome.success(
                  await _fetchTnsObject(
                    base: base,
                    headers: headers,
                    apiKey: trimmedKey,
                    objectName: name,
                  ),
                );
              } catch (error) {
                return _TnsObjectOutcome.failure(error);
              }
            }),
          );
          for (final outcome in batch) {
            final alert = outcome.alert;
            if (alert != null) {
              alerts.add(alert);
            } else {
              failedObjects++;
              _logger.warning(
                'TNS object lookup failed: ${outcome.error}',
                source: 'TransientAlertService',
              );
            }
          }
        }
        if (names.isNotEmpty && alerts.isEmpty) {
          throw TransientAlertFetchException(
            'TNS',
            'all $failedObjects object lookups failed',
          );
        }
        if (failedObjects > 0) {
          _logger.warning(
            'TNS returned $failedObjects unusable objects; retained '
            '${alerts.length} valid alerts',
            source: 'TransientAlertService',
          );
        }
        return alerts;
      } else if (response.statusCode == 401 || response.statusCode == 403) {
        throw const TransientAlertFetchException(
          'TNS',
          'authentication failed; check the bot identity and API key',
        );
      } else {
        throw TransientAlertFetchException(
          'TNS',
          'HTTP ${response.statusCode}: '
              '${response.reasonPhrase ?? 'request failed'}',
        );
      }
    } on TransientAlertFetchException catch (error) {
      _logger.error(error.toString(), source: 'TransientAlertService');
      rethrow;
    } catch (error) {
      final failure = TransientAlertFetchException(
        'TNS',
        'request or response parsing failed',
        error,
      );
      _logger.error(failure.toString(), source: 'TransientAlertService');
      throw failure;
    }
  }

  List<String> _parseTnsSearchResponse(dynamic decoded) {
    if (decoded is! Map) {
      throw const TransientAlertFetchException(
        'TNS',
        'search response was not an object',
      );
    }
    final data = decoded['data'];
    if (data is! Map) {
      throw const TransientAlertFetchException(
        'TNS',
        'search response had no data object',
      );
    }
    final reply = data['reply'];
    if (reply is! List) {
      throw const TransientAlertFetchException(
        'TNS',
        'search response had no reply list',
      );
    }
    final names = <String>[];
    var rejected = 0;
    for (final item in reply) {
      if (item is! Map) {
        rejected++;
        continue;
      }
      final name = item['objname']?.toString().trim() ?? '';
      if (name.isNotEmpty) {
        names.add(name);
      } else {
        rejected++;
      }
    }
    if (names.isEmpty && rejected > 0) {
      throw TransientAlertFetchException(
        'TNS',
        'all $rejected search results were malformed',
      );
    }
    if (rejected > 0) {
      _logger.warning(
        'TNS search returned $rejected malformed results; retained '
        '${names.length} valid names',
        source: 'TransientAlertService',
      );
    }
    return names;
  }

  Future<TransientAlert> _fetchTnsObject({
    required String base,
    required Map<String, String> headers,
    required String apiKey,
    required String objectName,
  }) async {
    final response = await _httpClient
        .post(
          Uri.parse('$base/get/object'),
          headers: headers,
          body: {
            'api_key': apiKey,
            'data': json.encode({'objname': objectName}),
          },
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw TransientAlertFetchException(
        'TNS',
        'Get Object for $objectName returned HTTP ${response.statusCode}',
      );
    }
    final decoded = json.decode(response.body);
    if (decoded is! Map) {
      throw TransientAlertFetchException(
        'TNS',
        'Get Object for $objectName returned a non-object response',
      );
    }
    final data = decoded['data'];
    if (data is! Map) {
      throw TransientAlertFetchException(
        'TNS',
        'Get Object for $objectName returned no data object',
      );
    }
    final reply = data['reply'];
    if (reply is! Map) {
      throw TransientAlertFetchException(
        'TNS',
        'Get Object for $objectName returned no reply object',
      );
    }
    final alert = _parseTnsObject(Map<String, dynamic>.from(reply));
    if (alert == null) {
      throw TransientAlertFetchException(
        'TNS',
        'Get Object for $objectName returned malformed alert data',
      );
    }
    return alert;
  }

  TransientAlert? _parseTnsObject(Map<String, dynamic> obj) {
    final raHours = _parseRaString(obj['ra']?.toString() ?? '');
    final decDegrees = _parseDecString(obj['dec']?.toString() ?? '');
    if (raHours == null || decDegrees == null) return null;

    final objectType = obj['object_type'];
    final classification = objectType is Map
        ? objectType['name']?.toString().trim() ?? ''
        : objectType?.toString().trim() ?? '';
    final type = _classifyTnsObject(classification);
    final magnitude = _finiteDoubleOrNull(
      (obj['discoverymag'] ?? obj['discovermag'])?.toString(),
    );
    final objectName = obj['objname']?.toString().trim() ?? '';
    if (objectName.isEmpty) return null;
    final prefix = obj['name_prefix']?.toString().trim() ?? '';
    final displayName = objectName.startsWith(prefix)
        ? objectName
        : '$prefix$objectName';
    final discoveryTime = DateTime.tryParse(
      obj['discoverydate']?.toString() ?? '',
    );
    if (discoveryTime == null) return null;
    final lastUpdated =
        DateTime.tryParse(obj['lastmodified']?.toString() ?? '') ??
        discoveryTime;
    final objectId = obj['objid']?.toString().trim();

    return TransientAlert(
      id: 'tns_${objectId == null || objectId.isEmpty ? objectName : objectId}',
      name: displayName,
      type: type,
      raHours: raHours,
      decDegrees: decDegrees,
      magnitude: magnitude,
      peakMagnitude: magnitude,
      discoveryTime: discoveryTime,
      lastUpdated: lastUpdated,
      source: TransientSource.tns,
      sourceUrl: 'https://www.wis-tns.org/object/$objectName',
      priority: _calculatePriority(type, magnitude),
      classification: classification.isEmpty ? null : classification,
    );
  }

  /// Classifies a TNS object type string to our TransientType enum.
  TransientType _classifyTnsObject(String classification) {
    final lower = classification.toLowerCase();
    if (lower.contains('sn ia') || lower.contains('type ia')) {
      return TransientType.supernova;
    }
    if (lower.contains('sn ii') ||
        lower.contains('sn ib') ||
        lower.contains('sn ic')) {
      return TransientType.supernova;
    }
    if (lower.contains('nova')) {
      return TransientType.nova;
    }
    if (lower.contains('cv') || lower.contains('cataclysmic')) {
      return TransientType.cataclysmic;
    }
    if (lower.contains('grb') || lower.contains('gamma')) {
      return TransientType.gammaRayBurst;
    }
    return TransientType.other;
  }

  /// Fetches all alerts from enabled sources and filters by settings.
  ///
  /// Implements caching to avoid excessive API calls. Cache TTL is 15 minutes.
  ///
  /// Parameters:
  /// - [settings]: Alert settings controlling which sources and types to include
  ///
  /// Returns a filtered, deduplicated, and sorted list of alerts.
  Future<List<TransientAlert>> getAllAlerts(
    TransientAlertSettings settings, {
    int? tnsBotId,
    String? tnsBotName,
    bool tnsUseSandbox = false,
  }) async {
    final fetchSignature = _fetchSignature(
      settings,
      tnsBotId: tnsBotId,
      tnsBotName: tnsBotName,
      tnsUseSandbox: tnsUseSandbox,
    );
    // Check cache first
    if (isCacheValid &&
        _cachedAlerts != null &&
        _cacheFetchSignature == fetchSignature) {
      _logger.debug(
        'Returning cached alerts (${_cachedAlerts!.length} total)',
        source: 'TransientAlertService',
      );
      return _filterAlerts(_cachedAlerts!, settings);
    }

    _logger.debug(
      'Fetching alerts from enabled sources',
      source: 'TransientAlertService',
    );

    // Fetch from enabled sources in parallel. One successful source is enough
    // to retain useful results, but a refresh where every attempted source
    // fails must not be cached as a trustworthy empty feed.
    final futures = <Future<_TransientFetchOutcome>>[];

    if (settings.enabledSources.contains(TransientSource.tns)) {
      if (settings.tnsApiKey != null && settings.tnsApiKey!.isNotEmpty) {
        futures.add(
          _fetchOutcome(
            TransientSource.tns,
            fetchTnsAlerts(
              apiKey: settings.tnsApiKey,
              botId: tnsBotId,
              botName: tnsBotName,
              useSandbox: tnsUseSandbox,
            ),
          ),
        );
      } else {
        // An enabled TNS source without credentials is a setup state, not a
        // failed network fetch. Leave it out of this refresh; the UI can point
        // the operator to Science settings while manual/local alerts remain
        // usable.
      }
    }

    final results = await Future.wait(futures);
    final failures = results.where((result) => !result.succeeded).toList();
    final successes = results.where((result) => result.succeeded).toList();
    if (results.isNotEmpty && successes.isEmpty) {
      final detail = failures
          .map((failure) => '${failure.source.name}: ${failure.error}')
          .join('; ');
      throw TransientAlertFetchException(
        'enabled sources',
        'none completed successfully',
        detail,
      );
    }
    if (failures.isNotEmpty) {
      _logger.warning(
        'Transient refresh was partially successful: '
        '${failures.map((failure) => failure.error).join('; ')}',
        source: 'TransientAlertService',
      );
    }

    // Combine all alerts
    final allAlerts = <TransientAlert>[];
    for (final result in successes) {
      allAlerts.addAll(result.alerts!);
    }

    // Deduplicate by name (case-insensitive)
    final seen = <String>{};
    final deduplicatedAlerts = <TransientAlert>[];
    for (final alert in allAlerts) {
      final key = alert.name.toLowerCase().trim();
      if (!seen.contains(key)) {
        seen.add(key);
        deduplicatedAlerts.add(alert);
      }
    }

    // Update cache
    _cachedAlerts = deduplicatedAlerts;
    _cacheExpiry = DateTime.now().add(_cacheTtl);
    _cacheFetchSignature = fetchSignature;

    _logger.info(
      'Fetched ${deduplicatedAlerts.length} unique alerts, cache updated',
      source: 'TransientAlertService',
    );

    return _filterAlerts(deduplicatedAlerts, settings);
  }

  Future<_TransientFetchOutcome> _fetchOutcome(
    TransientSource source,
    Future<List<TransientAlert>> fetch,
  ) async {
    try {
      return _TransientFetchOutcome.success(source, await fetch);
    } catch (error) {
      return _TransientFetchOutcome.failure(source, error);
    }
  }

  String _fetchSignature(
    TransientAlertSettings settings, {
    required int? tnsBotId,
    required String? tnsBotName,
    required bool tnsUseSandbox,
  }) {
    final implementedSources =
        settings.enabledSources
            .where(kFetchableTransientSources.contains)
            .map((source) => source.name)
            .toList()
          ..sort();
    // Kept only in memory and never logged. Including the key means replacing
    // a credential cannot reuse data authenticated as the prior bot.
    return '${implementedSources.join(',')}|${tnsBotId ?? 0}|'
        '${tnsBotName?.trim() ?? ''}|$tnsUseSandbox|'
        '${settings.tnsApiKey?.trim() ?? ''}';
  }

  /// Filters alerts based on user settings.
  List<TransientAlert> _filterAlerts(
    List<TransientAlert> alerts,
    TransientAlertSettings settings,
  ) {
    var filtered = alerts.where((alert) {
      // Filter by type
      if (!settings.typesToMonitor.contains(alert.type)) {
        return false;
      }

      // Filter by magnitude threshold (only if magnitude is known)
      if (alert.magnitude != null &&
          alert.magnitude! > settings.magnitudeThreshold) {
        return false;
      }

      // Filter by source
      if (!settings.enabledSources.contains(alert.source)) {
        return false;
      }

      return true;
    }).toList();

    // Sort by priority (ascending, 1=highest) then by discovery time (newest first)
    filtered.sort((a, b) {
      final priorityCompare = a.priority.compareTo(b.priority);
      if (priorityCompare != 0) {
        return priorityCompare;
      }
      return b.discoveryTime.compareTo(a.discoveryTime);
    });

    return filtered;
  }

  /// Determines if an alert should trigger a notification.
  ///
  /// Returns true if the alert matches the notification criteria:
  /// - Alert type is being monitored
  /// - Magnitude is below the notification threshold (brighter)
  /// - If autoQueueBright is enabled, checks if brighter than autoQueueMagnitude
  ///
  /// Parameters:
  /// - [alert]: The alert to check
  /// - [settings]: Current alert settings
  bool shouldNotify(TransientAlert alert, TransientAlertSettings settings) {
    // Must be a monitored type
    if (!settings.typesToMonitor.contains(alert.type)) {
      return false;
    }

    // Must be from an enabled source
    if (!settings.enabledSources.contains(alert.source)) {
      return false;
    }

    // Check magnitude threshold (if magnitude is known)
    if (alert.magnitude != null) {
      // Alert must be brighter than (less than) the threshold
      if (alert.magnitude! > settings.magnitudeThreshold) {
        return false;
      }
    }

    // Check auto-queue criteria for bright transients
    if (settings.autoQueueBright) {
      if (alert.magnitude != null &&
          alert.magnitude! <= settings.autoQueueMagnitude) {
        // This is a bright transient that should be auto-queued
        return true;
      }
    }

    // Notify for any alert that passes magnitude and type filters
    return settings.notifyOnNew;
  }

  /// Closes the HTTP client and releases resources.
  void dispose() {
    _httpClient.close();
    _logger.debug(
      'TransientAlertService disposed',
      source: 'TransientAlertService',
    );
  }
}

/// Provider for the transient alert service.
final transientAlertServiceProvider = Provider<TransientAlertService>((ref) {
  final logger = ref.watch(loggingServiceProvider);
  final service = TransientAlertService(
    httpClient: http.Client(),
    logger: logger,
  );

  ref.onDispose(() {
    service.dispose();
  });

  return service;
});
