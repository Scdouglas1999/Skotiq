import 'package:flutter/material.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';
import '../tokens/shell_chrome_metrics.dart';
import '../utils/touch_target.dart';

/// The 56 px row every routed screen starts with (04-shell §4).
///
/// ```
/// | 24 | [icon 18] [Title 20/600] [context 14]   [tab] [tab]   …   [actions] | 24 |
/// ```
///
/// There is deliberately no `subtitle`. A sentence under a page title is the
/// app explaining itself on every visit to an operator who has read it once;
/// the help button in the top bar is where an explanation belongs. Replaces
/// [ScreenHeader], which is deprecated.
class PageHeader extends StatelessWidget {
  /// The screen's name. One noun phrase, sentence case, no punctuation.
  final String title;

  /// 18 px, `textSecondary`, to the left of the title.
  final IconData? icon;

  /// One short muted fact that qualifies the title — the target being framed,
  /// the profile in use. NOT a description of the screen.
  final String? context;

  /// The underline tab strip. The ONLY tab style allowed in a page header;
  /// pass an `AdaptiveTabBar`.
  final Widget? tabs;

  /// Right-aligned, 8 px apart. At most one `primary` button, and only when it
  /// is the screen's main action.
  final List<Widget> actions;

  /// Replaces the whole header body below the hairline — used by the narrow
  /// Tonight and Imaging headers for their 28 px status strip.
  final Widget? bottom;

  const PageHeader({
    super.key,
    required this.title,
    this.icon,
    this.context,
    this.tabs,
    this.actions = const [],
    this.bottom,
  });

  /// Gap between the title block and the tab strip.
  static const double _titleToTabsGap = 28.0;

  /// Cap on the title block (icon + title + context) before it ellipsizes.
  static const double _titleMaxWidth = 420.0;

  @override
  Widget build(BuildContext buildContext) {
    final colors = SkotiqColors.of(buildContext);
    // Below the breakpoint the header is 48 and the tabs move to their own
    // scrollable row, because a title, a tab strip and an action will not
    // share 700 px without one of them being cut.
    final narrow =
        MediaQuery.sizeOf(buildContext).width <
        ShellChromeMetrics.shellLayoutBreakpoint;

    // The hairline is chrome, not content: a 48 px header with a 1 px bottom
    // border leaves its row 47, one pixel short of the Android touch minimum,
    // so a `SkotiqIconButton` action in a narrow header measured 48 x 47
    // and failed the tap-target guideline. Add the hairline back on a touch
    // platform. Desktop is unchanged.
    final double hairline = SkotiqTouchTarget.isTouch(buildContext)
        ? _hairlineWidth
        : 0;
    final header = Container(
      height:
          (narrow
              ? ShellChromeMetrics.pageHeaderHeightNarrow
              : ShellChromeMetrics.pageHeaderHeight) +
          hairline,
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.space2xl,
      ),
      decoration: BoxDecoration(
        color: colors.background,
        border: Border(
          bottom: BorderSide(color: colors.border, width: _hairlineWidth),
        ),
      ),
      // The tab strip gets ALL the width the title and the actions do not use.
      //
      // It used to be a `Flexible` followed by a `Spacer`, which made the title
      // block, the strip and the spacer three flex children of equal weight: on
      // a 1600px window the strip was handed ~330px of the ~1180px going spare,
      // so Plan's six tabs became "Tonight · Projects · Schedule · Framir…"
      // with a scroll arrow — the opposite of every screen mockup, which shows
      // the whole strip. The title is inflexible now (it sizes to its words and
      // ellipsises inside its own Text), the strip is `Expanded`, and the
      // actions keep their natural width at the right edge.
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            if (tabs != null && !narrow) ...[
              _titleBlock(colors, maxWidth: _titleCap(constraints.maxWidth)),
              const SizedBox(width: _titleToTabsGap),
              Expanded(child: tabs!),
            ] else
              // No strip: the title owns whatever the actions leave, sits at
              // the left edge of that space, and shrinks (ellipsizes) before a
              // single action is pushed off a 360 px phone header.
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(
                    right: SkotiqTokens.spaceMd,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _titleBlock(
                      colors,
                      maxWidth: _titleCap(constraints.maxWidth),
                    ),
                  ),
                ),
              ),
            for (var i = 0; i < actions.length; i++) ...[
              if (i > 0) const SizedBox(width: SkotiqTokens.spaceSm),
              actions[i],
            ],
          ],
        ),
      ),
    );

    if ((tabs == null || !narrow) && bottom == null) return header;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        if (tabs != null && narrow)
          Container(
            decoration: BoxDecoration(
              color: colors.background,
              border: Border(
                bottom: BorderSide(color: colors.border, width: 1),
              ),
            ),
            child: tabs,
          ),
        if (bottom != null) bottom!,
      ],
    );
  }

  /// The title block.
  ///
  /// The title may take up to half the header, capped at [_titleMaxWidth];
  /// beyond that it ellipsizes. Relative, so a 390 px phone header still fits.
  static double _titleCap(double rowWidth) {
    final half = rowWidth.isFinite ? rowWidth * 0.5 : _titleMaxWidth;
    return half < _titleMaxWidth ? half : _titleMaxWidth;
  }

  Widget _titleBlock(SkotiqColors colors, {required double maxWidth}) {
    // Intrinsic width up to a cap. A Flexible title split the free space with
    // the trailing Spacer and, being a loose fit, left its unused half AFTER
    // the actions — which then sat mid-row on every tab-less screen.
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: _iconSize, color: colors.textSecondary),
            const SizedBox(width: SkotiqTokens.spaceSm + 2),
          ],
          Flexible(
            child: Text(
              title,
              style: SkotiqTypography.pageTitle.copyWith(
                color: colors.textPrimary,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          if (context != null) ...[
            const SizedBox(width: SkotiqTokens.spaceMd),
            Flexible(
              child: Text(
                context!,
                style: SkotiqTypography.body.copyWith(
                  color: colors.textMuted,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// The header's bottom hairline, in logical pixels.
  static const double _hairlineWidth = 1.0;

  static const double _iconSize = SkotiqTokens.iconRail;
}
