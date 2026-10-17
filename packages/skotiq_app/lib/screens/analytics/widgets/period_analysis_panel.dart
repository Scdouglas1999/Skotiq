import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/snackbar_helper.dart';
import 'adaptive_chart_container.dart';
import 'chart_axis.dart';

part 'period_analysis_panel/result_widgets.dart';
part 'period_analysis_panel/periodogram_painter.dart';
part 'period_analysis_panel/phase_fold_painter.dart';
part 'period_analysis_panel/bls_spectrum_painter.dart';

const _kPeriodAnalysisInfo = '''
Period analysis searches your light curve for a repeating signal — the rotation period of a variable star, the orbital period of an eclipsing binary, or the period of a transiting exoplanet. Skotiq runs two complementary algorithms.

Lomb-Scargle is a frequency-domain method that finds sinusoidal periodicity, well suited to smoothly varying stars (pulsators, spotted rotators). Box Least Squares (BLS) instead fits a flat-bottomed box dip and is the standard tool for finding the brief, periodic dimming of a planetary transit.

The False Alarm Probability (FAP) reported for the Lomb-Scargle peak is the chance that noise alone would produce a peak this strong. FAP < 0.01 is a significant detection; FAP < 0.001 is a strong one.

For BLS, the Signal Detection Efficiency (SDE) measures how far the best period stands above the surrounding spectrum. SDE > 6 is noteworthy; SDE > 7 is a strong transit candidate worth following up.

The phase-folded plots wrap every data point onto a single cycle at the best period, so a real signal collapses into a clean shape. As with all photometry charts here, magnitude is inverted — brighter points sit higher on the plot.
''';

/// The one way this panel writes a period.
///
/// Every headline and every chart marker goes through here, so the same
/// detected period cannot be stated three ways on one scroll. The axes keep
/// their own natural units (cycles per day, log period) and say so in their
/// labels.
String formatPeriodLabel(double periodDays) {
  if (periodDays < 1.0) {
    final hours = periodDays * 24.0;
    if (hours < 1.0) {
      final minutes = hours * 60.0;
      return '${minutes.toStringAsFixed(1)} min';
    }
    return '${hours.toStringAsFixed(2)} hr';
  }
  return '${periodDays.toStringAsFixed(4)} d';
}

/// The peak marker drawn on the Lomb-Scargle periodogram.
///
/// The x axis there is frequency, but the annotation is a PERIOD and has to
/// read like the headline result it annotates.
@visibleForTesting
String periodogramPeakLabel(double bestFrequency) =>
    'P=${formatPeriodLabel(1.0 / bestFrequency)}';

/// The peak marker drawn on the BLS spectrum.
@visibleForTesting
String blsPeakLabel(double bestPeriodDays) =>
    'P=${formatPeriodLabel(bestPeriodDays)}';

/// Panel that provides Lomb-Scargle and BLS period detection analysis
/// for variable star and exoplanet transit detection.
class PeriodAnalysisPanel extends ConsumerStatefulWidget {
  final SkotiqColors colors;

  /// Photometry from the session currently being analysed.
  final List<LightCurvePoint> lightCurve;

  /// The same object measured across every night of the campaign, when the
  /// session belongs to a target. A single night is almost never long enough
  /// to measure a period, so this is the series that usually matters.
  final List<LightCurvePoint> campaignLightCurve;

  /// Number of sessions [campaignLightCurve] spans, for the scope labels.
  final int campaignSessionCount;

  const PeriodAnalysisPanel({
    super.key,
    required this.colors,
    required this.lightCurve,
    this.campaignLightCurve = const [],
    this.campaignSessionCount = 0,
  });

  @override
  ConsumerState<PeriodAnalysisPanel> createState() =>
      _PeriodAnalysisPanelState();
}

class _PeriodAnalysisPanelState extends ConsumerState<PeriodAnalysisPanel> {
  double _minPeriod = 0.01;
  double _maxPeriod = 10.0;
  late final _minPeriodController =
      TextEditingController(text: _minPeriod.toStringAsFixed(3));
  late final _maxPeriodController =
      TextEditingController(text: _maxPeriod.toStringAsFixed(1));
  final _customPeriodController = TextEditingController();

  /// Analyse the whole campaign by default when one is available: a single
  /// night can only ever bound the period from below.
  bool _useCampaignScope = true;

  /// The series the search actually runs on.
  List<LightCurvePoint> get _activeCurve =>
      _campaignAvailable && _useCampaignScope
          ? widget.campaignLightCurve
          : widget.lightCurve;

  bool get _campaignAvailable =>
      widget.campaignSessionCount > 1 &&
      widget.campaignLightCurve.length > widget.lightCurve.length;

  @override
  void dispose() {
    _minPeriodController.dispose();
    _maxPeriodController.dispose();
    _customPeriodController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final analysisState = ref.watch(periodAnalysisProvider);
    final colors = widget.colors;

    return SkotiqPanel(
      padding: SkotiqTokens.paddingLg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Icon(LucideIcons.activity,
                  size: SkotiqTokens.iconSm, color: colors.primary),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(
                child: Text(
                  'Period Analysis',
                  style: SkotiqTypography.sectionTitle.copyWith(
                      color: colors.textPrimary, fontWeight: FontWeight.w600),
                ),
              ),
              const ScienceInfoButton(
                title: 'Period analysis',
                body: _kPeriodAnalysisInfo,
              ),
              if (analysisState.result != null)
                Tooltip(
                  message: 'Clear results',
                  child: Semantics(
                      button: true,
                      enabled: true,
                      child: InkWell(
                        onTap: () =>
                            ref.read(periodAnalysisProvider.notifier).clear(),
                        borderRadius: SkotiqTokens.borderRadiusLg,
                        child: Container(
                          constraints: const BoxConstraints(
                            minWidth: SkotiqTokens.minTouchTarget,
                            minHeight: SkotiqTokens.minTouchTarget,
                          ),
                          alignment: Alignment.center,
                          child: Icon(LucideIcons.x,
                              size: SkotiqTokens.iconXs,
                              color: colors.textMuted),
                        ),
                      )),
                ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),

          // Controls row
          if (_campaignAvailable) ...[
            _buildScopeSelector(colors),
            const SizedBox(height: SkotiqTokens.spaceMd),
          ],
          _buildControls(colors, analysisState),
          const SizedBox(height: SkotiqTokens.spaceLg),

          // Results
          if (analysisState.isRunning)
            AdaptiveChartContainer.fixed(
              height: 200,
              // The skeleton is the well; `panel -> well` is as deep as the
              // ladder goes.
              well: false,
              child: ShimmerLoading(
                child: Container(
                  decoration: BoxDecoration(
                    color: colors.well,
                    borderRadius: SkotiqTokens.borderRadiusLg,
                    border: Border.all(color: colors.border),
                  ),
                  padding: SkotiqTokens.paddingLg,
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SkeletonBox(width: 160, height: 12),
                      SizedBox(height: SkotiqTokens.spaceMd),
                      Expanded(child: SkeletonBox(height: double.infinity)),
                    ],
                  ),
                ),
              ),
            )
          else if (analysisState.error != null)
            _buildError(colors, analysisState.error!)
          else if (analysisState.result != null)
            _buildResults(colors, analysisState)
          else
            _buildEmptyState(colors),
        ],
      ),
    );
  }

  /// Choose between this night and the whole campaign. Defaults to the
  /// campaign because a single night's baseline is shorter than nearly every
  /// period worth searching for, which forces an unconstrained result.
  Widget _buildScopeSelector(SkotiqColors colors) {
    final campaignNights = widget.campaignSessionCount;
    Widget chip(
        String label, String detail, bool selected, VoidCallback onTap) {
      return Expanded(
        child: Semantics(
            button: true,
            enabled: true,
            selected: selected,
            child: InkWell(
              onTap: onTap,
              borderRadius: SkotiqTokens.borderRadiusLg,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: SkotiqTokens.spaceMd,
                  vertical: SkotiqTokens.spaceSm,
                ),
                decoration: BoxDecoration(
                  color: selected
                      ? colors.primary.withValues(
                          alpha: SkotiqTokens.opacityAccentTint,
                        )
                      : null,
                  borderRadius: SkotiqTokens.borderRadiusLg,
                  border: Border.all(
                    color: selected ? colors.primary : colors.border,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: SkotiqTypography.labelSm.copyWith(
                        color: selected ? colors.primary : colors.textPrimary,
                      ),
                    ),
                    Text(
                      detail,
                      style: SkotiqTypography.caption
                          .copyWith(color: colors.textMuted),
                    ),
                  ],
                ),
              ),
            )),
      );
    }

    return Row(
      children: [
        chip(
          'This session',
          '${widget.lightCurve.length} points',
          !_useCampaignScope,
          () => setState(() => _useCampaignScope = false),
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        chip(
          'All nights',
          '${widget.campaignLightCurve.length} points · $campaignNights sessions',
          _useCampaignScope,
          () => setState(() => _useCampaignScope = true),
        ),
      ],
    );
  }

  Widget _buildPeriodField({
    required TextEditingController controller,
    ValueChanged<String>? onChanged,
    double width = 70,
  }) {
    return SizedBox(
      width: width,
      child: SkotiqTextField(
        controller: controller,
        hint: width >= 100 ? 'e.g. 1.234' : null,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[\d.]')),
        ],
        onChanged: onChanged,
      ),
    );
  }

  Widget _buildControls(
      SkotiqColors colors, PeriodAnalysisState analysisState) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = constraints.maxWidth < 1080;

        final minField = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Min period (d):',
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textSecondary),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            _buildPeriodField(
              controller: _minPeriodController,
              onChanged: (v) {
                final parsed = double.tryParse(v);
                if (parsed != null && parsed > 0) {
                  _minPeriod = parsed;
                }
              },
            ),
          ],
        );

        final maxField = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Max period (d):',
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textSecondary),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            _buildPeriodField(
              controller: _maxPeriodController,
              onChanged: (v) {
                final parsed = double.tryParse(v);
                if (parsed != null && parsed > 0) {
                  _maxPeriod = parsed;
                }
              },
            ),
          ],
        );

        Widget runButton = SkotiqButton(
          label: 'Run Period Search',
          icon: LucideIcons.search,
          size: ButtonSize.small,
          onPressed: analysisState.isRunning
              ? null
              : () {
                  ref.read(periodAnalysisProvider.notifier).runAnalysis(
                        lightCurve: _activeCurve,
                        config: PeriodAnalysisConfig(
                          minPeriodDays: _minPeriod,
                          maxPeriodDays: _maxPeriod,
                        ),
                      );
                },
        );
        if (stacked) {
          runButton = SizedBox(width: double.infinity, child: runButton);
        }

        final controlBar = stacked
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  minField,
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  maxField,
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  runButton,
                ],
              )
            : Row(
                children: [
                  Expanded(child: minField),
                  const SizedBox(width: SkotiqTokens.spaceLg),
                  Expanded(child: maxField),
                  const SizedBox(width: SkotiqTokens.spaceLg),
                  runButton,
                ],
              );

        if (analysisState.result == null) return controlBar;

        final customLabel = Text(
          'Custom period (d):',
          style: SkotiqTypography.caption.copyWith(color: colors.textSecondary),
        );
        final customField = _buildPeriodField(
          controller: _customPeriodController,
          width: 100,
        );
        Widget foldButton = SkotiqButton(
          label: 'Fold',
          size: ButtonSize.small,
          onPressed: () {
            final period = double.tryParse(_customPeriodController.text);
            if (period != null && period > 0) {
              ref.read(periodAnalysisProvider.notifier).setCustomPeriod(
                    periodDays: period,
                    lightCurve: _activeCurve,
                  );
            } else {
              context
                  .showErrorSnackBar('Enter a period in days greater than 0');
            }
          },
        );
        if (stacked) {
          foldButton = SizedBox(width: double.infinity, child: foldButton);
        }

        final customRow = stacked
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      customLabel,
                      const SizedBox(width: SkotiqTokens.spaceSm),
                      Expanded(child: customField),
                    ],
                  ),
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  foldButton,
                ],
              )
            : Row(
                children: [
                  customLabel,
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  customField,
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  foldButton,
                ],
              );

        return Column(
          children: [
            controlBar,
            const SizedBox(height: SkotiqTokens.spaceSm),
            customRow,
          ],
        );
      },
    );
  }

  Widget _buildError(SkotiqColors colors, String error) {
    return Container(
      padding: SkotiqTokens.paddingMd,
      decoration: BoxDecoration(
        color: colors.error.withValues(alpha: 0.1),
        borderRadius: SkotiqTokens.borderRadiusLg,
        border: Border.all(color: colors.error.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.alertTriangle,
              size: SkotiqTokens.iconSm, color: colors.error),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Expanded(
            child: Text(
              error,
              style: SkotiqTypography.caption.copyWith(color: colors.error),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(SkotiqColors colors) {
    final pointCount = _activeCurve.length;
    final tooFew = pointCount < 10;
    return AdaptiveChartContainer.fixed(
      // The guidance body needs more vertical room than the ready-to-run
      // prompt. At 120px the compact empty state had only 94px after padding
      // and border, so its icon, wrapped title, and body overflowed in valid
      // early-session layouts.
      //
      // Raised again for the Observatory `EmptyState`: its title is
      // `sectionTitle` (15) where the old one was `h6` (14), and at this width
      // that one point takes both of these titles onto an extra line — 21px in
      // the tall branch, 11px in the short one, both measured.
      height: tooFew ? 215 : 140,
      well: false,
      child: Container(
        decoration: SkotiqDecorations.well(colors),
        child: EmptyState.compact(
          icon: LucideIcons.activity,
          title: tooFew
              ? 'Need at least 10 photometry points ($pointCount available)'
              : 'Click "Run Period Search" to analyze $pointCount data points',
          body: tooFew
              ? 'Pick a target star in the Differential Photometry chart and capture more frames.'
              : null,
        ),
      ),
    );
  }

  Widget _buildResults(SkotiqColors colors, PeriodAnalysisState analysisState) {
    final result = analysisState.result!;
    final ls = result.lombScargle;
    final bls = result.bls;

    // Phase fold at the best LS period by default.
    final service = ref.read(periodAnalysisServiceProvider);
    final lsPhaseFold = service.phaseFold(
      points: widget.lightCurve,
      periodDays: ls.bestPeriod,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Best period summary
        _buildPeriodSummary(colors, ls, bls),
        const SizedBox(height: SkotiqTokens.spaceLg),

        // Lomb-Scargle power spectrum
        Text(
          'Lomb-Scargle Periodogram',
          style: SkotiqTypography.bodySm
              .copyWith(color: colors.textPrimary, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        AdaptiveChartContainer(
          preferredHeight: 200,
          child: _PeriodogramPainter(
            colors: colors,
            frequencies: ls.frequencies,
            powers: ls.powers,
            bestFrequency: ls.bestFrequency,
            plotColor: SkotiqChartColors.seriesBlue,
            peakColor: SkotiqChartColors.seriesAmber,
            xLabel: 'Frequency (1/day)',
            yLabel: 'Power',
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),

        // Phase-folded light curve at best LS period
        Text(
          'Phase-Folded Light Curve (P = ${_formatPeriod(ls.bestPeriod)})',
          style: SkotiqTypography.bodySm
              .copyWith(color: colors.textPrimary, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        AdaptiveChartContainer(
          preferredHeight: 200,
          child: _PhaseFoldPainter(
            colors: colors,
            points: lsPhaseFold,
            plotColor: SkotiqChartColors.seriesBlue,
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),

        // BLS results
        _buildBlsSection(colors, bls),

        // Custom phase fold (if set)
        if (analysisState.customPhaseFold != null &&
            analysisState.customPeriodDays != null) ...[
          const SizedBox(height: SkotiqTokens.spaceLg),
          Text(
            'Custom Phase Fold (P = ${_formatPeriod(analysisState.customPeriodDays!)})',
            style: SkotiqTypography.bodySm.copyWith(
                color: colors.textPrimary, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          AdaptiveChartContainer(
            preferredHeight: 200,
            child: _PhaseFoldPainter(
              colors: colors,
              points: analysisState.customPhaseFold!,
              plotColor: SkotiqChartColors.seriesViolet,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildPeriodSummary(
      SkotiqColors colors, LombScargleResult ls, BlsResult bls) {
    final fap = ls.falseAlarmProbability;
    // A peak found with less than two cycles of coverage is the baseline
    // reporting itself back, not a measured period — a run shorter than the
    // period always piles the periodogram up against its low-frequency edge.
    // Withhold the verdict there rather than badging "Strong" on a number that
    // is just the length of the night.
    final constrained = ls.isPeriodConstrained;
    final _Verdict? lsVerdict = !constrained
        ? null
        : fap < 0.001
            ? _Verdict.strong
            : fap < 0.01
                ? _Verdict.significant
                : null;
    final sde = bls.signalDetectionEfficiency;
    // The BLS statistic SR = s^2 / (r(1-r)) is sign-blind, so its best box can
    // be BRIGHTER than the out-of-box baseline — an anti-transit. On pure noise
    // that is the usual outcome. Such a solution is not a transit candidate and
    // must never carry a detection verdict.
    final brightening = _isBrightening(bls);
    final _Verdict? blsVerdict = !constrained || brightening
        ? null
        : sde > 7
            ? _Verdict.strong
            : sde > 6
                ? _Verdict.noteworthy
                : null;

    final lsColumn = _ResultColumn(
      colors: colors,
      label: 'Lomb-Scargle Best Period',
      value: constrained
          ? _formatPeriod(ls.bestPeriod)
          : '≥ ${_formatPeriod(ls.bestPeriod)}',
      detail: constrained
          ? 'Peak power: ${ls.peakPower.toStringAsFixed(2)}  |  FAP: ${_formatFap(fap)}'
          : 'Only ${ls.observedCycles.toStringAsFixed(2)} cycles observed — '
              'this run is too short to measure the period',
      verdict: lsVerdict,
    );
    final blsColumn = _ResultColumn(
      colors: colors,
      label: 'BLS Best Period',
      value: constrained
          ? _formatPeriod(bls.bestPeriod)
          : '≥ ${_formatPeriod(bls.bestPeriod)}',
      // SDE is meaningless without the bar it has to clear, so the number is
      // always printed against the 6.0 threshold the service documents.
      // Comparing SDE across different light curves is still not meaningful,
      // which is why that caveat stays.
      detail: constrained
          ? '${_depthLabel(bls)}: ${_depthMmag(bls)} mmag  |  '
              'SDE: ${sde.toStringAsFixed(1)} '
              '(${sde > 6 ? 'above' : 'below'} the 6.0 significance threshold; '
              'compare SDE only within one light curve)'
          : 'Needs a longer baseline to separate a transit from a trend',
      verdict: blsVerdict,
    );

    // The requested range is silently clamped to what the data supports. Say
    // so, rather than leaving "Max period: 10.0" on screen next to a search
    // that never looked past a fraction of a day.
    final clampedHigh = ls.searchedMaxPeriod < _maxPeriod * 0.999;
    final clampedLow = ls.searchedMinPeriod > _minPeriod * 1.001;

    return Container(
      padding: SkotiqTokens.paddingMd,
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: 0.06),
        borderRadius: SkotiqTokens.borderRadiusLg,
        border: Border.all(color: colors.primary.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 1080) {
                return Column(
                  children: [
                    lsColumn,
                    Divider(
                        height: SkotiqTokens.space2xl, color: colors.border),
                    blsColumn,
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: lsColumn),
                  Container(
                    width: 1,
                    height: 40,
                    color: colors.border,
                  ),
                  Expanded(child: blsColumn),
                ],
              );
            },
          ),
          if (clampedHigh || clampedLow) ...[
            const SizedBox(height: SkotiqTokens.spaceSm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(LucideIcons.info,
                    size: SkotiqTokens.iconXs, color: colors.textMuted),
                const SizedBox(width: SkotiqTokens.spaceXs),
                Expanded(
                  child: Text(
                    'Searched ${_formatPeriodDays(ls.searchedMinPeriod)}'
                    '–${_formatPeriodDays(ls.searchedMaxPeriod)} d — '
                    '${clampedHigh ? 'capped by the ${_formatPeriodDays(ls.timeBaseline)} d baseline' : 'raised to twice the sampling interval'}'
                    '${clampedHigh && clampedLow ? ' and by the sampling interval' : ''}.',
                    style: SkotiqTypography.caption
                        .copyWith(color: colors.textMuted),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Period in days at a precision that stays readable across the four orders
  /// of magnitude this search spans.
  static String _formatPeriodDays(double days) {
    if (days >= 1) return days.toStringAsFixed(2);
    if (days >= 0.1) return days.toStringAsFixed(3);
    return days.toStringAsFixed(4);
  }

  Widget _buildBlsSection(SkotiqColors colors, BlsResult bls) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Box Least Squares (Transit Search)',
          style: SkotiqTypography.bodySm
              .copyWith(color: colors.textPrimary, fontWeight: FontWeight.w600),
        ),
        if (_isBrightening(bls)) ...[
          const SizedBox(height: SkotiqTokens.spaceXs),
          // Not a caveat on a detection — a statement that the search did not
          // find one. The box that maximised SR sits ABOVE the baseline, which
          // is what pure noise usually produces.
          Text(
            'Best box is brighter than the baseline: this is an anti-transit '
            '(a brightening), not a transit candidate.',
            style: SkotiqTypography.captionSm.copyWith(
              color: colors.warning,
            ),
          ),
        ],
        const SizedBox(height: SkotiqTokens.spaceSm),
        // BLS SR spectrum
        AdaptiveChartContainer(
          preferredHeight: 180,
          child: _BlsSpectrumPainter(
            colors: colors,
            trialPeriods: bls.trialPeriods,
            srSpectrum: bls.srSpectrum,
            bestPeriod: bls.bestPeriod,
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        // BLS detail stats
        Wrap(
          spacing: SkotiqTokens.space2xl,
          runSpacing: SkotiqTokens.spaceSm,
          children: [
            _BlsStat(
                colors: colors,
                label: 'Period',
                value: _formatPeriod(bls.bestPeriod)),
            _BlsStat(
                colors: colors,
                label: 'Duration',
                value: _formatDuration(bls.transitDuration)),
            _BlsStat(
                colors: colors,
                label: _depthLabel(bls),
                value: '${_depthMmag(bls)} mmag'),
            _BlsStat(
                colors: colors,
                label: 'SDE',
                value: bls.signalDetectionEfficiency.toStringAsFixed(2)),
            _BlsStat(
                colors: colors,
                label: 'Mid-phase',
                value: bls.transitMidPhase.toStringAsFixed(3)),
          ],
        ),
      ],
    );
  }

  /// The BLS box that maximises SR can be brighter than the out-of-box
  /// baseline (negative depth). Labelling that "Depth" under a heading that
  /// says "Transit Search" presents a brightening as a transit.
  static bool _isBrightening(BlsResult bls) => bls.transitDepth < 0;

  static String _depthLabel(BlsResult bls) =>
      _isBrightening(bls) ? 'Brightening (anti-transit)' : 'Depth';

  static String _depthMmag(BlsResult bls) =>
      (bls.transitDepth.abs() * 1000).toStringAsFixed(1);

  String _formatPeriod(double periodDays) => formatPeriodLabel(periodDays);

  String _formatDuration(double durationDays) {
    final hours = durationDays * 24.0;
    if (hours < 1.0) {
      return '${(hours * 60.0).toStringAsFixed(1)} min';
    }
    return '${hours.toStringAsFixed(2)} hr';
  }

  String _formatFap(double fap) {
    if (fap < 1e-10) return '< 1e-10';
    if (fap < 0.001) return fap.toStringAsExponential(1);
    return fap.toStringAsFixed(4);
  }
}
