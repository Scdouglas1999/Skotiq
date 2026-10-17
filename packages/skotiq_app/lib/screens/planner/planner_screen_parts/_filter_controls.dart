// Search field, filter chips (object type, constellation, magnitude, size, altitude, moon separation), sort dropdown, reset chip, the _ControlChip primitive, and the shared _showAngleSlider helper used by the angle-based filter sheets.
part of '../planner_screen.dart';

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final SkotiqColors colors;
  final ValueChanged<String> onChanged;

  /// On phone the field tightens (shorter, smaller hint) so search + the
  /// Filters button fit one row and the controls bar stays a single strip.
  final bool compact;

  const _SearchField({
    required this.controller,
    required this.colors,
    required this.onChanged,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    // On a narrow phone row the long hint never fully shows anyway; a short
    // hint reads better and avoids an awkward mid-word clip.
    final hint =
        compact ? 'Search catalogs' : context.l10n.text('plannerSearchHint');
    return SkotiqTextField(
      controller: controller,
      onChanged: onChanged,
      hint: hint,
      dense: true,
      prefixIcon: LucideIcons.search,
      suffixWidget: controller.text.isEmpty
          ? null
          : SkotiqIconButton(
              icon: LucideIcons.x,
              tooltip: 'Clear search',
              size: IconButtonSize.sm,
              onPressed: () {
                controller.clear();
                onChanged('');
              },
            ),
    );
  }
}

class _ObjectTypeMultiSelect extends ConsumerWidget {
  final SkotiqColors colors;
  final Set<String> selected;

  const _ObjectTypeMultiSelect({required this.colors, required this.selected});

  static const _options = <String>[
    'galaxy',
    'nebula',
    'cluster',
    'planetary',
    'supernova remnant',
    'comet',
    'asteroid',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = selected.isEmpty
        ? 'Type: any'
        : 'Type: ${selected.map(_displayLabel).join(', ')}';

    return _ControlChip(
      colors: colors,
      icon: LucideIcons.shapes,
      label: label,
      active: selected.isNotEmpty,
      onTap: () async {
        final result = await _showObjectTypeDialog(
          context: context,
          colors: colors,
          selected: selected,
        );
        if (result != null) {
          final notifier = ref.read(suggestionFilterProvider.notifier);
          notifier.state = notifier.state.copyWith(selectedObjectTypes: result);
          ref.read(_plannerVisibleCountProvider.notifier).state =
              _kPlannerPageSize;
        }
      },
    );
  }

  static String _displayLabel(String key) {
    return key
        .split(' ')
        .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }
}

/// Object-type multi-select sheet.
///
/// Returns `null` when dismissed, otherwise the chosen set.
Future<Set<String>?> _showObjectTypeDialog({
  required BuildContext context,
  required SkotiqColors colors,
  required Set<String> selected,
}) {
  return showDialog<Set<String>>(
    context: context,
    builder: (dialogCtx) {
      final draft = Set<String>.of(selected);
      return StatefulBuilder(
        builder: (dialogCtx, setDialogState) {
          return AlertDialog(
            backgroundColor: colors.surface,
            title: Text(
              'Object types',
              style: SkotiqTypography.bodyStrong.copyWith(
                color: colors.textPrimary,
              ),
            ),
            content: SizedBox(
              width: dialogMaxWidth(context, 380),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _ObjectTypeMultiSelect._options
                    .map((opt) => FilterChip(
                          label: Text(
                            _ObjectTypeMultiSelect._displayLabel(opt),
                          ),
                          selected: draft.contains(opt),
                          showCheckmark: false,
                          onSelected: (on) {
                            setDialogState(() {
                              if (on) {
                                draft.add(opt);
                              } else {
                                draft.remove(opt);
                              }
                            });
                          },
                        ))
                    .toList(),
              ),
            ),
            actions: [
              SkotiqButton(
                label: 'Clear',
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: () => setDialogState(draft.clear),
              ),
              SkotiqButton(
                label: 'Apply',
                variant: ButtonVariant.primary,
                size: ButtonSize.small,
                onPressed: () => Navigator.of(dialogCtx).pop(draft),
              ),
            ],
          );
        },
      );
    },
  );
}

/// Test-only seam exposing the constellation picker.
///
/// Returns the dialog's result: null for a barrier dismiss, the empty string
/// for "Any constellation", otherwise the chosen abbreviation.
@visibleForTesting
Future<String?> showConstellationPickerForTest({
  required BuildContext context,
  required SkotiqColors colors,
  required List<String> available,
  String? selected,
}) {
  return showDialog<String?>(
    context: context,
    builder: (dCtx) => _ConstellationPickerDialog(
      colors: colors,
      available: available,
      selected: selected,
    ),
  );
}

/// Test-only seam exposing the object-types sheet.
///
/// Same rationale as [showAngleSliderForTest]: the sheet is a private helper
/// inside a `part` file, and pumping the whole PlannerScreen runs a 1 s sky
/// clock that never settles. Nothing in production calls this.
@visibleForTesting
Future<Set<String>?> showObjectTypeDialogForTest({
  required BuildContext context,
  required SkotiqColors colors,
  required Set<String> selected,
}) {
  return _showObjectTypeDialog(
    context: context,
    colors: colors,
    selected: selected,
  );
}

/// Constellation filter.
///
/// Catalog rows store the three-letter IAU abbreviation. A bare
/// [DropdownButton] of up to 88 of them ("And", "Aql", "CVn"…) would make
/// finding a constellation a matter of knowing its abbreviation and scrolling,
/// so this is a searchable dialog like every other filter chip in the row,
/// listing the full name with the abbreviation in tow so both spellings are
/// matchable.
class _ConstellationDropdown extends ConsumerWidget {
  final SkotiqColors colors;
  final List<String> available;
  final String? selected;

  const _ConstellationDropdown({
    required this.colors,
    required this.available,
    required this.selected,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = selected != null;
    return _ControlChip(
      colors: colors,
      icon: LucideIcons.star,
      label: active ? constellationFullName(selected!) : 'Constellation: any',
      active: active,
      onTap: () async {
        final result = await showDialog<String?>(
          context: context,
          builder: (dCtx) => _ConstellationPickerDialog(
            colors: colors,
            available: available,
            selected: selected,
          ),
        );
        // A barrier dismiss returns null and must NOT clear the filter; the
        // dialog signals both "any" and a pick through a wrapper.
        if (result == null) return;
        final picked = result.isEmpty ? null : result;
        final notifier = ref.read(suggestionFilterProvider.notifier);
        notifier.state = notifier.state.copyWith(
          selectedConstellations:
              picked == null ? <String>{} : <String>{picked},
        );
        ref.read(_plannerVisibleCountProvider.notifier).state =
            _kPlannerPageSize;
      },
    );
  }
}

class _ConstellationPickerDialog extends StatefulWidget {
  final SkotiqColors colors;
  final List<String> available;
  final String? selected;

  const _ConstellationPickerDialog({
    required this.colors,
    required this.available,
    required this.selected,
  });

  @override
  State<_ConstellationPickerDialog> createState() =>
      _ConstellationPickerDialogState();
}

class _ConstellationPickerDialogState
    extends State<_ConstellationPickerDialog> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    // Sorted by the name the user reads, not by the abbreviation, so the list
    // is alphabetical on screen.
    final entries = [
      for (final abbr in widget.available) (abbr, constellationFullName(abbr)),
    ]..sort((a, b) => a.$2.toLowerCase().compareTo(b.$2.toLowerCase()));
    final q = _query.trim().toLowerCase();
    final matches = q.isEmpty
        ? entries
        : entries
            .where((e) =>
                e.$2.toLowerCase().contains(q) ||
                e.$1.toLowerCase().contains(q))
            .toList();

    return AlertDialog(
      backgroundColor: colors.surface,
      title: Text(
        'Constellation',
        style: SkotiqTypography.bodyStrong.copyWith(color: colors.textPrimary),
      ),
      content: SizedBox(
        width: dialogMaxWidth(context, 380),
        height: 380,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SearchField(
              controller: _search,
              colors: colors,
              compact: true,
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            Text(
              '${entries.length} constellation'
              '${entries.length == 1 ? '' : 's'} in tonight’s candidates',
              style: SkotiqTypography.caption.copyWith(
                color: colors.textMuted,
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceXs),
            Expanded(
              child: matches.isEmpty
                  ? Center(
                      child: Text(
                        'No constellation matches "$_query".',
                        style: SkotiqTypography.caption.copyWith(
                          color: colors.textMuted,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: matches.length,
                      itemBuilder: (context, i) {
                        final (abbr, name) = matches[i];
                        final isSelected = widget.selected == abbr;
                        return ListTile(
                          dense: true,
                          selected: isSelected,
                          title: Text(
                            '$name ($abbr)',
                            style: SkotiqTypography.bodySm.copyWith(
                              color: isSelected
                                  ? colors.primary
                                  : colors.textPrimary,
                            ),
                          ),
                          onTap: () => Navigator.of(context).pop(abbr),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        SkotiqButton(
          label: 'Any constellation',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
          // Empty string, not null: null is what a barrier dismiss returns and
          // must stay distinguishable from "clear the filter".
          onPressed: () => Navigator.of(context).pop(''),
        ),
      ],
    );
  }
}
