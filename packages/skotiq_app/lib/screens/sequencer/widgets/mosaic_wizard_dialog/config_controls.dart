part of '../mosaic_wizard_dialog.dart';

class _GridSizer extends StatelessWidget {
  final SkotiqColors colors;
  final int rows;
  final int cols;
  final double overlapPercent;
  final double rotation;
  final void Function({
    int? rows,
    int? cols,
    double? overlap,
    double? rotation,
  }) onChange;

  const _GridSizer({
    required this.colors,
    required this.rows,
    required this.cols,
    required this.overlapPercent,
    required this.rotation,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Grid', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _IntStepper(
                  colors: colors,
                  label: 'Columns',
                  value: cols,
                  min: 1,
                  max: 10,
                  onChanged: (v) => onChange(cols: v),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _IntStepper(
                  colors: colors,
                  label: 'Rows',
                  value: rows,
                  min: 1,
                  max: 10,
                  onChanged: (v) => onChange(rows: v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _SliderRow(
            colors: colors,
            label: 'Overlap',
            value: overlapPercent,
            min: 0,
            max: 50,
            suffix: '%',
            onChanged: (v) => onChange(overlap: v),
          ),
          const SizedBox(height: 8),
          _SliderRow(
            colors: colors,
            label: 'Rotation',
            value: rotation,
            min: -180,
            max: 180,
            suffix: '°',
            onChanged: (v) => onChange(rotation: v),
          ),
        ],
      ),
    );
  }
}

class _IntStepper extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  const _IntStepper({
    required this.colors,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize11,
                color: colors.textSecondary)),
        const SizedBox(height: 4),
        Row(
          children: [
            _StepperButton(
              colors: colors,
              icon: LucideIcons.minus,
              enabled: value > min,
              onTap: () => onChanged(value - 1),
            ),
            Expanded(
              child: Center(
                child: Text(
                  '$value',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize18,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ),
            _StepperButton(
              colors: colors,
              icon: LucideIcons.plus,
              enabled: value < max,
              onTap: () => onChanged(value + 1),
            ),
          ],
        ),
      ],
    );
  }
}

class _StepperButton extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  const _StepperButton({
    required this.colors,
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            border: Border.all(color: colors.border),
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
            color: enabled ? colors.surfaceAlt : Colors.transparent,
          ),
          child: Icon(
            icon,
            size: 14,
            color: enabled ? colors.textPrimary : colors.textMuted,
          ),
        ),
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final double value;
  final double min;
  final double max;
  final String suffix;
  final ValueChanged<double> onChanged;

  const _SliderRow({
    required this.colors,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.suffix,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: SkotiqTypography.fontSize11,
                    color: colors.textSecondary)),
            const Spacer(),
            Text(
              '${value.toStringAsFixed(0)}$suffix',
              style: TextStyle(
                  fontSize: SkotiqTypography.fontSize12,
                  color: colors.primary,
                  fontWeight: FontWeight.w700),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
            activeColor: colors.primary,
          ),
        ),
      ],
    );
  }
}

class _StatsCard extends StatelessWidget {
  final SkotiqColors colors;
  final int activePanels;
  final String gridLabel;
  final String panelArcminLabel;
  final String overlapLabel;

  /// Number of filters imaged per panel (1 on the simple single-filter path).
  final int filterCount;

  /// Total light-exposure seconds per panel, summed across every filter.
  final double exposureSecsPerPanel;

  /// Total subs per panel, summed across every filter.
  final int exposuresPerPanel;
  final double estTimeHours;
  final int totalExposures;

  const _StatsCard({
    required this.colors,
    required this.activePanels,
    required this.gridLabel,
    required this.panelArcminLabel,
    required this.overlapLabel,
    required this.filterCount,
    required this.exposureSecsPerPanel,
    required this.exposuresPerPanel,
    required this.estTimeHours,
    required this.totalExposures,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final perPanelMins = (exposureSecsPerPanel / 60).toStringAsFixed(0);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Plan summary', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          _row('Active panels:', '$activePanels'),
          _row('Grid:', gridLabel),
          _row('Panel size:', panelArcminLabel),
          _row('Overlap:', overlapLabel),
          if (filterCount > 1) _row('Filters per panel:', '$filterCount'),
          const Divider(height: 16),
          _row('Est. time (${perPanelMins}m/panel x $exposuresPerPanel subs):',
              '${estTimeHours.toStringAsFixed(1)} h',
              highlight: true),
          _row('Total exposures:', '$totalExposures'),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {bool highlight = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The est-time label can be long ("Est. time (5m/panel x 30
          // subs):"); flex it so it wraps within the narrow config column
          // instead of overflowing the fixed-width row.
          Expanded(
            child: Text(label,
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize12,
                  color: colors.textSecondary,
                  fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
                )),
          ),
          const SizedBox(width: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: highlight
                  ? SkotiqTypography.fontSize14
                  : SkotiqTypography.fontSize12,
              color: highlight ? colors.accent : colors.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _AdvancedPanel extends StatelessWidget {
  final SkotiqColors colors;
  final bool expanded;
  final double centerRa;
  final double centerDec;
  final double panelWidthArcmin;
  final double panelHeightArcmin;

  /// Per-dimension: false while neither the rig nor the user has supplied that
  /// panel field. The field then starts EMPTY — pre-filling it with the state's
  /// placeholder prints a concrete size under the banner saying the panel size
  /// is unknown. See `mosaic_wizard_dialog.dart` for why it is per-dimension.
  final bool panelWidthKnown;
  final bool panelHeightKnown;
  final VoidCallback onToggle;
  final void Function({
    double? centerRa,
    double? centerDec,
    double? panelWidthArcmin,
    double? panelHeightArcmin,
  }) onChanged;

  const _AdvancedPanel({
    required this.colors,
    required this.expanded,
    required this.centerRa,
    required this.centerDec,
    required this.panelWidthArcmin,
    required this.panelHeightArcmin,
    required this.panelWidthKnown,
    required this.panelHeightKnown,
    required this.onToggle,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // A bare InkWell publishes a tap action but no role and no enabled
          // state, and AT-SPI reads the missing enabled flag as insensitive, so
          // this live control dumps as `panel: Advanced (numerical) [DISABLED]`.
          // Declaring the role and the (always true) enabled state is what makes
          // it announce as the expandable button it is.
          Semantics(
            button: true,
            enabled: true,
            expanded: expanded,
            label: 'Advanced (numerical)',
            child: InkWell(
              onTap: onToggle,
              borderRadius:
                  BorderRadius.circular(SkotiqTokens.radiusInline8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(LucideIcons.sliders,
                        size: 14, color: colors.textMuted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('Advanced (numerical)',
                          style: SkotiqTypography.labelStrong
                              .copyWith(color: colors.textPrimary)),
                    ),
                    Icon(
                      expanded
                          ? LucideIcons.chevronUp
                          : LucideIcons.chevronDown,
                      size: 14,
                      color: colors.textMuted,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                children: [
                  _NumberField(
                    colors: colors,
                    label: 'Center RA (hours)',
                    value: centerRa,
                    min: 0,
                    max: 24,
                    decimals: 4,
                    onChanged: (v) => onChanged(centerRa: v),
                  ),
                  const SizedBox(height: 10),
                  _NumberField(
                    colors: colors,
                    label: 'Center Dec (degrees)',
                    value: centerDec,
                    min: -90,
                    max: 90,
                    decimals: 4,
                    onChanged: (v) => onChanged(centerDec: v),
                  ),
                  const SizedBox(height: 10),
                  _NumberField(
                    colors: colors,
                    label: 'Panel width (arcmin)',
                    value: panelWidthKnown ? panelWidthArcmin : null,
                    hintText: 'one camera field, e.g. 60.0',
                    min: 1,
                    max: 360,
                    decimals: 1,
                    onChanged: (v) => onChanged(panelWidthArcmin: v),
                  ),
                  const SizedBox(height: 10),
                  _NumberField(
                    colors: colors,
                    label: 'Panel height (arcmin)',
                    value: panelHeightKnown ? panelHeightArcmin : null,
                    hintText: 'one camera field, e.g. 40.0',
                    min: 1,
                    max: 360,
                    decimals: 1,
                    onChanged: (v) => onChanged(panelHeightArcmin: v),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _NumberField extends StatefulWidget {
  final SkotiqColors colors;
  final String label;

  /// The current value, or null when the wizard has no value to show — the
  /// field then starts empty behind [hintText] rather than presenting a
  /// placeholder as fact.
  final double? value;
  final String? hintText;
  final double min;
  final double max;
  final int decimals;
  final ValueChanged<double> onChanged;

  const _NumberField({
    required this.colors,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.decimals,
    required this.onChanged,
    this.hintText,
  });

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final TextEditingController _ctl;
  final FocusNode _focus = FocusNode();

  /// Why the last keystroke was not accepted, or null. Dropping out-of-range
  /// typing in silence leaves the characters in the field and the old number in
  /// the wizard, with nothing saying which one is in force.
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController(
      text: widget.value?.toStringAsFixed(widget.decimals) ?? '',
    );
    _focus.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (_focus.hasFocus) return;
    // On leaving, snap the text back to the value actually in force so the
    // field can never keep a number the wizard rejected.
    final value = widget.value;
    if (value != null) {
      _ctl.text = value.toStringAsFixed(widget.decimals);
    }
    if (_error != null && mounted) setState(() => _error = null);
  }

  @override
  void didUpdateWidget(_NumberField old) {
    super.didUpdateWidget(old);
    final value = widget.value;
    if (value == null) return;
    // Never rewrite the field the user is typing in: this branch would
    // otherwise write the seeded value over a half-entered number.
    if (_focus.hasFocus) return;
    final current = double.tryParse(_ctl.text);
    if (current == null || (current - value).abs() > 1e-3) {
      _ctl.text = value.toStringAsFixed(widget.decimals);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctl,
      focusNode: _focus,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hintText,
        errorText: _error,
        isDense: true,
        border: OutlineInputBorder(
            borderSide: BorderSide(color: widget.colors.border)),
      ),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: (text) {
        final parsed = double.tryParse(text);
        if (parsed != null && parsed >= widget.min && parsed <= widget.max) {
          if (_error != null) setState(() => _error = null);
          widget.onChanged(parsed);
          return;
        }
        // Half-typed input ("", "-", "1.") is on the way somewhere; only a
        // complete number that lands outside the range is a refusal worth
        // showing.
        final message = parsed == null
            ? null
            : 'Enter ${widget.min.toStringAsFixed(0)}–'
                '${widget.max.toStringAsFixed(0)}';
        if (_error != message) setState(() => _error = message);
      },
    );
  }
}

/// One filter's exposure plan in the multi-filter mosaic editor: which filter,
/// how long each sub is, how many subs per panel, and whether it's included.
/// Mutable so the [_FilterPlanCard]'s inline fields can edit it in place; the
/// dialog snapshots it into immutable [MosaicFilterExposure]s when it builds
/// the sequence.
class _MosaicFilterRow {
  String filterName;
  double exposureSeconds;
  int count;
  bool enabled = true;

  _MosaicFilterRow({
    required this.filterName,
    required this.exposureSeconds,
    required this.count,
  });
}

/// Collapsible card that drives the multi-filter mosaic plan. Collapsed (the
/// default) the wizard images each panel with the single Smart-Night filter
/// recommendation. Toggled on, the user edits one row per filter — name,
/// exposure (s) and sub count — and every panel is imaged through each enabled
/// row in order.
class _FilterPlanCard extends StatelessWidget {
  final SkotiqColors colors;
  final bool enabled;
  final List<_MosaicFilterRow> rows;
  final ValueChanged<bool> onToggle;

  /// Called after an in-place edit to a row's fields so the dialog can rebuild
  /// its previews; the row instance is already mutated.
  final VoidCallback onChanged;
  final VoidCallback onAddRow;
  final ValueChanged<_MosaicFilterRow> onRemoveRow;

  const _FilterPlanCard({
    required this.colors,
    required this.enabled,
    required this.rows,
    required this.onToggle,
    required this.onChanged,
    required this.onAddRow,
    required this.onRemoveRow,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              children: [
                Icon(LucideIcons.layers, size: 14, color: colors.textMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Multi-filter plan',
                      style: SkotiqTypography.labelStrong
                          .copyWith(color: colors.textPrimary)),
                ),
                SkotiqSwitch(
                  value: enabled,
                  onChanged: onToggle,
                ),
              ],
            ),
          ),
          if (enabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Each panel is imaged through every enabled filter below.',
                    style: TextStyle(
                        fontSize: SkotiqTypography.fontSize11,
                        color: colors.textMuted),
                  ),
                  const SizedBox(height: 8),
                  for (final row in rows)
                    _FilterPlanRow(
                      key: ObjectKey(row),
                      colors: colors,
                      row: row,
                      canRemove: rows.length > 1,
                      onChanged: onChanged,
                      onRemove: () => onRemoveRow(row),
                    ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SkotiqButton(
                      onPressed: onAddRow,
                      icon: LucideIcons.plus,
                      label: 'Add filter',
                      variant: ButtonVariant.ghost,
                      size: ButtonSize.small,
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

class _FilterPlanRow extends StatefulWidget {
  final SkotiqColors colors;
  final _MosaicFilterRow row;
  final bool canRemove;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  const _FilterPlanRow({
    required this.colors,
    required this.row,
    required this.canRemove,
    required this.onChanged,
    required this.onRemove,
    super.key,
  });

  @override
  State<_FilterPlanRow> createState() => _FilterPlanRowState();
}

class _FilterPlanRowState extends State<_FilterPlanRow> {
  late final TextEditingController _nameCtl;
  late final TextEditingController _expCtl;
  late final TextEditingController _countCtl;

  @override
  void initState() {
    super.initState();
    _nameCtl = TextEditingController(text: widget.row.filterName);
    _expCtl = TextEditingController(
        text: widget.row.exposureSeconds.round().toString());
    _countCtl = TextEditingController(text: widget.row.count.toString());
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    _expCtl.dispose();
    _countCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: SkotiqCheckbox(
              value: widget.row.enabled,
              onChanged: (v) {
                widget.row.enabled = v ?? false;
                widget.onChanged();
              },
            ),
          ),
          Expanded(
            flex: 3,
            child: _SmallField(
              colors: colors,
              controller: _nameCtl,
              hint: 'Filter',
              keyboardType: TextInputType.text,
              onChanged: (v) {
                widget.row.filterName = v.trim().isEmpty ? 'Filter' : v.trim();
                widget.onChanged();
              },
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 2,
            child: _SmallField(
              colors: colors,
              controller: _expCtl,
              hint: 'Exp',
              suffix: 's',
              keyboardType: TextInputType.number,
              onChanged: (v) {
                final parsed = double.tryParse(v);
                if (parsed != null && parsed > 0) {
                  widget.row.exposureSeconds = parsed;
                  widget.onChanged();
                }
              },
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 2,
            child: _SmallField(
              colors: colors,
              controller: _countCtl,
              hint: 'Count',
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (v) {
                final parsed = int.tryParse(v);
                if (parsed != null && parsed > 0) {
                  widget.row.count = parsed;
                  widget.onChanged();
                }
              },
            ),
          ),
          SizedBox(
            width: 32,
            child: IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              iconSize: 16,
              icon: Icon(LucideIcons.trash2,
                  color: widget.canRemove ? colors.textMuted : colors.border),
              onPressed: widget.canRemove ? widget.onRemove : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _SmallField extends StatelessWidget {
  final SkotiqColors colors;
  final TextEditingController controller;
  final String hint;
  final String? suffix;
  final TextInputType keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String> onChanged;

  const _SmallField({
    required this.colors,
    required this.controller,
    required this.hint,
    required this.keyboardType,
    required this.onChanged,
    this.suffix,
    this.inputFormatters,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        style: TextStyle(
            color: colors.textPrimary,
            fontSize: SkotiqTypography.fontSize12),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(
              color: colors.textMuted,
              fontSize: SkotiqTypography.fontSize11),
          suffixText: suffix,
          suffixStyle: TextStyle(
              color: colors.textMuted,
              fontSize: SkotiqTypography.fontSize11),
          isDense: true,
          filled: true,
          fillColor: colors.surfaceAlt,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
            borderSide: BorderSide(color: colors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
            borderSide: BorderSide(color: colors.border),
          ),
        ),
        onChanged: onChanged,
      ),
    );
  }
}

// Visual planner — interactive sky view with FOV panels
