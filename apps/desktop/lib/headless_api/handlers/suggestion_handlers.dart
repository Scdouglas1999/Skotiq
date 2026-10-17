import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// Handlers for target suggestion service
class SuggestionHandlers {
  final ProviderContainer container;

  SuggestionHandlers(this.container);

  /// Upper bound for the `maxResults` page size. Suggestions are computed over
  /// the user's own targets and sliced with `take(maxResults)`; 1000 is far more
  /// than any "tonight" list surfaces while keeping the value sane.
  static const int _maxSuggestionResults = 1000;

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'SuggestionHandlers');

  // Why: a malformed `/api/suggestions/score/{targetId}` path would otherwise
  // surface a FormatException → 500. Throw BadRequestError so the middleware
  // returns a structured 400.
  int _parsePathId(String raw, String field) {
    final parsed = int.tryParse(raw);
    if (parsed == null) {
      throw BadRequestError(field: field, expected: 'integer');
    }
    return parsed;
  }

  // Get suggestions for tonight

  Future<Response> handleGetSuggestionsForTonight(Request request) async {
    _logInfo('[API] GET /api/suggestions/tonight');

    // Validate every query parameter BEFORE touching the database so a
    // malformed request fails closed with a 400 and does no work. Each optional
    // param keeps its documented default only when absent; a supplied but
    // invalid value (NaN, out of the service range, a bogus sort mode, a
    // non-boolean flag) is a 400 rather than silently snapping to the default.
    final query = request.url.queryParameters;

    // Altitude filter is in degrees; the sky spans -90..90 (negatives are valid
    // for below-horizon inclusion, as the per-target score endpoint uses).
    final minAltitude =
        optionalQueryDouble(query, 'minAltitude', min: -90, max: 90) ?? 30.0;
    // Score is documented 0..100 (TargetSuggestionConfig.minScore).
    final minScore =
        optionalQueryDouble(query, 'minScore', min: 0, max: 100) ?? 0.0;
    // maxResults bounds `suggestions.take(maxResults)`: a negative would throw a
    // RangeError, so require a positive, sanely-bounded whole number.
    final maxResults =
        optionalQueryInt(
          query,
          'maxResults',
          min: 1,
          max: _maxSuggestionResults,
        ) ??
        20;
    // Absent means false; a supplied non-boolean is a 400.
    final prioritizeIncomplete =
        optionalQueryBool(query, 'prioritizeIncomplete') ?? false;

    // Sort mode must be a real enum member; an unknown value is a 400 rather
    // than silently defaulting to bestScore (which would hide a client typo).
    final sortModeStr = query['sortMode'];
    final SuggestionSortMode sortMode;
    if (sortModeStr == null || sortModeStr.isEmpty) {
      sortMode = SuggestionSortMode.bestScore;
    } else {
      final match = SuggestionSortMode.values
          .where((m) => m.name == sortModeStr)
          .toList();
      if (match.isEmpty) {
        throw BadRequestError(
          field: 'sortMode',
          expected: SuggestionSortMode.values.map((m) => m.name).join(', '),
          message: 'Unknown sortMode "$sortModeStr"',
        );
      }
      sortMode = match.first;
    }

    // Normalize object types: split, trim, and drop blank entries so an empty
    // or comma-only value (`objectTypes=` / `objectTypes=,,`) yields [] rather
    // than a list of empty strings that would never match a target.
    final objectTypesStr = query['objectTypes'];
    final preferredObjectTypes = objectTypesStr == null
        ? <String>[]
        : objectTypesStr
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();

    final database = container.read(databaseProvider);

    // Get location from settings
    final latitude = await database.settingsDao.getObserverLatitude();
    final longitude = await database.settingsDao.getObserverLongitude();
    if (latitude == 0.0 && longitude == 0.0) {
      return jsonBadRequest({
        "error": "No location configured. Set location in settings first.",
      });
    }

    // Get all targets
    final targets = await database.targetsDao.getAllTargets();
    if (targets.isEmpty) {
      return jsonOk({"suggestions": []});
    }

    // Get all sessions for progress calculation
    final sessions = await database.sessionsDao.getAllSessions();

    // Create suggestion config
    final config = TargetSuggestionConfig(
      minAltitude: minAltitude,
      minScore: minScore,
      sortMode: sortMode,
      prioritizeIncomplete: prioritizeIncomplete,
      preferredObjectTypes: preferredObjectTypes,
    );

    // Generate suggestions
    final loggingService = container.read(loggingServiceProvider);
    final suggestionService = TargetSuggestionService(
      loggingService: loggingService,
    );

    final suggestions = await suggestionService.getSuggestionsForTonight(
      config: config,
      latitude: latitude,
      longitude: longitude,
      targets: targets,
      sessions: sessions,
    );

    // Limit results
    final limited = suggestions.take(maxResults).toList();

    return jsonOk({
      "suggestions": limited.map((s) => _suggestionToJson(s)).toList(),
      "totalMatching": suggestions.length,
      "location": {"latitude": latitude, "longitude": longitude},
    });
  }

  // Get suggestion config

  Future<Response> handleGetConfig(Request request) async {
    _logInfo('[API] GET /api/suggestions/config');
    // Return default configuration
    const config = TargetSuggestionConfig();

    return jsonOk({
      "config": {
        "minAltitude": config.minAltitude,
        "minScore": config.minScore,
        "maxMoonDistance": config.maxMoonDistance,
        "sortMode": config.sortMode.name,
        "prioritizeIncomplete": config.prioritizeIncomplete,
        "preferredObjectTypes": config.preferredObjectTypes,
      },
    });
  }

  // Get target score

  Future<Response> handleGetTargetScore(
    Request request,
    String targetId,
  ) async {
    _logInfo('[API] GET /api/suggestions/score/$targetId');
    final tid = _parsePathId(targetId, 'targetId');
    final database = container.read(databaseProvider);

    // Get target
    final target = await database.targetsDao.getTargetById(tid);
    if (target == null) {
      return jsonNotFound({"error": "Target not found: $targetId"});
    }

    // Get location
    final latitude = await database.settingsDao.getObserverLatitude();
    final longitude = await database.settingsDao.getObserverLongitude();
    if (latitude == 0.0 && longitude == 0.0) {
      return jsonBadRequest({"error": "No location configured"});
    }

    // Get sessions for progress calculation
    final sessions = await database.sessionsDao.getSessionsForTarget(tid);

    // Generate suggestion for this target
    final loggingService = container.read(loggingServiceProvider);
    final suggestionService = TargetSuggestionService(
      loggingService: loggingService,
    );

    const config = TargetSuggestionConfig(
      minAltitude: -90, // Include all altitudes
      minScore: -1000, // Include all scores
    );

    final suggestions = await suggestionService.getSuggestionsForTonight(
      config: config,
      latitude: latitude,
      longitude: longitude,
      targets: [target],
      sessions: sessions,
    );

    if (suggestions.isEmpty) {
      return jsonOk({
        "targetId": tid,
        "targetName": target.name,
        "belowHorizon": null,
        "message":
            "Unable to score target - target may be below horizon or not visible tonight",
      });
    }

    final suggestion = suggestions.first;

    return jsonOk({
      "targetId": tid,
      "targetName": target.name,
      "suggestion": _suggestionToJson(suggestion),
    });
  }

  // Helpers

  Map<String, dynamic> _suggestionToJson(TargetSuggestion s) {
    return {
      'targetId': s.targetId,
      'targetName': s.targetName,
      'catalogId': s.catalogId,
      'raHours': s.raHours,
      'decDegrees': s.decDegrees,
      'totalScore': s.totalScore,
      'scoreBreakdown': s.scoreBreakdown,
      'warnings': s.warnings
          .map((w) => {'message': w.message, 'severity': w.severity.name})
          .toList(),
      'visibility': {
        'currentAltitude': s.visibility.currentAltitude,
        'currentAzimuth': s.visibility.currentAzimuth,
        'transitAltitude': s.visibility.transitAltitude,
        'riseTime': s.visibility.riseTime?.millisecondsSinceEpoch,
        'transitTime': s.visibility.transitTime?.millisecondsSinceEpoch,
        'setTime': s.visibility.setTime?.millisecondsSinceEpoch,
        'isCircumpolar': s.visibility.isCircumpolar,
        'neverRises': s.visibility.neverRises,
        'airmass': s.visibility.airmass,
        'moonDistance': s.visibility.moonDistance,
      },
      'reasoning': s.reasoning,
      'dataProgress': s.dataProgress,
      'objectType': s.objectType,
      'magnitude': s.magnitude,
      'sizeArcmin': s.sizeArcmin,
      'constellation': s.constellation,
    };
  }
}
