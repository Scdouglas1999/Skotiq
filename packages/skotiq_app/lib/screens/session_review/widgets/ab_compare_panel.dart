import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../session_review_controller.dart';
import 'master_preview_view.dart';

/// Side-by-side A/B comparison of two [IntegrationSettings] recipes over the
/// same accepted subs.
///
/// The comparison is EXPLORATORY: it must not change the controller's working
/// settings, persist a master, or flip the shared hero/`lastOutcome`. Each side
/// runs `controller.reIntegratePreview(settings)`, a throwaway non-persisting
/// integration, which is what guarantees that.
///
/// Recipe A defaults to the controller's current working settings; recipe B
/// seeds a "tighter rejection" variant the user can edit via the recipe chips.
/// Everything routes through the one [SessionReviewController] — no separate
/// provider read — so a comparison stays a comparison.
class AbComparePanel extends StatefulWidget {
  final SessionReviewController controller;

  const AbComparePanel({super.key, required this.controller});

  @override
  State<AbComparePanel> createState() => _AbComparePanelState();
}

class _AbComparePanelState extends State<AbComparePanel> {
  IntegrationSettings? _recipeA;
  IntegrationSettings? _recipeB;

  PostSessionIntegrationOutcome? _outcomeA;
  PostSessionIntegrationOutcome? _outcomeB;
  bool _runningA = false;
  bool _runningB = false;
  String? _error;
  RemoveListener? _removeListener;

  @override
  void initState() {
    super.initState();
    // Seed recipe A from the controller's current working settings (and B from
    // a tighter-rejection variant) the first time the controller publishes its
    // state. Listening avoids the deprecated `debugState` getter and keeps A in
    // sync if the user edits settings elsewhere before running a comparison.
    _removeListener = widget.controller.addListener((state) {
      if (_recipeA != null) return; // seed once; edits below own the recipes
      setState(() {
        _recipeA = state.settings;
        _recipeB = _tighterRejection(state.settings);
      });
    });
  }

  @override
  void dispose() {
    _removeListener?.call();
    super.dispose();
  }

  /// A defensible "B" seed: the same recipe with tighter sigma rejection — the
  /// most common A/B question ("did clipping harder help or hurt?").
  static IntegrationSettings _tighterRejection(IntegrationSettings base) {
    return base.copyWith(
      reject: RejectAlgorithm.sigmaClip,
      rejectLow: (base.rejectLow - 0.5).clamp(1.0, 6.0),
      rejectHigh: (base.rejectHigh - 0.5).clamp(1.0, 6.0),
    );
  }

  Future<void> _run({required bool isA}) async {
    final recipe = isA ? _recipeA : _recipeB;
    if (recipe == null) return;
    setState(() {
      if (isA) {
        _runningA = true;
      } else {
        _runningB = true;
      }
      _error = null;
    });
    final outcome = await widget.controller.reIntegratePreview(recipe);
    if (!mounted) return;
    setState(() {
      if (isA) {
        _runningA = false;
        _outcomeA = outcome;
      } else {
        _runningB = false;
        _outcomeB = outcome;
      }
      if (outcome == null) {
        _error = 'Re-integration failed for recipe ${isA ? 'A' : 'B'}.';
      }
    });
  }

  Future<void> _runBoth() async {
    await _run(isA: true);
    if (!mounted) return;
    await _run(isA: false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final recipeA = _recipeA;
    final recipeB = _recipeB;
    return SkotiqPanel(
      child: Padding(
        padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(SkotiqIcons.layers,
                    size: SkotiqTokens.iconSm, color: colors.accent),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Text(
                  'A / B recipe compare',
                  style: SkotiqTypography.sectionTitle
                      .copyWith(color: colors.textPrimary),
                ),
                const Spacer(),
                SkotiqButton(
                  label: 'Run both',
                  icon: SkotiqIcons.play,
                  variant: ButtonVariant.primary,
                  size: ButtonSize.small,
                  isLoading: _runningA || _runningB,
                  onPressed: (recipeA == null || _runningA || _runningB)
                      ? null
                      : _runBoth,
                ),
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            if (_error != null) ...[
              SkotiqBanner(
                title: 'The comparison could not be built',
                tone: BannerTone.error,
                message: _error!,
              ),
              const SizedBox(height: SkotiqTokens.spaceMd),
            ],
            if (recipeA == null || recipeB == null)
              const Padding(
                padding:
                    EdgeInsets.symmetric(vertical: SkotiqTokens.space4xl),
                child: Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else ...[
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _RecipeColumn(
                        label: 'A',
                        accent: colors.info,
                        settings: recipeA,
                        outcome: _outcomeA,
                        running: _runningA,
                        onEdit: (s) => setState(() => _recipeA = s),
                        onRun: () => _run(isA: true),
                      ),
                    ),
                    const SizedBox(width: SkotiqTokens.spaceMd),
                    Expanded(
                      child: _RecipeColumn(
                        label: 'B',
                        accent: colors.accent,
                        settings: recipeB,
                        outcome: _outcomeB,
                        running: _runningB,
                        onEdit: (s) => setState(() => _recipeB = s),
                        onRun: () => _run(isA: false),
                      ),
                    ),
                  ],
                ),
              ),
              if (_outcomeA != null && _outcomeB != null) ...[
                const SizedBox(height: SkotiqTokens.spaceMd),
                _DiffStrip(a: _outcomeA!.result, b: _outcomeB!.result),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _RecipeColumn extends StatelessWidget {
  final String label;
  final Color accent;
  final IntegrationSettings settings;
  final PostSessionIntegrationOutcome? outcome;
  final bool running;
  final ValueChanged<IntegrationSettings> onEdit;
  final VoidCallback onRun;

  const _RecipeColumn({
    required this.label,
    required this.accent,
    required this.settings,
    required this.outcome,
    required this.running,
    required this.onEdit,
    required this.onRun,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return SkotiqPanel(
      child: Padding(
        padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: SkotiqTokens.spaceLg,
                  height: SkotiqTokens.spaceLg,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: accent.withValues(
                        alpha: SkotiqTokens.opacityStatusFill),
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusSm),
                    border: Border.all(color: accent),
                  ),
                  child: Text(
                    label,
                    style: SkotiqTypography.labelStrongSm
                        .copyWith(color: accent),
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Expanded(
                  child: Text(
                    _recipeSummary(settings),
                    style: SkotiqTypography.bodySm
                        .copyWith(color: colors.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                SkotiqButton(
                  label: 'Run',
                  icon: SkotiqIcons.refresh,
                  variant: ButtonVariant.secondary,
                  size: ButtonSize.small,
                  isLoading: running,
                  onPressed: running ? null : onRun,
                ),
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            _RecipeChips(settings: settings, onEdit: onEdit),
            const SizedBox(height: SkotiqTokens.spaceMd),
            SizedBox(
              height: 280,
              child: outcome != null
                  ? MasterPreviewView.fromOutcome(outcome!)
                  : _PreviewPlaceholder(running: running),
            ),
            if (outcome != null) ...[
              const SizedBox(height: SkotiqTokens.spaceSm),
              _StatBlock(result: outcome!.result),
            ],
          ],
        ),
      ),
    );
  }
}

/// Compact editable knobs for the most A/B-relevant settings (rejection +
/// combine). Heavier editing lives in the full integration settings panel; here
/// we expose just enough to make a meaningful comparison without leaving.
class _RecipeChips extends StatelessWidget {
  final IntegrationSettings settings;
  final ValueChanged<IntegrationSettings> onEdit;

  const _RecipeChips({required this.settings, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Wrap(
      spacing: SkotiqTokens.spaceSm,
      runSpacing: SkotiqTokens.spaceXs,
      children: [
        _Chip(
          icon: SkotiqIcons.filter,
          label: 'Reject: ${_rejectLabel(settings.reject)}',
          colors: colors,
          onTap: () =>
              onEdit(settings.copyWith(reject: _nextReject(settings.reject))),
        ),
        _Chip(
          icon: SkotiqIcons.sliders,
          label:
              'clip ${settings.rejectLow.toStringAsFixed(1)}/${settings.rejectHigh.toStringAsFixed(1)}',
          colors: colors,
        ),
        _Chip(
          icon: SkotiqIcons.layers,
          label: 'Combine: ${_combineLabel(settings.combine)}',
          colors: colors,
          onTap: () => onEdit(settings.copyWith(
            combine: settings.combine == CombineMode.mean
                ? CombineMode.median
                : CombineMode.mean,
          )),
        ),
        if (settings.weightingEnabled)
          _Chip(
            icon: SkotiqIcons.gauge,
            label: 'Weighted',
            colors: colors,
          ),
        if (settings.drizzle)
          _Chip(
            icon: SkotiqIcons.grid,
            label: 'Drizzle ${settings.drizzleScale.toStringAsFixed(1)}×',
            colors: colors,
          ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final SkotiqColors colors;

  /// When set, the chip becomes a tappable control (cycles the setting it
  /// represents); when null it is a display-only pill.
  final VoidCallback? onTap;

  const _Chip({
    required this.icon,
    required this.label,
    required this.colors,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceSm,
        vertical: SkotiqTokens.spaceXs,
      ),
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: SkotiqTokens.iconXs, color: colors.textMuted),
          const SizedBox(width: SkotiqTokens.spaceXs),
          Text(
            label,
            style: SkotiqTypography.labelSm
                .copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
    if (onTap == null) return chip;
    return Semantics(
        button: true,
        enabled: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
          child: chip,
        ));
  }
}

/// Cycle to the next [RejectAlgorithm] so tapping the Reject chip walks the
/// available algorithms.
RejectAlgorithm _nextReject(RejectAlgorithm r) {
  const values = RejectAlgorithm.values;
  return values[(r.index + 1) % values.length];
}

class _PreviewPlaceholder extends StatelessWidget {
  final bool running;
  const _PreviewPlaceholder({required this.running});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        border: Border.all(color: colors.border),
      ),
      alignment: Alignment.center,
      child: running
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(height: SkotiqTokens.spaceSm),
                Text(
                  'Integrating…',
                  style: SkotiqTypography.bodySm
                      .copyWith(color: colors.textSecondary),
                ),
              ],
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(SkotiqIcons.image,
                    size: SkotiqTokens.iconXl, color: colors.textMuted),
                const SizedBox(height: SkotiqTokens.spaceSm),
                Text(
                  'Run this recipe to preview',
                  style: SkotiqTypography.bodySm
                      .copyWith(color: colors.textMuted),
                ),
              ],
            ),
    );
  }
}

class _StatBlock extends StatelessWidget {
  final IntegrateSessionResult result;
  const _StatBlock({required this.result});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Wrap(
      spacing: SkotiqTokens.spaceLg,
      runSpacing: SkotiqTokens.spaceXs,
      children: [
        _Stat(
          label: 'Integrated',
          value: '${result.framesIntegrated}',
          colors: colors,
        ),
        _Stat(
          label: 'Rejected',
          value: '${result.framesRejected}',
          colors: colors,
        ),
        _Stat(
          label: 'Time',
          value: formatHms(result.totalIntegrationSec),
          colors: colors,
        ),
        _Stat(
          label: 'Residual',
          value: '${result.rmsResidual.toStringAsFixed(2)} px',
          colors: colors,
        ),
        _Stat(
          label: 'Size',
          value: '${result.width}×${result.height}',
          colors: colors,
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final SkotiqColors colors;

  const _Stat({
    required this.label,
    required this.value,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: SkotiqTypography.readoutMd
              .copyWith(color: colors.textPrimary),
        ),
        Text(
          label.toUpperCase(),
          style: SkotiqTypography.readoutLabel
              .copyWith(color: colors.textMuted),
        ),
      ],
    );
  }
}

/// Per-metric winner callout under the two previews.
class _DiffStrip extends StatelessWidget {
  final IntegrateSessionResult a;
  final IntegrateSessionResult b;

  const _DiffStrip({required this.a, required this.b});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return SkotiqPanel(
      child: Padding(
        padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Winner by metric',
              style: SkotiqTypography.labelStrong
                  .copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            Wrap(
              spacing: SkotiqTokens.spaceMd,
              runSpacing: SkotiqTokens.spaceXs,
              children: [
                _DiffPill(
                  metric: 'Frames kept',
                  winner: _cmp(a.framesIntegrated, b.framesIntegrated,
                      higherIsBetter: true),
                  detail: '${a.framesIntegrated} vs ${b.framesIntegrated}',
                  colors: colors,
                ),
                _DiffPill(
                  metric: 'Residual',
                  winner:
                      _cmp(a.rmsResidual, b.rmsResidual, higherIsBetter: false),
                  detail:
                      '${a.rmsResidual.toStringAsFixed(2)} vs ${b.rmsResidual.toStringAsFixed(2)} px',
                  colors: colors,
                ),
                _DiffPill(
                  metric: 'Integration time',
                  winner: _cmp(a.totalIntegrationSec, b.totalIntegrationSec,
                      higherIsBetter: true),
                  detail:
                      '${formatHms(a.totalIntegrationSec)} vs ${formatHms(b.totalIntegrationSec)}',
                  colors: colors,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Returns 'A', 'B', or '=' for the winning recipe on a metric.
  static String _cmp(num x, num y, {required bool higherIsBetter}) {
    if (x == y) return '=';
    final aWins = higherIsBetter ? x > y : x < y;
    return aWins ? 'A' : 'B';
  }
}

class _DiffPill extends StatelessWidget {
  final String metric;
  final String winner;
  final String detail;
  final SkotiqColors colors;

  const _DiffPill({
    required this.metric,
    required this.winner,
    required this.detail,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final tint = winner == 'A'
        ? colors.info
        : winner == 'B'
            ? colors.accent
            : colors.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
        vertical: SkotiqTokens.spaceSm,
      ),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: SkotiqTokens.opacityStatusFill),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        border: Border.all(color: tint),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                metric,
                style: SkotiqTypography.labelSm
                    .copyWith(color: colors.textSecondary),
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Text(
                winner == '=' ? 'tie' : 'wins: $winner',
                style: SkotiqTypography.labelStrongSm.copyWith(color: tint),
              ),
            ],
          ),
          Text(
            detail,
            style:
                SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}

String _recipeSummary(IntegrationSettings s) {
  final parts = <String>[
    _combineLabel(s.combine),
    _rejectLabel(s.reject),
    'clip ${s.rejectLow.toStringAsFixed(1)}/${s.rejectHigh.toStringAsFixed(1)}',
    if (s.weightingEnabled) 'weighted',
    if (s.drizzle) 'drizzle',
  ];
  return parts.join(' · ');
}

String _rejectLabel(RejectAlgorithm r) {
  switch (r) {
    case RejectAlgorithm.auto:
      return 'auto';
    case RejectAlgorithm.none:
      return 'none';
    case RejectAlgorithm.sigmaClip:
      return 'sigma';
    case RejectAlgorithm.winsorizedSigma:
      return 'winsorized';
    case RejectAlgorithm.linearFit:
      return 'linear-fit';
    case RejectAlgorithm.percentile:
      return 'percentile';
    case RejectAlgorithm.minMax:
      return 'min/max';
  }
}

String _combineLabel(CombineMode c) {
  switch (c) {
    case CombineMode.mean:
      return 'mean';
    case CombineMode.median:
      return 'median';
  }
}
