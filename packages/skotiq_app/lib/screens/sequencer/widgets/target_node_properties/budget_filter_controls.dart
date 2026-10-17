part of '../target_node_properties.dart';

class _FilterRow extends StatelessWidget {
  final SkotiqColors colors;
  final String filterName;
  final FilterBudgetEntry entry;
  final ValueChanged<FilterBudgetEntry> onChanged;
  final VoidCallback onRemove;

  const _FilterRow({
    required this.colors,
    required this.filterName,
    required this.entry,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final isRatio = entry.isRatio;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: Text(
              filterName,
              style: SkotiqTypography.h6.copyWith(color: colors.textPrimary),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: NodeNumberInput(
              colors: colors,
              value: isRatio ? entry.value : entry.value / 3600.0,
              suffix: isRatio ? '' : 'h',
              min: 0,
              max: isRatio ? 100 : 24,
              decimals: 2,
              onChanged: (v) {
                if (isRatio) {
                  onChanged(FilterBudgetEntry.ratio(v));
                } else {
                  onChanged(FilterBudgetEntry.absolute(v * 3600.0));
                }
              },
            ),
          ),
          const SizedBox(width: 8),
          _KindToggle(
            colors: colors,
            isRatio: isRatio,
            onChanged: (newRatio) {
              if (newRatio == isRatio) return;
              if (newRatio) {
                onChanged(const FilterBudgetEntry.ratio(1));
              } else {
                onChanged(const FilterBudgetEntry.absolute(3600));
              }
            },
          ),
          IconButton(
            icon: Icon(LucideIcons.x, size: 14, color: colors.textMuted),
            tooltip: 'Remove $filterName',
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

class _KindToggle extends StatelessWidget {
  final SkotiqColors colors;
  final bool isRatio;
  final ValueChanged<bool> onChanged;

  const _KindToggle({
    required this.colors,
    required this.isRatio,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    Widget pill(String label, bool active) {
      return GestureDetector(
        onTap: () => onChanged(label == 'Ratio'),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: active ? colors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize10,
              fontWeight: FontWeight.w600,
              color: active ? colors.background : colors.textMuted,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          pill('Hours', !isRatio),
          pill('Ratio', isRatio),
        ],
      ),
    );
  }
}

class _AddFilterRow extends StatefulWidget {
  final SkotiqColors colors;
  final Set<String> existingFilters;
  final ValueChanged<String> onAdd;

  const _AddFilterRow({
    required this.colors,
    required this.existingFilters,
    required this.onAdd,
  });

  @override
  State<_AddFilterRow> createState() => _AddFilterRowState();
}

class _AddFilterRowState extends State<_AddFilterRow> {
  late final TextEditingController _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _ctl,
              style: TextStyle(
                  fontSize: SkotiqTypography.fontSize12,
                  color: widget.colors.textPrimary),
              decoration: InputDecoration(
                hintText: 'Filter name (e.g. Ha)',
                hintStyle: TextStyle(
                    fontSize: SkotiqTypography.fontSize12,
                    color: widget.colors.textMuted),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                  borderSide: BorderSide(color: widget.colors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                  borderSide: BorderSide(color: widget.colors.border),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          TextButton.icon(
            onPressed: () {
              final name = _ctl.text.trim();
              if (name.isEmpty) return;
              if (widget.existingFilters.contains(name)) return;
              widget.onAdd(name);
              _ctl.clear();
            },
            icon:
                Icon(LucideIcons.plus, size: 14, color: widget.colors.primary),
            label: Text(
              'Add',
              style: TextStyle(
                  fontSize: SkotiqTypography.fontSize12,
                  color: widget.colors.primary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Live "what will this carve up to?" preview, mirroring
