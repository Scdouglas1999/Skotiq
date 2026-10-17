import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Split view layout for flat wizard.
///
/// On tablet/desktop the controls sit in a fixed-fraction column on the left
/// with the preview filling the rest. On a phone the preview is the dominant
/// region and the capture/tuning controls collapse into a bottom sheet (or a
/// side-by-side split in landscape) via [AdaptivePanelLayout], so the narrow
/// controls column never squishes the sliders/inputs into overflow.
class FlatWizardSplitView extends StatelessWidget {
  final Widget controlsPanel;
  final Widget previewPanel;
  final double controlsWidth;

  const FlatWizardSplitView({
    super.key,
    required this.controlsPanel,
    required this.previewPanel,
    this.controlsWidth = 0.4, // 40% for controls
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;

        // Phone tier: preview dominant, controls in a sheet / landscape split.
        if (width < 600) {
          return AdaptivePanelLayout(
            primary: Container(
              color: colors.background,
              child: previewPanel,
            ),
            phoneStrategy: PhonePanelStrategy.bottomSheet,
            panelSide: PanelSide.start,
            primarySegmentLabel: 'Preview',
            primarySegmentIcon: LucideIcons.image,
            secondary: [
              AdaptivePanel(
                title: 'Capture controls',
                icon: LucideIcons.sliders,
                child: Container(
                  color: colors.surface,
                  child: controlsPanel,
                ),
              ),
            ],
          );
        }

        // Tablet / desktop: fixed-fraction controls column on the left.
        final controlsPixelWidth =
            (constraints.maxWidth * controlsWidth).clamp(280.0, 460.0);

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
