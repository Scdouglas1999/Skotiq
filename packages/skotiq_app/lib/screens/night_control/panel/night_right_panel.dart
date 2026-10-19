// Tonight's right panel: the six tabs over their bodies.
//
// The bodies sit in an IndexedStack, so a half-typed field survives a tab
// switch. Mount, Guide and Solve come in through the constructor; their
// package (P7) never imports this one and this one never imports it.
//
// Only the operator switches tabs: pressing a tab, or an action-bar button
// that selects its own tab. Something that happens on its own (an autofocus
// a sequence step started, a lost guide star) puts a dot on the tab instead.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart' hide EquipmentStatus;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../data/session/equipment_summary_provider.dart';
import '../night_control_contracts.dart';
import '../night_control_layout.dart';
import 'camera/camera_tab.dart';
import 'focus/focus_tab.dart';
import 'overview/overview_tab.dart';

/// An autofocus is running, whoever started it: the Focus tab's dot.
final nightFocusActiveProvider = Provider<bool>((ref) {
  return ref.watch(autofocusOverlayProvider.select((s) => s.isRunning));
});

/// The guider needs a look: the star is lost or the guider faulted. The
/// Guide tab's dot.
final nightGuideAlertProvider = Provider<bool>((ref) {
  if (ref.watch(phd2StateProvider) == Phd2State.lostLock) return true;
  for (final row in ref.watch(nightEquipmentProvider)) {
    if (row.kind == EquipmentKind.guider) {
      return row.status == EquipmentStatus.fault;
    }
  }
  return false;
});

class NightRightPanel extends ConsumerWidget {
  const NightRightPanel({
    super.key,
    required this.mountTab,
    required this.guideTab,
    required this.solveTab,
  });

  final Widget mountTab;
  final Widget guideTab;
  final Widget solveTab;

  static String _tabKey(NightPanelTab tab) => switch (tab) {
        NightPanelTab.overview => 'nightPanelTabOverview',
        NightPanelTab.camera => 'nightPanelTabCamera',
        NightPanelTab.focus => 'nightPanelTabFocus',
        NightPanelTab.mount => 'nightPanelTabMount',
        NightPanelTab.guide => 'nightPanelTabGuide',
        NightPanelTab.solve => 'nightPanelTabSolve',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = SkotiqLocalizations.of(context);
    final colors = context.skotiqColors;
    final selected = ref.watch(nightPanelTabProvider);
    final focusActive = ref.watch(nightFocusActiveProvider);
    final guideAlert = ref.watch(nightGuideAlertProvider);

    PanelTabItem item(NightPanelTab tab) {
      final label = l10n.text(_tabKey(tab));
      if (tab == NightPanelTab.focus && focusActive) {
        return PanelTabItem(
          label,
          badge: PanelTabBadge.active,
          semanticLabel: l10n.text(
            'nightPanelTabFocusActive',
            params: <String, String>{'tab': label},
          ),
        );
      }
      if (tab == NightPanelTab.guide && guideAlert) {
        return PanelTabItem(
          label,
          badge: PanelTabBadge.alert,
          semanticLabel: l10n.text(
            'nightPanelTabGuideAlert',
            params: <String, String>{'tab': label},
          ),
        );
      }
      return PanelTabItem(label);
    }

    final bodies = <Widget>[
      const NightOverviewTab(),
      const NightCameraTab(),
      const NightFocusTab(),
      mountTab,
      guideTab,
      solveTab,
    ];
    final scrolls =
        NightControlDensity.maybeOf(context)?.slotsScrollThemselves ?? true;

    final strip = DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: PanelTabStrip(
        tabs: <PanelTabItem>[
          for (final tab in NightPanelTab.values) item(tab),
        ],
        selectedIndex: selected.index,
        onSelected: (index) => ref.read(nightPanelTabProvider.notifier).state =
            NightPanelTab.values[index],
        semanticLabel: l10n.text('nightPanelTabs'),
      ),
    );

    if (scrolls) {
      return ColoredBox(
        color: colors.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            strip,
            Expanded(
              child: IndexedStack(
                index: selected.index,
                sizing: StackFit.expand,
                children: <Widget>[
                  for (var i = 0; i < bodies.length; i++)
                    _TabBody(active: i == selected.index, child: bodies[i]),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // The single column scrolls the page, so the panel sizes to the
    // selected body. Offstage bodies keep their state and take no room,
    // where an IndexedStack would be as tall as the tallest tab.
    return ColoredBox(
      color: colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          strip,
          for (var i = 0; i < bodies.length; i++)
            Offstage(
              offstage: i != selected.index,
              child: _TabBody(active: i == selected.index, child: bodies[i]),
            ),
        ],
      ),
    );
  }
}

/// A hidden body neither animates nor reaches assistive technology.
class _TabBody extends StatelessWidget {
  const _TabBody({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TickerMode(
      enabled: active,
      child: ExcludeSemantics(excluding: !active, child: child),
    );
  }
}
