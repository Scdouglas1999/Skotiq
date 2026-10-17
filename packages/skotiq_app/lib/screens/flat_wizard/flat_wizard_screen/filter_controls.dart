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
    final notifier = ref.read(flatWizardProvider.notifier);

    if (state.filterSettings.isEmpty) {
      return const EmptyState.compact(
        icon: LucideIcons.filter,
        title: 'No filters',
        body: 'Connect a filter wheel to batch flats by filter.',
      );
    }

    // While a capture run is active the filter set must not change (the run
    // captured its filter list with stable indices at start), so the toggles
    // are visibly disabled — not just silently ignored by the notifier guard.
    final interactable = !state.isCapturing;

    // A well inside the controls column, not a card: this is a data inset,
    // and a panel inside a panel does not exist (02 rule 2).
    return Container(
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: SkotiqTokens.borderRadiusSm,
      ),
      child: Column(
        children: [
          for (int i = 0; i < state.filterSettings.length; i++)
            _FilterChecklistItem(
              filter: state.filterSettings[i],
              isLast: i == state.filterSettings.length - 1,
              onToggle: interactable
                  ? (enabled) => notifier.toggleFilter(i, enabled)
                  : null,
            ),
        ],
      ),
    );
  }
}

class _FilterChecklistItem extends StatelessWidget {
  final FlatFilterSettings filter;
  final bool isLast;

  /// Null while a capture run is active — disables the checkbox so the filter
  /// set cannot change mid-run.
  final ValueChanged<bool>? onToggle;

  const _FilterChecklistItem({
    required this.filter,
    required this.isLast,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
        vertical: SkotiqTokens.spaceSm,
      ),
      decoration: BoxDecoration(
        border:
            isLast ? null : Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          SkotiqCheckbox(
            value: filter.enabled,
            onChanged: onToggle == null ? null : (v) => onToggle!(v ?? false),
          ),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: Text(
              filter.filterName,
              style: SkotiqTypography.bodySm.copyWith(
                color: filter.enabled ? colors.textPrimary : colors.textMuted,
              ),
            ),
          ),
          if (filter.suggestedExposure != null)
            Text(
              '~${filter.suggestedExposure!.toStringAsFixed(1)} s',
              style: SkotiqTypography.monoCaption.copyWith(
                color: colors.textMuted,
              ),
            ),
        ],
      ),
    );
  }
}
