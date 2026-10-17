// The Tonight tab's one empty state: the catalog is missing, or the filters
// left nothing. Never both, never a stack of cards.
part of '../planner_screen.dart';

/// The single [EmptyState] the candidate list falls back to.
///
/// Two causes, one surface. When the scorer had NOTHING to score the cause is
/// almost always a missing object catalog, and the fix is to install it; when
/// it scored candidates and the filters excluded them all, the fix is to reset
/// the filters. The old card stacked a heading, a filter-impact breakdown, a
/// two-item "next steps" list and a button; 06 §Plan removes all of it.
class _PlannerFilteredEmptyState extends ConsumerWidget {
  final SkotiqColors colors;

  const _PlannerFilteredEmptyState({required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final breakdown = ref.watch(plannerFilterExclusionProvider);
    final catalogInstalled =
        ref.watch(catalogStateProvider).dsoCatalogStatus.isInstalled;

    if (breakdown.total == 0 && !catalogInstalled) {
      return plannerCentredEmptyState(
        EmptyState(
          icon: LucideIcons.download,
          title: l10n.text('plannerNoCatalogTitle'),
          body: l10n.text('plannerNoCatalogBody'),
          action: SkotiqButton(
            label: l10n.text('plannerNoCatalogAction'),
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: () => context.go('/settings/plate-solving'),
          ),
        ),
      );
    }

    return plannerCentredEmptyState(
      EmptyState(
        icon: LucideIcons.filterX,
        title: l10n.text('plannerNoMatchesTitle'),
        body: l10n.text(
          'plannerNoMatchesBody',
          params: {
            'total': '${breakdown.total}',
            'passed': '${breakdown.passed}',
          },
        ),
        action: SkotiqButton(
          label: l10n.text('plannerNoMatchesAction'),
          icon: LucideIcons.rotateCcw,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: () {
            ref.read(suggestionFilterProvider.notifier).state =
                const SuggestionFilterState();
            ref.read(_plannerVisibleCountProvider.notifier).state =
                _kPlannerPageSize;
          },
        ),
      ),
    );
  }
}

/// Centres an [EmptyState] when the viewport has room and scrolls it when it
/// does not.
///
/// A phone in landscape with the software keyboard up leaves this tab under
/// 150 px, which is shorter than an icon + title + sentence + button. Centred
/// alone, that overflows and the button becomes unreachable — the state whose
/// whole job is to offer the ONE fix.
Widget plannerCentredEmptyState(Widget child) {
  return LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: Center(child: child),
      ),
    ),
  );
}
