/// Pure, side-effect-free evaluation of hardware-weather telemetry against the
/// operator's configured maxima.
///
/// Architecture-unification 2026-06-05 (Subsystem 2 step 3): this logic was
/// inlined in `WeatherSafetyNotifier._evaluateHardwareWeather`, making it
/// impossible to unit-test in isolation and a candidate for drifting out of
/// sync with any other place that needs the same thresholds. It is now a single
/// pure definition with no Riverpod / provider dependencies so it can be tested
/// directly and reused.
///
/// "Safe" means EVERY available reading is within its configured maximum. A
/// reading that is absent (`null`) is treated as "no evidence of danger from
/// this metric" and does not, on its own, make conditions unsafe — the absence
/// of a sensor value is handled by the caller's fail-mode policy, not here.
/// This evaluator only answers the narrower question: "given the readings we
/// DO have, does any of them breach a configured limit?"
library;

/// Maximum-value limits a hardware weather reading must stay within to be
/// considered safe. Mirrors the operator-configurable fields on
/// `WeatherSettings` (`maxHumidityPercent`, `maxWindSpeedKph`,
/// `maxCloudCoverPercent`); rain is unsafe at any positive rate.
class WeatherThresholds {
  /// Relative humidity ceiling, percent (0..100). A reading strictly above
  /// this is unsafe (dew / condensation risk).
  final double maxHumidityPercent;

  /// Wind-speed ceiling, km/h. A reading strictly above this is unsafe.
  final double maxWindSpeedKph;

  /// Cloud-cover ceiling, percent (0..100). A reading strictly above this is
  /// unsafe.
  final double maxCloudCoverPercent;

  const WeatherThresholds({
    required this.maxHumidityPercent,
    required this.maxWindSpeedKph,
    required this.maxCloudCoverPercent,
  });
}

/// A single hardware-weather telemetry sample. Every field is nullable because
/// not all weather devices report every metric; a `null` field is "not
/// reported", not "zero".
class WeatherReading {
  final double? humidityPercent;
  final double? windSpeedKph;
  final double? rainRate;
  final double? cloudCoverPercent;

  const WeatherReading({
    this.humidityPercent,
    this.windSpeedKph,
    this.rainRate,
    this.cloudCoverPercent,
  });
}

/// The specific metric that tripped an unsafe verdict, for operator-facing
/// reasoning. `none` means the reading was safe.
enum WeatherThresholdBreach { none, humidity, wind, rain, cloud }

/// Result of evaluating a [WeatherReading] against [WeatherThresholds].
class WeatherThresholdResult {
  /// True iff no available reading breached its configured limit.
  final bool isSafe;

  /// The first metric that breached its limit (in humidity → wind → rain →
  /// cloud order), or [WeatherThresholdBreach.none] when safe.
  final WeatherThresholdBreach breach;

  const WeatherThresholdResult({required this.isSafe, required this.breach});

  static const safe = WeatherThresholdResult(
    isSafe: true,
    breach: WeatherThresholdBreach.none,
  );
}

/// Pure evaluator for hardware-weather thresholds. Stateless; the single
/// definition of "is this hardware reading within configured limits".
class WeatherThresholdEvaluator {
  const WeatherThresholdEvaluator();

  /// Evaluate [reading] against [thresholds].
  ///
  /// Breach order is humidity → wind → rain → cloud; the first breach is the
  /// reported reason. Rain is unsafe at any strictly-positive rate regardless
  /// of the configured ceilings.
  WeatherThresholdResult evaluate(
    WeatherReading reading,
    WeatherThresholds thresholds,
  ) {
    final humidity = reading.humidityPercent;
    if (humidity != null && humidity > thresholds.maxHumidityPercent) {
      return const WeatherThresholdResult(
        isSafe: false,
        breach: WeatherThresholdBreach.humidity,
      );
    }

    final wind = reading.windSpeedKph;
    if (wind != null && wind > thresholds.maxWindSpeedKph) {
      return const WeatherThresholdResult(
        isSafe: false,
        breach: WeatherThresholdBreach.wind,
      );
    }

    final rain = reading.rainRate;
    if (rain != null && rain > 0) {
      return const WeatherThresholdResult(
        isSafe: false,
        breach: WeatherThresholdBreach.rain,
      );
    }

    final cloud = reading.cloudCoverPercent;
    if (cloud != null && cloud > thresholds.maxCloudCoverPercent) {
      return const WeatherThresholdResult(
        isSafe: false,
        breach: WeatherThresholdBreach.cloud,
      );
    }

    return WeatherThresholdResult.safe;
  }
}
