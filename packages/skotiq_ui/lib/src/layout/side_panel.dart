import 'package:flutter/material.dart';

import '../components/skotiq_icon_button.dart';
import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../tokens/shell_chrome_metrics.dart';

/// One section of a [SidePanel]'s icon strip.
@immutable
class SidePanelSection {
  const SidePanelSection({required this.icon, required this.tooltip});

  /// The strip glyph. Lucide only.
  final IconData icon;

  /// What the section is, in sentence case. Shown on hover and used as the
  /// strip button's accessible name.
  final String tooltip;
}

/// The right column: 320px by default, with an optional 44px vertical icon
/// strip on its OUTER edge.
///
/// With [sections] the strip carries one `SkotiqIconButton(size: strip)`
/// per section and the content area is `width − stripWidth`. Without them
/// (Sequencer properties 300, Guiding 300, Plan detail 380, Equipment 320)
/// there is no strip and the content takes the full width.
///
/// Content padding is 16, sections are 16 apart, and each starts with a
/// `SectionTitle`.
class SidePanel extends StatelessWidget {
  const SidePanel({
    super.key,
    required this.child,
    this.width = defaultWidth,
    this.sections,
    this.selectedSection = 0,
    this.onSectionSelected,
    this.collapsed = false,
  });

  /// The panel's content — normally a `Column` of sections.
  final Widget child;

  /// Total width INCLUDING the strip.
  final double width;

  /// When given, the strip is drawn and one button per entry appears on it.
  final List<SidePanelSection>? sections;

  /// Index of the selected strip section.
  final int selectedSection;

  /// Called with the tapped section's index.
  final ValueChanged<int>? onSectionSelected;

  /// Animates the panel closed. The width goes to zero over
  /// [SkotiqTokens.durationSmooth]; the caller keeps the toggle (the page
  /// header's `panel-right` button).
  final bool collapsed;

  /// The default side-panel width (03 §3.4 `sidePanelWidth`).
  static const double defaultWidth = ShellChromeMetrics.sidePanelWidth;

  /// The icon strip's width (03 §3.4 `sidePanelStripWidth`).
  static const double stripWidth = ShellChromeMetrics.sidePanelStripWidth;

  /// Padding inside the content area.
  static const EdgeInsets contentPadding = SkotiqTokens.paddingLg;

  /// Gap between sections.
  static const double sectionGap = SkotiqTokens.spaceLg;

  /// Vertical padding at the top and bottom of the strip.
  static const double stripPadding = SkotiqTokens.spaceSm;

  /// Gap between strip buttons.
  static const double stripGap = 2;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final hasStrip = sections != null && sections!.isNotEmpty;

    final content = Padding(
      padding: contentPadding,
      // The panel's own width is fixed, so the content is clipped rather than
      // allowed to push it wider mid-animation.
      child: child,
    );

    final body = Row(
      children: <Widget>[
        Expanded(child: content),
        if (hasStrip) ...<Widget>[
          Container(width: 1, color: colors.border),
          SizedBox(
            width: stripWidth - 1,
            child: Column(
              // The strip is as tall as its buttons, so a panel laid out in a
              // context with no height of its own does not throw.
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                const SizedBox(height: stripPadding),
                for (var i = 0; i < sections!.length; i++) ...<Widget>[
                  if (i > 0) const SizedBox(height: stripGap),
                  SkotiqIconButton(
                    icon: sections![i].icon,
                    tooltip: sections![i].tooltip,
                    size: IconButtonSize.strip,
                    selected: i == selectedSection,
                    onPressed: onSectionSelected == null
                        ? null
                        : () => onSectionSelected!(i),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );

    return AnimatedContainer(
      duration: SkotiqTokens.durationSmooth,
      curve: SkotiqTokens.curveStandard,
      width: collapsed ? 0 : width,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(left: BorderSide(color: colors.border)),
      ),
      // A collapsing panel is narrower than its content for the whole 220ms;
      // clipping is what keeps the content from painting over the page while
      // it closes.
      clipBehavior: Clip.hardEdge,
      child: OverflowBox(
        alignment: Alignment.centerLeft,
        minWidth: width,
        maxWidth: width,
        child: body,
      ),
    );
  }
}
