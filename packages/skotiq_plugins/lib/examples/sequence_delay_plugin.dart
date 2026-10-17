import 'dart:async';
import 'dart:math' as math;

import '../src/plugin_api.dart';

/// Plugin that provides intelligent delay sequence nodes for the Skotiq
/// sequencer.
///
/// Demonstrates:
/// - Implementing `SequencePlugin` with multiple node definitions
/// - Building `PluginSequenceNode` implementations with parameter validation
/// - Using the event bus within sequence node execution
/// - Creating nodes with different complexity levels
///
/// Provided nodes:
/// - **Conditional Delay**: Waits a fixed duration, can be aborted by an event
/// - **Cooldown Wait**: Waits for sensor temperature to reach a target
/// - **Twilight Wait**: Waits until a specified sun altitude is reached
///
/// Usage:
/// ```dart
/// await host.registerPlugin(SequenceDelayPlugin());
/// ```
class SequenceDelayPlugin extends SequencePlugin {
  PluginContext? _context;

  @override
  String get id => 'com.skotiq.sequencedelay';

  @override
  String get name => 'Intelligent Delays';

  @override
  String get version => '1.0.0';

  @override
  String get description =>
      'Adds smart delay nodes to the sequencer: conditional delays, '
      'temperature cooldown waits, and twilight timing';

  @override
  String get author => 'Skotiq Team';

  @override
  String? get minAppVersion => '2.5.0';

  @override
  Future<void> onLoad(PluginContext context) async {
    _context = context;
    context.logger.info(
      'Sequence delay plugin loaded with ${nodeDefinitions.length} nodes',
    );
  }

  @override
  Future<void> onUnload() async {
    _context?.logger.info('Sequence delay plugin unloading');
    _context = null;
  }

  @override
  List<SequenceNodeDefinition> get nodeDefinitions => [
    SequenceNodeDefinition(
      id: 'delay.conditional',
      name: 'Conditional Delay',
      category: 'Smart Delays',
      description:
          'Waits for a specified duration but can be aborted early '
          'by a named event',
      createNode: (params) {
        final durationSeconds = params['durationSeconds'] as int? ?? 60;
        final abortEvent = params['abortEvent'] as String?;
        return ConditionalDelayNode(
          durationSeconds: durationSeconds,
          abortEventName: abortEvent,
        );
      },
    ),
    SequenceNodeDefinition(
      id: 'delay.cooldown',
      name: 'Cooldown Wait',
      category: 'Smart Delays',
      description:
          'Waits until the sensor temperature reaches a target value. '
          'Monitors focuser temperature events.',
      createNode: (params) {
        final targetTemp = params['targetTemperature'] as double? ?? -10.0;
        final toleranceDeg = params['toleranceDegrees'] as double? ?? 1.0;
        final timeoutMinutes = params['timeoutMinutes'] as int? ?? 60;
        return CooldownWaitNode(
          targetTemperature: targetTemp,
          toleranceDegrees: toleranceDeg,
          timeoutMinutes: timeoutMinutes,
        );
      },
    ),
    SequenceNodeDefinition(
      id: 'delay.twilight',
      name: 'Twilight Wait',
      category: 'Smart Delays',
      description:
          'Waits until the sun reaches a specified altitude '
          '(e.g., -18 degrees for astronomical twilight)',
      createNode: (params) {
        final targetAltitude = params['targetSunAltitude'] as double? ?? -18.0;
        final timeoutMinutes = params['timeoutMinutes'] as int? ?? 120;
        return TwilightWaitNode(
          targetSunAltitude: targetAltitude,
          timeoutMinutes: timeoutMinutes,
        );
      },
    ),
  ];
}

/// Sequence node that waits for a fixed duration but can be aborted early
/// if a specific event is received.
///
/// Parameters:
/// - `durationSeconds`: How long to wait (default: 60)
/// - `abortEvent`: Optional event name that aborts the wait early
class ConditionalDelayNode implements PluginSequenceNode {
  final int durationSeconds;
  final String? abortEventName;

  ConditionalDelayNode({required this.durationSeconds, this.abortEventName});

  @override
  String? validate() {
    if (durationSeconds <= 0) {
      return 'Duration must be a positive number of seconds';
    }
    if (durationSeconds > 86400) {
      return 'Duration cannot exceed 24 hours (86400 seconds)';
    }
    return null;
  }

  @override
  Future<bool> execute(PluginContext context) async {
    context.logger.info(
      'Starting conditional delay for $durationSeconds seconds'
      '${abortEventName != null ? ' (abort on: $abortEventName)' : ''}',
    );

    final completer = Completer<bool>();
    StreamSubscription? abortSubscription;

    // Set up abort listener if configured
    if (abortEventName != null) {
      abortSubscription = context.eventBus.on(abortEventName!).listen((data) {
        context.logger.info('Delay aborted by event: $abortEventName');
        if (!completer.isCompleted) {
          completer.complete(true); // Abort is a success, not a failure
        }
      });
    }

    // Set up the main delay timer
    final timer = Timer(Duration(seconds: durationSeconds), () {
      context.logger.info('Conditional delay completed normally');
      if (!completer.isCompleted) {
        completer.complete(true);
      }
    });

    // Emit progress events every 10 seconds
    final progressTimer = Timer.periodic(const Duration(seconds: 10), (t) {
      final elapsed = (t.tick * 10);
      final remaining = durationSeconds - elapsed;
      if (remaining > 0) {
        context.eventBus.emit('plugin.delay.progress', {
          'elapsed': elapsed,
          'remaining': remaining,
          'total': durationSeconds,
        });
      }
    });

    try {
      final result = await completer.future;
      return result;
    } finally {
      timer.cancel();
      progressTimer.cancel();
      await abortSubscription?.cancel();
    }
  }
}

/// Sequence node that waits until the sensor temperature reaches a target.
///
/// Monitors `focuser.moved` events for temperature data. Completes when the
/// temperature is within the tolerance range of the target, or when the
/// timeout expires.
///
/// Parameters:
/// - `targetTemperature`: Target temperature in degrees Celsius (default: -10.0)
/// - `toleranceDegrees`: Acceptable deviation from target (default: 1.0)
/// - `timeoutMinutes`: Maximum wait time in minutes (default: 60)
class CooldownWaitNode implements PluginSequenceNode {
  final double targetTemperature;
  final double toleranceDegrees;
  final int timeoutMinutes;

  CooldownWaitNode({
    required this.targetTemperature,
    required this.toleranceDegrees,
    required this.timeoutMinutes,
  });

  @override
  String? validate() {
    if (toleranceDegrees <= 0) {
      return 'Tolerance must be a positive value';
    }
    if (timeoutMinutes <= 0) {
      return 'Timeout must be a positive number of minutes';
    }
    if (timeoutMinutes > 1440) {
      return 'Timeout cannot exceed 24 hours (1440 minutes)';
    }
    return null;
  }

  @override
  Future<bool> execute(PluginContext context) async {
    context.logger.info(
      'Waiting for sensor temperature to reach '
      '${targetTemperature.toStringAsFixed(1)} C '
      '(+/- ${toleranceDegrees.toStringAsFixed(1)} C, '
      'timeout: $timeoutMinutes min)',
    );

    final completer = Completer<bool>();
    final deadline = DateTime.now().add(Duration(minutes: timeoutMinutes));

    // Listen for temperature updates from focuser events
    final subscription = context.eventBus.on('focuser.moved').listen((data) {
      final temp = data['temperature'];
      if (temp == null) return;

      final temperature = (temp is num)
          ? temp.toDouble()
          : double.tryParse(temp.toString());
      if (temperature == null) return;

      final delta = (temperature - targetTemperature).abs();

      context.logger.debug(
        'Temperature: ${temperature.toStringAsFixed(1)} C '
        '(delta: ${delta.toStringAsFixed(1)} C)',
      );

      context.eventBus.emit('plugin.cooldown.progress', {
        'currentTemperature': temperature,
        'targetTemperature': targetTemperature,
        'delta': delta,
        'tolerance': toleranceDegrees,
      });

      if (delta <= toleranceDegrees) {
        context.logger.info(
          'Temperature ${temperature.toStringAsFixed(1)} C is within '
          'tolerance of target ${targetTemperature.toStringAsFixed(1)} C',
        );
        if (!completer.isCompleted) {
          completer.complete(true);
        }
      }
    });

    // Set up timeout
    final timeoutTimer = Timer(Duration(minutes: timeoutMinutes), () {
      if (!completer.isCompleted) {
        context.logger.warning(
          'Cooldown wait timed out after $timeoutMinutes minutes',
        );
        completer.complete(false);
      }
    });

    // Also poll periodically in case we miss events
    final pollTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (DateTime.now().isAfter(deadline) && !completer.isCompleted) {
        context.logger.warning('Cooldown wait deadline exceeded');
        completer.complete(false);
      }
    });

    try {
      return await completer.future;
    } finally {
      await subscription.cancel();
      timeoutTimer.cancel();
      pollTimer.cancel();
    }
  }
}

/// Sequence node that waits until the sun reaches a specified altitude.
///
/// Useful for starting sequences at astronomical twilight (-18 degrees),
/// nautical twilight (-12 degrees), or civil twilight (-6 degrees).
///
/// Parameters:
/// - `targetSunAltitude`: Target sun altitude in degrees (default: -18.0)
/// - `timeoutMinutes`: Maximum wait time in minutes (default: 120)
class TwilightWaitNode implements PluginSequenceNode {
  final double targetSunAltitude;
  final int timeoutMinutes;

  TwilightWaitNode({
    required this.targetSunAltitude,
    required this.timeoutMinutes,
  });

  @override
  String? validate() {
    if (targetSunAltitude < -90 || targetSunAltitude > 90) {
      return 'Sun altitude must be between -90 and 90 degrees';
    }
    if (timeoutMinutes <= 0) {
      return 'Timeout must be a positive number of minutes';
    }
    if (timeoutMinutes > 1440) {
      return 'Timeout cannot exceed 24 hours (1440 minutes)';
    }
    return null;
  }

  @override
  Future<bool> execute(PluginContext context) async {
    final twilightType = _describeTwilightType(targetSunAltitude);
    context.logger.info(
      'Waiting for $twilightType '
      '(sun altitude <= ${targetSunAltitude.toStringAsFixed(1)} degrees, '
      'timeout: $timeoutMinutes min)',
    );

    final deadline = DateTime.now().add(Duration(minutes: timeoutMinutes));
    var checkCount = 0;

    while (DateTime.now().isBefore(deadline)) {
      // Compute current sun altitude.
      // In a production plugin, this would use the observer's latitude/longitude
      // from the app's location settings and a proper solar position algorithm
      // (e.g., Jean Meeus "Astronomical Algorithms").
      final sunAltitude = _computeSunAltitude(DateTime.now());

      checkCount++;
      if (checkCount % 6 == 0) {
        // Log progress every ~60 seconds (6 * 10s interval)
        context.logger.info(
          'Sun altitude: ${sunAltitude.toStringAsFixed(1)} degrees '
          '(target: ${targetSunAltitude.toStringAsFixed(1)})',
        );
      }

      context.eventBus.emit('plugin.twilight.progress', {
        'currentSunAltitude': sunAltitude,
        'targetSunAltitude': targetSunAltitude,
        'twilightType': twilightType,
      });

      if (sunAltitude <= targetSunAltitude) {
        context.logger.info(
          '$twilightType reached: sun at '
          '${sunAltitude.toStringAsFixed(1)} degrees',
        );
        return true;
      }

      // Check every 10 seconds
      await Future<void>.delayed(const Duration(seconds: 10));
    }

    context.logger.warning(
      'Twilight wait timed out after $timeoutMinutes minutes. '
      'Sun may not reach ${targetSunAltitude.toStringAsFixed(1)} degrees tonight.',
    );
    return false;
  }

  /// Compute the current sun altitude in degrees.
  ///
  /// This is a simplified calculation for demonstration. A production
  /// implementation should use a proper solar position algorithm with
  /// the observer's geographic coordinates.
  double _computeSunAltitude(DateTime utcNow) {
    // Simplified solar altitude estimate based on time of day.
    // Real implementation would use:
    // 1. Julian date from UTC time
    // 2. Solar mean anomaly and ecliptic longitude
    // 3. Right ascension and declination
    // 4. Hour angle from observer longitude and sidereal time
    // 5. Altitude from hour angle, declination, and observer latitude
    //
    // Return a coarse estimate that keeps this example self-contained.
    // The sequencer's built-in twilight node should be preferred for
    // production use; this example demonstrates the plugin node pattern.

    final hour = utcNow.hour + utcNow.minute / 60.0;
    // Very rough approximation: sun transits at ~12 UTC for 0-degree longitude
    final hourAngle = (hour - 12.0) * 15.0; // degrees from meridian

    // Assume ~45 degree latitude, ~23.5 degree max declination at solstice
    // This produces a sinusoidal-ish altitude curve for demonstration
    final dayOfYear = utcNow.difference(DateTime.utc(utcNow.year)).inDays;
    final declination =
        23.45 * _sinDegValue(360.0 * (284.0 + dayOfYear) / 365.0);

    const latitude = 45.0;
    final altitude = _asinDegValue(
      _sinDegValue(latitude) * _sinDegValue(declination) +
          _cosDegValue(latitude) *
              _cosDegValue(declination) *
              _cosDegValue(hourAngle),
    );

    return altitude;
  }

  String _describeTwilightType(double altitude) {
    if (altitude <= -18) return 'astronomical twilight';
    if (altitude <= -12) return 'nautical twilight';
    if (altitude <= -6) return 'civil twilight';
    if (altitude <= 0) return 'sunset';
    return 'sun below ${altitude.toStringAsFixed(0)} degrees';
  }

  static double _sinDegValue(double degrees) =>
      math.sin(degrees * math.pi / 180.0);

  static double _cosDegValue(double degrees) =>
      math.cos(degrees * math.pi / 180.0);

  static double _asinDegValue(double value) =>
      math.asin(value.clamp(-1.0, 1.0)) * 180.0 / math.pi;
}
