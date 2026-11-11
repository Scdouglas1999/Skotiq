part of '../period_analysis_panel.dart';

/// Lomb-Scargle power against frequency, with the best period marked.
class _PeriodogramChart extends StatelessWidget {
  const _PeriodogramChart({
    required this.frequencies,
    required this.powers,
    required this.bestFrequency,
  });

  final List<double> frequencies;
  final List<double> powers;
  final double bestFrequency;

  @override
  Widget build(BuildContext context) {
    final count = math.min(frequencies.length, powers.length);
    return SkotiqChart(
      semanticLabel: 'Lomb-Scargle periodogram, '
          'strongest at ${periodogramPeakLabel(bestFrequency)}',
      series: <ChartSeries>[
        ChartSeries(
          points: <Offset>[
            for (var i = 0; i < count; i++) Offset(frequencies[i], powers[i]),
          ],
          label: 'Power',
          color: SkotiqChartColors.seriesBlue,
        ),
      ],
      x: const ChartAxis(title: 'Frequency (1/day)'),
      // Normalized power sits below 0.1 for anything short of a strong
      // detection, so the scale is fitted from zero rather than fixed at 1.
      y: const ChartAxis(includeZero: true, title: 'Power'),
      rules: <ChartRule>[
        ChartRule.x(
          bestFrequency,
          color: SkotiqChartColors.seriesAmber,
          dashed: false,
          label: periodogramPeakLabel(bestFrequency),
        ),
      ],
      emptyText: 'No periodogram to display',
    );
  }
}

/// The light curve folded on a period: magnitude against phase, brighter up,
/// each point with its uncertainty.
class _PhaseFoldChart extends StatelessWidget {
  const _PhaseFoldChart({required this.points, required this.plotColor});

  final List<PhaseFoldedPoint> points;

  /// A fixed series hue; the chart re-expresses it for red night.
  final Color plotColor;

  @override
  Widget build(BuildContext context) {
    return SkotiqChart(
      semanticLabel: 'Phase-folded light curve, ${points.length} points',
      series: <ChartSeries>[
        ChartSeries(
          points: <Offset>[
            for (final p in points) Offset(p.phase, p.magnitude),
          ],
          errors: <double>[for (final p in points) p.uncertainty],
          label: 'Magnitude',
          color: plotColor,
          kind: ChartSeriesKind.scatter,
        ),
      ],
      x: const ChartAxis(
        min: 0,
        max: 1,
        ticks: <double>[0, 0.2, 0.4, 0.6, 0.8, 1],
        title: 'Phase',
      ),
      y: const ChartAxis(inverted: true, title: 'Magnitude (brighter up)'),
      emptyText: 'No data to display',
    );
  }
}

/// Box Least Squares signal residual against trial period, on a logarithmic
/// period axis, with the best period marked.
class _BlsSpectrumChart extends StatelessWidget {
  const _BlsSpectrumChart({
    required this.trialPeriods,
    required this.srSpectrum,
    required this.bestPeriod,
  });

  final List<double> trialPeriods;
  final List<double> srSpectrum;
  final double bestPeriod;

  static double _log10(double v) => math.log(v) / math.ln10;

  @override
  Widget build(BuildContext context) {
    final count = math.min(trialPeriods.length, srSpectrum.length);
    final positive = count > 0 && trialPeriods.first > 0;
    return SkotiqChart(
      semanticLabel: 'Box Least Squares spectrum, '
          'strongest at ${blsPeakLabel(bestPeriod)}',
      series: <ChartSeries>[
        if (positive)
          ChartSeries(
            points: <Offset>[
              for (var i = 0; i < count; i++)
                Offset(_log10(trialPeriods[i]), srSpectrum[i]),
            ],
            label: 'SR',
            color: SkotiqChartColors.seriesGreen,
          ),
      ],
      x: ChartAxis(
        // Each tick names its own unit, so the caption does not claim one.
        title: 'Period (log scale)',
        ticks: positive
            ? <double>[
                for (final period in ChartScale.logTicks(
                  trialPeriods.first,
                  trialPeriods[count - 1],
                ))
                  _log10(period),
              ]
            : null,
        format: (v) {
          final days = math.pow(10, v).toDouble();
          return days < 1
              ? '${QuantityFormat.trimmed(days * 24, maxDecimals: 2)}h'
              : '${QuantityFormat.trimmed(days, maxDecimals: 2)}d';
        },
      ),
      y: const ChartAxis(includeZero: true, title: 'SR (signal residue)'),
      rules: <ChartRule>[
        if (positive && bestPeriod > 0)
          ChartRule.x(
            _log10(bestPeriod),
            color: SkotiqChartColors.seriesAmber,
            dashed: false,
            label: blsPeakLabel(bestPeriod),
          ),
      ],
      emptyText: 'No BLS data',
    );
  }
}
