import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// Handlers for intelligent scheduler endpoints
///
/// These endpoints provide astronomical calculations for target planning:
/// - Altitude calculation at specific times
/// - Transit time calculation
/// - Rise/set time calculation
/// - Hours above horizon calculation
/// - Target optimization for tonight
/// - Twilight times
/// - Moon information
class SchedulerHandlers {
  final ProviderContainer container;

  SchedulerHandlers(this.container);

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'SchedulerHandlers');

  // Autopilot preview decision (host -> slave mirror)

  /// GET /api/scheduler/preview
  ///
  /// Returns the host's live autopilot preview decision — "what the rig would
  /// slew to next". A remote slave's scheduler engine has no candidate data
  /// (the catalog/targets live in the host DB), so it would always compute
  /// "nothing eligible"; the slave fetches this instead and mirrors the real
  /// host pick.
  Future<Response> handlePreviewDecision(Request request) async {
    _logInfo('[API] GET /api/scheduler/preview');
    try {
      final decision = await container.read(
        schedulerPreviewDecisionProvider.future,
      );
      return jsonOk(decision.toJson());
    } catch (e) {
      return jsonInternalServerError({
        'error': 'Failed to compute scheduler preview: $e',
      });
    }
  }

  Future<Map<String, dynamic>> _schedulerState() async {
    final engine = await container.read(schedulerEngineReadyProvider.future);
    final decision = await engine.previewDecision(DateTime.now());
    return {
      'status': engine.status.toJson(),
      'decision': decision.toJson(),
      'config': engine.config.toStorageJson(),
      'readiness': container
          .read(schedulerStartReadinessProvider)
          .toStorageJson(),
    };
  }

  /// GET /api/scheduler/state
  Future<Response> handleGetState(Request request) async {
    _logInfo('[API] GET /api/scheduler/state');
    try {
      return jsonOk(await _schedulerState());
    } catch (e) {
      return jsonInternalServerError({
        'error': 'Failed to read scheduler state: $e',
      });
    }
  }

  /// POST /api/scheduler/control
  Future<Response> handleControl(Request request) async {
    _logInfo('[API] POST /api/scheduler/control');
    final payload = await readJsonObject(request);
    final action = requireString(payload, 'action');
    final confirmWarnings = payload['confirmWarnings'] == true;
    const validActions = {'start', 'pause', 'resume', 'stop', 'evaluate'};
    if (!validActions.contains(action)) {
      throw BadRequestError(
        field: 'action',
        expected: 'one_of:start,pause,resume,stop,evaluate',
        message: 'Unknown scheduler action',
      );
    }

    final engine = switch (action) {
      'pause' || 'stop' => container.read(schedulerEngineProvider),
      _ => await container.read(schedulerEngineReadyProvider.future),
    };
    if (action == 'start') {
      final readiness = container.read(schedulerStartReadinessProvider);
      if (readiness.blocked ||
          (readiness.warnings.isNotEmpty && !confirmWarnings)) {
        throw BadRequestError(
          field: 'action',
          expected: readiness.blocked
              ? 'scheduler_ready'
              : 'confirmWarnings:true',
          message: readiness.blocked
              ? 'Scheduler readiness is blocked.'
              : 'Scheduler warnings require explicit confirmation.',
        );
      }
    }
    switch (action) {
      case 'start':
        try {
          await engine.start();
        } on SchedulerStartException catch (error) {
          throw BadRequestError(
            field: 'action',
            expected: 'scheduler_with_at_least_one_target',
            message: error.message,
          );
        }
      case 'pause':
        await engine.pause();
      case 'resume':
        await engine.resume();
      case 'stop':
        await engine.stop();
      case 'evaluate':
        await engine.evaluateNow(reason: 'remote manual re-evaluation');
    }
    return jsonOk(await _schedulerState());
  }

  /// POST /api/scheduler/config
  Future<Response> handleUpdateConfig(Request request) async {
    _logInfo('[API] POST /api/scheduler/config');
    final payload = await readJsonObject(request);
    final weightsPayload = payload['weights'];
    if (weightsPayload is! Map) {
      throw BadRequestError(
        field: 'weights',
        expected: 'object',
        message: 'Scheduler weights must be an object',
      );
    }
    final weights = weightsPayload.cast<String, dynamic>();
    final config = SchedulerConfig.defaults.copyWith(
      hysteresisRatio: requireDouble(
        payload,
        'hysteresisRatio',
        min: 1,
        max: 2,
      ),
      minAltitudeDegrees: requireDouble(
        payload,
        'minAltitudeDegrees',
        min: 0,
        max: 60,
      ),
      weights: SchedulerWeights(
        altitude: requireDouble(weights, 'altitude', min: 0, max: 3),
        meridian: requireDouble(weights, 'meridian', min: 0, max: 3),
        moon: requireDouble(weights, 'moon', min: 0, max: 3),
        timeRemaining: requireDouble(weights, 'timeRemaining', min: 0, max: 3),
        filterCoverage: requireDouble(
          weights,
          'filterCoverage',
          min: 0,
          max: 3,
        ),
        userPriority: requireDouble(weights, 'userPriority', min: 0, max: 3),
      ),
    );

    // Commit durability before changing the live engine. A failed disk write
    // must not leave the UI and running scheduler on a transient config.
    await container.read(schedulerConfigStoreProvider).save(config);
    container.read(schedulerConfigUserDirtyProvider.notifier).state = true;
    final engine = await container.read(schedulerEngineReadyProvider.future);
    engine.updateConfig(config);
    return jsonOk(await _schedulerState());
  }

  // Calculate altitude

  /// GET /api/scheduler/altitude?ra=X&dec=Y&time=Z
  /// Calculate altitude of object at given time (or now if no time)
  Future<Response> handleCalculateAltitude(Request request) async {
    _logInfo('[API] GET /api/scheduler/altitude');
    final database = container.read(databaseProvider);

    // Parse query parameters
    final raParam = request.url.queryParameters['ra'];
    final decParam = request.url.queryParameters['dec'];
    final timeParam = request.url.queryParameters['time'];

    if (raParam == null || decParam == null) {
      return jsonBadRequest({
        'error': 'Missing required parameters: ra and dec',
      });
    }

    final raHours = double.tryParse(raParam);
    final decDegrees = double.tryParse(decParam);
    if (raHours == null || decDegrees == null) {
      return jsonBadRequest({'error': 'Invalid ra or dec values'});
    }

    // Parse time or use now
    DateTime time;
    if (timeParam != null) {
      final parsed = DateTime.tryParse(timeParam);
      if (parsed == null) {
        final epochMs = int.tryParse(timeParam);
        if (epochMs == null) {
          return jsonBadRequest({
            'error': 'Invalid time format. Use ISO8601 or epoch milliseconds.',
          });
        }
        time = DateTime.fromMillisecondsSinceEpoch(epochMs);
      } else {
        time = parsed;
      }
    } else {
      time = DateTime.now();
    }

    // Get observer location
    final latitude = await database.settingsDao.getObserverLatitude();
    final longitude = await database.settingsDao.getObserverLongitude();
    if (latitude == 0.0 && longitude == 0.0) {
      return jsonBadRequest({
        'error':
            'No observer location configured. Set location in settings first.',
      });
    }

    // Calculate altitude and azimuth
    final raDeg = raHours * 15.0; // Convert RA hours to degrees
    final (altitude, azimuth) = AstronomyCalculations.objectAltAz(
      raDeg: raDeg,
      decDeg: decDegrees,
      dt: time,
      latitudeDeg: latitude,
      longitudeDeg: longitude,
    );

    // Calculate airmass
    final airmass = altitude > 0
        ? AstronomyCalculations.airmass(altitude)
        : double.infinity;

    // Determine if rising or setting
    final futureTime = time.add(const Duration(minutes: 10));
    final (futureAlt, _) = AstronomyCalculations.objectAltAz(
      raDeg: raDeg,
      decDeg: decDegrees,
      dt: futureTime,
      latitudeDeg: latitude,
      longitudeDeg: longitude,
    );
    final isRising = futureAlt > altitude;

    return jsonOk({
      'ra': raHours,
      'dec': decDegrees,
      'time': time.toIso8601String(),
      'altitude': altitude,
      'azimuth': azimuth,
      'airmass': airmass.isFinite ? airmass : null,
      'isAboveHorizon': altitude > 0,
      'isRising': isRising,
      'location': {'latitude': latitude, 'longitude': longitude},
    });
  }

  // Calculate transit time

  /// GET /api/scheduler/transit-time?ra=X&dec=Y
  /// Get transit time for object tonight
  Future<Response> handleCalculateTransitTime(Request request) async {
    _logInfo('[API] GET /api/scheduler/transit-time');
    final database = container.read(databaseProvider);

    // Parse query parameters
    final raParam = request.url.queryParameters['ra'];
    final decParam = request.url.queryParameters['dec'];

    if (raParam == null || decParam == null) {
      return jsonBadRequest({
        'error': 'Missing required parameters: ra and dec',
      });
    }

    final raHours = double.tryParse(raParam);
    final decDegrees = double.tryParse(decParam);
    if (raHours == null || decDegrees == null) {
      return jsonBadRequest({'error': 'Invalid ra or dec values'});
    }

    // Get observer location
    final latitude = await database.settingsDao.getObserverLatitude();
    final longitude = await database.settingsDao.getObserverLongitude();
    if (latitude == 0.0 && longitude == 0.0) {
      return jsonBadRequest({
        'error':
            'No observer location configured. Set location in settings first.',
      });
    }

    // Calculate visibility
    final raDeg = raHours * 15.0;
    final now = DateTime.now();
    final visibility = AstronomyCalculations.calculateObjectVisibility(
      raDeg: raDeg,
      decDeg: decDegrees,
      date: now,
      latitudeDeg: latitude,
      longitudeDeg: longitude,
    );

    if (visibility.transitTime == null) {
      return jsonOk({
        'ra': raHours,
        'dec': decDegrees,
        'transitTime': null,
        'transitAltitude': null,
        'isCircumpolar': visibility.isCircumpolar,
        'neverRises': visibility.neverRises,
      });
    }

    return jsonOk({
      'ra': raHours,
      'dec': decDegrees,
      'transitTime': visibility.transitTime!.toIso8601String(),
      'transitTimeEpoch': visibility.transitTime!.millisecondsSinceEpoch,
      'transitAltitude': visibility.transitAltitude,
      'isCircumpolar': visibility.isCircumpolar,
      'neverRises': visibility.neverRises,
      'location': {'latitude': latitude, 'longitude': longitude},
    });
  }

  // Calculate Rise/Set times

  /// GET /api/scheduler/rise-set?ra=X&dec=Y
  /// Get rise and set times for object
  Future<Response> handleCalculateRiseSet(Request request) async {
    _logInfo('[API] GET /api/scheduler/rise-set');

    // Validate the coordinates BEFORE the observer-location DB read so a
    // malformed request fails closed and does no work. RA is in HOURS for this
    // endpoint (raDeg = raHours * 15), Dec in degrees. A supplied minAltitude
    // must be finite and physical (-90..90); a malformed value must NOT silently
    // become 0 and produce a bogus rise/set time.
    final query = request.url.queryParameters;
    final raHours = requireQueryDouble(query, 'ra', min: 0, max: 24);
    final decDegrees = requireQueryDouble(query, 'dec', min: -90, max: 90);
    final minAltitude =
        optionalQueryDouble(query, 'minAltitude', min: -90, max: 90) ?? 0.0;

    final database = container.read(databaseProvider);

    // Get observer location
    final latitude = await database.settingsDao.getObserverLatitude();
    final longitude = await database.settingsDao.getObserverLongitude();
    if (latitude == 0.0 && longitude == 0.0) {
      return jsonBadRequest({
        'error':
            'No observer location configured. Set location in settings first.',
      });
    }

    // Calculate visibility
    final raDeg = raHours * 15.0;
    final now = DateTime.now();
    final visibility = AstronomyCalculations.calculateObjectVisibility(
      raDeg: raDeg,
      decDeg: decDegrees,
      date: now,
      latitudeDeg: latitude,
      longitudeDeg: longitude,
      minAltitude: minAltitude,
    );

    return jsonOk({
      'ra': raHours,
      'dec': decDegrees,
      'minAltitude': minAltitude,
      'riseTime': visibility.riseTime?.toIso8601String(),
      'riseTimeEpoch': visibility.riseTime?.millisecondsSinceEpoch,
      'transitTime': visibility.transitTime?.toIso8601String(),
      'transitTimeEpoch': visibility.transitTime?.millisecondsSinceEpoch,
      'setTime': visibility.setTime?.toIso8601String(),
      'setTimeEpoch': visibility.setTime?.millisecondsSinceEpoch,
      'transitAltitude': visibility.transitAltitude,
      'isCircumpolar': visibility.isCircumpolar,
      'neverRises': visibility.neverRises,
      'durationAboveHorizonMinutes': visibility.durationAboveHorizon?.inMinutes,
      'location': {'latitude': latitude, 'longitude': longitude},
    });
  }

  // Calculate hours above horizon

  /// GET /api/scheduler/hours-above-horizon?ra=X&dec=Y&minAltitude=30
  /// Get hours object is above altitude
  Future<Response> handleCalculateHoursAbove(Request request) async {
    _logInfo('[API] GET /api/scheduler/hours-above-horizon');

    // Validate coordinates before the observer-location DB read. RA is in HOURS
    // (raDeg = raHours * 15), Dec in degrees, minAltitude finite and physical.
    // A malformed supplied minAltitude must NOT silently become 30.
    final query = request.url.queryParameters;
    final raHours = requireQueryDouble(query, 'ra', min: 0, max: 24);
    final decDegrees = requireQueryDouble(query, 'dec', min: -90, max: 90);
    final minAltitude =
        optionalQueryDouble(query, 'minAltitude', min: -90, max: 90) ?? 30.0;

    final database = container.read(databaseProvider);

    // Get observer location
    final latitude = await database.settingsDao.getObserverLatitude();
    final longitude = await database.settingsDao.getObserverLongitude();
    if (latitude == 0.0 && longitude == 0.0) {
      return jsonBadRequest({
        'error':
            'No observer location configured. Set location in settings first.',
      });
    }

    // Calculate visibility
    final raDeg = raHours * 15.0;
    final now = DateTime.now();
    final visibility = AstronomyCalculations.calculateObjectVisibility(
      raDeg: raDeg,
      decDeg: decDegrees,
      date: now,
      latitudeDeg: latitude,
      longitudeDeg: longitude,
      minAltitude: minAltitude,
    );

    double hoursAbove;
    if (visibility.isCircumpolar) {
      hoursAbove = 24.0;
    } else if (visibility.neverRises) {
      hoursAbove = 0.0;
    } else if (visibility.durationAboveHorizon != null) {
      hoursAbove = visibility.durationAboveHorizon!.inMinutes / 60.0;
    } else {
      hoursAbove = 0.0;
    }

    return jsonOk({
      'ra': raHours,
      'dec': decDegrees,
      'minAltitude': minAltitude,
      'hoursAbove': hoursAbove,
      'isCircumpolar': visibility.isCircumpolar,
      'neverRises': visibility.neverRises,
      'transitAltitude': visibility.transitAltitude,
      'location': {'latitude': latitude, 'longitude': longitude},
    });
  }

  // Optimize targets

  /// POST /api/scheduler/optimize-targets
  /// Reorder a list of target IDs for optimal imaging tonight
  Future<Response> handleOptimizeTargets(Request request) async {
    _logInfo('[API] POST /api/scheduler/optimize-targets');
    final database = container.read(databaseProvider);
    final payload = await readJsonObject(request);

    // Parse target IDs from payload. Accept either a homogeneous int array or
    // a mixed array of ints/numeric strings (legacy clients).
    final rawIds = payload['targetIds'];
    if (rawIds == null) {
      throw BadRequestError(field: 'targetIds', expected: 'array<integer>');
    }
    if (rawIds is! List) {
      throw BadRequestError(field: 'targetIds', expected: 'array<integer>');
    }
    final targetIds = <int>[];
    for (final v in rawIds) {
      if (v is int) {
        targetIds.add(v);
      } else if (v is String) {
        final parsed = int.tryParse(v);
        if (parsed == null) {
          throw BadRequestError(
            field: 'targetIds',
            expected: 'array<integer>',
            message: 'Element "$v" is not a valid integer',
          );
        }
        targetIds.add(parsed);
      } else {
        throw BadRequestError(field: 'targetIds', expected: 'array<integer>');
      }
    }

    if (targetIds.isEmpty) {
      return jsonBadRequest({'error': 'Missing or empty targetIds array'});
    }

    // Parse strategy
    final strategyStr = optionalString(payload, 'strategy') ?? 'transitTime';
    final minAltitude = optionalDouble(payload, 'minAltitude') ?? 30.0;

    // Get observer location
    final latitude = await database.settingsDao.getObserverLatitude();
    final longitude = await database.settingsDao.getObserverLongitude();
    if (latitude == 0.0 && longitude == 0.0) {
      return jsonBadRequest({
        'error':
            'No observer location configured. Set location in settings first.',
      });
    }

    // Fetch targets from database
    final targets = <dynamic>[];
    for (final id in targetIds) {
      final target = await database.targetsDao.getTargetById(id);
      if (target != null) {
        targets.add(target);
      }
    }

    if (targets.isEmpty) {
      return jsonBadRequest({
        'error': 'No valid targets found for provided IDs',
      });
    }

    // Calculate visibility data for each target
    final now = DateTime.now();
    final targetVisibility = <int, Map<String, dynamic>>{};

    for (final target in targets) {
      final raDeg = target.ra * 15.0;
      final visibility = AstronomyCalculations.calculateObjectVisibility(
        raDeg: raDeg,
        decDeg: target.dec,
        date: now,
        latitudeDeg: latitude,
        longitudeDeg: longitude,
        minAltitude: minAltitude,
      );

      final (currentAlt, currentAz) = AstronomyCalculations.objectAltAz(
        raDeg: raDeg,
        decDeg: target.dec,
        dt: now,
        latitudeDeg: latitude,
        longitudeDeg: longitude,
      );

      // Determine if rising
      final futureTime = now.add(const Duration(minutes: 10));
      final (futureAlt, _) = AstronomyCalculations.objectAltAz(
        raDeg: raDeg,
        decDeg: target.dec,
        dt: futureTime,
        latitudeDeg: latitude,
        longitudeDeg: longitude,
      );
      final isRising = futureAlt > currentAlt;

      targetVisibility[target.id] = {
        'target': target,
        'visibility': visibility,
        'currentAltitude': currentAlt,
        'currentAzimuth': currentAz,
        'isRising': isRising,
        'transitTime': visibility.transitTime,
      };
    }

    // Sort based on strategy. Note: the casts below are over typed values we
    // just stored into the targetVisibility map ourselves — they are not
    // payload casts and cannot leak caller-induced type errors.
    final sortedTargets = List<dynamic>.from(targets);
    final inputOrder = <int, int>{
      for (final (index, target) in targets.indexed) target.id as int: index,
    };

    switch (strategyStr.toLowerCase()) {
      case 'transittime':
        // Sort by transit time (earliest first)
        sortedTargets.sort((a, b) {
          final aTransit = targetVisibility[a.id]!['transitTime'] as DateTime?;
          final bTransit = targetVisibility[b.id]!['transitTime'] as DateTime?;
          if (aTransit == null && bTransit == null) return 0;
          if (aTransit == null) return 1;
          if (bTransit == null) return -1;
          return aTransit.compareTo(bTransit);
        });
        break;

      case 'currentaltitude':
        // Sort by current altitude, setting targets first (higher alt first for setting)
        sortedTargets.sort((a, b) {
          final aData = targetVisibility[a.id]!;
          final bData = targetVisibility[b.id]!;
          final aRising = aData['isRising'] as bool;
          final bRising = bData['isRising'] as bool;
          final aAlt = aData['currentAltitude'] as double;
          final bAlt = bData['currentAltitude'] as double;

          // Setting targets first
          if (!aRising && bRising) return -1;
          if (aRising && !bRising) return 1;

          // Within same category, higher altitude first for setting, lower for rising
          if (!aRising) {
            return bAlt.compareTo(aAlt);
          } else {
            return aAlt.compareTo(bAlt);
          }
        });
        break;

      case 'risingfirst':
        // Image rising targets first
        sortedTargets.sort((a, b) {
          final aData = targetVisibility[a.id]!;
          final bData = targetVisibility[b.id]!;
          final aRising = aData['isRising'] as bool;
          final bRising = bData['isRising'] as bool;
          final aAlt = aData['currentAltitude'] as double;
          final bAlt = bData['currentAltitude'] as double;

          if (aRising != bRising) {
            return aRising ? -1 : 1;
          }
          return aAlt.compareTo(bAlt);
        });
        break;

      case 'settingfirst':
        // Image setting targets first
        sortedTargets.sort((a, b) {
          final aData = targetVisibility[a.id]!;
          final bData = targetVisibility[b.id]!;
          final aRising = aData['isRising'] as bool;
          final bRising = bData['isRising'] as bool;
          final aAlt = aData['currentAltitude'] as double;
          final bAlt = bData['currentAltitude'] as double;

          if (aRising != bRising) {
            return aRising ? 1 : -1;
          }
          if (!aRising) {
            return bAlt.compareTo(aAlt);
          }
          return aAlt.compareTo(bAlt);
        });
        break;

      case 'priority':
        // The target library, project overrides, and dynamic scheduler all
        // define a higher numeric value as more important. Preserve request
        // order for ties so equal priorities remain deterministic.
        sortedTargets.sort((a, b) {
          final byPriority = b.priority.compareTo(a.priority);
          if (byPriority != 0) return byPriority;
          return inputOrder[a.id]!.compareTo(inputOrder[b.id]!);
        });
        break;

      default:
        return jsonBadRequest({
          'error':
              'Unknown strategy: $strategyStr. Valid options: transitTime, currentAltitude, risingFirst, settingFirst, priority',
        });
    }

    // Build response
    final orderedResults = sortedTargets.map((target) {
      final data = targetVisibility[target.id]!;
      final visibility = data['visibility'] as ObjectVisibility;
      return {
        'targetId': target.id,
        'targetName': target.name,
        'raHours': target.ra,
        'decDegrees': target.dec,
        'currentAltitude': data['currentAltitude'],
        'currentAzimuth': data['currentAzimuth'],
        'isRising': data['isRising'],
        'transitTime': visibility.transitTime?.toIso8601String(),
        'transitAltitude': visibility.transitAltitude,
        'isCircumpolar': visibility.isCircumpolar,
        'neverRises': visibility.neverRises,
      };
    }).toList();

    return jsonOk({
      'strategy': strategyStr,
      'minAltitude': minAltitude,
      'optimizedTargets': orderedResults,
      'location': {'latitude': latitude, 'longitude': longitude},
    });
  }

  // Get twilight times

  /// GET /api/scheduler/twilight-times
  /// Get astronomical, nautical, civil twilight times for tonight
  Future<Response> handleGetTwilightTimes(Request request) async {
    _logInfo('[API] GET /api/scheduler/twilight-times');
    final database = container.read(databaseProvider);

    // Get observer location
    final latitude = await database.settingsDao.getObserverLatitude();
    final longitude = await database.settingsDao.getObserverLongitude();
    if (latitude == 0.0 && longitude == 0.0) {
      return jsonBadRequest({
        'error':
            'No observer location configured. Set location in settings first.',
      });
    }

    // Optional date parameter
    final dateParam = request.url.queryParameters['date'];
    DateTime date;
    if (dateParam != null) {
      final parsed = DateTime.tryParse(dateParam);
      if (parsed == null) {
        return jsonBadRequest({'error': 'Invalid date format. Use ISO8601.'});
      }
      date = parsed;
    } else {
      date = DateTime.now();
    }

    // Calculate twilight times
    final twilight = AstronomyCalculations.calculateTwilightTimes(
      date: date,
      latitudeDeg: latitude,
      longitudeDeg: longitude,
    );

    return jsonOk({
      'date': date.toIso8601String().split('T')[0],
      'sunset': twilight.sunset?.toIso8601String(),
      'sunsetEpoch': twilight.sunset?.millisecondsSinceEpoch,
      'civilDusk': twilight.civilDusk?.toIso8601String(),
      'civilDuskEpoch': twilight.civilDusk?.millisecondsSinceEpoch,
      'nauticalDusk': twilight.nauticalDusk?.toIso8601String(),
      'nauticalDuskEpoch': twilight.nauticalDusk?.millisecondsSinceEpoch,
      'astronomicalDusk': twilight.astronomicalDusk?.toIso8601String(),
      'astronomicalDuskEpoch':
          twilight.astronomicalDusk?.millisecondsSinceEpoch,
      'astronomicalDawn': twilight.astronomicalDawn?.toIso8601String(),
      'astronomicalDawnEpoch':
          twilight.astronomicalDawn?.millisecondsSinceEpoch,
      'nauticalDawn': twilight.nauticalDawn?.toIso8601String(),
      'nauticalDawnEpoch': twilight.nauticalDawn?.millisecondsSinceEpoch,
      'civilDawn': twilight.civilDawn?.toIso8601String(),
      'civilDawnEpoch': twilight.civilDawn?.millisecondsSinceEpoch,
      'sunrise': twilight.sunrise?.toIso8601String(),
      'sunriseEpoch': twilight.sunrise?.millisecondsSinceEpoch,
      'darknessDurationMinutes': twilight.darknessDuration?.inMinutes,
      'location': {'latitude': latitude, 'longitude': longitude},
    });
  }

  // Get moon info

  /// GET /api/scheduler/moon-info
  /// Get moon phase, rise/set, illumination
  Future<Response> handleGetMoonInfo(Request request) async {
    _logInfo('[API] GET /api/scheduler/moon-info');
    final database = container.read(databaseProvider);

    // Get observer location
    final latitude = await database.settingsDao.getObserverLatitude();
    final longitude = await database.settingsDao.getObserverLongitude();
    if (latitude == 0.0 && longitude == 0.0) {
      return jsonBadRequest({
        'error':
            'No observer location configured. Set location in settings first.',
      });
    }

    // Optional date parameter
    final dateParam = request.url.queryParameters['date'];
    DateTime date;
    if (dateParam != null) {
      final parsed = DateTime.tryParse(dateParam);
      if (parsed == null) {
        return jsonBadRequest({'error': 'Invalid date format. Use ISO8601.'});
      }
      date = parsed;
    } else {
      date = DateTime.now();
    }

    // Calculate moon position and illumination
    final (moonRaDeg, moonDecDeg, moonDistance) =
        AstronomyCalculations.moonPosition(date);
    final moonRaHours = moonRaDeg / 15.0;
    final illumination = AstronomyCalculations.moonIllumination(date);
    final phaseName = AstronomyCalculations.moonPhaseName(date);

    // Calculate current altitude
    final (moonAlt, moonAz) = AstronomyCalculations.objectAltAz(
      raDeg: moonRaDeg,
      decDeg: moonDecDeg,
      dt: date,
      latitudeDeg: latitude,
      longitudeDeg: longitude,
    );

    // Calculate moon rise/set times
    final moonTimes = AstronomyCalculations.calculateMoonTimes(
      date: date,
      latitudeDeg: latitude,
      longitudeDeg: longitude,
    );

    return jsonOk({
      'date': date.toIso8601String(),
      'position': {
        'raHours': moonRaHours,
        'raDegrees': moonRaDeg,
        'decDegrees': moonDecDeg,
        'distanceKm': moonDistance,
      },
      'illumination': illumination,
      'phaseName': phaseName,
      'currentAltitude': moonAlt,
      'currentAzimuth': moonAz,
      'isAboveHorizon': moonAlt > 0,
      'moonrise': moonTimes.moonrise?.toIso8601String(),
      'moonriseEpoch': moonTimes.moonrise?.millisecondsSinceEpoch,
      'moonset': moonTimes.moonset?.toIso8601String(),
      'moonsetEpoch': moonTimes.moonset?.millisecondsSinceEpoch,
      'location': {'latitude': latitude, 'longitude': longitude},
    });
  }
}
