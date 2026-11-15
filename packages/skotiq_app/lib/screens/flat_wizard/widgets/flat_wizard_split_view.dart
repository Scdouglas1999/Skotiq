import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The Flat wizard's page body: a settings column beside the preview on a wide
/// window, and the settings alone with the preview in a sheet on a narrow one.
///
/// Both panes sit inside the page gutter; neither pads itself.
class FlatWizardSplitView extends StatelessWidget {
  const FlatWizardSplitView({
    super.key,
    required this.controlsPanel,
    required this.previewPanel,
  });

  /// The settings column's content. It is scrolled here.
  final Widget controlsPanel;

  final Widget previewPanel;

  /// Width of the settings column beside the preview.
  static const double controlsWidth = 520;

  /// Widest the settings run when they are the whole page.
  static const double controlsMaxWidth = 880;

  /// Below this the preview moves into a sheet.
  static const double sideBySideMinWidth = 900;

  static const double _panelGap = SkotiqTokens.spaceLg;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final gutter = width < SkotiqTokens.breakpointTablet
            ? SkotiqTokens.screenPaddingCompact
            : SkotiqTokens.screenPadding;

        if (width < sideBySideMinWidth) {
          return AdaptivePanelLayout(
            primary: ColoredBox(
              color: colors.background,
              child: SingleChildScrollView(
                padding: gutter,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints:
                        const BoxConstraints(maxWidth: controlsMaxWidth),
                    child: controlsPanel,
                  ),
                ),
              ),
            ),
            phoneStrategy: PhonePanelStrategy.bottomSheet,
            // The preview keeps its desktop side when it is a column.
            panelSide: PanelSide.end,
            primarySegmentLabel: 'Capture controls',
            primarySegmentIcon: LucideIcons.sliders,
            secondary: [
              AdaptivePanel(
                title: 'Preview',
                icon: LucideIcons.image,
                // A phone sheet scrolls its content and pads it itself; a
                // side column does neither.
                child: LayoutBuilder(
                  builder: (context, panel) => panel.maxHeight.isFinite
                      ? ColoredBox(
                          color: colors.background,
                          child: Padding(padding: gutter, child: previewPanel),
                        )
                      : previewPanel,
                ),
              ),
            ],
          );
        }

        return ColoredBox(
          color: colors.background,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: gutter.left + controlsWidth,
                child: SingleChildScrollView(
                  padding: gutter.copyWith(right: 0),
                  child: controlsPanel,
                ),
              ),
              const SizedBox(width: _panelGap),
              Expanded(
                child: Padding(
                  padding: gutter.copyWith(left: 0),
                  child: previewPanel,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
