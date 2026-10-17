import 'package:flutter/material.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Editor for [IntegrationSettings]: smart-default presets front-and-centre with
/// a collapsible "Advanced" section exposing every knob.
///
/// The panel is a pure controlled widget — it never mutates settings itself;
/// every change is reported through [onChanged] so the owning controller is the
/// single source of truth. [subCount] drives the live "this run will use N subs"
/// readout and the resolved-auto-reject hint so the smart default is transparent.
class IntegrationSettingsPanel extends StatefulWidget {
  final IntegrationSettings settings;
  final int subCount;
  final ValueChanged<IntegrationSettings> onChanged;

  const IntegrationSettingsPanel({
    super.key,
    required this.settings,
    required this.subCount,
    required this.onChanged,
  });

  /// Human-readable list of the knobs [settings] changes relative to the
  /// Balanced baseline ([IntegrationSettings.defaults]), e.g.
  /// `['RANSAC 1.0 px', 'Max ref stars 120', 'Normalization Local grid']`.
  /// Empty when the settings are the baseline.
  ///
  /// Derived by diffing, never hand-written per preset: the readout under the
  /// chips therefore cannot claim a distinction a profile does not make. That
  /// matters because "Maximum Quality" once shipped as a byte-identical copy of
  /// Balanced, and every surface described the two runs the same way.
  static List<String> deltasFromBalanced(IntegrationSettings s) {
    const base = IntegrationSettings.defaults;
    final out = <String>[];
    void add(bool changed, String text) {
      if (changed) out.add(text);
    }

    add(s.model != base.model,
        'Model ${_IntegrationSettingsPanelState._transformLabel(s.model)}');
    add(s.resampler != base.resampler,
        _IntegrationSettingsPanelState._resamplerLabel(s.resampler));
    add(s.ransacThresholdPx != base.ransacThresholdPx,
        'RANSAC ${s.ransacThresholdPx.toStringAsFixed(1)} px');
    add(s.maxRefStars != base.maxRefStars, 'Max ref stars ${s.maxRefStars}');
    add(s.weighting != base.weighting,
        'Weight ${_IntegrationSettingsPanelState._weightLabel(s.weighting)}');
    add(!s.weightingEnabled, 'No weighting');
    add(
        s.normalization != base.normalization,
        'Normalization '
        '${_IntegrationSettingsPanelState._normLabel(s.normalization)}');
    add(!s.normalizationEnabled, 'No normalization');
    add(s.reject != base.reject,
        'Reject ${_IntegrationSettingsPanelState._rejectLabel(s.reject)}');
    add(s.rejectLow != base.rejectLow || s.rejectHigh != base.rejectHigh,
        'Thresholds ${s.rejectLow}/${s.rejectHigh}');
    add(s.generateRejectionMap != base.generateRejectionMap,
        s.generateRejectionMap ? 'Rejection map' : 'No rejection map');
    add(
        s.cosmeticCorrection != base.cosmeticCorrection,
        s.cosmeticCorrection
            ? 'Cosmetic correction'
            : 'No cosmetic correction');
    add(s.outputBitDepth != base.outputBitDepth,
        s.outputBitDepth == OutputBitDepth.f32 ? '32-bit float' : '16-bit');
    add(s.drizzle != base.drizzle, s.drizzle ? 'Drizzle' : 'No drizzle');
    return out;
  }

  @override
  State<IntegrationSettingsPanel> createState() =>
      _IntegrationSettingsPanelState();
}

class _IntegrationSettingsPanelState extends State<IntegrationSettingsPanel> {
  bool _advancedExpanded = false;

  IntegrationSettings get _s => widget.settings;

  void _emit(IntegrationSettings next) => widget.onChanged(next);

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final resolved = _s.resolvedReject(widget.subCount);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SectionTitle(
          icon: SkotiqIcons.layers,
          title: 'Integration',
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        _PresetChips(
          active: _s.sourcePreset,
          onSelected: (preset) => _emit(IntegrationSettings.preset(preset)),
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        _ReadoutCard(
          subCount: widget.subCount,
          resolvedReject: resolved,
          autoCullPercentile: _s.autoCull ? _s.cullPercentile : null,
          deltas: IntegrationSettingsPanel.deltasFromBalanced(_s),
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        _AdvancedToggle(
          expanded: _advancedExpanded,
          onTap: () => setState(() => _advancedExpanded = !_advancedExpanded),
        ),
        if (_advancedExpanded) ...[
          const SizedBox(height: SkotiqTokens.spaceMd),
          _advancedSection(colors),
        ],
      ],
    );
  }

  Widget _advancedSection(SkotiqColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const _GroupLabel('Alignment'),
        _DropdownRow<TransformModel>(
          label: 'Transform model',
          tooltip: 'Geometric model fit by RANSAC. Affine suits most rigs; '
              'Homography for wide / uncorrected fields.',
          value: _s.model,
          values: TransformModel.values,
          labelOf: _transformLabel,
          onChanged: (v) =>
              _emit(_s.copyWith(model: v, clearSourcePreset: true)),
        ),
        _DropdownRow<Resampler>(
          label: 'Resampler',
          tooltip: 'Output interpolation kernel. Lanczos-3 is highest quality '
              '(PixInsight default); Bilinear is fastest.',
          value: _s.resampler,
          values: Resampler.values,
          labelOf: _resamplerLabel,
          onChanged: (v) =>
              _emit(_s.copyWith(resampler: v, clearSourcePreset: true)),
        ),
        _SliderRow(
          label: 'RANSAC threshold',
          tooltip: 'Inlier distance in reference pixels.',
          value: _s.ransacThresholdPx,
          min: 0.5,
          max: 6.0,
          divisions: 11,
          suffix: ' px',
          onChanged: (v) =>
              _emit(_s.copyWith(ransacThresholdPx: v, clearSourcePreset: true)),
        ),
        _StepperRow(
          label: 'Max reference stars',
          tooltip: 'Brightest-N stars used for asterism matching.',
          value: _s.maxRefStars,
          min: 20,
          max: 300,
          step: 10,
          onChanged: (v) =>
              _emit(_s.copyWith(maxRefStars: v, clearSourcePreset: true)),
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        const _GroupLabel('Weighting'),
        _SwitchRow(
          label: 'Per-sub weighting',
          tooltip: 'Let the best subs dominate the master (PSF Signal Weight).',
          value: _s.weightingEnabled,
          onChanged: (v) =>
              _emit(_s.copyWith(weightingEnabled: v, clearSourcePreset: true)),
        ),
        if (_s.weightingEnabled)
          _DropdownRow<WeightFormula>(
            label: 'Weight formula',
            tooltip: 'How a sub\'s quality maps to its integration weight.',
            value: _s.weighting,
            values: WeightFormula.values,
            labelOf: _weightLabel,
            onChanged: (v) =>
                _emit(_s.copyWith(weighting: v, clearSourcePreset: true)),
          ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        const _GroupLabel('Normalization'),
        _SwitchRow(
          label: 'Normalize to reference',
          tooltip:
              'Match each sub\'s background + scale to the reference before '
              'rejection (essential for correct sigma-clip).',
          value: _s.normalizationEnabled,
          onChanged: (v) => _emit(
              _s.copyWith(normalizationEnabled: v, clearSourcePreset: true)),
        ),
        if (_s.normalizationEnabled)
          _DropdownRow<NormalizationMode>(
            label: 'Mode',
            tooltip:
                'Global = one coefficient per channel. Local = a grid that '
                'tracks gradient drift through a long night.',
            value: _s.normalization,
            values: NormalizationMode.values,
            labelOf: _normLabel,
            onChanged: (v) =>
                _emit(_s.copyWith(normalization: v, clearSourcePreset: true)),
          ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        const _GroupLabel('Pixel rejection'),
        _DropdownRow<RejectAlgorithm>(
          label: 'Algorithm',
          tooltip:
              'Auto picks by sub count: <8 percentile, 8-24 Winsorized-sigma, '
              '25+ linear-fit.',
          value: _s.reject,
          values: RejectAlgorithm.values,
          labelOf: _rejectLabel,
          onChanged: (v) =>
              _emit(_s.copyWith(reject: v, clearSourcePreset: true)),
        ),
        _SliderRow(
          label: 'Reject low',
          tooltip: 'Low threshold (sigma, or fraction for percentile).',
          value: _s.rejectLow,
          min: 0.0,
          max: 5.0,
          divisions: 20,
          onChanged: (v) =>
              _emit(_s.copyWith(rejectLow: v, clearSourcePreset: true)),
        ),
        _SliderRow(
          label: 'Reject high',
          tooltip: 'High threshold (sigma, or fraction for percentile).',
          value: _s.rejectHigh,
          min: 0.0,
          max: 5.0,
          divisions: 20,
          onChanged: (v) =>
              _emit(_s.copyWith(rejectHigh: v, clearSourcePreset: true)),
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        const _GroupLabel('Output & calibration'),
        _DropdownRow<OutputBitDepth>(
          label: 'Master bit depth',
          tooltip: 'F32 keeps the linear master unquantised (archival).',
          value: _s.outputBitDepth,
          values: OutputBitDepth.values,
          labelOf: (v) => v == OutputBitDepth.f32 ? '32-bit float' : '16-bit',
          onChanged: (v) =>
              _emit(_s.copyWith(outputBitDepth: v, clearSourcePreset: true)),
        ),
        _SwitchRow(
          label: 'Generate rejection map',
          tooltip: 'Save a per-pixel rejection-count map (satellites, planes).',
          value: _s.generateRejectionMap,
          onChanged: (v) => _emit(
              _s.copyWith(generateRejectionMap: v, clearSourcePreset: true)),
        ),
        _SwitchRow(
          label: 'Cosmetic correction',
          tooltip: 'Correct hot/cold pixels per light before registration.',
          value: _s.cosmeticCorrection,
          onChanged: (v) => _emit(
              _s.copyWith(cosmeticCorrection: v, clearSourcePreset: true)),
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        const _GroupLabel('Drizzle'),
        _SwitchRow(
          label: 'Drizzle integrate',
          tooltip:
              'Variable-pixel reconstruction onto a finer grid instead of plain '
              'resample-and-combine. Pays off only with dithered, undersampled '
              'data — off by default.',
          value: _s.drizzle,
          onChanged: (v) =>
              _emit(_s.copyWith(drizzle: v, clearSourcePreset: true)),
        ),
        if (_s.drizzle) ...[
          _SliderRow(
            label: 'Scale',
            tooltip: 'Linear output/input scale factor (2× is typical).',
            value: _s.drizzleScale,
            min: 1.0,
            max: 3.0,
            divisions: 8,
            suffix: '×',
            onChanged: (v) =>
                _emit(_s.copyWith(drizzleScale: v, clearSourcePreset: true)),
          ),
          _SliderRow(
            label: 'Pixfrac',
            tooltip:
                'Drop-shrink fraction in (0, 1]. Smaller = sharper, noisier.',
            value: _s.drizzlePixfrac,
            min: 0.1,
            max: 1.0,
            divisions: 9,
            onChanged: (v) =>
                _emit(_s.copyWith(drizzlePixfrac: v, clearSourcePreset: true)),
          ),
          _DropdownRow<DrizzleKernel>(
            label: 'Kernel',
            tooltip: 'Drop-deposition footprint.',
            value: _s.drizzleKernel,
            values: DrizzleKernel.values,
            labelOf: _drizzleKernelLabel,
            onChanged: (v) =>
                _emit(_s.copyWith(drizzleKernel: v, clearSourcePreset: true)),
          ),
          _SwitchRow(
            label: 'Bayer drizzle',
            tooltip: 'Drizzle the raw CFA mosaic directly into RGB (no debayer '
                'interpolation). Only for one-shot-colour sensors.',
            value: _s.bayerDrizzle,
            onChanged: (v) =>
                _emit(_s.copyWith(bayerDrizzle: v, clearSourcePreset: true)),
          ),
        ],
      ],
    );
  }

  static String _drizzleKernelLabel(DrizzleKernel k) => switch (k) {
        DrizzleKernel.square => 'Square',
        DrizzleKernel.gaussian => 'Gaussian',
        DrizzleKernel.point => 'Point',
      };

  static String _transformLabel(TransformModel m) => switch (m) {
        TransformModel.similarity => 'Similarity',
        TransformModel.affine => 'Affine',
        TransformModel.homography => 'Homography',
      };

  static String _resamplerLabel(Resampler r) => switch (r) {
        Resampler.bilinear => 'Bilinear',
        Resampler.catmullRom => 'Catmull-Rom',
        Resampler.lanczos3 => 'Lanczos-3',
      };

  static String _weightLabel(WeightFormula w) => switch (w) {
        WeightFormula.snr => 'SNR',
        WeightFormula.snrSquared => 'SNR squared',
        WeightFormula.fwhmInverse => 'Inverse FWHM',
        WeightFormula.custom => 'Custom exponents',
      };

  static String _normLabel(NormalizationMode m) =>
      m == NormalizationMode.global ? 'Global' : 'Local grid';

  static String _rejectLabel(RejectAlgorithm r) => switch (r) {
        RejectAlgorithm.auto => 'Auto (by sub count)',
        RejectAlgorithm.none => 'None',
        RejectAlgorithm.sigmaClip => 'Sigma clip',
        RejectAlgorithm.winsorizedSigma => 'Winsorized sigma',
        RejectAlgorithm.linearFit => 'Linear fit',
        RejectAlgorithm.percentile => 'Percentile',
        RejectAlgorithm.minMax => 'Min/max',
      };
}

class _PresetChips extends StatelessWidget {
  final IntegrationPreset? active;
  final ValueChanged<IntegrationPreset> onSelected;

  const _PresetChips({required this.active, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Wrap(
      spacing: SkotiqTokens.spaceSm,
      runSpacing: SkotiqTokens.spaceSm,
      children: IntegrationPreset.values.map((preset) {
        final selected = preset == active;
        return ChoiceChip(
          label: Text(
            preset.label,
            style: SkotiqTypography.labelSm.copyWith(
              color: selected ? colors.textPrimary : colors.textSecondary,
            ),
          ),
          selected: selected,
          selectedColor: colors.primary.withValues(alpha: 0.2),
          backgroundColor: colors.well,
          side: BorderSide(color: selected ? colors.primary : colors.border),
          onSelected: (_) => onSelected(preset),
          visualDensity: VisualDensity.compact,
        );
      }).toList(),
    );
  }
}

class _ReadoutCard extends StatelessWidget {
  final int subCount;
  final RejectAlgorithm resolvedReject;
  final double? autoCullPercentile;

  /// Knobs the active settings change relative to the Balanced baseline; see
  /// [IntegrationSettingsPanel.deltasFromBalanced]. Rendered verbatim so two
  /// profiles that stack identically cannot describe themselves differently.
  final List<String> deltas;

  const _ReadoutCard({
    required this.subCount,
    required this.resolvedReject,
    required this.autoCullPercentile,
    required this.deltas,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final rejectLabel = switch (resolvedReject) {
      RejectAlgorithm.percentile => 'Percentile clip',
      RejectAlgorithm.winsorizedSigma => 'Winsorized sigma',
      RejectAlgorithm.linearFit => 'Linear fit',
      RejectAlgorithm.sigmaClip => 'Sigma clip',
      RejectAlgorithm.minMax => 'Min/max',
      RejectAlgorithm.none => 'No rejection',
      RejectAlgorithm.auto => 'Auto',
    };
    final cull = autoCullPercentile;
    return SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(SkotiqIcons.info, size: 16, color: colors.info),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Will integrate $subCount accepted sub'
                  '${subCount == 1 ? '' : 's'} using $rejectLabel'
                  '${cull != null ? '. Recommends culling the worst '
                      '${(cull * 100).round()}%' : ''}.',
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: SkotiqTokens.spaceXs),
                Text(
                  deltas.isEmpty
                      ? 'Same knobs as Balanced.'
                      : 'Differs from Balanced: ${deltas.join(' · ')}.',
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AdvancedToggle extends StatelessWidget {
  final bool expanded;
  final VoidCallback onTap;

  const _AdvancedToggle({required this.expanded, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Semantics(
        button: true,
        enabled: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm),
            child: Row(
              children: [
                Icon(
                  expanded ? SkotiqIcons.chevronDown : SkotiqIcons.chevronRight,
                  size: 16,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: SkotiqTokens.spaceXs),
                Text(
                  'Advanced settings',
                  style: SkotiqTypography.label.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ));
  }
}

class _GroupLabel extends StatelessWidget {
  final String label;
  const _GroupLabel(this.label);

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(
        top: SkotiqTokens.spaceXs,
        bottom: SkotiqTokens.spaceXs,
      ),
      child: Text(
        label.toUpperCase(),
        style: SkotiqTypography.labelStrongSm.copyWith(
          color: colors.textMuted,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _RowShell extends StatelessWidget {
  final String label;
  final String? tooltip;
  final Widget control;

  const _RowShell({
    required this.label,
    required this.control,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceXs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    label,
                    style: SkotiqTypography.bodySm.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
                if (tooltip != null) ...[
                  const SizedBox(width: SkotiqTokens.spaceXs),
                  Tooltip(
                    message: tooltip!,
                    child: Icon(
                      SkotiqIcons.info,
                      size: 12,
                      color: colors.textMuted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceMd),
          control,
        ],
      ),
    );
  }
}

class _DropdownRow<T> extends StatelessWidget {
  final String label;
  final String? tooltip;
  final T value;
  final List<T> values;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  const _DropdownRow({
    required this.label,
    required this.value,
    required this.values,
    required this.labelOf,
    required this.onChanged,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final names = values.map((v) => v.toString()).toList();
    final labels = values.map(labelOf).toList();
    return _RowShell(
      label: label,
      tooltip: tooltip,
      control: SizedBox(
        width: 180,
        child: SkotiqDropdown(
          isExpanded: true,
          isDense: true,
          value: value.toString(),
          items: names,
          itemLabels: labels,
          onChanged: (name) {
            if (name == null) return;
            final idx = names.indexOf(name);
            if (idx >= 0) onChanged(values[idx]);
          },
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final String label;
  final String? tooltip;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return _RowShell(
      label: label,
      tooltip: tooltip,
      control: SkotiqSwitch(value: value, onChanged: onChanged),
    );
  }
}

class _SliderRow extends StatelessWidget {
  final String label;
  final String? tooltip;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String suffix;
  final ValueChanged<double> onChanged;

  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    this.tooltip,
    this.suffix = '',
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return _RowShell(
      label: label,
      tooltip: tooltip,
      control: SizedBox(
        width: 200,
        child: Row(
          children: [
            Expanded(
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                activeColor: colors.primary,
                onChanged: onChanged,
              ),
            ),
            SizedBox(
              width: 46,
              child: Text(
                '${value.toStringAsFixed(1)}$suffix',
                textAlign: TextAlign.end,
                style: SkotiqTypography.mono.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StepperRow extends StatelessWidget {
  final String label;
  final String? tooltip;
  final int value;
  final int min;
  final int max;
  final int step;
  final ValueChanged<int> onChanged;

  const _StepperRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return _RowShell(
      label: label,
      tooltip: tooltip,
      control: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            icon:
                Icon(SkotiqIcons.remove, size: 16, color: colors.textSecondary),
            onPressed: value > min
                ? () => onChanged((value - step).clamp(min, max))
                : null,
          ),
          SizedBox(
            width: 40,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: SkotiqTypography.mono.copyWith(
                color: colors.textPrimary,
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(SkotiqIcons.add, size: 16, color: colors.textSecondary),
            onPressed: value < max
                ? () => onChanged((value + step).clamp(min, max))
                : null,
          ),
        ],
      ),
    );
  }
}
