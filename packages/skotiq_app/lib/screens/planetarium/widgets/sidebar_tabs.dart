import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/pill_tab.dart';

// Re-export all tab widgets and shared widgets so existing imports still work
export 'tonight_tab.dart';
export 'catalog_tab.dart' show CatalogTab;
export 'search_tab.dart';
export 'info_tab.dart';
export 'lists_tab.dart';
export 'sidebar_shared_widgets.dart';

/// The planetarium sidebar sub-tabs, rendered as filled icon-over-label pills
/// matching the imaging panel's sub-tabs.
///
/// This drives the ambient [DefaultTabController] (length 5) so taps, swipes on
/// the [TabBarView], and programmatic index changes all stay in sync. The pill
/// styling is shared with the imaging panel via [PillTab].
class SidebarTabs extends StatelessWidget {
  final SkotiqColors colors;

  const SidebarTabs({super.key, required this.colors});

  static const _tabs = [
    (SkotiqIcons.moon, 'Tonight'),
    (SkotiqIcons.book, 'Catalog'),
    (SkotiqIcons.list, 'Lists'),
    (SkotiqIcons.search, 'Search'),
    (SkotiqIcons.info, 'Info'),
  ];

  @override
  Widget build(BuildContext context) {
    final controller = DefaultTabController.of(context);
    // On phone (esp. the short cover-screen sheet) use the dense pill + tighter
    // padding/gaps so the 5-tab row claims far less of the scarce height.
    final dense = Responsive.isPhone(context);
    final gap = dense ? 4.0 : 6.0;

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      padding: EdgeInsets.all(dense ? 4 : 6),
      child: AnimatedBuilder(
        animation: controller.animation!,
        builder: (context, _) {
          final selected = controller.index;
          return Row(
            children: [
              for (var i = 0; i < _tabs.length; i++) ...[
                if (i > 0) SizedBox(width: gap),
                Expanded(
                  child: PillTab(
                    icon: _tabs[i].$1,
                    label: _tabs[i].$2,
                    isSelected: selected == i,
                    onTap: () => controller.animateTo(i),
                    colors: colors,
                    dense: dense,
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
