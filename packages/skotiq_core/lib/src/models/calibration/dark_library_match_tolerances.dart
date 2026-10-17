/// Unified tolerance configuration for dark-frame matching.
///
/// This value class is the single source of truth that both
/// `DarkLibraryCoverageService.evaluate` (which powers the "do I have darks"
/// UI badges) and `DarkLibraryDao.findBestMatch` (which actually picks the
/// dark to subtract at runtime) must consult. They MUST agree, otherwise the
/// coverage UI can show "all darks present" while the calibration pipeline
/// silently returns null — this audit bug.
///
/// Defaults are tuned for typical astrophotography cameras:
///   * Exposure: ±0.5s catches the request-vs-reported drift seen on real
///     cameras (60.0 vs 60.001 vs 59.999) without falling over to a frame
///     captured at a deliberately different duration.
///   * Temperature: ±1.0°C is the conventional pipeline default — wide
///     enough for typical cooled-camera regulation jitter.
///   * Gain / offset / binning: exact match. These are discrete settings
///     selected by the user; "close enough" is never correct here.
class DarkLibraryMatchTolerances {
  /// Maximum allowed difference between the requested light-frame exposure
  /// (seconds) and a candidate dark's exposure to still be considered a
  /// match. Must be >= 0.
  final double exposureSecs;

  /// Maximum allowed difference between the requested light-frame sensor
  /// temperature (°C) and a candidate dark's temperature to still be
  /// considered a match. Must be >= 0.
  final double temperatureC;

  /// Construct a tolerances object. Both values must be finite and >= 0.
  ///
  /// Out-of-range input throws instead of clamping: a negative tolerance is a
  /// configuration mistake, and clamping it would silently widen or narrow
  /// which darks match.
  const DarkLibraryMatchTolerances({
    this.exposureSecs = 0.5,
    this.temperatureC = 1.0,
  }) : assert(
         exposureSecs >= 0,
         'exposureSecs tolerance must be >= 0, got $exposureSecs',
       ),
       assert(
         temperatureC >= 0,
         'temperatureC tolerance must be >= 0, got $temperatureC',
       );

  /// Construct from arbitrary user input (e.g. settings DAO values).
  ///
  /// Throws [ArgumentError] when either value is negative, NaN, or
  /// infinite. We deliberately do not clamp — silent clamping hides bugs
  /// for months.
  factory DarkLibraryMatchTolerances.validated({
    required double exposureSecs,
    required double temperatureC,
  }) {
    if (exposureSecs.isNaN || exposureSecs.isInfinite || exposureSecs < 0) {
      throw ArgumentError.value(
        exposureSecs,
        'exposureSecs',
        'Dark-library exposure tolerance must be a finite, non-negative '
            'number of seconds',
      );
    }
    if (temperatureC.isNaN || temperatureC.isInfinite || temperatureC < 0) {
      throw ArgumentError.value(
        temperatureC,
        'temperatureC',
        'Dark-library temperature tolerance must be a finite, non-negative '
            'number of degrees',
      );
    }
    return DarkLibraryMatchTolerances(
      exposureSecs: exposureSecs,
      temperatureC: temperatureC,
    );
  }

  /// The defaults documented in the class comment. Kept as a named const
  /// so callers can show users what "factory settings" are.
  static const DarkLibraryMatchTolerances defaults =
      DarkLibraryMatchTolerances();

  DarkLibraryMatchTolerances copyWith({
    double? exposureSecs,
    double? temperatureC,
  }) {
    return DarkLibraryMatchTolerances(
      exposureSecs: exposureSecs ?? this.exposureSecs,
      temperatureC: temperatureC ?? this.temperatureC,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DarkLibraryMatchTolerances &&
          exposureSecs == other.exposureSecs &&
          temperatureC == other.temperatureC;

  @override
  int get hashCode => Object.hash(exposureSecs, temperatureC);

  @override
  String toString() =>
      'DarkLibraryMatchTolerances(exposure=±${exposureSecs}s, '
      'temperature=±$temperatureC°C)';
}
