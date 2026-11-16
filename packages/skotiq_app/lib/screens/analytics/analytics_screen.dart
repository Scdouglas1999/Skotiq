import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/providers.dart';

import '../../localization/skotiq_localizations.dart';
import '../../tours/tour_target.dart';
import '../diagnostics/diagnostics_screen.dart';
import '../science/science_screen.dart';
import '../../widgets/run_status/run_status_presentation.dart';
import '../../router/analytics_route.dart';
import 'analytics_providers.dart';
import 'history/history_tab.dart';
import 'history/night_page.dart';
import 'quick_capture_selection.dart';
import 'session_elapsed.dart';
import 'widgets/analytics_empty_state.dart';
import 'widgets/analytics_session_picker.dart';
import 'widgets/session_chart.dart';
import 'widgets/session_chart_grid.dart';
import 'widgets/image_thumbnail_strip.dart';
import '../../router/app_routes.dart';
export '../../router/analytics_route.dart'
    show AnalyticsTab, NightRef, NightView, ScienceTab, SessionView;
export 'analytics_providers.dart';

part 'analytics_screen/session_tab.dart';

class AnalyticsScreen extends ConsumerStatefulWidget {
  /// The tab a link asked for; null opens Session.
  final AnalyticsTab? initialTab;

  /// The Science view a link asked for. A link that names no tab opens the
  /// Science tab on it.
  final ScienceTab? initialScienceView;

  /// The Session view a link asked for; null opens the charts.
  final SessionView? initialSessionView;

  /// The night a link asked History to open, or null for the list.
  final NightRef? night;

  /// The view of [night] a link asked for; null opens its summary.
  final NightView? nightView;

  /// The saved sequence a link asked History to list the runs of.
  final int? historySequenceId;

  const AnalyticsScreen({
    super.key,
    this.initialTab,
    this.initialScienceView,
    this.initialSessionView,
    this.night,
    this.nightView,
    this.historySequenceId,
  });

  @override
  ConsumerState<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends ConsumerState<AnalyticsScreen> {
  late int _currentSubTab;
  late SessionView _sessionView;

  @override
  void initState() {
    super.initState();
    _currentSubTab = (_requestedTab ?? AnalyticsTab.session).index;
    _sessionView = widget.initialSessionView ?? SessionView.charts;
  }

  /// `?view=` names a Science view only when no other tab is asked for: the
  /// Session tab and a night have views of their own.
  AnalyticsTab? get _requestedTab =>
      widget.initialTab == null && widget.initialScienceView != null
          ? AnalyticsTab.science
          : widget.initialTab;

  @override
  void didUpdateWidget(AnalyticsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // go_router keeps this State when only the query changes, so a link that
    // names another tab while Analytics is showing (the transient alerts
    // menu's "View all alerts") has to be applied here or it does nothing. A
    // link that names no tab keeps the one the operator is on.
    final requested = _requestedTab;
    if (requested != null &&
        (widget.initialTab != oldWidget.initialTab ||
            widget.initialScienceView != oldWidget.initialScienceView)) {
      setState(() => _currentSubTab = requested.index);
    }
    final sessionView = widget.initialSessionView;
    if (sessionView != null && sessionView != oldWidget.initialSessionView) {
      setState(() => _sessionView = sessionView);
    }
  }

  void _go(String location) => GoRouter.maybeOf(context)?.go(location);

  /// Leaves a night for the History list: back to where the night was opened
  /// from when that is still under this page, otherwise the list itself.
  void _closeNight() {
    final router = GoRouter.maybeOf(context);
    if (router != null && router.canPop()) {
      router.pop();
    } else {
      _go(AppRoutes.history(sequenceId: widget.historySequenceId));
    }
  }

  /// A tab picked by hand goes into the location. Left as the link that
  /// opened Analytics, the location still named that link's tab, so
  /// following the same link again changed nothing and the tab stayed where
  /// the operator had moved it.
  void _writeLocation(AnalyticsTab tab, [ScienceTab? scienceView]) {
    GoRouter.maybeOf(context)
        ?.go(AppRoutes.analytics(tab: tab, scienceView: scienceView));
  }

  /// The Analytics sub-tabs, in [AnalyticsTab] enum order. Each carries an icon
  /// so [AdaptiveTabBar] can collapse to icon-only on a compact phone instead
  /// of overflowing, and a [AdaptiveTab.buttonKey] for the tutorial spotlight.
  List<AdaptiveTab> _tabs(BuildContext context) {
    final l10n = context.l10n;
    return [
      AdaptiveTab(
        label: l10n.text('analyticsSession'),
        icon: LucideIcons.activity,
        buttonKey: TourTarget.analyticsSessionTab.key,
      ),
      AdaptiveTab(
        label: l10n.text('analyticsHistory'),
        icon: LucideIcons.history,
        buttonKey: TourTarget.analyticsHistoryTab.key,
      ),
      AdaptiveTab(
        label: l10n.text('analyticsScience'),
        icon: LucideIcons.flaskConical,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tabs = _tabs(context);

    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: [
            PageHeader(
              icon: LucideIcons.barChart3,
              title: l10n.text('navAnalytics'),
              tabs: AdaptiveTabBar(
                tabs: tabs,
                selectedIndex: _currentSubTab,
                onSelected: (index) {
                  setState(() => _currentSubTab = index);
                  _writeLocation(AnalyticsTab.values[index]);
                },
              ),
            ),

            // Content. Order must match the AnalyticsTab enum.
            Expanded(
              child: IndexedStack(
                index: _currentSubTab,
                children: [
                  _SessionTab(
                    view: _sessionView,
                    onViewPicked: (view) {
                      setState(() => _sessionView = view);
                      _go(AppRoutes.session(view: view));
                    },
                  ),
                  // The list stays alive under an open night, so coming back
                  // finds its filters and scroll position as they were.
                  IndexedStack(
                    index: widget.night == null ? 0 : 1,
                    children: [
                      HistoryTab(sequenceId: widget.historySequenceId),
                      if (widget.night case final night?)
                        NightPage(
                          night: night,
                          view: widget.nightView,
                          onViewPicked: (view) => _go(
                            AppRoutes.night(
                              night,
                              view: view,
                              sequenceId: widget.historySequenceId,
                            ),
                          ),
                          onBack: _closeNight,
                        )
                      else
                        const SizedBox.shrink(),
                    ],
                  ),
                  ScienceWorkspaceView(
                    initialView: widget.initialScienceView,
                    onViewPicked: (view) =>
                        _writeLocation(AnalyticsTab.science, view),
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
