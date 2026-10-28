import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Prioritize batch setup; keep the preview alongside it on wide screens and
/// available in an adaptive panel on smaller screens.
class FlatWizardSplitView extends StatelessWidget {
  final Widget controlsPanel;
  final Widget previewPanel;
  final double controlsWidth;

  const FlatWizardSplitView({
    super.key,
    required this.controlsPanel,
    required this.previewPanel,
    this.controlsWidth = 0.62,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;

        // Keep setup visible without opening a sheet.
        if (width < 900) {
          return AdaptivePanelLayout(
            primary: Container(
              color: colors.background,
              child: controlsPanel,
            ),
            phoneStrategy: PhonePanelStrategy.bottomSheet,
            panelSide: PanelSide.start,
            primarySegmentLabel: 'Capture controls',
            primarySegmentIcon: LucideIcons.sliders,
            secondary: [
              AdaptivePanel(
                title: 'Preview',
                icon: LucideIcons.image,
                child: Container(
                  color: colors.surface,
                  child: previewPanel,
                ),
              ),
            ],
          );
        }

        // Tablet / desktop: fixed-fraction controls column on the left.
        final controlsPixelWidth =
            (constraints.maxWidth * controlsWidth).clamp(480.0, 900.0);

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Controls panel (left)
            SizedBox(
              width: controlsPixelWidth,
              child: Container(
                decoration: BoxDecoration(
                  color: colors.surface,
                  border: Border(
                    right: BorderSide(color: colors.border),
                  ),
                ),
                child: controlsPanel,
              ),
            ),

            // Preview panel (right)
            Expanded(
              child: Container(
                color: colors.background,
                child: previewPanel,
              ),
            ),
          ],
        );
      },
    );
  }
}
