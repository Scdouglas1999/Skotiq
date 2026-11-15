import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../router/analytics_route.dart';
import '../analytics/widgets/science_analytics_tab.dart';
import '../analytics/widgets/science_export_hub.dart';
import '../first_light/first_light_view.dart';
import '../transients/transients_screen.dart';

/// Analytics > Science: the measurements, first light and observing alerts
/// views, chosen with a switch at the top of the tab. `/science` only
/// redirects here.
class ScienceWorkspaceView extends ConsumerStatefulWidget {
  /// The view a link asked for; null opens the measurements.
  final ScienceTab? initialView;

  /// The operator picked a view by hand, so the host can put it in the
  /// location.
  final ValueChanged<ScienceTab>? onViewPicked;

  const ScienceWorkspaceView({
    super.key,
    this.initialView,
    this.onViewPicked,
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
    _currentSubTab = (widget.initialView ?? ScienceTab.workspace).index;
  }

  @override
  void didUpdateWidget(ScienceWorkspaceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The host (Analytics / Science route) keys pages by path, not query, so a
    // new `?view=` while already mounted reuses this State without re-running
    // initState. Re-resolve so deep-links (notably the /transients alert link)
    // select the target sub-tab.
    if (widget.initialView != oldWidget.initialView) {
      final resolved = widget.initialView;
      if (resolved != null && resolved.index != _currentSubTab) {
        setState(() => _currentSubTab = resolved.index);
      }
    }
  }

  /// About what the three view names take on one line.
  static const double _switchWidth = 300;

  /// The view names, in [ScienceTab] order.
  static const List<String> _views = [
    'Measurements',
    'First light',
    'Observing alerts',
  ];

  /// The view's actions: refresh and settings on the observing alerts, and
  /// the science export on every view.
  List<Widget> _actions(BuildContext context) {
    return [
      if (_currentSubTab == ScienceTab.transients.index) ...[
        SkotiqIconButton(
          icon: SkotiqIcons.refresh,
          tooltip: 'Refresh alerts',
          onPressed: () => refreshTransientAlerts(ref),
        ),
        SkotiqIconButton(
          icon: SkotiqIcons.settings,
          tooltip: 'Alert settings',
          onPressed: () => showTransientSettingsDialog(context, ref),
        ),
      ],
      SkotiqIconButton(
        icon: LucideIcons.database,
        tooltip: 'Export science data',
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => const ScienceExportHub(),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final isPhone = Responsive.isPhone(context);

    // A switch inside the page, not a second row of header tabs: the header
    // above already carries Analytics' own tabs.
    final views = SegmentedControl(
      segments: _views,
      selectedIndex: _currentSubTab,
      semanticLabel: 'Science view',
      onSelected: (index) {
        setState(() => _currentSubTab = index);
        widget.onViewPicked?.call(ScienceTab.values[index]);
      },
    );

    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            isPhone ? SkotiqTokens.spaceLg : SkotiqTokens.space2xl,
            isPhone ? SkotiqTokens.spaceMd : SkotiqTokens.spaceLg,
            isPhone ? SkotiqTokens.spaceSm : SkotiqTokens.spaceLg,
            0,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final actions = _actions(context);
              final oneLine = constraints.maxWidth >=
                  _switchWidth + actions.length * SkotiqTokens.minTouchTarget;
              final switchRow = Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: views,
                    ),
                  ),
                  if (oneLine) ...actions,
                ],
              );
              if (oneLine) return switchRow;
              // Too narrow for the switch and the actions on one line: the
              // actions go under it, at the end, so no view name is cut.
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  switchRow,
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: actions,
                  ),
                ],
              );
            },
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _currentSubTab,
            children: const [
              ScienceAnalyticsTab(),
              FirstLightView(),
              TransientsView(),
            ],
          ),
        ),
      ],
    );
  }
}
