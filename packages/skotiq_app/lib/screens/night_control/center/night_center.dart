// The center slot of the Tonight screen: the frame stage, the manual-action
// bar, the frame strip and the chart row, top to bottom.
//
// In the column layouts the frame takes whatever height is left and never
// drops below [NightControlLayout.minFrameHeight]; when the window is too
// short for that, the chart row folds into a toggle first. In the single
// column the frame is sized by its aspect (240 to 360 px) and the page
// scrolls.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../night_control_layout.dart';
import 'frame_stage.dart';
import 'frame_strip.dart';
import 'manual_action_bar.dart';
import 'session_charts_row.dart';

class NightCenter extends ConsumerStatefulWidget {
  const NightCenter({super.key});

  /// The single column's frame height range.
  static const double minSingleColumnFrame = 240;
  static const double maxSingleColumnFrame = 360;

  /// The bar that replaces a folded chart row.
  static const double chartToggleHeight = 28;

  @override
  ConsumerState<NightCenter> createState() => _NightCenterState();
}

class _NightCenterState extends ConsumerState<NightCenter> {
  /// The operator opened the folded chart row anyway.
  bool _chartsOpened = false;

  @override
  Widget build(BuildContext context) {
    final density = NightControlDensity.maybeOf(context);
    if (density != null && !density.slotsScrollThemselves) {
      return _singleColumn(context);
    }
    final chartHeight =
        density?.chartRowHeight ?? NightControlLayout.chartRowHeight;
    return LayoutBuilder(
      builder: (context, constraints) {
        const fixed = ManualActionBar.height + FrameStrip.height;
        final fits = !constraints.hasBoundedHeight ||
            constraints.maxHeight - fixed - chartHeight >=
                NightControlLayout.minFrameHeight;
        final showCharts = fits || _chartsOpened;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Expanded(child: FrameStage()),
            const ManualActionBar(),
            const FrameStrip(),
            if (!fits)
              _ChartsToggle(
                open: _chartsOpened,
                onPressed: () => setState(() => _chartsOpened = !_chartsOpened),
              ),
            if (showCharts) const SessionChartsRow(),
          ],
        );
      },
    );
  }

  Widget _singleColumn(BuildContext context) {
    final image = ref.watch(nightStageImageProvider);
    return LayoutBuilder(
      builder: (context, constraints) {
        final aspect = image == null || image.height <= 0
            ? 3 / 2
            : image.width / image.height;
        final frameHeight = (constraints.maxWidth / aspect).clamp(
          NightCenter.minSingleColumnFrame,
          NightCenter.maxSingleColumnFrame,
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(height: frameHeight, child: const FrameStage()),
            const ManualActionBar(),
            const FrameStrip(),
            const SessionChartsRow(),
          ],
        );
      },
    );
  }
}

class _ChartsToggle extends StatelessWidget {
  const _ChartsToggle({required this.open, required this.onPressed});

  final bool open;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final label =
        context.l10n.text(open ? 'nightCtrHideCharts' : 'nightCtrShowCharts');
    return Container(
      height: NightCenter.chartToggleHeight,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      alignment: Alignment.centerLeft,
      child: Semantics(
        button: true,
        expanded: open,
        label: label,
        excludeSemantics: true,
        onTap: onPressed,
        child: InkWell(
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SkotiqTokens.spaceMd,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  open ? LucideIcons.chevronDown : LucideIcons.chevronUp,
                  size: 14,
                  color: colors.textMuted,
                ),
                const SizedBox(width: SkotiqTokens.spaceXs),
                Text(
                  label,
                  style: SkotiqTypography.captionSm.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
