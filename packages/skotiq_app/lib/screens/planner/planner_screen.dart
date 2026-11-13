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
import 'package:skotiq_planetarium/skotiq_planetarium.dart' hide FramingView;
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../framing/framing_screen.dart';
import '../planetarium/planetarium_screen.dart';
import '../../router/show_in_sky.dart';
import '../../widgets/accessible_dropdown.dart';
import '../discover/your_sky/your_sky_screen.dart';
import '../discover/constellation/constellation_screen.dart';
import '../discover/collaborative_sky/collaborative_sky_screen.dart';
import '../../localization/skotiq_localizations.dart';
import '../../tours/tour_target.dart';
import '../../utils/authority_bound_dialog.dart';
import '../../utils/darkroom_navigation.dart' show unavailableControlName;
import '../../utils/plan_tonight_sequencer_helper.dart';
import '../../widgets/auto_build_options_dialog.dart';
import '../../widgets/catalogs/sky_catalog_download_panel.dart';
import '../imaging/widgets/camera_panel.dart';
import '../night_control/center/chart_axes.dart';
import 'widgets/planning_risks_banner.dart';
import 'widgets/progress_tab_content.dart';
import 'widgets/projects_tab_content.dart';
import 'widgets/scheduler_tab_content.dart';
import 'widgets/week_forecast_strip.dart';
import '../../router/planner_route.dart';
import '../../router/settings_sections.dart';
import '../../router/app_routes.dart';

export '../../router/planner_route.dart' show PlannerTab, DiscoverView;
// File split: the rest of this library lives in `planner_screen_parts/`.
// Each part is `part of '../planner_screen.dart';` and contains a cohesive
// group of private widgets / helpers. Imports are owned here so part files
// inherit the same symbol scope.

part 'planner_screen_parts/_recommendation_tab.dart';
part 'planner_screen_parts/_autopilot_preview_banner.dart';
part 'planner_screen_parts/_header_and_controls_bar.dart';
part 'planner_screen_parts/_filter_controls.dart';
part 'planner_screen_parts/_candidate_list.dart';
part 'planner_screen_parts/_filtered_empty_state.dart';
part 'planner_screen_parts/_primary_target_card.dart';
part 'planner_screen_parts/_search_results.dart';
part 'planner_screen_parts/_projects_tab.dart';
part 'planner_screen_parts/_schedule_tab.dart';
part 'planner_screen_parts/_discover_tab.dart';
part 'planner_screen_parts/_candidate_observing_list.dart';
part 'planner_screen_parts/_range_controls.dart';

/// Page size for the candidate list. The list starts at one page and grows
/// when the user taps "Load more" or scrolls to the bottom.
const int _kPlannerPageSize = 25;

/// Why a filter measured from the observing site cannot be used yet.
///
/// The words the disabled chips carry, in the same clause form the rest of the
/// app uses for a refusal ("Compare — it needs a second branch"), so
/// [unavailableControlName] can put them straight in the accessible name.
const String kPlannerSiteFilterRefusal =
    'it is measured from your observing site, and no site is set — add your '
    'latitude and longitude in Settings';

/// Whether no observing site is configured.
///
/// One predicate, read by the Recommendation tab's body (which answers
/// "Location not configured") and by the filter chips that need a site. They
/// disagreed: on a fresh install the body said the planner could not run while
/// "Alt now" and "Moon" above it opened live sliders and applied limits the
/// suggestion pipeline had no site to evaluate. A screen states one thing about
/// itself, so both read this.
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
          'Plan Tonight is using default exposures: the Smart Night exposure '
          'context could not be read ($error)',
          source: 'Planner',
        );
      }
    }
    return ref.watch(sessionOptimizerServiceProvider).buildPlanFromSuggestions(
          suggestions,
          generatedAt: DateTime.now(),
          exposureContext: exposureContext,
        );
  } on PlannerSiteUnsetError {
    rethrow;
  } catch (error, stackTrace) {
    logger.error(
      'Plan Tonight could not build tonight\'s plan: $error',
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

/// Full "Plan Tonight" workspace.
///
/// Six sub-tabs:
///   * Recommendation — the primary scoring engine: best target right now,
///     filterable / sortable / searchable candidate list, SIMBAD fallback,
///     risk factors and rationale.
///   * Projects — the multi-night campaign workspace ([_ProjectsTab]): a scope
///     switch between the active campaign's per-target integration goals
///     ([ProjectsTabContent], with the "Plan in Smart Night" handoff) and the
///     global all-targets progress roll-up ([ProgressTabContent]).
///   * Schedule — the seven-night forecast strip ([WeekForecastStrip]) pinned
///     above the RoboTarget-class dynamic scheduler ([SchedulerTabContent]):
///     which nights to run, and the queue that runs them.
///   * Framing / Planetarium — the sky-work surfaces.
///   * Discover — the Your Sky / Constellation discovery surfaces.
class PlannerScreen extends ConsumerStatefulWidget {
  /// The tab a link asked for; null opens Recommendation.
  final PlannerTab? initialTab;

  /// The Discover view a link asked for; null keeps Your sky.
  final DiscoverView? initialDiscoverView;

  const PlannerScreen({
    super.key,
    this.initialTab,
    this.initialDiscoverView,
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
                        builder: (context) => AlertDialog(
                              title: const Text('Camera / cooling'),
                              content: SizedBox(
                                  width: 420,
                                  height: 500,
                                  child: CameraPanel(colors: colors)),
                              actions: [
                                SkotiqButton(
                                    label: 'Done',
                                    onPressed: () => Navigator.pop(context))
                              ],
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
        PlannerTab.projects => AdaptiveTab(
            label: l10n.text('plannerTabProjects'),
            icon: LucideIcons.folderKanban,
          ),
        PlannerTab.schedule => AdaptiveTab(
            label: l10n.text('plannerTabSchedule'),
            icon: LucideIcons.calendarDays,
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

  /// Schedule and Discover read host state (scheduler snapshot, atlas
  /// regions, coverage and per-region timelines) for as long as they are
  /// mounted, which on a companion means requests to the imaging host. They
  /// are built only while selected, so a hidden tab never polls; the other
  /// tabs keep their state. Framing and Planetarium stay built for instant
  /// switching but sit under a TickerMode, so their sky animations stop while
  /// off-tab.
  Widget _bodyFor(PlannerTab tab, {required bool selected}) => switch (tab) {
        PlannerTab.recommendation => const _RecommendationTab(),
        PlannerTab.projects => const _ProjectsTab(),
        PlannerTab.schedule =>
          selected ? const _ScheduleTab() : const SizedBox.shrink(),
        PlannerTab.framing =>
          TickerMode(enabled: selected, child: const FramingView()),
        PlannerTab.planetarium =>
          TickerMode(enabled: selected, child: const PlanetariumView()),
        PlannerTab.discover => selected
            ? _DiscoverTab(requestedView: widget.initialDiscoverView)
            : const SizedBox.shrink(),
      };
}
