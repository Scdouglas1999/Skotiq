
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Used by part files (history_cards.dart, session_detail_dialog.dart) for
// context.go / context.push — part files share the library's imports.
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/utils.dart';

// Exports hand off through revealExportedFile (share sheet on mobile, path
// snackbar on desktop) rather than calling share_plus directly — shareXFiles is
// unimplemented on Linux/Windows and threw an internal API name at the user.
import '../../utils/darkroom_navigation.dart';
import '../../utils/exported_file_reveal.dart';
import 'package:path/path.dart' as path;
import '../../localization/skotiq_localizations.dart';
import '../../utils/snackbar_helper.dart';
import '../../tours/tour_target.dart';
import '../accessible_dropdown.dart';
import '../diagnostics/diagnostics_screen.dart';
import '../science/science_screen.dart';
import '../sequencer/run_status_presentation.dart';
import '../sequencer/widgets/session_report_dialog.dart';
import 'analytics_route.dart';
import 'quick_capture_selection.dart';
import 'session_elapsed.dart';
import 'widgets/analytics_empty_state.dart';
import 'widgets/science_analytics_tab.dart' show latestScienceSessionProvider;
import 'widgets/session_chart.dart';
import 'widgets/image_thumbnail_strip.dart';
import 'widgets/project_tracking_panel.dart';
import '../../router/app_routes.dart';
export 'analytics_route.dart' show AnalyticsTab, ScienceTab;

part 'analytics_screen/session_tab.dart';
part 'analytics_screen/history_tab.dart';
part 'analytics_screen/history_cards.dart';
part 'analytics_screen/session_detail_dialog.dart';
part 'analytics_screen/equipment_stats.dart';
part 'analytics_screen/skeletons.dart';

class AnalyticsScreen extends ConsumerStatefulWidget {
  /// The tab a link asked for; null opens Session.
  final AnalyticsTab? initialTab;

  /// The Science view a link asked for. When set, the Science tab opens on it
  /// whatever [initialTab] says.
  final ScienceTab? initialScienceView;

  const AnalyticsScreen({
    super.key,
    this.initialTab,
    this.initialScienceView,
  });

  @override
  ConsumerState<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends ConsumerState<AnalyticsScreen> {
  late int _currentSubTab;

  @override
  void initState() {
    super.initState();
    _currentSubTab = (_requestedTab ?? AnalyticsTab.session).index;
  }

  AnalyticsTab? get _requestedTab => widget.initialScienceView != null
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
        label: l10n.text('analyticsProjects'),
        icon: LucideIcons.folderKanban,
      ),
      AdaptiveTab(
        label: l10n.text('analyticsEquipmentTab'),
        icon: LucideIcons.wrench,
        buttonKey: TourTarget.analyticsEquipmentTab.key,
      ),
      AdaptiveTab(
        label: l10n.text('analyticsScience'),
        icon: LucideIcons.flaskConical,
      ),
      AdaptiveTab(
        label: l10n.text('analyticsDiagnostics'),
        icon: LucideIcons.stethoscope,
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
            // The one 56 px page header every screen starts with (04 §4): the
            // bar-chart glyph, the screen name, and the six sub-tabs as the
            // ONLY tab style in the app. The old row hand-built a title block
            // and a divider beside the strip; PageHeader owns both now.
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
                  const _SessionTab(),
                  const _HistoryTab(),
                  const _ProjectsTab(),
                  const _EquipmentStatsTab(),
                  ScienceWorkspaceView(
                    initialView: widget.initialScienceView,
                    onViewPicked: (view) =>
                        _writeLocation(AnalyticsTab.science, view),
                    showHeader: false,
                  ),
                  const DiagnosticsTabContent(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
