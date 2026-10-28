part of '../flat_wizard_screen.dart';

class _FilterSelector extends ConsumerWidget {
  const _FilterSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    final state = ref.watch(flatWizardProvider);
    final notifier = ref.read(flatWizardProvider.notifier);
    final filters = state.filterSettings;

    // No filters loaded (no wheel / not yet seeded): keep the read-only card so
    // the section is not an empty control.
    if (filters.isEmpty) {
      // The FormRow around this already carries the "Filter" label, so the
      // card-with-an-icon-and-a-label collapses to the value it was hiding.
      return Text(
        'No filter',
        style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
      );
    }

    final selectedIndex = state.currentFilterIndex >= 0 &&
            state.currentFilterIndex < filters.length
        ? state.currentFilterIndex
        : 0;

    // A REAL selection over the loaded filters. Indices are the item values
    // (labelled by filter name) so duplicate filter names never collide.
    // Disabled while a run holds the busy latch — the run captured its target
    // filter at start — mirroring _FilterChecklist's null-onChanged disable.
    return SkotiqDropdown(
      isExpanded: true,
      isDense: true,
      value: selectedIndex.toString(),
      items: [for (var i = 0; i < filters.length; i++) i.toString()],
      itemLabels: [for (final f in filters) f.filterName],
      onChanged: state.isCapturing
          ? null
          : (v) {
              if (v != null) notifier.selectQuickFilter(int.parse(v));
            },
    );
  }
}

class _FilterChecklist extends ConsumerWidget {
  const _FilterChecklist({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    final state = ref.watch(flatWizardProvider);

    if (state.filterSettings.isEmpty) {
      return const EmptyState.compact(
        icon: LucideIcons.filter,
        title: 'No filters',
        body: 'Connect a filter wheel to batch flats by filter.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
            'Set gain and offset to match each filter’s lights. Clear a field to inherit the camera defaults below.',
            style:
                SkotiqTypography.bodySm.copyWith(color: colors.textMuted)),
        const SizedBox(height: SkotiqTokens.spaceMd),
        LayoutBuilder(builder: (context, constraints) {
          if (constraints.maxWidth < 480) return const SizedBox.shrink();
          return Row(children: [
            const SizedBox(width: 110, child: Text('Filter')),
            for (final label in ['Gain', 'Offset', 'Frames'])
              Expanded(
                  child: Text(label,
                      style: SkotiqTypography.caption
                          .copyWith(color: colors.textMuted))),
          ]);
        }),
        for (var i = 0; i < state.filterSettings.length; i++)
          _FilterSettingsRow(
            key: ValueKey(
                'flat-filter-row-${state.filterSettings[i].filterPosition}'),
            index: i,
            showToggle: true,
          ),
      ],
    );
  }
}

class _FilterSettingsRow extends ConsumerWidget {
  final int index;
  final bool showToggle;

  const _FilterSettingsRow(
      {super.key, required this.index, this.showToggle = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(flatWizardProvider);
    final filter = state.filterSettings[index];
    final config = ref.watch(flatCameraConfigProvider);
    final notifier = ref.read(flatWizardProvider.notifier);
    final colors = SkotiqColors.of(context);
    final editable = !state.isCapturing && (!showToggle || filter.enabled);
    FlatFilterSettings current() =>
        ref.read(flatWizardProvider).filterSettings[index];
    void update(FlatFilterSettings value) =>
        notifier.updateFilterSettings(index, value);

    Widget field(
        String name, int? value, int? inherited, ValueChanged<int?> change,
        {bool supported = true, bool showLabel = true, int? min, int? max}) {
      final invalid = value != null &&
          ((min != null && value < min) || (max != null && value > max));
      return Semantics(
        label: '${filter.filterName} $name',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showLabel) ...[
              Text(name,
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textMuted)),
              const SizedBox(height: SkotiqTokens.spaceXs),
            ],
            _FilterNumberField(
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
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm),
      decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.border))),
      child: LayoutBuilder(builder: (context, constraints) {
        final wide = constraints.maxWidth >= 480;
        final fields = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
                child: Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: field('Gain', filter.gainOverride, config.gain,
                        (v) => update(current().copyWith(gainOverride: v)),
                        showLabel: !wide || !showToggle,
                        supported:
                            !config.capabilitiesKnown || config.canSetGain,
                        min: config.gainMin,
                        max: config.gainMax))),
            Expanded(
                child: Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: field('Offset', filter.offsetOverride, config.offset,
                        (v) => update(current().copyWith(offsetOverride: v)),
                        showLabel: !wide || !showToggle,
                        supported:
                            !config.capabilitiesKnown || config.canSetOffset,
                        min: config.offsetMin,
                        max: config.offsetMax))),
            Expanded(
                child: field(
                    'Frames',
                    filter.frameCountOverride,
                    state.globalSettings.frameCount,
                    (v) => update(current().copyWith(frameCountOverride: v)),
                    showLabel: !wide || !showToggle,
                    min: 1,
                    max: 999)),
          ],
        );
        final label = Row(mainAxisSize: MainAxisSize.min, children: [
          if (showToggle)
            SkotiqCheckbox(
              value: filter.enabled,
              onChanged: state.isCapturing
                  ? null
                  : (v) => notifier.toggleFilter(index, v ?? false),
            ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Flexible(
              child: Text(filter.filterName,
                  overflow: TextOverflow.ellipsis,
                  style: SkotiqTypography.bodySm
                      .copyWith(color: colors.textPrimary))),
        ]);
        if (constraints.maxWidth < 480) {
          return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                label,
                const SizedBox(height: SkotiqTokens.spaceSm),
                fields
              ]);
        }
        return Row(children: [
          SizedBox(width: 110, child: label),
          Expanded(child: fields)
        ]);
      }),
    );
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
