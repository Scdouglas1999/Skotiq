import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../stacking_panel.dart';
import 'live_stack_darkroom_panel.dart';
import 'live_stack_frame_log_panel.dart';
import 'live_stack_tuning_panel.dart';

/// Persists which Live Stack side-panel section is active across tab switches.
final selectedLiveStackPanelProvider = StateProvider<int>((ref) => 0);

/// The Live Stack tab's Observatory right column — matching [ImagingSidePanel]'s
/// 320 px panel with a 44 px icon strip.
///
/// Four focused sections eliminate the endless scrolling wall of sliders while
/// putting Live Darkroom, the transparent Frame Log, and Presets / Quality Gates
/// one click away.
class LiveStackSidePanel extends ConsumerWidget {
  const LiveStackSidePanel({
    super.key,
    required this.colors,
    this.collapsed = false,
  });

  final SkotiqColors colors;
  final bool collapsed;

  static const int sessionSectionIndex = 0;
  static const int darkroomSectionIndex = 1;
  static const int frameLogSectionIndex = 2;
  static const int tuningSectionIndex = 3;

  static const List<SidePanelSection> sections = <SidePanelSection>[
    SidePanelSection(
      icon: SkotiqIcons.layers,
      tooltip: 'Session & filters',
    ),
    SidePanelSection(
      icon: SkotiqIcons.aperture,
      tooltip: 'Live Darkroom',
    ),
    SidePanelSection(
      icon: SkotiqIcons.history,
      tooltip: 'Frame log',
    ),
    SidePanelSection(
      icon: SkotiqIcons.settings,
      tooltip: 'Presets & quality gates',
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedLiveStackPanelProvider);
    return SidePanel(
      sections: sections,
      selectedSection: selected,
      onSectionSelected: (index) =>
          ref.read(selectedLiveStackPanelProvider.notifier).state = index,
      collapsed: collapsed,
      child: IndexedStack(
        index: selected,
        children: <Widget>[
          StackingPanel(colors: colors, showPreview: false),
          LiveStackDarkroomPanel(colors: colors),
          LiveStackFrameLogPanel(colors: colors),
          LiveStackTuningPanel(colors: colors),
        ],
      ),
    );
  }
}

/// Narrow-layout host for the Live Stack tab: compact underline tabs over the
/// four sections so phone / narrow windows get Live Darkroom, Frame Log, and
/// Tuning too.
class LiveStackNarrowWorkspace extends ConsumerWidget {
  const LiveStackNarrowWorkspace({super.key, required this.colors});

  final SkotiqColors colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedLiveStackPanelProvider);
    final frameEvents = ref.watch(
      liveStackingProvider.select((s) => s.frameLog.length),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AdaptiveTabBar(
          tabs: <AdaptiveTab>[
            const AdaptiveTab(label: 'Session', icon: SkotiqIcons.layers),
            const AdaptiveTab(label: 'Darkroom', icon: SkotiqIcons.aperture),
            AdaptiveTab(
              label: 'Log',
              icon: SkotiqIcons.history,
              count: frameEvents > 0 ? '$frameEvents' : null,
            ),
            const AdaptiveTab(label: 'Tuning', icon: SkotiqIcons.settings),
          ],
          selectedIndex: selected,
          onSelected: (index) =>
              ref.read(selectedLiveStackPanelProvider.notifier).state = index,
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
            child: switch (selected) {
              0 => StackingPanel(colors: colors, showPreview: true),
              1 => LiveStackDarkroomPanel(colors: colors),
              2 => LiveStackFrameLogPanel(colors: colors),
              _ => LiveStackTuningPanel(colors: colors),
            },
          ),
        ),
      ],
    );
  }
}
