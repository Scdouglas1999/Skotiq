import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../localization/skotiq_localizations.dart';
import '../analytics/widgets/science_analytics_tab.dart';
import '../analytics/widgets/science_export_hub.dart';
import '../first_light/first_light_view.dart';
import '../transients/transients_screen.dart';

/// Identifies a Science sub-tab for deep-linking via `?tab=`/`?view=` query.
enum ScienceTab {
  workspace,
  firstLight,
  transients,
}

/// Maps the router `?tab=`/`?view=` query value to a [ScienceTab]. Returns null
/// for an unrecognised value so the caller can fall back. Public so router code
/// can share the same canonical mapping (notably `view=transients` from the
/// legacy `/transients` redirect).
ScienceTab? scienceTabFromQuery(String? value) {
  if (value == null) return null;
  switch (value.toLowerCase()) {
    case 'workspace':
      return ScienceTab.workspace;
    case 'firstlight':
    case 'first_light':
    case 'discovery':
      return ScienceTab.firstLight;
    case 'transients':
    case 'alerts':
      return ScienceTab.transients;
  }
  return null;
}

/// Scaffold-free science workspace body: the photometry / first-light /
/// observing-alerts tab host. Science ships folded into Analytics → Science,
/// which mounts this with `showHeader: false` — the `/science` path is a pure
/// deep-link redirect onto that tab and builds no page of its own.
class ScienceWorkspaceView extends ConsumerStatefulWidget {
  /// Selects the initial sub-tab (workspace / first light / observing alerts).
  final String? initialViewQuery;

  /// When true, the science title folds inline to the left of the sub-tab bar,
  /// for a host that does not name the surface itself. Analytics — the only
  /// host today — passes false because its own chrome already names it; either
  /// way the per-tab actions sit inline at the right end of the sub-tab row.
  final bool showHeader;

  const ScienceWorkspaceView({
    super.key,
    this.initialViewQuery,
    this.showHeader = true,
  });

  @override
  ConsumerState<ScienceWorkspaceView> createState() =>
      _ScienceWorkspaceViewState();
}

class _ScienceWorkspaceViewState extends ConsumerState<ScienceWorkspaceView> {
  late int _currentSubTab;

  @override
  void initState() {
    super.initState();
    final resolved =
        scienceTabFromQuery(widget.initialViewQuery) ?? ScienceTab.workspace;
    _currentSubTab = resolved.index;
  }

  @override
  void didUpdateWidget(ScienceWorkspaceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The host (Analytics / Science route) keys pages by path, not query, so a
    // new `?view=` while already mounted reuses this State without re-running
    // initState. Re-resolve so deep-links (notably the /transients alert link)
    // select the target sub-tab.
    if (widget.initialViewQuery != oldWidget.initialViewQuery) {
      final resolved = scienceTabFromQuery(widget.initialViewQuery);
      if (resolved != null && resolved.index != _currentSubTab) {
        setState(() => _currentSubTab = resolved.index);
      }
    }
  }

  List<AdaptiveTab> _tabs(BuildContext context) {
    final l10n = context.l10n;
    return [
      AdaptiveTab(
        label: l10n.text('analyticsScience'),
        icon: LucideIcons.flaskConical,
      ),
      const AdaptiveTab(
        label: 'First light',
        icon: LucideIcons.sparkles,
      ),
      const AdaptiveTab(
        label: 'Observing alerts',
        icon: LucideIcons.satellite,
      ),
    ];
  }

  /// The per-tab action affordances: alert refresh/settings (transients sub-tab
  /// only) plus the always-present science export hub. Shared by the standalone
  /// header trailing slot and the embedded inline toolbar.
  List<Widget> _actions(BuildContext context, SkotiqColors colors) {
    return [
      if (_currentSubTab == ScienceTab.transients.index) ...[
        IconButton(
          icon: Icon(
            SkotiqIcons.refresh,
            size: SkotiqTokens.iconMd,
            color: colors.textSecondary,
          ),
          onPressed: () => refreshTransientAlerts(ref),
          tooltip: 'Refresh alerts',
          constraints: const BoxConstraints(
            minWidth: SkotiqTokens.minTouchTarget,
            minHeight: SkotiqTokens.minTouchTarget,
          ),
        ),
        IconButton(
          icon: Icon(
            SkotiqIcons.settings,
            size: SkotiqTokens.iconMd,
            color: colors.textSecondary,
          ),
          onPressed: () => showTransientSettingsDialog(context, ref),
          tooltip: 'Alert settings',
          constraints: const BoxConstraints(
            minWidth: SkotiqTokens.minTouchTarget,
            minHeight: SkotiqTokens.minTouchTarget,
          ),
        ),
      ],
      Tooltip(
        message: 'Export science data',
        child: IconButton(
          icon: Icon(
            LucideIcons.database,
            size: SkotiqTokens.iconMd,
            color: colors.textSecondary,
          ),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => const ScienceExportHub(),
          ),
          padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
          constraints: const BoxConstraints(
            minWidth: SkotiqTokens.minTouchTarget,
            minHeight: SkotiqTokens.minTouchTarget,
          ),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;

    final tabBar = AdaptiveTabBar(
      tabs: _tabs(context),
      selectedIndex: _currentSubTab,
      onSelected: (index) => setState(() => _currentSubTab = index),
    );

    final isPhone = Responsive.isPhone(context);

    return Column(
      children: [
        // Title + sub-tabs + per-tab actions share ONE row. On the standalone
        // `/science` route the screen owns its title, so it folds inline to the
        // left of the tab strip (icon-only on a phone) instead of sitting in a
        // separate ~56px ScreenHeader above the tabs. When embedded in Analytics
        // the outer chrome already names the screen, so the title is omitted and
        // only the per-tab actions ride at the right end of the row.
        Container(
          decoration: BoxDecoration(
            color: colors.surfaceAlt,
            border: Border(bottom: BorderSide(color: colors.border)),
          ),
          child: Row(
            children: [
              if (widget.showHeader)
                Padding(
                  padding: EdgeInsets.only(
                    left: SkotiqTokens.spaceLg,
                    right: isPhone
                        ? SkotiqTokens.spaceSm
                        : SkotiqTokens.spaceMd,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        LucideIcons.flaskConical,
                        size: 18,
                        color: colors.primary,
                      ),
                      if (!isPhone) ...[
                        const SizedBox(width: SkotiqTokens.spaceSm),
                        Text(
                          l10n.text('analyticsScience'),
                          style: SkotiqTypography.h5.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              Expanded(child: tabBar),
              ..._actions(context, colors),
              const SizedBox(width: SkotiqTokens.spaceSm),
            ],
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _currentSubTab,
            children: const [
              ScienceAnalyticsTab(),
              FirstLightView(showHeader: false),
              TransientsView(showHeader: false),
            ],
          ),
        ),
      ],
    );
  }
}
