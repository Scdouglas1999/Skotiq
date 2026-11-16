/// Results from a Lomb-Scargle periodogram analysis.
class LombScargleResult {
  /// Trial frequencies at which the periodogram was evaluated.
  final List<double> frequencies;

  /// Normalized power at each trial frequency.
  final List<double> powers;

  /// The frequency with the highest power.
  final double bestFrequency;

  /// The best-fit period (1 / bestFrequency), in the same time units as input.
  final double bestPeriod;

  final double peakPower;

  /// Estimated false alarm probability for the peak.
  /// Lower FAP = more significant detection.
  final double falseAlarmProbability;

  /// Time span of the observations, in the same units as the input times.
  final double timeBaseline;

  /// The period range actually searched. The requested range is clamped to
  /// what the data can support (no period longer than the baseline, none
  /// shorter than twice the sampling interval), so this can be far narrower
  /// than what the caller asked for.
  final double searchedMinPeriod;
  final double searchedMaxPeriod;

  const LombScargleResult({
    required this.frequencies,
    required this.powers,
    required this.bestFrequency,
    required this.bestPeriod,
    required this.peakPower,
    required this.falseAlarmProbability,
    required this.timeBaseline,
    required this.searchedMinPeriod,
    required this.searchedMaxPeriod,
  });

  /// How many full cycles of [bestPeriod] the observations actually cover.
  double get observedCycles => cyclesCovered(timeBaseline, bestPeriod);

  /// Whether the peak is a real period measurement rather than an artefact of
  /// running out of baseline.
  ///
  /// A periodogram cannot see beyond the length of the run: when the true
  /// period exceeds the baseline the peak piles up against the low-frequency
  /// edge of the search and the "best period" simply reports the baseline
  /// back. Two cycles is the usual minimum for a period to be considered
  /// measured; below that the honest statement is "the period is at least
  /// this long", not "the period is this long".
  bool get isPeriodConstrained => isMeasuredPeriod(observedCycles);
}

/// Full cycles of [periodDays] a [baselineDays] run covers.
double cyclesCovered(double baselineDays, double periodDays) =>
    periodDays > 0 ? baselineDays / periodDays : 0.0;

/// Whether [cycles] observed cycles make a period a measurement.
bool isMeasuredPeriod(double cycles) => cycles >= 2.0;

/// Results from a Box Least Squares (BLS) transit search.
class BlsResult {
  /// The best-fit orbital period (same time units as input).
  final double bestPeriod;

  /// The transit duration as a fraction of the period.
  final double transitDurationFraction;

  /// The transit duration in the same time units as input.
  final double transitDuration;

  /// The transit depth in magnitude units.
  final double transitDepth;

  /// Signal Residue (SR) statistic — higher means more significant.
  final double signalResidueStatistic;

  /// Signal Detection Efficiency (SDE) — the significance measure.
  /// SDE > ~6 is typically considered a significant detection.
  final double signalDetectionEfficiency;

  /// The phase of mid-transit (0..1).
  final double transitMidPhase;

  /// Trial periods that were searched.
  final List<double> trialPeriods;

  /// SR statistic at each trial period (for plotting).
  final List<double> srSpectrum;

  const BlsResult({
    required this.bestPeriod,
    required this.transitDurationFraction,
    required this.transitDuration,
    required this.transitDepth,
    required this.signalResidueStatistic,
    required this.signalDetectionEfficiency,
    required this.transitMidPhase,
    required this.trialPeriods,
    required this.srSpectrum,
  });
}

/// A single point in a phase-folded light curve.
class PhaseFoldedPoint {
  /// Phase value (0..1), where 0 = epoch.
  final double phase;

  /// The differential magnitude at this phase.
  final double magnitude;

  /// The uncertainty on the magnitude.
  final double uncertainty;

  const PhaseFoldedPoint({
    required this.phase,
    required this.magnitude,
    required this.uncertainty,
  });
}

/// Combined results from all period analysis algorithms.
class PeriodAnalysisResult {
  final LombScargleResult lombScargle;
  final BlsResult bls;

  const PeriodAnalysisResult({required this.lombScargle, required this.bls});

  /// What the search found, without its periodograms.
  PeriodFinding get finding => PeriodFinding(
    lombScarglePeriodDays: lombScargle.bestPeriod,
    peakPower: lombScargle.peakPower,
    falseAlarmProbability: lombScargle.falseAlarmProbability,
    baselineDays: lombScargle.timeBaseline,
    searchedMinPeriodDays: lombScargle.searchedMinPeriod,
    searchedMaxPeriodDays: lombScargle.searchedMaxPeriod,
    blsPeriodDays: bls.bestPeriod,
    transitDepthMag: bls.transitDepth,
    transitDurationDays: bls.transitDuration,
    signalDetectionEfficiency: bls.signalDetectionEfficiency,
  );
}

/// What a period search found: the numbers a science report prints. The
/// search runs on the screen that shows it and is never stored, so a linked
/// client sends this to its host with the report request.
class PeriodFinding {
  const PeriodFinding({
    required this.lombScarglePeriodDays,
    required this.peakPower,
    required this.falseAlarmProbability,
    required this.baselineDays,
    required this.searchedMinPeriodDays,
    required this.searchedMaxPeriodDays,
    required this.blsPeriodDays,
    required this.transitDepthMag,
    required this.transitDurationDays,
    required this.signalDetectionEfficiency,
  });

  factory PeriodFinding.fromJson(Map<String, dynamic> json) {
    double read(String key) {
      final value = json[key];
      if (value is! num || !value.isFinite) {
        throw FormatException('period.$key must be a finite number');
      }
      return value.toDouble();
    }

    return PeriodFinding(
      lombScarglePeriodDays: read('lombScarglePeriodDays'),
      peakPower: read('peakPower'),
      falseAlarmProbability: read('falseAlarmProbability'),
      baselineDays: read('baselineDays'),
      searchedMinPeriodDays: read('searchedMinPeriodDays'),
      searchedMaxPeriodDays: read('searchedMaxPeriodDays'),
      blsPeriodDays: read('blsPeriodDays'),
      transitDepthMag: read('transitDepthMag'),
      transitDurationDays: read('transitDurationDays'),
      signalDetectionEfficiency: read('signalDetectionEfficiency'),
    );
  }

  final double lombScarglePeriodDays;
  final double peakPower;
  final double falseAlarmProbability;
  final double baselineDays;
  final double searchedMinPeriodDays;
  final double searchedMaxPeriodDays;
  final double blsPeriodDays;
  final double transitDepthMag;
  final double transitDurationDays;
  final double signalDetectionEfficiency;

  /// Cycles of the Lomb-Scargle period the observations span.
  double get observedCycles =>
      cyclesCovered(baselineDays, lombScarglePeriodDays);

  /// Whether the period is a measurement rather than a lower bound (see
  /// [LombScargleResult.isPeriodConstrained]).
  bool get isPeriodConstrained => isMeasuredPeriod(observedCycles);

  Map<String, dynamic> toJson() => {
    'lombScarglePeriodDays': lombScarglePeriodDays,
    'peakPower': peakPower,
    'falseAlarmProbability': falseAlarmProbability,
    'baselineDays': baselineDays,
    'searchedMinPeriodDays': searchedMinPeriodDays,
    'searchedMaxPeriodDays': searchedMaxPeriodDays,
    'blsPeriodDays': blsPeriodDays,
    'transitDepthMag': transitDepthMag,
    'transitDurationDays': transitDurationDays,
    'signalDetectionEfficiency': signalDetectionEfficiency,
  };
}
