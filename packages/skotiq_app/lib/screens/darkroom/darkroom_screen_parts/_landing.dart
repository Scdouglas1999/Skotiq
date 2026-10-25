part of '../darkroom_screen.dart';

/// Below this window width the header chip's text is shortened.
const double _narrowHeader = 600;

/// The tab icons, in [DarkroomTab] order.
IconData _darkroomTabIcon(DarkroomTab tab) => switch (tab) {
      DarkroomTab.targets => SkotiqIcons.target,
      DarkroomTab.calibration => SkotiqIcons.sliders,
      DarkroomTab.edit => SkotiqIcons.edit,
      DarkroomTab.activity => SkotiqIcons.activity,
    };

/// The Darkroom's four tabs under the standard page header. The selected tab
/// lives in the location, so a link, a notification or Back reopens it.
class _DarkroomTabsView extends StatelessWidget {
  const _DarkroomTabsView({required this.route});

  final DarkroomRoute route;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Darkroom',
          icon: SkotiqIcons.aperture,
          tabs: AdaptiveTabBar(
            tabs: [
              for (final tab in DarkroomTab.values)
                AdaptiveTab(
                  label: tab.label,
                  icon: _darkroomTabIcon(tab),
                  buttonKey: ValueKey('darkroom_tab_${tab.name}'),
                ),
            ],
            selectedIndex: route.tab.index,
            onSelected: (index) {
              final tab = DarkroomTab.values[index];
              if (tab == route.tab && route.target == null) return;
              context.go(darkroomTabLocation(tab));
            },
          ),
          actions: [
            // A phone header keeps the title and the chip on one row.
            DarkroomStatusChip(
              maxValueWidth:
                  MediaQuery.sizeOf(context).width < _narrowHeader ? 120 : 320,
            ),
          ],
        ),
        Expanded(
          child: DarkroomRouteScope(
            route: route,
            child: switch (route.tab) {
              DarkroomTab.targets => const DarkroomTargetsTab(),
              DarkroomTab.calibration => const DarkroomCalibrationTab(),
              DarkroomTab.edit => const DarkroomEditTab(),
              DarkroomTab.activity => const DarkroomActivityTab(),
            },
          ),
        ),
      ],
    );
  }
}
