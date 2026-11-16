import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../router/app_routes.dart';
import '../sequencer_screen.dart';
import '../../../utils/authority_bound_dialog.dart';
import '../sequence_mutator_helper.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../utils/count_label.dart';
import '../../../utils/exported_file_reveal.dart';
import '../widgets/save_sequence.dart';

part 'sequence_library_tab/library_toolbar.dart';
part 'sequence_library_tab/sequence_row.dart';
part 'sequence_library_tab/version_history_dialog.dart';
part 'sequence_library_tab/tag_editor_dialog.dart';
part 'sequence_library_tab/delete_sequence_dialog.dart';

// The saved list itself is skotiq_core's savedSequenceSummariesProvider: one
// grouped query that does not hydrate each sequence's node tree.

/// Search text for the saved list. Written through a debounce in the toolbar.
final sequenceSearchProvider = StateProvider.autoDispose<String>((ref) => '');

/// Active tag filter. Empty = no tag filter (show all). A summary matches when
/// it carries every selected tag (AND semantics), so narrowing tags narrows
/// the list.
final sequenceTagFilterProvider =
    StateProvider.autoDispose<Set<String>>((ref) => <String>{});

/// When true, the list is restricted to favorited sequences.
final sequenceFavoritesOnlyProvider =
    StateProvider.autoDispose<bool>((ref) => false);

enum SequenceSortOrder {
  dateModified('Last modified'),
  dateCreated('Date created'),
  name('Name'),
  nodeCount('Step count');

  const SequenceSortOrder(this.label);

  final String label;
}

final sequenceSortOrderProvider = StateProvider.autoDispose<SequenceSortOrder>(
  (ref) => SequenceSortOrder.dateModified,
);

/// Every tag present across the saved sequences, sorted, for the tag filter.
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

/// Saved-sequence summaries with the search, tag and favorite filters and the
/// sort order applied, kept out of `build` so a rebuild from an unrelated
/// provider does not re-run the pipeline.
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
      case SequenceSortOrder.dateModified:
        filtered.sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
      case SequenceSortOrder.dateCreated:
        filtered.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case SequenceSortOrder.nodeCount:
        filtered.sort((a, b) => b.nodeCount.compareTo(a.nodeCount));
    }
    return filtered;
  });
});

/// Sequencer > Saved: the sequences in the library, one row each.
///
/// A row opens its sequence in the Builder; the star and a "more" menu carry
/// everything else. "Save current" is the page header's, not this tab's.
class SequenceLibraryTab extends ConsumerWidget {
  const SequenceLibraryTab({super.key});

  void _clearFilters(WidgetRef ref) {
    ref.read(sequenceSearchProvider.notifier).state = '';
    ref.read(sequenceTagFilterProvider.notifier).state = <String>{};
    ref.read(sequenceFavoritesOnlyProvider.notifier).state = false;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final libraryAsync = ref.watch(savedSequenceSummariesProvider);
    final filteredAsync = ref.watch(filteredSequenceSummariesProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < BreakpointTokens.breakpointPhone;
        final padding = compact
            ? SkotiqTokens.screenPaddingCompact
            : SkotiqTokens.screenPadding;

        return libraryAsync.when(
          loading: () => const Center(
            child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36),
          ),
          error: (error, _) => Center(
            child: EmptyState.error(
              title: 'Could not load saved sequences',
              body: userFacingError(error),
              onRetry: () => ref.invalidate(savedSequenceSummariesProvider),
            ),
          ),
          data: (library) {
            // An empty library has nothing to search or sort: the page is the
            // empty state alone.
            if (library.isEmpty) {
              return Center(
                child: EmptyState(
                  icon: LucideIcons.folderOpen,
                  title: 'No saved sequences',
                  body: 'Save a sequence from the Builder and it appears here.',
                  action: SkotiqButton(
                    label: 'Open the Builder',
                    variant: ButtonVariant.secondary,
                    size: ButtonSize.small,
                    onPressed: () => ref
                        .read(sequencerTabProvider.notifier)
                        .state = SequencerTab.builder.index,
                  ),
                ),
              );
            }
            final filtered = filteredAsync.valueOrNull ?? const [];
            return Padding(
              padding: padding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _LibraryToolbar(compact: compact),
                  const SizedBox(height: SkotiqTokens.spaceLg),
                  Expanded(
                    child: filtered.isEmpty
                        ? Center(
                            child: EmptyState(
                              icon: LucideIcons.searchX,
                              title: 'No sequences match',
                              body:
                                  'Try a different search, or clear the filters.',
                              action: SkotiqButton(
                                label: 'Clear filters',
                                variant: ButtonVariant.secondary,
                                size: ButtonSize.small,
                                onPressed: () => _clearFilters(ref),
                              ),
                            ),
                          )
                        : _SequenceList(
                            summaries: filtered,
                            total: library.length,
                            compact: compact,
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

const double _panelInset = SkotiqTokens.spaceSm;

/// A row's star and "more" buttons with the gaps [ListRow] puts around them.
const double _rowActionsWidth =
    ListRow.maxActions * SkotiqTokens.iconButtonSize +
        (ListRow.maxActions + 1) * SkotiqTokens.spaceXs;

/// The eyebrow heads and the panel of rows.
class _SequenceList extends StatelessWidget {
  const _SequenceList({
    required this.summaries,
    required this.total,
    required this.compact,
  });

  final List<SequenceSummary> summaries;
  final int total;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final eyebrow = SkotiqTypography.eyebrow.copyWith(color: colors.textMuted);
    final count = summaries.length == total
        ? countLabel(total, 'sequence')
        : '${summaries.length} of ${countLabel(total, 'sequence')}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Inset to line up with the row text and the trailing figure.
        Padding(
          padding: EdgeInsets.only(
            left: _panelInset + SkotiqTokens.spaceSm,
            right: _panelInset + (compact ? 0 : _rowActionsWidth),
          ),
          child: Row(
            children: [
              Expanded(child: Text(count.toUpperCase(), style: eyebrow)),
              if (!compact) Text('LAST RUN', style: eyebrow),
            ],
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        Flexible(
          child: SkotiqPanel(
            padding: const EdgeInsets.symmetric(
              horizontal: _panelInset,
              vertical: SkotiqTokens.spaceXs,
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: summaries.length,
              itemBuilder: (context, index) => _SequenceRow(
                key: ValueKey(summaries[index].id),
                summary: summaries[index],
                compact: compact,
                last: index == summaries.length - 1,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The page-header action on the Saved tab: save the plan open in the Builder
/// as a library entry.
class SaveCurrentSequenceButton extends ConsumerWidget {
  const SaveCurrentSequenceButton({super.key, this.iconOnly = false});

  /// A phone header has room for a glyph, not the words.
  final bool iconOnly;

  static const String label = 'Save current';

  void _save(BuildContext context, WidgetRef ref) {
    final current = ref.read(currentSequenceProvider);
    if (current == null) {
      context.showWarningSnackBar('There is no sequence in the Builder');
      return;
    }
    showSaveSequenceDialog(context, sequence: current);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (iconOnly) {
      return SkotiqIconButton(
        icon: LucideIcons.save,
        tooltip: label,
        onPressed: () => _save(context, ref),
      );
    }
    return SkotiqButton(
      label: label,
      icon: LucideIcons.save,
      variant: ButtonVariant.secondary,
      onPressed: () => _save(context, ref),
    );
  }
}
