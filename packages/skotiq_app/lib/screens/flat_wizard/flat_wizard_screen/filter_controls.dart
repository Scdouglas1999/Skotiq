part of '../flat_wizard_screen.dart';

/// The filter a quick capture takes: a picker over the loaded filters.
class _FilterSelector extends ConsumerWidget {
  const _FilterSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final state = ref.watch(flatWizardProvider);
    final notifier = ref.read(flatWizardProvider.notifier);
    final filters = state.filterSettings;

    // Filters load a frame after the screen opens.
    if (filters.isEmpty) return const SizedBox.shrink();

    // Nothing to pick between: a camera with no filters, or one filter.
    if (filters.length == 1) {
      return Text(
        filters.single.label,
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
        style: SkotiqTypography.bodyStrong.copyWith(color: colors.textPrimary),
      );
    }

    final selectedIndex = state.currentFilterIndex >= 0 &&
            state.currentFilterIndex < filters.length
        ? state.currentFilterIndex
        : 0;

    // The row index is the item value, so two filters with one name stay
    // apart. A run took its filter when it started, so the picker is off
    // while it captures.
    return SkotiqDropdown(
      isExpanded: true,
      dense: true,
      value: selectedIndex.toString(),
      items: [for (var i = 0; i < filters.length; i++) i.toString()],
      itemLabels: [for (final f in filters) f.label],
      onChanged: state.isCapturing
          ? null
          : (v) {
              if (v != null) notifier.selectQuickFilter(int.parse(v));
            },
    );
  }
}

/// The line above the per-filter table, naming only the controls the camera
/// has: a DSLR reads ISO, a gain camera gain (and offset when it has one), and
/// a camera with neither only sets frame counts.
String _filterOverridesHint(ExposureSensitivity sensitivity) =>
    switch (sensitivity) {
      IsoSensitivity() => 'Set the ISO to match each filter’s lights. '
          'Default takes the camera’s.',
      GainSensitivity(hasGain: true, hasOffset: true) =>
        'Set gain and offset to match each filter’s lights. '
            'A blank field takes the camera’s value.',
      GainSensitivity(hasGain: true) => 'Set the gain to match each '
          'filter’s lights. A blank field takes the camera’s value.',
      GainSensitivity(hasOffset: true) => 'Set the offset to match each '
          'filter’s lights. A blank field takes the camera’s value.',
      GainSensitivity() => 'A blank frames field takes the count above.',
    };

/// The clause beside the Camera panel's title: when these values apply.
String _cameraDefaultsNote(ExposureSensitivity sensitivity) =>
    switch (sensitivity) {
      IsoSensitivity() => 'used unless a filter sets its own ISO',
      GainSensitivity(hasGain: true, hasOffset: true) =>
        'used unless a filter sets its own gain or offset',
      GainSensitivity(hasGain: true) =>
        'used unless a filter sets its own gain',
      GainSensitivity(hasOffset: true) =>
        'used unless a filter sets its own offset',
      GainSensitivity() => 'used by every filter',
    };

/// The filters a run takes and what each one overrides: one frame count for
/// all of them, then a table of filter, sensitivity and frames.
class _PerFilterPanel extends ConsumerWidget {
  const _PerFilterPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final state = ref.watch(flatWizardProvider);
    final notifier = ref.read(flatWizardProvider.notifier);
    final sensitivity = ref.watch(flatCameraConfigProvider).sensitivity;
    final batch = state.mode != FlatWizardMode.quick;
    final filters = state.filterSettings;
    final selected = filters.where((f) => f.enabled).length;

    return FlatWizardPanel(
      title: 'Per filter',
      note: batch && filters.length > 1
          ? '$selected of ${filters.length} selected'
          : null,
      actions: [
        if (state.mode == FlatWizardMode.skyFlats && filters.length > 1)
          SkotiqButton(
            label: 'Auto-order',
            icon: LucideIcons.arrowUpDown,
            // A run holds its filters by index, so the order is fixed while it
            // captures.
            onPressed: state.isCapturing ? null : notifier.autoOrderForTwilight,
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
          ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          FormRow(
            label: 'Frames per filter',
            labelWidth: _formLabelWidth,
            child: _FrameCountInput(
              key: TourTarget.flatFrameCount.key,
              value: state.globalSettings.frameCount,
              onChanged: notifier.setFrameCount,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          Text(
            _filterOverridesHint(sensitivity),
            style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          _FilterTable(key: TourTarget.flatFilterSelect.key, batch: batch),
        ],
      ),
    );
  }
}

/// Column widths of the per-filter table for the width it is given.
class _FilterColumns {
  const _FilterColumns({
    required this.sensitivity,
    required this.offset,
    required this.frames,
  });

  /// Gain or ISO column; zero when the camera has neither.
  final double sensitivity;

  /// Offset column; zero when the camera has none.
  final double offset;
  final double frames;

  static const double gap = SkotiqTokens.spaceSm;

  /// The narrowest the filter's own column may get.
  static const double _filterMin = 104;
  static const double _fieldMin = 56;
  static const double _fieldMax = 96;

  /// An ISO picker shows a word and a number, so it takes more than a number.
  static const double _isoShare = 1.6;

  factory _FilterColumns.fit(double maxWidth, ExposureSensitivity sensitivity) {
    final sensitivityShare = switch (sensitivity) {
      IsoSensitivity() => _isoShare,
      GainSensitivity(hasGain: true) => 1.0,
      GainSensitivity() => 0.0,
    };
    final offsetShare = sensitivity.hasOffset ? 1.0 : 0.0;
    final shares = sensitivityShare + offsetShare + 1;
    final count =
        (sensitivityShare > 0 ? 1 : 0) + (offsetShare > 0 ? 1 : 0) + 1;
    final unit = ((maxWidth - _filterMin - gap * count) / shares)
        .clamp(_fieldMin, _fieldMax);
    return _FilterColumns(
      sensitivity: unit * sensitivityShare,
      offset: unit * offsetShare,
      frames: unit,
    );
  }
}

class _FilterTable extends ConsumerWidget {
  const _FilterTable({super.key, required this.batch});

  /// Every filter with a checkbox; otherwise the one filter a quick capture
  /// takes, with a picker in its place.
  final bool batch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final state = ref.watch(flatWizardProvider);
    final sensitivity = ref.watch(flatCameraConfigProvider).sensitivity;
    final filters = state.filterSettings;
    final head = SkotiqTypography.eyebrow.copyWith(color: colors.textMuted);

    return LayoutBuilder(builder: (context, constraints) {
      final columns = _FilterColumns.fit(constraints.maxWidth, sensitivity);
      Widget headCell(String label, double width) => Padding(
            padding: const EdgeInsets.only(left: _FilterColumns.gap),
            child: SizedBox(
              width: width,
              child: Text(label.toUpperCase(),
                  style: head, overflow: TextOverflow.ellipsis, maxLines: 1),
            ),
          );

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceXs),
            child: Row(children: [
              Expanded(child: Text('FILTER', style: head)),
              if (columns.sensitivity > 0)
                headCell(sensitivity.label, columns.sensitivity),
              if (columns.offset > 0) headCell('Offset', columns.offset),
              headCell('Frames', columns.frames),
            ]),
          ),
          if (!batch && filters.isNotEmpty)
            _FilterSettingsRow(
              index: state.currentFilterIndex.clamp(0, filters.length - 1),
              columns: columns,
            )
          else if (batch)
            for (var i = 0; i < filters.length; i++)
              _FilterSettingsRow(
                key: ValueKey('flat-filter-row-${filters[i].filterPosition}'),
                index: i,
                showToggle: true,
                columns: columns,
              ),
        ],
      );
    });
  }
}

/// One filter's row: its name (a checkbox in a batch, the picker in a quick
/// capture), then the fields the camera has.
class _FilterSettingsRow extends ConsumerWidget {
  /// Row in `filterSettings`.
  final int index;
  final bool showToggle;
  final _FilterColumns columns;

  const _FilterSettingsRow(
      {super.key,
      required this.index,
      required this.columns,
      this.showToggle = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(flatWizardProvider);
    final colors = SkotiqColors.of(context);

    Widget row(List<Widget> cells) => DecoratedBox(
          decoration: BoxDecoration(
              border: Border(top: BorderSide(color: colors.border))),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm),
            child: Row(children: cells),
          ),
        );
    Widget cell(double width, Widget child) => Padding(
          padding: const EdgeInsets.only(left: _FilterColumns.gap),
          child: SizedBox(width: width, child: child),
        );

    final filter = state.filterSettings[index];
    final config = ref.watch(flatCameraConfigProvider);
    final notifier = ref.read(flatWizardProvider.notifier);
    final editable = !state.isCapturing && (!showToggle || filter.enabled);
    FlatFilterSettings current() =>
        ref.read(flatWizardProvider).filterSettings[index];
    void update(FlatFilterSettings value) =>
        notifier.updateFilterSettings(index, value);

    Widget field(
        String name, int? value, int? inherited, ValueChanged<int?> change,
        {bool supported = true, int? min, int? max}) {
      final invalid = value != null &&
          ((min != null && value < min) || (max != null && value > max));
      return Semantics(
        label: '${filter.label} $name',
        child: _FilterNumberField(
          key: ValueKey(
              'flat-filter-${name.toLowerCase()}-${filter.filterPosition}'),
          value: value,
          hint: supported ? '${inherited ?? "Default"}' : 'Unavailable',
          enabled: editable && (supported || value != null),
          onChanged: change,
          error: !supported && value != null
              ? 'Unsupported; clear'
              : invalid
                  ? '${min ?? "?"}–${max ?? "?"}'
                  : null,
        ),
      );
    }

    // A filter's ISO, or Default to take the camera default.
    Widget isoOverride(IsoSensitivity iso, int? value, int? inherited) {
      const unset = '';
      final defaultLabel = inherited == null
          ? 'Default'
          : 'Default (${iso.describe(inherited)})';
      return Semantics(
        label: '${filter.label} ${iso.label}',
        child: SkotiqDropdown(
          key: ValueKey('flat-filter-iso-${filter.filterPosition}'),
          value: value == null ? unset : '${iso.accept(value)}',
          items: [unset, for (final s in iso.speeds) '$s'],
          itemLabels: [defaultLabel, for (final s in iso.speeds) '$s'],
          isExpanded: true,
          dense: true,
          onChanged: editable
              ? (picked) => update(
                  current().copyWith(gainOverride: int.tryParse(picked ?? '')))
              : null,
        ),
      );
    }

    // Merged, so the checkbox is announced by its filter's name.
    final name = showToggle
        ? MergeSemantics(
            child: Row(children: [
              SkotiqCheckbox(
                value: filter.enabled,
                onChanged: state.isCapturing
                    ? null
                    : (v) => notifier.toggleFilter(index, v ?? false),
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Flexible(
                child: Text(
                  filter.label,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: SkotiqTypography.bodyStrong.copyWith(
                    color: filter.enabled
                        ? colors.textPrimary
                        : colors.textSecondary,
                  ),
                ),
              ),
            ]),
          )
        : const _FilterSelector();

    return row([
      Expanded(child: name),
      if (columns.sensitivity > 0)
        cell(
          columns.sensitivity,
          SensitivityField(
            value: filter.gainOverride,
            sensitivity: config.sensitivity,
            onChanged: (v) => update(current().copyWith(gainOverride: v)),
            isoField: (context, iso) =>
                isoOverride(iso, filter.gainOverride, config.gain),
            gainField: (_) => field('Gain', filter.gainOverride, config.gain,
                (v) => update(current().copyWith(gainOverride: v)),
                supported: !config.capabilitiesKnown || config.canSetGain,
                min: config.gainMin,
                max: config.gainMax),
          ),
        ),
      if (columns.offset > 0)
        cell(
          columns.offset,
          field('Offset', filter.offsetOverride, config.offset,
              (v) => update(current().copyWith(offsetOverride: v)),
              supported: !config.capabilitiesKnown || config.canSetOffset,
              min: config.offsetMin,
              max: config.offsetMax),
        ),
      cell(
        columns.frames,
        field(
            'Frames',
            filter.frameCountOverride,
            state.globalSettings.frameCount,
            (v) => update(current().copyWith(frameCountOverride: v)),
            min: 1,
            max: 999),
      ),
    ]);
  }
}

/// Blank means inherit; numeric zero remains an explicit camera setting.
class _FilterNumberField extends StatefulWidget {
  final int? value;
  final String hint;
  final bool enabled;
  final String? error;
  final ValueChanged<int?> onChanged;
  const _FilterNumberField(
      {super.key,
      required this.value,
      required this.hint,
      required this.enabled,
      required this.onChanged,
      this.error});

  @override
  State<_FilterNumberField> createState() => _FilterNumberFieldState();
}

class _FilterNumberFieldState extends State<_FilterNumberField> {
  late final controller =
      TextEditingController(text: widget.value?.toString() ?? '');
  @override
  void didUpdateWidget(covariant _FilterNumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value &&
        int.tryParse(controller.text) != widget.value) {
      controller.text = widget.value?.toString() ?? '';
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SkotiqTextField(
        controller: controller,
        hint: widget.hint,
        enabled: widget.enabled,
        mono: true,
        dense: true,
        errorText: widget.error,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(6)
        ],
        onChanged: (text) =>
            widget.onChanged(text.isEmpty ? null : int.parse(text)),
      );
}
