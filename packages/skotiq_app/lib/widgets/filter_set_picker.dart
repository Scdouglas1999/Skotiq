import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The Filters picker, in every place a plan's filters are filled in
/// automatically before it is built: the combinations this rig can image,
/// Skotiq's choice marked "Recommended", the sets the user saved, and
/// "Custom…" to build and save one ([showFilterSetBuilder]). The line under
/// it says why Skotiq recommends its set, and offers a suggested one.
class FilterSetPicker extends ConsumerWidget {
  const FilterSetPicker({
    super.key,
    required this.choice,
    required this.value,
    required this.onChanged,
    this.dense = false,
  });

  /// Skotiq's choice for the target on this rig.
  final SmartNightFilterChoice choice;

  /// The set the plan images through now; null when its rows match none
  /// (a step edited by hand).
  final FilterSet? value;

  final ValueChanged<FilterSet> onChanged;

  /// 28 px control, for a dense card or side panel.
  final bool dense;

  static const _customKey = 'filter-set-builder';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final prefs = ref.watch(filterSetPreferencesProvider);
    final sets = choice.sets(saved: prefs.valueOrNull?.custom ?? const []);
    final current = value;
    final listed = [
      ...sets,
      if (current != null && !sets.any((set) => set.key == current.key))
        current,
    ];
    final recommendedKey = choice.recommended.key;
    final canBuild = choice.wheelFilters.length > 1;
    final suggested = choice.suggested;
    final offer = current == null ? null : choice.suggestionFor(current);
    final muted = SkotiqTypography.bodySm.copyWith(color: colors.textMuted);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: 'Filters',
          child: SkotiqDropdown(
            key: const ValueKey('filter-set-picker'),
            value: current?.key,
            hint: 'Choose filters',
            items: [
              for (final set in listed) set.key,
              if (canBuild) _customKey,
            ],
            itemLabels: [
              for (final set in listed) set.label,
              if (canBuild) 'Custom…',
            ],
            itemDetails: [
              for (final set in listed) _detail(set, recommendedKey),
              if (canBuild) null,
            ],
            isExpanded: true,
            dense: dense,
            onChanged: (key) async {
              if (key == null || key == current?.key) return;
              if (key == _customKey) {
                final built = await showFilterSetBuilder(
                  context,
                  wheelFilters: choice.wheelFilters,
                );
                final resolved = built?.resolve(choice.wheelFilters);
                if (resolved != null) onChanged(resolved);
                return;
              }
              onChanged(listed.firstWhere((set) => set.key == key));
            },
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        Text(
          current == null || current.key == recommendedKey
              ? choice.recommendation
              : 'Your choice. ${choice.recommendation}',
          style: muted,
        ),
        if (offer != null &&
            suggested != null &&
            sets.any((set) => set.key == suggested.key)) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          Row(
            children: [
              Expanded(child: Text(offer, style: muted)),
              const SizedBox(width: SkotiqTokens.spaceMd),
              SkotiqButton(
                label: 'Add Ha',
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: () => onChanged(suggested),
              ),
            ],
          ),
        ],
        if (prefs.hasError) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          Text(
            'Your saved filter sets could not be read: '
            '${userFacingError(prefs.error)}',
            style: SkotiqTypography.bodySm.copyWith(color: colors.error),
          ),
        ],
      ],
    );
  }

  /// "Recommended" for Skotiq's set, and the filters of a set whose label
  /// does not name them.
  static String? _detail(FilterSet set, String recommendedKey) {
    final parts = [
      if (set.key == recommendedKey) 'Recommended',
      if (set.isCustom || set.preset == SmartNightStrategy.monoLrgb)
        set.filters.join(' '),
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

/// The "Custom…" filter set builder: tick filters on the wheel, name the
/// set, and save it on the equipment profile for every plan to offer. The
/// sets saved before are listed with a way to delete them. Returns the set
/// saved, or null.
Future<CustomFilterSet?> showFilterSetBuilder(
  BuildContext context, {
  required List<String> wheelFilters,
}) =>
    showDialog<CustomFilterSet>(
      context: context,
      builder: (_) => _FilterSetBuilderDialog(wheelFilters: wheelFilters),
    );

class _FilterSetBuilderDialog extends ConsumerStatefulWidget {
  const _FilterSetBuilderDialog({required this.wheelFilters});

  final List<String> wheelFilters;

  @override
  ConsumerState<_FilterSetBuilderDialog> createState() =>
      _FilterSetBuilderDialogState();
}

class _FilterSetBuilderDialogState
    extends ConsumerState<_FilterSetBuilderDialog> {
  final _name = TextEditingController();
  final _ticked = <String>{};
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _canSave =>
      !_saving && _name.text.trim().isNotEmpty && _ticked.isNotEmpty;

  Future<void> _save() async {
    final set = CustomFilterSet(
      name: _name.text.trim(),
      filters: [
        for (final filter in widget.wheelFilters)
          if (_ticked.contains(filter)) filter,
      ],
    );
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(filterSetPreferencesProvider.notifier).save(set);
      if (mounted) Navigator.of(context).pop(set);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save the filter set: ${userFacingError(e)}';
        });
      }
    }
  }

  Future<void> _delete(String name) async {
    try {
      await ref.read(filterSetPreferencesProvider.notifier).delete(name);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = 'Could not delete "$name": ${userFacingError(e)}',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final saved = ref.watch(filterSetPreferencesProvider).valueOrNull?.custom ??
        const <CustomFilterSet>[];
    return SkotiqDialog(
      title: 'Custom filter set',
      width: SkotiqDialog.widthConfirm,
      closeEnabled: !_saving,
      actions: [
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
        ),
        SkotiqButton(
          label: 'Save set',
          isLoading: _saving,
          onPressed: _canSave ? _save : null,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormRow(
            label: 'Name',
            child: SkotiqTextField(
              key: const ValueKey('filter-set-name'),
              controller: _name,
              hint: 'HaRGB',
              autofocus: true,
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          Text(
            'FILTERS',
            style: SkotiqTypography.eyebrow.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          for (final filter in widget.wheelFilters)
            _FilterTick(
              filter: filter,
              value: _ticked.contains(filter),
              onChanged: (on) => setState(
                () => on ? _ticked.add(filter) : _ticked.remove(filter),
              ),
            ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Text(
            'Plans take the filters in wheel order, with the same time on '
            'each.',
            style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
          ),
          if (saved.isNotEmpty) ...[
            const SizedBox(height: SkotiqTokens.space2xl),
            Text(
              'SAVED SETS',
              style: SkotiqTypography.eyebrow.copyWith(color: colors.textMuted),
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            for (final set in saved)
              Padding(
                padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceXs),
                child: Row(
                  children: [
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: set.name,
                              style: SkotiqTypography.bodyStrong
                                  .copyWith(color: colors.textPrimary),
                            ),
                            TextSpan(
                              text: '  ${set.filters.join(' ')}',
                              style: SkotiqTypography.bodySm
                                  .copyWith(color: colors.textMuted),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SkotiqIconButton(
                      icon: LucideIcons.trash2,
                      tooltip: 'Delete ${set.name}',
                      onPressed: _saving ? null : () => _delete(set.name),
                    ),
                  ],
                ),
              ),
          ],
          if (_error != null) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            Text(
              _error!,
              style: SkotiqTypography.bodySm.copyWith(color: colors.error),
            ),
          ],
        ],
      ),
    );
  }
}

class _FilterTick extends StatelessWidget {
  const _FilterTick({
    required this.filter,
    required this.value,
    required this.onChanged,
  });

  final String filter;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(
          children: [
            SkotiqCheckbox(
              value: value,
              onChanged: (on) => onChanged(on ?? false),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: Text(
                filter,
                style: SkotiqTypography.body.copyWith(
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

/// How a plan takes its filters: one exposure per filter in turn, or each
/// filter's frames together. Automatic plans rotate on a rig with a
/// motorized wheel (`smartNightRotatesFilters`); this is where the user
/// switches.
class FilterOrderControl extends StatelessWidget {
  const FilterOrderControl({
    super.key,
    required this.rotate,
    required this.onChanged,
  });

  final bool rotate;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SegmentedControl(
          semanticLabel: 'Filter order',
          segments: const ['Rotate', 'Blocks'],
          selectedIndex: rotate ? 0 : 1,
          onSelected: (index) => onChanged(index == 0),
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        Text(
          rotate
              ? 'One exposure per filter in turn, so a night cut short still '
                  'has every filter.'
              : 'Each filter\'s frames together, for a wheel you turn by '
                  'hand.',
          style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }
}
