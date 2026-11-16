import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../framing/framing_screen.dart';
import '../planetarium/planetarium_screen.dart';
import '../../router/show_in_sky.dart';
import '../discover/your_sky/your_sky_screen.dart';
import '../discover/constellation/constellation_screen.dart';
import '../discover/collaborative_sky/collaborative_sky_screen.dart';
import '../../localization/skotiq_localizations.dart';
import '../../tours/tour_target.dart';
import '../../utils/authority_bound_dialog.dart';
import '../../utils/held_future.dart';
import '../../utils/plan_tonight_sequencer_helper.dart';
import '../../widgets/auto_build_options_dialog.dart';
import '../../widgets/catalogs/sky_catalog_download_panel.dart';
import '../imaging/widgets/camera_panel.dart';
import '../night_control/center/chart_axes.dart';
import 'image_tonight_controller.dart';
import 'targets/plan_targets_tab.dart';
import 'widgets/planning_risks_banner.dart';
import '../../router/planner_route.dart';
import '../../router/settings_sections.dart';
import '../../router/app_routes.dart';
import '../../utils/snackbar_helper.dart';

export '../../router/planner_route.dart' show PlannerTab, DiscoverView;
// File split: the rest of this library lives in `planner_screen_parts/`.
// Each part is `part of '../planner_screen.dart';` and contains a cohesive
// group of private widgets / helpers. Imports are owned here so part files
// inherit the same symbol scope.

part 'planner_screen_parts/_recommendation_tab.dart';
part 'planner_screen_parts/_header_and_controls_bar.dart';
part 'planner_screen_parts/_filter_controls.dart';
part 'planner_screen_parts/_candidate_list.dart';
part 'planner_screen_parts/_filtered_empty_state.dart';
part 'planner_screen_parts/_primary_target_card.dart';
part 'planner_screen_parts/_search_results.dart';
part 'planner_screen_parts/_discover_tab.dart';
part 'planner_screen_parts/_candidate_observing_list.dart';
part 'planner_screen_parts/_range_controls.dart';

/// Page size for the candidate list. The list starts at one page and grows
/// when the user taps "Load more" or scrolls to the bottom.
const int _kPlannerPageSize = 25;

/// Whether no observing site is configured.
///
/// Without a site nothing can be scored, so Best tonight is then one empty
/// state with no filters above it, and the header leaves out the night chips.
///
/// (0, 0) counts as unset, which is also what [appObserverLocationProvider]
/// answers null for. Stating it here as well means a caller holding a raw
/// settings row — rather than that provider's already-folded answer — gets the
/// same reading, and the two cannot drift apart.
bool plannerSiteUnset(LocationSettings? location) =>
    location == null || (location.latitude == 0.0 && location.longitude == 0.0);

class PlannerSiteUnsetError implements Exception {
  const PlannerSiteUnsetError();

  @override
  String toString() => 'Observing location is not configured. '
      'Set your latitude and longitude in Settings before using the planner.';
}

/// FutureProvider that produces tonight's optimization plan from the
/// unfiltered suggestion pool. The primary recommendation is "best of
/// everything tonight" so it never disappears when the user narrows filters.
final _plannerOptimizationProvider =
    FutureProvider.autoDispose<SessionOptimizationPlan>((ref) async {
  // Depend on the SELECT-based location provider, not the whole appSettings
  // future. The host broadcasts `settings/updated` very frequently (scheduler
  // runtime config), and awaiting appSettingsProvider.future would re-run this
  // plan — reloading the Recommendation tab — on every one.
  // appObserverLocation only emits when latitude/longitude actually change, so
  // unrelated settings churn does not thrash the tab.
  final location = ref.watch(appObserverLocationProvider);
  if (plannerSiteUnset(location)) {
    throw const PlannerSiteUnsetError();
  }
  final logger = ref.read(loggingServiceProvider);
  try {
    final suggestions = await ref.watch(tonightSuggestionsProvider.future);
    SmartNightExposureContext? exposureContext;
    if (suggestions.isNotEmpty) {
      // The exposure context only refines sub lengths; without it the plan
      // still ranks tonight's targets on the planner's default exposures.
      try {
        exposureContext =
            await ref.watch(smartNightExposureContextProvider.future);
      } catch (error) {
        logger.warning(
          'Best tonight is using default exposures: the Smart Night exposure '
          'context could not be read ($error)',
          source: 'Planner',
        );
      }
    }
    return ref.watch(sessionOptimizerServiceProvider).buildPlanFromSuggestions(
          suggestions,
          generatedAt: ref.read(clockProvider).instant,
          exposureContext: exposureContext,
        );
  } on PlannerSiteUnsetError {
    rethrow;
  } catch (error, stackTrace) {
    logger.error(
      'Best tonight could not build tonight\'s plan: $error',
      source: 'Planner',
      fields: {'stack': stackTrace.toString()},
    );
    rethrow;
  }
});

/// Tracks how many candidate rows are currently rendered. Increments by
/// [_kPlannerPageSize] each time the user requests more.
final _plannerVisibleCountProvider = StateProvider.autoDispose<int>(
  (_) => _kPlannerPageSize,
);

/// The Plan destination.
///
/// Five tabs:
///   * Best tonight: the scoring engine's pick for right now, with the
///     filterable candidate list, SIMBAD fallback, risks and rationale.
///   * Targets: the owner's targets, their progress and goals, and the
///     autopilot that works through them ([PlanTargetsTab]).
///   * Framing / Planetarium: the sky-work surfaces.
///   * Your sky: the discovery surfaces.
class PlannerScreen extends ConsumerStatefulWidget {
  /// The tab a link asked for; null opens Recommendation.
  final PlannerTab? initialTab;

  /// The Discover view a link asked for; null keeps Your sky.
  final DiscoverView? initialDiscoverView;

  /// The Targets group (`?group=`) and target (`?target=`) a link asked for.
  final String? initialGroup;
  final int? initialTargetId;

  const PlannerScreen({
    super.key,
    this.initialTab,
    this.initialDiscoverView,
    this.initialGroup,
    this.initialTargetId,
  });

  @override
  ConsumerState<PlannerScreen> createState() => _PlannerScreenState();
}

class _PlannerScreenState extends ConsumerState<PlannerScreen> {
  late int _currentSubTab;

  @override
  void initState() {
    super.initState();
    final resolved = widget.initialTab ?? PlannerTab.recommendation;
    _currentSubTab = resolved.index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _publishTab();
    });
  }

  void _showTab(int index) {
    setState(() => _currentSubTab = index);
    _publishTab();
  }

  /// Lets the command palette know whether its target rows should move the
  /// sky on screen or open Framing.
  void _publishTab() => ref.read(plannerShowsSkyProvider.notifier).state =
      _currentSubTab == PlannerTab.planetarium.index;

  @override
  void didUpdateWidget(PlannerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // go_router keys pages by path, not query, so navigating to a different
    // `?tab=` while the planner is already the active host reuses this State
    // without re-running initState. Re-resolve so deep-links and the in-planner
    // "Send to framing" / scheduler handoffs select the target tab.
    if (widget.initialTab != oldWidget.initialTab) {
      final resolved = widget.initialTab;
      if (resolved != null && resolved.index != _currentSubTab) {
        _showTab(resolved.index);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;

    // On a phone with the software keyboard up the whole viewport is ~200px
    // tall; the header is the one row that can go, because the field the
    // operator is typing into is the navigation context while it is open.
    final keyboardCompact = Responsive.isPhone(context) &&
        MediaQuery.viewInsetsOf(context).bottom > 0;

    final tabBar = AdaptiveTabBar(
      tabs: [for (final tab in PlannerTab.values) _tabFor(tab, l10n)],
      selectedIndex: _currentSubTab,
      onSelected: (index) {
        _showTab(index);
        // Into the location, so a link to the tab it still named is not a
        // link to where the planner already is.
        GoRouter.maybeOf(context)
            ?.go(AppRoutes.planner(tab: PlannerTab.values[index]));
      },
      // The page header owns the 24px gutter, so the strip starts flush
      // against the title block.
      horizontalPadding: 0,
    );

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: [
            // While a phone keyboard is open, the focused search field is the
            // active navigation context. Temporarily reclaim the header's
            // height so the controls row still fits in a short landscape
            // viewport; it returns unchanged when the keyboard closes.
            if (!keyboardCompact)
              PageHeader(
                icon: LucideIcons.compass,
                title: l10n.text('plannerTitleShort'),
                tabs: tabBar,
                actions: [
                  if (MediaQuery.sizeOf(context).width >= 1000)
                    const _PlanNightChips(),
                  SkotiqButton(
                    label: MediaQuery.sizeOf(context).width < 1000
                        ? 'Camera'
                        : 'Camera / cooling',
                    icon: SkotiqIcons.frost,
                    variant: ButtonVariant.secondary,
                    onPressed: () => showDialog<void>(
                        context: context,
                        builder: (context) => SkotiqDialog(
                              title: 'Camera / cooling',
                              width: SkotiqDialog.widthConfirm,
                              actions: [
                                SkotiqButton(
                                    label: 'Done',
                                    onPressed: () => Navigator.pop(context))
                              ],
                              child: CameraPanel(
                                  colors: colors, scrollable: false),
                            )),
                  ),
                ],
              ),
            Expanded(
              child: IndexedStack(
                index: _currentSubTab,
                children: [
                  for (final tab in PlannerTab.values)
                    _bodyFor(tab, selected: tab.index == _currentSubTab),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Each tab carries an icon so [AdaptiveTabBar] can collapse to icon-only
  /// on a compact phone rather than overflowing the strip.
  static AdaptiveTab _tabFor(PlannerTab tab, SkotiqLocalizations l10n) =>
      switch (tab) {
        PlannerTab.recommendation => AdaptiveTab(
            label: l10n.text('plannerTabTonight'),
            icon: LucideIcons.sparkles,
          ),
        PlannerTab.targets => AdaptiveTab(
            label: l10n.text('plannerTabTargets'),
            icon: LucideIcons.target,
          ),
        PlannerTab.framing => AdaptiveTab(
            label: l10n.text('plannerTabFraming'),
            icon: LucideIcons.crop,
            buttonKey: TourTarget.planTabFraming.key,
          ),
        PlannerTab.planetarium => AdaptiveTab(
            label: l10n.text('plannerTabPlanetarium'),
            icon: LucideIcons.globe,
            buttonKey: TourTarget.planTabPlanetarium.key,
          ),
        PlannerTab.discover => AdaptiveTab(
            label: l10n.text('plannerTabYourSky'),
            icon: LucideIcons.orbit,
          ),
      };

  /// Targets and Discover read host state (the autopilot, atlas regions,
  /// coverage and timelines) for as long as they are mounted, which on a
  /// linked client means requests to the imaging host. They are built only
  /// while selected, so a hidden tab never polls; the other tabs keep their
  /// state. Framing and Planetarium stay built for instant switching but sit
  /// under a TickerMode, so their sky animations stop while off-tab.
  Widget _bodyFor(PlannerTab tab, {required bool selected}) => switch (tab) {
        PlannerTab.recommendation => const _RecommendationTab(),
        PlannerTab.targets => selected
            ? PlanTargetsTab(
                initialGroup: widget.initialGroup,
                initialTargetId: widget.initialTargetId,
              )
            : const SizedBox.shrink(),
        PlannerTab.framing =>
          TickerMode(enabled: selected, child: const FramingView()),
        PlannerTab.planetarium =>
          TickerMode(enabled: selected, child: const PlanetariumView()),
        PlannerTab.discover => selected
            ? _DiscoverTab(requestedView: widget.initialDiscoverView)
            : const SizedBox.shrink(),
      };
}
