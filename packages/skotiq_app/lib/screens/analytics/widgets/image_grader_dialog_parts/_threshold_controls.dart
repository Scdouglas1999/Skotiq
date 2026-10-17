// Threshold sliders, numeric rows and the rejection list.
part of '../image_grader_dialog.dart';

class _ThresholdSliders extends StatelessWidget {
  final SkotiqColors colors;
  final FrameGradeRules rules;
  final List<DbCapturedImage> frames;
  final Map<int, ({double? fwhm, double? eccentricity})> psfMetricsByImage;
  final ValueChanged<FrameGradeRules> onChanged;

  const _ThresholdSliders({
    required this.colors,
    required this.rules,
    required this.frames,
    required this.psfMetricsByImage,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final hfrs = frames
        .map((f) => f.hfr)
        .whereType<double>()
        .where((v) => v.isFinite)
        .toList(growable: false);
    final stars =
        frames.map((f) => f.starCount).whereType<int>().toList(growable: false);
    final guiding = frames
        .map((f) => f.guidingRmsTotal)
        .whereType<double>()
        .where((v) => v.isFinite)
        .toList(growable: false);
    final fwhms = psfMetricsByImage.values
        .map((m) => m.fwhm)
        .whereType<double>()
        .toList(growable: false);
    final eccs = psfMetricsByImage.values
        .map((m) => m.eccentricity)
        .whereType<double>()
        .toList(growable: false);

    return Column(
      children: [
        _DoubleRow(
          colors: colors,
          label: 'Max HFR',
          unit: 'px',
          metric: 'HFR',
          value: rules.maxHfr,
          available: hfrs,
          rangeMin: hfrs.isEmpty ? 0.0 : hfrs.reduce((a, b) => a < b ? a : b),
          rangeMax: hfrs.isEmpty ? 10.0 : hfrs.reduce((a, b) => a > b ? a : b),
          onChanged: (v) => onChanged(rules.copyWith(maxHfr: v)),
          onCleared: () => onChanged(rules.copyWith(clearHfr: true)),
        ),
        // FWHM / eccentricity come from each frame's PSF field map (science
        // pipeline product); frames without one skip these rules, and the
        // sliders disable entirely when no frame has PSF data.
        _DoubleRow(
          colors: colors,
          label: 'Max FWHM',
          unit: 'px',
          metric: 'FWHM',
          value: rules.maxFwhm,
          available: fwhms,
          rangeMin: fwhms.isEmpty ? 0.0 : fwhms.reduce((a, b) => a < b ? a : b),
          rangeMax:
              fwhms.isEmpty ? 12.0 : fwhms.reduce((a, b) => a > b ? a : b),
          onChanged: (v) => onChanged(rules.copyWith(maxFwhm: v)),
          onCleared: () => onChanged(rules.copyWith(clearFwhm: true)),
        ),
        _DoubleRow(
          colors: colors,
          label: 'Max eccentricity',
          unit: '',
          metric: 'eccentricity',
          value: rules.maxEccentricity,
          available: eccs,
          rangeMin: 0,
          rangeMax: eccs.isEmpty ? 1.0 : eccs.reduce((a, b) => a > b ? a : b),
          onChanged: (v) => onChanged(rules.copyWith(maxEccentricity: v)),
          onCleared: () => onChanged(rules.copyWith(clearEccentricity: true)),
        ),
        _IntRow(
          colors: colors,
          label: 'Min stars',
          metric: 'star count',
          value: rules.minStars,
          available: stars,
          rangeMin: stars.isEmpty ? 0 : stars.reduce((a, b) => a < b ? a : b),
          rangeMax: stars.isEmpty ? 200 : stars.reduce((a, b) => a > b ? a : b),
          onChanged: (v) => onChanged(rules.copyWith(minStars: v)),
          onCleared: () => onChanged(rules.copyWith(clearStars: true)),
        ),
        _DoubleRow(
          colors: colors,
          label: 'Max guiding RMS',
          unit: '"',
          metric: 'guiding',
          value: rules.maxGuidingRmsTotalArcsec,
          available: guiding,
          rangeMin: 0,
          rangeMax:
              guiding.isEmpty ? 3.0 : guiding.reduce((a, b) => a > b ? a : b),
          onChanged: (v) =>
              onChanged(rules.copyWith(maxGuidingRmsTotalArcsec: v)),
          onCleared: () => onChanged(rules.copyWith(clearGuiding: true)),
        ),
      ],
    );
  }
}

/// How far a threshold slider's track runs.
///
/// A session where every frame shares one value (one HFR, one FWHM) gives a
/// zero-width range, which Material refuses; the track is widened by one unit
/// so it still renders.
@visibleForTesting
double thresholdSliderMax(double rangeMin, double rangeMax) =>
    rangeMax <= rangeMin ? rangeMin + 1 : rangeMax;

/// Where a "Max x" rule's thumb sits.
///
/// An off rule sits at the permissive end of the complete slider track.
@visibleForTesting
double maxRuleThumbValue(double? value, double rangeMin, double rangeMax) {
  final top = thresholdSliderMax(rangeMin, rangeMax);
  return (value ?? top).clamp(rangeMin, top);
}

/// Where a "Min x" rule's thumb sits.
///
/// The permissive end of a minimum is the BOTTOM, so an off rule parks there.
/// A rule that IS set still has to be able to reach the top of the widened
/// track: clamping it to `rangeMax` instead sprang the thumb back to the
/// bottom of a degenerate track while the readout kept showing the higher
/// number the user had just dragged to.
@visibleForTesting
int minRuleThumbValue(int? value, int rangeMin, int rangeMax) {
  final top =
      thresholdSliderMax(rangeMin.toDouble(), rangeMax.toDouble()).round();
  return (value ?? rangeMin).clamp(rangeMin, top);
}

class _DoubleRow extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final String unit;
  final String metric;
  final double? value;
  final List<double> available;
  final double rangeMin;
  final double rangeMax;
  final ValueChanged<double> onChanged;
  final VoidCallback onCleared;

  const _DoubleRow({
    required this.colors,
    required this.label,
    required this.unit,
    required this.metric,
    required this.value,
    required this.available,
    required this.rangeMin,
    required this.rangeMax,
    required this.onChanged,
    required this.onCleared,
  });

  @override
  Widget build(BuildContext context) {
    final span = rangeMax - rangeMin;
    final enabled = available.isNotEmpty;
    final sliderMax = thresholdSliderMax(rangeMin, rangeMax);
    final effectiveValue = maxRuleThumbValue(value, rangeMin, rangeMax);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceXs + 2),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textSecondary),
                ),
                if (!enabled)
                  Text(
                    'no $metric data',
                    style: SkotiqTypography.captionSm
                        .copyWith(color: colors.textMuted),
                  ),
              ],
            ),
          ),
          Expanded(
            // An off rule is dimmed rather than hidden: it still reads as a
            // track the user can drag to switch the rule on, but it no longer
            // looks like a threshold that is in force.
            child: Opacity(
              opacity: value == null ? 0.45 : 1.0,
              child: SkotiqSlider(
                min: rangeMin,
                max: sliderMax,
                value: effectiveValue,
                divisions: span > 0 ? 40 : null,
                onChanged: enabled ? onChanged : null,
              ),
            ),
          ),
          SizedBox(
            width: 86,
            child: Text(
              value == null ? 'off' : '${value!.toStringAsFixed(2)} $unit',
              style: SkotiqTypography.monoSm.copyWith(
                color: value == null ? colors.textMuted : colors.textPrimary,
              ),
            ),
          ),
          SkotiqIconButton(
            icon: value == null ? LucideIcons.plus : LucideIcons.minus,
            tooltip: value == null ? 'Enable rule' : 'Disable rule',
            size: IconButtonSize.sm,
            onPressed: () {
              if (value == null) {
                onChanged((rangeMin + rangeMax) / 2);
              } else {
                onCleared();
              }
            },
          ),
        ],
      ),
    );
  }
}

class _IntRow extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final String metric;
  final int? value;
  final List<int> available;
  final int rangeMin;
  final int rangeMax;
  final ValueChanged<int> onChanged;
  final VoidCallback onCleared;

  const _IntRow({
    required this.colors,
    required this.label,
    required this.metric,
    required this.value,
    required this.available,
    required this.rangeMin,
    required this.rangeMax,
    required this.onChanged,
    required this.onCleared,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = available.isNotEmpty;
    final effective = minRuleThumbValue(value, rangeMin, rangeMax);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceXs + 2),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textSecondary),
                ),
                if (!enabled)
                  Text(
                    'no $metric data',
                    style: SkotiqTypography.captionSm
                        .copyWith(color: colors.textMuted),
                  ),
              ],
            ),
          ),
          Expanded(
            // Same convention as [_DoubleRow]: an off rule is dimmed, and its
            // thumb sits at the permissive end — here the MINIMUM, because
            // "Min stars: off" accepts any star count.
            child: Opacity(
              opacity: value == null ? 0.45 : 1.0,
              child: SkotiqSlider(
                min: rangeMin.toDouble(),
                max: thresholdSliderMax(
                    rangeMin.toDouble(), rangeMax.toDouble()),
                value: effective.toDouble(),
                divisions:
                    (rangeMax - rangeMin) > 0 ? (rangeMax - rangeMin) : null,
                onChanged: enabled ? (v) => onChanged(v.round()) : null,
              ),
            ),
          ),
          SizedBox(
            width: 86,
            child: Text(
              value == null ? 'off' : '$value',
              style: SkotiqTypography.monoSm.copyWith(
                color: value == null ? colors.textMuted : colors.textPrimary,
              ),
            ),
          ),
          SkotiqIconButton(
            icon: value == null ? LucideIcons.plus : LucideIcons.minus,
            tooltip: value == null ? 'Enable rule' : 'Disable rule',
            size: IconButtonSize.sm,
            onPressed: () {
              if (value == null) {
                onChanged(((rangeMin + rangeMax) / 2).round());
              } else {
                onCleared();
              }
            },
          ),
        ],
      ),
    );
  }
}

class _PreviewSummary extends StatelessWidget {
  final SkotiqColors colors;
  final int rejected;
  final int accepted;
  final String activeRules;

  const _PreviewSummary({
    required this.colors,
    required this.rejected,
    required this.accepted,
    required this.activeRules,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
        vertical: SkotiqTokens.spaceSm + 2,
      ),
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: SkotiqTokens.borderRadiusLg,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Chip(
                colors: colors,
                label: 'Will reject',
                value: '$rejected',
                tone: rejected == 0 ? colors.textMuted : colors.warning,
              ),
              const SizedBox(width: SkotiqTokens.spaceMd),
              _Chip(
                colors: colors,
                label: 'Will keep',
                value: '$accepted',
                tone: colors.success,
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Text(
            activeRules,
            style: SkotiqTypography.monoXs.copyWith(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final String value;
  final Color tone;

  const _Chip({
    required this.colors,
    required this.label,
    required this.value,
    required this.tone,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceSm + 2,
        vertical: SkotiqTokens.spaceXs + 1,
      ),
      decoration: SkotiqDecorations.chip(colors, tone: tone),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: SkotiqTypography.captionSm
                .copyWith(color: colors.textSecondary),
          ),
          const SizedBox(width: SkotiqTokens.spaceXs + 2),
          Text(
            value,
            style: SkotiqTypography.withTabular(
              SkotiqTypography.labelStrong.copyWith(
                color: tone,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What is about to be rejected, and why.
///
/// Bounded and independently scrollable so it always sits directly above the
/// dialog's action bar: this is the confirmation list for a destructive-looking
/// action, so it must be readable without hunting for a scroll.
class _RejectionList extends StatefulWidget {
  final SkotiqColors colors;
  final List<({DbCapturedImage frame, String reason})> rejections;

  const _RejectionList({required this.colors, required this.rejections});

  @override
  State<_RejectionList> createState() => _RejectionListState();
}

class _RejectionListState extends State<_RejectionList> {
  /// Shared by the list and its scrollbar so the thumb can stay visible.
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final rejections = widget.rejections;
    if (rejections.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceMd + 2),
        child: Text(
          'No frames currently fail any rule.',
          style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
        ),
      );
    }
    // Never more than a bit over a quarter of the viewport, so the sliders
    // above keep a usable share of a phone-sized dialog.
    final maxHeight = math.min(190.0, MediaQuery.sizeOf(context).height * 0.28);
    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        border: Border.all(color: colors.border),
        borderRadius: SkotiqTokens.borderRadiusLg,
      ),
      child: Scrollbar(
        controller: _controller,
        thumbVisibility: true,
        child: ListView.separated(
          controller: _controller,
          itemCount: rejections.length,
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          separatorBuilder: (_, __) =>
              Divider(color: colors.border, height: 1, thickness: 0.5),
          itemBuilder: (_, i) {
            final r = rejections[i];
            final filename = r.frame.filePath.split(RegExp(r'[\\/]')).last;
            return Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: SkotiqTokens.spaceMd,
                vertical: SkotiqTokens.spaceSm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    filename,
                    style: SkotiqTypography.label
                        .copyWith(color: colors.textPrimary),
                  ),
                  const SizedBox(height: SkotiqTokens.spaceXs - 2),
                  Text(
                    r.reason,
                    style: SkotiqTypography.captionSm
                        .copyWith(color: colors.textMuted),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
