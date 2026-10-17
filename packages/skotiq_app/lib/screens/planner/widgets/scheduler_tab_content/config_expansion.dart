part of '../scheduler_tab_content.dart';

class _ConfigExpansion extends StatefulWidget {
  final SchedulerConfig config;
  final void Function(SchedulerWeights) onWeightsChanged;
  final void Function(double) onMinAltitudeChanged;
  final void Function(double) onHysteresisChanged;

  const _ConfigExpansion({
    required this.config,
    required this.onWeightsChanged,
    required this.onMinAltitudeChanged,
    required this.onHysteresisChanged,
  });

  @override
  State<_ConfigExpansion> createState() => _ConfigExpansionState();
}

class _ConfigExpansionState extends State<_ConfigExpansion> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final w = widget.config.weights;
    final c = widget.config;
    return Theme(
      data: Theme.of(context).copyWith(
          dividerColor: Colors.transparent, splashColor: Colors.transparent),
      // ExpansionTile's header is a ListTile; the surrounding SkotiqCard
      // is a DecoratedBox with a background color, which (Flutter 3.44) trips
      // the "ListTile ink/background may be invisible" assertion. A
      // transparent Material gives the ListTile a Material ancestor to paint
      // on without changing the visuals.
      child: Material(
        type: MaterialType.transparency,
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          initiallyExpanded: _expanded,
          onExpansionChanged: (v) => setState(() => _expanded = v),
          leading: Icon(LucideIcons.sliders,
              size: SkotiqTokens.iconSm, color: colors.primary),
          title: Text(
            'Scoring weights',
            style: SkotiqTypography.labelStrong.copyWith(
              color: colors.textPrimary,
            ),
          ),
          children: [
            _WeightSlider(
              label: 'Altitude',
              value: w.altitude,
              onChanged: (v) =>
                  widget.onWeightsChanged(w.copyWith(altitude: v)),
            ),
            _WeightSlider(
              label: 'Meridian',
              value: w.meridian,
              onChanged: (v) =>
                  widget.onWeightsChanged(w.copyWith(meridian: v)),
            ),
            _WeightSlider(
              label: 'Moon',
              value: w.moon,
              onChanged: (v) => widget.onWeightsChanged(w.copyWith(moon: v)),
            ),
            _WeightSlider(
              label: 'Time remaining',
              value: w.timeRemaining,
              onChanged: (v) =>
                  widget.onWeightsChanged(w.copyWith(timeRemaining: v)),
            ),
            _WeightSlider(
              label: 'Filter coverage',
              value: w.filterCoverage,
              onChanged: (v) =>
                  widget.onWeightsChanged(w.copyWith(filterCoverage: v)),
            ),
            _WeightSlider(
              label: 'User priority',
              value: w.userPriority,
              onChanged: (v) =>
                  widget.onWeightsChanged(w.copyWith(userPriority: v)),
            ),
            const Divider(height: 12),
            _ParameterSlider(
              label: 'Min altitude',
              value: c.minAltitudeDegrees,
              min: 0.0,
              max: 60.0,
              divisions: 60,
              suffix: '°',
              onChanged: widget.onMinAltitudeChanged,
            ),
            _ParameterSlider(
              label: 'Switch hysteresis',
              value: c.hysteresisRatio,
              min: 1.0,
              max: 2.0,
              divisions: 20,
              suffix: 'x',
              onChanged: widget.onHysteresisChanged,
            ),
          ],
        ),
      ),
    );
  }
}

class _WeightSlider extends StatelessWidget {
  final String label;
  final double value;
  final void Function(double) onChanged;

  const _WeightSlider({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textSecondary),
            ),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(0.0, 3.0),
              min: 0.0,
              max: 3.0,
              divisions: 30,
              label: value.toStringAsFixed(2),
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(
              value.toStringAsFixed(2),
              textAlign: TextAlign.right,
              style: SkotiqTypography.caption.copyWith(
                  color: colors.textPrimary,
                  fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
        ],
      ),
    );
  }
}

class _ParameterSlider extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String suffix;
  final void Function(double) onChanged;

  const _ParameterSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.suffix,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textSecondary),
            ),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              label: '${value.toStringAsFixed(2)}$suffix',
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 60,
            child: Text(
              '${value.toStringAsFixed(2)}$suffix',
              textAlign: TextAlign.right,
              style: SkotiqTypography.caption.copyWith(
                  color: colors.textPrimary,
                  fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
        ],
      ),
    );
  }
}
