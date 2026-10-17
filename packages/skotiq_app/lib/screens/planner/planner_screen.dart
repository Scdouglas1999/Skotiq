import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    hide FramingView;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../framing/framing_screen.dart';
import '../planetarium/planetarium_screen.dart';
import '../planetarium/show_in_sky.dart';
import '../accessible_dropdown.dart';
import '../your_sky/your_sky_screen.dart';
import '../constellation/constellation_screen.dart';
import '../collaborative_sky/collaborative_sky_screen.dart';
import '../../localization/skotiq_localizations.dart';
import '../../utils/authority_bound_dialog.dart';
import '../../utils/darkroom_navigation.dart' show unavailableControlName;
import '../../utils/plan_tonight_sequencer_helper.dart';
import '../../widgets/auto_build_options_dialog.dart';
import '../imaging/widgets/camera_panel.dart';
import 'widgets/planning_risks_banner.dart';
import 'widgets/progress_tab_content.dart';
import 'widgets/projects_tab_content.dart';
import 'widgets/scheduler_tab_content.dart';
import 'widgets/week_forecast_strip.dart';
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

/// Identifies a Plan Tonight sub-tab for deep-linking via `?tab=` query
/// param. Order here matches the rendered tab order; Recommendation is the
/// default.
///
/// The tabs read left-to-right as a planning-to-execution funnel: what is best
/// right now, the multi-night campaign workspace, the forecast strip over the
/// target queue, the two sky-work surfaces, then discovery.
///
/// The rendered `tabs` list and the `IndexedStack` children in
/// [_PlannerScreenState.build] MUST be kept in lockstep with this order,
/// because the selected-tab index is [PlannerTab.index]: reordering here
/// without matching both lists mis-routes deep-links and tab taps.
enum PlannerTab {
  recommendation,
  projects,
  schedule,
  framing,
  planetarium,
  discover,
}

/// Maps the router `?tab=` query value to a [PlannerTab]. Returns null for
/// an unrecognised value so the caller can fall back to a default. Public
/// so router code (and tests) can share the same canonical mapping.
PlannerTab? plannerTabFromQuery(String? value) {
  if (value == null) return null;
  switch (value.toLowerCase()) {
    case 'recommendation':
    case 'recommend':
      return PlannerTab.recommendation;
    case 'projects':
    case 'project':
    case 'campaign':
    case 'campaigns':
    case 'progress':
    case 'history':
      return PlannerTab.projects;
    case 'schedule':
    case 'scheduler':
    case 'queue':
    case 'target-queue':
    case 'targetqueue':
    case 'week':
    case 'forecast':
    case 'thisweek':
    case 'this-week':
      return PlannerTab.schedule;
    case 'framing':
      return PlannerTab.framing;
    case 'planetarium':
      return PlannerTab.planetarium;
    case 'discover':
    case 'sky':
    case 'yoursky':
    case 'your-sky':
    case 'constellation':
      return PlannerTab.discover;
  }
  return null;
}

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
    throw StateError(
      'Observing location is not configured. '
      'Set your latitude and longitude in Settings before using the planner.',
    );
  }
  final suggestions = await ref.watch(tonightSuggestionsProvider.future);
  final exposureContext = suggestions.isEmpty
      ? null
      : await ref.watch(smartNightExposureContextProvider.future);
  return ref.watch(sessionOptimizerServiceProvider).buildPlanFromSuggestions(
        suggestions,
        generatedAt: DateTime.now(),
        exposureContext: exposureContext,
      );
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
///
/// Query param `?tab=` selects the initial tab via [plannerTabFromQuery].
class PlannerScreen extends ConsumerStatefulWidget {
  /// Optional initial tab selection. When null, falls back to
  /// [initialTabQuery] parsing, then to [PlannerTab.recommendation].
  final PlannerTab? initialTab;

  /// Raw `?tab=` value parsed from the router. Lets deep-links select a
  /// specific Plan Tonight tab (notably `?tab=scheduler` from the legacy
  /// `/scheduler` redirect).
  final String? initialTabQuery;

  const PlannerScreen({
    super.key,
    this.initialTab,
    this.initialTabQuery,
  });

  @override
  ConsumerState<PlannerScreen> createState() => _PlannerScreenState();
}

class _PlannerScreenState extends ConsumerState<PlannerScreen> {
  late int _currentSubTab;

  @override
  void initState() {
    super.initState();
    final resolved = widget.initialTab ??
        plannerTabFromQuery(widget.initialTabQuery) ??
        PlannerTab.recommendation;
    _currentSubTab = resolved.index;
  }

  @override
  void didUpdateWidget(PlannerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // go_router keys pages by path, not query, so navigating to a different
    // `?tab=` while the planner is already the active host reuses this State
    // without re-running initState. Re-resolve so deep-links and the in-planner
    // "Send to framing" / scheduler handoffs select the target tab.
    if (widget.initialTabQuery != oldWidget.initialTabQuery) {
      final resolved = plannerTabFromQuery(widget.initialTabQuery);
      if (resolved != null && resolved.index != _currentSubTab) {
        setState(() => _currentSubTab = resolved.index);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    // Order MUST match [PlannerTab] declaration order: the selected index is
    // [PlannerTab.index], so a mismatch would mis-route deep-links and taps.
    // The assert is a developer guard against future drift; the tab-structure
    // tests assert the same invariant at runtime. Each tab carries an icon so
    // [AdaptiveTabBar] can collapse to icon-only on a compact phone rather than
    // overflowing the tab strip.
    final l10n = context.l10n;
    final tabs = <(PlannerTab, AdaptiveTab)>[
      (
        PlannerTab.recommendation,
        AdaptiveTab(
          label: l10n.text('plannerTabTonight'),
          icon: LucideIcons.sparkles,
        ),
      ),
      (
        PlannerTab.projects,
        AdaptiveTab(
          label: l10n.text('plannerTabProjects'),
          icon: LucideIcons.folderKanban,
        ),
      ),
      (
        PlannerTab.schedule,
        AdaptiveTab(
          label: l10n.text('plannerTabSchedule'),
          icon: LucideIcons.calendarDays,
        ),
      ),
      (
        PlannerTab.framing,
        AdaptiveTab(
          label: l10n.text('plannerTabFraming'),
          icon: LucideIcons.crop,
        ),
      ),
      (
        PlannerTab.planetarium,
        AdaptiveTab(
          label: l10n.text('plannerTabPlanetarium'),
          icon: LucideIcons.globe,
        ),
      ),
      (
        PlannerTab.discover,
        AdaptiveTab(
          label: l10n.text('plannerTabYourSky'),
          icon: LucideIcons.orbit,
        ),
      ),
    ];
    assert(
      tabs.length == PlannerTab.values.length &&
          tabs.asMap().entries.every((e) => e.value.$1.index == e.key),
      'Planner tab list is out of sync with PlannerTab: each entry must sit at '
      'its enum index and the list must cover every value.',
    );

    // On a phone with the software keyboard up the whole viewport is ~200px
    // tall; the header is the one row that can go, because the field the
    // operator is typing into is the navigation context while it is open.
    final keyboardCompact = Responsive.isPhone(context) &&
        MediaQuery.viewInsetsOf(context).bottom > 0;

    final tabBar = AdaptiveTabBar(
      tabs: [for (final t in tabs) t.$2],
      selectedIndex: _currentSubTab,
      onSelected: (index) => setState(() => _currentSubTab = index),
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
                // Order MUST match `tabs` / [PlannerTab] — one child per enum
                // value, at the same index.
                //
                // The last three are heavy LIVE-SKY views (HiPS tile maps with
                // time-ticking sky rotation, plus the animated living-sky in
                // Your sky). IndexedStack keeps every child BUILT — which is
                // what we want for state preservation — but it does NOT pause
                // their animations when off-tab, so all four ran their 60fps
                // repaints at once and pegged idle CPU (~78%), flashing the
                // panel.
                //
                // Wrap each heavy view in a TickerMode gated on "is this the
                // active tab". TickerMode mutes every AnimationController/Ticker
                // in the subtree while it's off-tab, so the continuous repaints
                // stop — but the widget stays mounted and its State (scroll,
                // selection, loaded tiles) is preserved, so switching back is
                // instant. Off-tab children are Offstage (don't paint), so the
                // only residual is a cheap ~1Hz clock rebuild that never paints.
                children: [
                  const _RecommendationTab(),
                  const _ProjectsTab(),
                  const _ScheduleTab(),
                  TickerMode(
                    enabled: _currentSubTab == PlannerTab.framing.index,
                    child: const FramingView(),
                  ),
                  TickerMode(
                    enabled: _currentSubTab == PlannerTab.planetarium.index,
                    child: const PlanetariumView(),
                  ),
                  TickerMode(
                    enabled: _currentSubTab == PlannerTab.discover.index,
                    child: const _DiscoverTab(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
