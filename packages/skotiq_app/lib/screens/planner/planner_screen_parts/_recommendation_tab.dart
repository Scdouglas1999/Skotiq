// Owns the Tonight tab: its selection state, scroll-driven pagination, and the
// two-column body (candidate list | 380px detail column) with the single
// empty / loading / error pattern around it.
part of '../planner_screen.dart';

/// How the stacked (narrow) Tonight tab splits its height between the selected
/// target's detail and the candidate list.
const int _kNarrowDetailFlex = 4;
const int _kNarrowListFlex = 6;

/// "Tonight" tab — the planner's scoring surface.
///
/// Two columns: the filtered candidate list on the left, and the selected
/// target's detail column on the right. Kept as a separate widget so the
/// search / filter state and the infinite-scroll machinery stay scoped to this
/// tab (the other tabs don't need it).
class _RecommendationTab extends ConsumerStatefulWidget {
  const _RecommendationTab();

  @override
  ConsumerState<_RecommendationTab> createState() => _RecommendationTabState();
}

class _RecommendationTabState extends ConsumerState<_RecommendationTab> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  /// The candidate the detail column describes, or null to follow the
  /// optimizer's pick. Held as a target id, not an index, so a filter change
  /// that reorders the list keeps the same target selected.
  int? _selectedTargetId;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_maybeLoadMore)
      ..dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    // Page in a screenful ahead of the end. A fixed 240px lead is most of a
    // page on a phone but a sliver of a tall desktop viewport, where the list
    // ran dry mid-flick before the next page was appended.
    final lead = position.viewportDimension * 0.5;
    if (position.pixels >= position.maxScrollExtent - lead) {
      final filtered =
          ref.read(plannerFilteredSuggestionsProvider).valueOrNull ?? const [];
      final current = ref.read(_plannerVisibleCountProvider);
      if (current < filtered.length) {
        ref.read(_plannerVisibleCountProvider.notifier).state =
            (current + _kPlannerPageSize).clamp(0, filtered.length);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final planAsync = ref.watch(_plannerOptimizationProvider);
    final filtersState = ref.watch(suggestionFilterProvider);
    final candidatesAsync = ref.watch(plannerFilteredSuggestionsProvider);

    // Keep the search field in sync if the provider changes from elsewhere.
    if (_searchController.text != filtersState.searchQuery) {
      _searchController.value = TextEditingValue(
        text: filtersState.searchQuery,
        selection:
            TextSelection.collapsed(offset: filtersState.searchQuery.length),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        return Column(
          children: [
            // A parent Scaffold may consume viewInsets before this subtree
            // sees them, so the height actually left over — not MediaQuery —
            // is what the bar sizes itself against; it is the only signal that
            // survives an outer shell resizing for the keyboard on our behalf.
            _PlannerControlsBar(
              colors: colors,
              controller: _searchController,
              filters: filtersState,
              candidatesAsync: candidatesAsync,
              availableHeight: constraints.maxHeight,
            ),
            Expanded(
              // NEVER FLASH: the optimization plan refreshes whenever its
              // inputs change (location, the 30s state re-hydration, a real
              // target/profile edit). `when(loading:)` would drop the whole tab
              // to a skeleton on every one of those, blanking the screen even
              // when the result is identical. Instead, keep rendering the LAST
              // good plan while a refresh is in flight (Riverpod retains the
              // previous value across a reload), and only fall back to the
              // skeleton on the very first load or the error screen when there
              // is no value to keep showing.
              child: _whenWithPrevious<SessionOptimizationPlan>(
                planAsync,
                data: (plan) => _buildBody(context, colors, plan,
                    candidatesAsync, constraints.maxWidth),
                loading: () => _buildLoadingState(colors),
                error: (error) => _buildErrorState(context, error),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Renders [data] using the latest-or-previous value of [async], so an
  /// in-flight refresh keeps the current content on screen instead of flashing
  /// the [loading] state. [loading] is only used before the first value exists;
  /// [error] only when there is no value to fall back to.
  Widget _whenWithPrevious<T>(
    AsyncValue<T> async, {
    required Widget Function(T value) data,
    required Widget Function() loading,
    required Widget Function(Object error) error,
  }) {
    if (async.hasValue) return data(async.requireValue);
    if (async.hasError) return error(async.error!);
    return loading();
  }

  Widget _buildBody(
    BuildContext context,
    SkotiqColors colors,
    SessionOptimizationPlan plan,
    AsyncValue<List<TargetSuggestion>> candidatesAsync,
    double availableWidth,
  ) {
    return _whenWithPrevious<List<TargetSuggestion>>(
      candidatesAsync,
      data: (candidates) =>
          _buildContent(context, colors, plan, candidates, availableWidth),
      loading: () => _buildLoadingState(colors),
      error: (error) => _buildErrorState(context, error),
    );
  }

  /// The candidate the detail column describes: the user's pick when it is
  /// still in the filtered list, else the optimizer's, else the top row.
  TargetSuggestion? _effectiveSelection(
    SessionOptimizationPlan plan,
    List<TargetSuggestion> candidates,
  ) {
    if (candidates.isEmpty) return null;
    final chosen = _selectedTargetId;
    if (chosen != null) {
      for (final candidate in candidates) {
        if (candidate.targetId == chosen) return candidate;
      }
    }
    final optimizerPick = plan.primaryTarget;
    if (optimizerPick != null) {
      for (final candidate in candidates) {
        if (candidate.targetId == optimizerPick.targetId) return candidate;
      }
    }
    return candidates.first;
  }

  Widget _buildContent(
    BuildContext context,
    SkotiqColors colors,
    SessionOptimizationPlan plan,
    List<TargetSuggestion> candidates,
    double availableWidth,
  ) {
    if (candidates.isEmpty) return _PlannerFilteredEmptyState(colors: colors);

    final selected = _effectiveSelection(plan, candidates);
    final list = _CandidateList(
      candidates: candidates,
      colors: colors,
      scrollController: _scrollController,
      selectedTargetId: selected?.targetId,
      onSelect: (target) => setState(() => _selectedTargetId = target.targetId),
      riskFactors: plan.riskFactors,
    );

    // Below the shell's layout breakpoint the two panes cannot both hold their
    // measurements, so they stack: the target you are about to act on first,
    // then the list you would pick a different one from.
    final narrow = availableWidth < ShellChromeMetrics.shellLayoutBreakpoint;
    if (narrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (selected != null)
            // Flex, not intrinsic height: the detail is ~450px of content and a
            // short landscape viewport is less than that, so it takes a share
            // of the column and scrolls inside it rather than overflowing.
            Flexible(
              flex: _kNarrowDetailFlex,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surface,
                  border: Border(bottom: BorderSide(color: colors.border)),
                ),
                child: Padding(
                  padding: SidePanel.contentPadding,
                  child: _TargetDetailColumn(
                    target: selected,
                    plan: plan,
                    onFrameIt: () => _sendToFraming(context, ref, selected),
                    onBuildSequence: () =>
                        _createSequence(context, colors, selected, plan),
                  ),
                ),
              ),
            ),
          Expanded(flex: _kNarrowListFlex, child: list),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: list),
        SidePanel(
          width: _kPlannerDetailWidth,
          child: selected == null
              ? const SizedBox.shrink()
              : _TargetDetailColumn(
                  target: selected,
                  plan: plan,
                  onFrameIt: () => _sendToFraming(context, ref, selected),
                  onBuildSequence: () =>
                      _createSequence(context, colors, selected, plan),
                ),
        ),
      ],
    );
  }

  Future<void> _createSequence(
    BuildContext context,
    SkotiqColors colors,
    TargetSuggestion target,
    SessionOptimizationPlan plan,
  ) async {
    try {
      final options = await showAutoBuildOptions(context, ref, target);
      if (options == null || !context.mounted) return;
      final built = await buildPlanTonightTargetSequence(
        ref: ref,
        target: target,
        plan: plan,
        options: options,
        includeSessionPreamble: true,
      );
      if (!context.mounted) return;
      final loaded = await loadPlanTonightSequenceIntoEditor(
        context: context,
        ref: ref,
        result: built,
        replaceSequence: true,
      );
      if (!loaded || !context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.text(
              'plannerDraftCreated',
              params: {
                'target': target.targetName,
                'exposure': planTonightSequenceSummary(built),
              },
            ),
          ),
          backgroundColor: colors.success,
        ),
      );

      context.go('/sequencer');
    } on SmartNightBuildException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message),
          backgroundColor: colors.error,
        ),
      );
    }
  }

  void _sendToFraming(
    BuildContext context,
    WidgetRef ref,
    TargetSuggestion target,
  ) {
    ref.read(framingProvider.notifier).setTargetSuggestion(target);
    context.goNamed('framing');
  }

  Widget _buildLoadingState(SkotiqColors colors) {
    return ShimmerLoading(
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.space2xl,
          vertical: SkotiqTokens.spaceMd,
        ),
        itemCount: 6,
        separatorBuilder: (_, __) =>
            const SizedBox(height: SkotiqTokens.spaceSm),
        itemBuilder: (_, __) => _CandidateSkeleton(colors: colors),
      ),
    );
  }

  /// The one error surface for this tab. A missing observing site is not an
  /// error the user caused, so it reads as the screen's single [EmptyState]
  /// with the fix on it; anything else offers a retry.
  Widget _buildErrorState(BuildContext context, Object error) {
    final l10n = context.l10n;
    final isLocationError = error is StateError;
    return plannerCentredEmptyState(
      Builder(
        builder: (context) => isLocationError
            ? EmptyState(
                icon: LucideIcons.mapPin,
                title: l10n.text('plannerNoSiteTitle'),
                body: l10n.text('plannerNoSiteBody'),
                action: SkotiqButton(
                  label: l10n.text('plannerNoSiteAction'),
                  variant: ButtonVariant.secondary,
                  size: ButtonSize.small,
                  onPressed: () => context.go('/settings?section=location'),
                ),
              )
            : EmptyState(
                icon: LucideIcons.alertCircle,
                title: l10n.text('plannerPlanFailedTitle'),
                body: l10n.text('plannerPlanFailedBody'),
                action: SkotiqButton(
                  label: l10n.text('plannerPlanFailedAction'),
                  variant: ButtonVariant.secondary,
                  size: ButtonSize.small,
                  onPressed: () => ref.invalidate(_plannerOptimizationProvider),
                ),
              ),
      ),
    );
  }
}
