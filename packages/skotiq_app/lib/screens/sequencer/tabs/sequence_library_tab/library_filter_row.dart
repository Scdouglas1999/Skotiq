part of '../sequence_library_tab.dart';

/// Favorite toggle + tag filter chips for the library list.
///
/// Reads the tag universe from the lightweight summaries (no node-tree
/// hydration) and renders a chip per tag plus a "Favorites" toggle. Hidden
/// entirely when there are no tags and no favorite filter is active, so a
/// fresh library stays uncluttered.
class _LibraryFilterRow extends ConsumerWidget {
  final SkotiqColors colors;

  const _LibraryFilterRow({required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tagsAsync = ref.watch(sequenceTagUniverseProvider);
    final selectedTags = ref.watch(sequenceTagFilterProvider);
    final favoritesOnly = ref.watch(sequenceFavoritesOnlyProvider);

    final tags = tagsAsync.maybeWhen(
      data: (t) => t,
      orElse: () => const <String>[],
    );

    // Nothing to filter by yet: no tags anywhere and favorites not engaged.
    if (tags.isEmpty && !favoritesOnly) {
      return const SizedBox.shrink();
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilterChip(
            avatar: Icon(
              LucideIcons.star,
              size: 14,
              color: favoritesOnly ? colors.warning : colors.textMuted,
            ),
            label: const Text('Favorites'),
            selected: favoritesOnly,
            visualDensity: VisualDensity.compact,
            onSelected: (on) {
              ref.read(sequenceFavoritesOnlyProvider.notifier).state = on;
            },
          ),
          for (final tag in tags)
            FilterChip(
              label: Text(tag),
              selected: selectedTags.contains(tag),
              visualDensity: VisualDensity.compact,
              onSelected: (on) {
                final next = {...selectedTags};
                if (on) {
                  next.add(tag);
                } else {
                  next.remove(tag);
                }
                ref.read(sequenceTagFilterProvider.notifier).state = next;
              },
            ),
        ],
      ),
    );
  }
}
