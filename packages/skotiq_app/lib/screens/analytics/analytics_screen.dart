// ignore_for_file: unused_element_parameter

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
import 'package:skotiq_core/skotiq_core.dart';

// Exports hand off through revealExportedFile (share sheet on mobile, path
// snackbar on desktop) rather than calling share_plus directly — shareXFiles is
// unimplemented on Linux/Windows and threw an internal API name at the user.
import '../../utils/darkroom_navigation.dart';
import '../../utils/exported_file_reveal.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as path;
import '../../localization/skotiq_localizations.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/tutorial_keys/analytics_keys.dart';
import '../accessible_dropdown.dart';
import '../diagnostics/diagnostics_screen.dart';
import '../science/science_screen.dart';
import '../sequencer/widgets/session_report_dialog.dart';
import 'quick_capture_selection.dart';
import 'session_elapsed.dart';
import 'widgets/analytics_empty_state.dart';
import 'widgets/science_analytics_tab.dart' show latestScienceSessionProvider;
import 'widgets/session_chart.dart';
import 'widgets/image_thumbnail_strip.dart';
import 'widgets/project_tracking_panel.dart';
part 'analytics_screen/session_tab.dart';
part 'analytics_screen/history_tab.dart';
part 'analytics_screen/history_cards.dart';
part 'analytics_screen/session_detail_dialog.dart';
part 'analytics_screen/equipment_stats.dart';
part 'analytics_screen/skeletons.dart';

/// Identifies an Analytics sub-tab for deep-linking via `?tab=` query param.
/// Order here matches the rendered tab order — Diagnostics is right-most.
enum AnalyticsTab {
  session,
  history,
  projects,
  equipment,
  science,
  diagnostics,
}

/// Maps the router `?tab=` query value to an [AnalyticsTab]. Returns null
/// for an unrecognised value so the caller can decide on a fallback. Public
/// so router code (and tests) can share the same canonical mapping.
AnalyticsTab? analyticsTabFromQuery(String? value) {
  if (value == null) return null;
  switch (value.toLowerCase()) {
    case 'session':
      return AnalyticsTab.session;
    case 'history':
      return AnalyticsTab.history;
    case 'projects':
      return AnalyticsTab.projects;
    case 'equipment':
    case 'equipment-stats':
    case 'equipmentstats':
      return AnalyticsTab.equipment;
    case 'science':
      return AnalyticsTab.science;
    case 'diagnostics':
      return AnalyticsTab.diagnostics;
  }
  return null;
}

class AnalyticsScreen extends ConsumerStatefulWidget {
  /// Optional initial tab selection. When null, falls back to
  /// [initialTabQuery] parsing, then to [AnalyticsTab.session].
  final AnalyticsTab? initialTab;

  /// Raw `?tab=` value parsed from the router. Lets deep-links select a
  /// specific Analytics tab (notably `?tab=diagnostics` from the legacy
  /// `/diagnostics` redirect).
  final String? initialTabQuery;

  /// Raw `?view=` value parsed from the router. Selects the inner science
  /// sub-view (workspace / first light / observing alerts) and, when present,
  /// forces the Science tab open — fed by the `/science` and `/transients`
  /// redirects.
  final String? initialScienceView;

  const AnalyticsScreen({
    super.key,
    this.initialTab,
    this.initialTabQuery,
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
    // A `?view=` deep-link (from /science or /transients) always lands on the
    // Science tab; otherwise honour `initialTab` / `?tab=`, then fall back to
    // Session.
    final resolved = widget.initialScienceView != null
        ? AnalyticsTab.science
        : widget.initialTab ??
            analyticsTabFromQuery(widget.initialTabQuery) ??
            AnalyticsTab.session;
    _currentSubTab = resolved.index;
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
        buttonKey: AnalyticsTutorialKeys.sessionTab,
      ),
      AdaptiveTab(
        label: l10n.text('analyticsHistory'),
        icon: LucideIcons.history,
        buttonKey: AnalyticsTutorialKeys.historyTab,
      ),
      AdaptiveTab(
        label: l10n.text('analyticsProjects'),
        icon: LucideIcons.folderKanban,
      ),
      AdaptiveTab(
        label: l10n.text('analyticsEquipmentTab'),
        icon: LucideIcons.wrench,
        buttonKey: AnalyticsTutorialKeys.equipmentTab,
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
                onSelected: (index) => setState(() => _currentSubTab = index),
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
                    initialViewQuery: widget.initialScienceView,
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
