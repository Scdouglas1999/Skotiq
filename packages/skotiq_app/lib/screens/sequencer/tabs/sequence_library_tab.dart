import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import '../sequencer_screen.dart';
import '../../../utils/authority_bound_dialog.dart';
import '../../../utils/sequence_mutator_helper.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../utils/count_label.dart';
import '../../../utils/exported_file_reveal.dart';
import '../plan_math.dart';

part 'sequence_library_tab/library_header.dart';
part 'sequence_library_tab/library_filter_row.dart';
part 'sequence_library_tab/action_button.dart';
part 'sequence_library_tab/sequence_card.dart';
part 'sequence_library_tab/supporting_widgets.dart';
part 'sequence_library_tab/save_sequence_dialog.dart';
part 'sequence_library_tab/version_history_dialog.dart';
part 'sequence_library_tab/tag_editor_dialog.dart';
part 'sequence_library_tab/sequence_card_dialogs.dart';

/// Provider for sequences list - loads from database
// autoDispose: list is only consumed by SequenceLibraryTab; refetching the
// DB on revisit is cheap and ensures we never show stale entries after the
// user edited a sequence elsewhere.
// Defined in skotiq_core: savedSequenceSummariesProvider
// (sequence_catalog_sync.dart) — a single grouped query that does NOT hydrate
// each sequence's full node tree.

/// Search provider for sequences
// autoDispose: filter input is tab-scoped; clearing it on revisit matches
// user expectation. Written via a debounce in the library header.
final sequenceSearchProvider = StateProvider.autoDispose<String>((ref) => '');

/// Active tag filter. Empty = no tag filter (show all). A summary matches when
/// it carries every selected tag (AND semantics), so narrowing tags narrows
/// the list.
// autoDispose: tab-scoped, cleared on revisit like the search query.
final sequenceTagFilterProvider =
    StateProvider.autoDispose<Set<String>>((ref) => <String>{});

/// When true, the list is restricted to favorited sequences.
// autoDispose: tab-scoped toggle.
final sequenceFavoritesOnlyProvider =
    StateProvider.autoDispose<bool>((ref) => false);

/// Sort order for sequences
enum SequenceSortOrder { name, dateModified, dateCreated, nodeCount }

/// Provider for sort order
// autoDispose: tab-scoped preference; default (dateModified) is appropriate
// on each visit.
final sequenceSortOrderProvider = StateProvider.autoDispose<SequenceSortOrder>(
  (ref) => SequenceSortOrder.dateModified,
);

/// Every tag present across the saved sequences, sorted, for the filter row.
/// Derived from the lightweight summaries so it never hydrates node trees.
final sequenceTagUniverseProvider =
    Provider.autoDispose<AsyncValue<List<String>>>((ref) {
  final summariesAsync = ref.watch(savedSequenceSummariesProvider);
  return summariesAsync.whenData((summaries) {
    final tags = <String>{};
    for (final summary in summaries) {
      tags.addAll(summary.tags);
    }
    final sorted = tags.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return sorted;
  });
});

/// Derived list of saved-sequence summaries with the active search, tag, and
/// favorite filters plus the sort order applied. Memoizes the filter+sort work
/// outside of `build` so a rebuild from an unrelated provider (e.g. hover state
/// on a card) doesn't re-run the whole pipeline. Recomputes only when the
/// underlying list, the (debounced) query, the tag/favorite filters, or the
/// sort order changes.
final filteredSequenceSummariesProvider =
    Provider.autoDispose<AsyncValue<List<SequenceSummary>>>((ref) {
  final summariesAsync = ref.watch(savedSequenceSummariesProvider);
  final query = ref.watch(sequenceSearchProvider).trim().toLowerCase();
  final tagFilter = ref.watch(sequenceTagFilterProvider);
  final favoritesOnly = ref.watch(sequenceFavoritesOnlyProvider);
  final order = ref.watch(sequenceSortOrderProvider);

  return summariesAsync.whenData((summaries) {
    var filtered = summaries.toList();

    if (favoritesOnly) {
      filtered = filtered.where((s) => s.isFavorite).toList();
    }

    if (tagFilter.isNotEmpty) {
      filtered = filtered
          .where((s) => tagFilter.every((tag) => s.tags.contains(tag)))
          .toList();
    }

    if (query.isNotEmpty) {
      filtered = filtered
          .where((s) =>
              s.name.toLowerCase().contains(query) ||
              (s.primaryTargetName?.toLowerCase().contains(query) ?? false) ||
              s.tags.any((t) => t.toLowerCase().contains(query)))
          .toList();
    }

    switch (order) {
      case SequenceSortOrder.name:
        filtered.sort((a, b) => a.name.compareTo(b.name));
        break;
      case SequenceSortOrder.dateModified:
        filtered.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
        break;
      case SequenceSortOrder.dateCreated:
        filtered.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        break;
      case SequenceSortOrder.nodeCount:
        filtered.sort((a, b) => b.nodeCount.compareTo(a.nodeCount));
        break;
    }
    return filtered;
  });
});

/// Optional incoming sequence-id filter the library "history" link writes
/// before switching to the History tab, so the History tab can pre-filter
/// to just that sequence's runs.
final historyFilterSequenceIdProvider = StateProvider<int?>((ref) => null);

class SequenceLibraryTab extends ConsumerWidget {
  const SequenceLibraryTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final isMobile = Responsive.isMobile(context);
    final filteredAsync = ref.watch(filteredSequenceSummariesProvider);
    final searchQuery = ref.watch(sequenceSearchProvider);
    final hasActiveFilter = searchQuery.trim().isNotEmpty ||
        ref.watch(sequenceTagFilterProvider).isNotEmpty ||
        ref.watch(sequenceFavoritesOnlyProvider);

    return Padding(
      padding: EdgeInsets.all(isMobile ? 12 : 24),
      child: Column(
        children: [
          // Header
          _LibraryHeader(colors: colors),

          const SizedBox(height: 16),

          // Tag / favorite filter row
          _LibraryFilterRow(colors: colors),

          const SizedBox(height: 16),

          // Content
          Expanded(
            child: filteredAsync.when(
              data: (filtered) {
                if (filtered.isEmpty) {
                  final hasSearch = hasActiveFilter;
                  return EmptyState(
                    icon: hasSearch
                        ? LucideIcons.searchX
                        : LucideIcons.folderOpen,
                    title:
                        hasSearch ? 'No sequences found' : 'No saved sequences',
                    // One sentence, and it already says where sequences come
                    // from — the "Tip: Use \"Save Current\"" card under it was
                    // a second sentence saying the same thing in a box, and it
                    // overflowed its own row on a narrow window.
                    body: hasSearch
                        ? 'Try a different search, or clear the filters.'
                        : 'Save a sequence from the Builder and it appears '
                            'here.',
                    action: hasSearch
                        ? SkotiqButton(
                            label: 'Clear filters',
                            icon: LucideIcons.x,
                            variant: ButtonVariant.secondary,
                            size: ButtonSize.small,
                            onPressed: () {
                              ref.read(sequenceSearchProvider.notifier).state =
                                  '';
                              ref
                                  .read(sequenceTagFilterProvider.notifier)
                                  .state = <String>{};
                              ref
                                  .read(sequenceFavoritesOnlyProvider.notifier)
                                  .state = false;
                            },
                          )
                        : null,
                  );
                }

                return ListView.separated(
                  itemCount: filtered.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 12),
                  itemBuilder: (context, index) {
                    return _SequenceCard(
                      colors: colors,
                      summary: filtered[index],
                    );
                  },
                );
              },
              loading: () => const Center(
                child: const SkotiqMark(
                    motion: SkotiqMarkMotion.loading, size: 36),
              ),
              error: (error, stack) => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.alertTriangle,
                        size: 48, color: colors.error),
                    const SizedBox(height: 16),
                    Text(
                      'Failed to load sequences',
                      style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: SkotiqTypography.fontSize16),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      error.toString(),
                      style: TextStyle(
                          color: colors.textMuted,
                          fontSize: SkotiqTypography.fontSize12),
                    ),
                    const SizedBox(height: 16),
                    SkotiqButton(
                      label: 'Retry',
                      icon: LucideIcons.refreshCw,
                      onPressed: () =>
                          ref.invalidate(savedSequenceSummariesProvider),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
