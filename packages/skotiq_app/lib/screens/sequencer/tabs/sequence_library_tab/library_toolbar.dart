part of '../sequence_library_tab.dart';

/// Search, then the sort, favorites and tag filters, on one line at the left.
/// On a phone the search takes the width and the chips scroll beneath it.
class _LibraryToolbar extends ConsumerStatefulWidget {
  const _LibraryToolbar({required this.compact});

  final bool compact;

  @override
  ConsumerState<_LibraryToolbar> createState() => _LibraryToolbarState();
}

class _LibraryToolbarState extends ConsumerState<_LibraryToolbar> {
  static const double _searchWidth = 280;
  static const Duration _searchDebounce = Duration(milliseconds: 300);

  late final TextEditingController _search =
      TextEditingController(text: ref.read(sequenceSearchProvider));
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    if (value.isEmpty) {
      ref.read(sequenceSearchProvider.notifier).state = '';
      return;
    }
    _debounce = Timer(_searchDebounce, () {
      if (!mounted) return;
      ref.read(sequenceSearchProvider.notifier).state = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    // The empty-result "Clear filters" clears the query from outside.
    ref.listen<String>(sequenceSearchProvider, (previous, next) {
      if (next.isEmpty && _search.text.isNotEmpty) _search.clear();
    });

    final compact = widget.compact;
    final sortOrder = ref.watch(sequenceSortOrderProvider);
    final favoritesOnly = ref.watch(sequenceFavoritesOnlyProvider);
    final tags =
        ref.watch(sequenceTagUniverseProvider).valueOrNull ?? const <String>[];
    final selectedTags = ref.watch(sequenceTagFilterProvider);

    final searchField = SkotiqSearchField(
      controller: _search,
      hint: 'Search sequences, targets and tags',
      onChanged: _onSearchChanged,
    );
    final chips = <Widget>[
      FilterMenuChip<SequenceSortOrder>(
        label: 'Sort: ${sortOrder.label.toLowerCase()}',
        name: 'Sort order',
        roomy: compact,
        entries: [
          for (final order in SequenceSortOrder.values) (order, order.label),
        ],
        selected: sortOrder,
        onSelected: (value) =>
            ref.read(sequenceSortOrderProvider.notifier).state = value,
      ),
      FilterMenuChip<bool>(
        label: favoritesOnly ? 'Favorites' : 'All sequences',
        name: 'Show',
        roomy: compact,
        entries: const [(false, 'All sequences'), (true, 'Favorites')],
        selected: favoritesOnly,
        onSelected: (value) =>
            ref.read(sequenceFavoritesOnlyProvider.notifier).state = value,
      ),
      if (tags.isNotEmpty || selectedTags.isNotEmpty)
        _TagFilterChip(
          tags: tags,
          selected: selectedTags,
          roomy: compact,
          onChanged: (next) =>
              ref.read(sequenceTagFilterProvider.notifier).state = next,
        ),
    ];

    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          searchField,
          const SizedBox(height: SkotiqTokens.spaceXs),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final chip in chips)
                  Padding(
                    padding: const EdgeInsets.only(right: SkotiqTokens.spaceSm),
                    child: chip,
                  ),
              ],
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        SizedBox(width: _searchWidth, child: searchField),
        const SizedBox(width: SkotiqTokens.spaceLg),
        Expanded(
          child: Wrap(
            spacing: SkotiqTokens.spaceSm,
            runSpacing: SkotiqTokens.spaceSm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: chips,
          ),
        ),
      ],
    );
  }
}

/// The tag filter: each pick toggles one tag, and a sequence must carry every
/// picked tag to stay listed.
class _TagFilterChip extends StatelessWidget {
  const _TagFilterChip({
    required this.tags,
    required this.selected,
    required this.roomy,
    required this.onChanged,
  });

  final List<String> tags;
  final Set<String> selected;
  final bool roomy;
  final ValueChanged<Set<String>> onChanged;

  static const double _touchTarget = 48;

  String get _label => switch (selected.length) {
        0 => 'Tags: any',
        1 => 'Tag: ${selected.single}',
        _ => 'Tags: ${selected.join(', ')}',
      };

  Future<void> _open(BuildContext context) async {
    final colors = SkotiqColors.of(context);
    final box = context.findRenderObject()! as RenderBox;
    // A record so "Any tag" (null) and a dismissed menu stay apart.
    final picked = await showMenu<(String?,)>(
      context: context,
      position: menuPositionFromRect(
        context,
        box.localToGlobal(Offset.zero) & box.size,
      ),
      color: colors.surfaceElevated,
      items: [
        PopupMenuItem<(String?,)>(
          value: (null,),
          child: Text(
            'Any tag',
            style: SkotiqTypography.bodySm.copyWith(
              color: selected.isEmpty ? colors.primary : colors.textPrimary,
            ),
          ),
        ),
        for (final tag in {...tags, ...selected})
          CheckedPopupMenuItem<(String?,)>(
            value: (tag,),
            checked: selected.contains(tag),
            child: Text(
              tag,
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textPrimary,
              ),
            ),
          ),
      ],
    );
    if (picked == null) return;
    final tag = picked.$1;
    if (tag == null) {
      onChanged(<String>{});
      return;
    }
    final next = {...selected};
    if (!next.remove(tag)) next.add(tag);
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    void open() => _open(context);
    final chip = SkotiqFilterChip(
      label: _label,
      trailingIcon: LucideIcons.chevronDown,
      onTap: open,
    );
    return Semantics(
      container: true,
      button: true,
      enabled: true,
      label: 'Tag filter: $_label',
      onTap: open,
      child: ExcludeSemantics(
        child: roomy
            ? GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: open,
                child: SizedBox(
                  height: _touchTarget,
                  child: Center(
                    widthFactor: 1,
                    child: IgnorePointer(child: chip),
                  ),
                ),
              )
            : chip,
      ),
    );
  }
}
