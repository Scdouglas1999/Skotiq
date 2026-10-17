import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../analytics/widgets/transient_report_panel.dart';

/// Submit-to-network dialog for one First Light transient candidate.
///
/// Wraps the existing [TransientReportPanel] (the canonical AAVSO / MPC / TNS
/// report generator) so the discovery surface and the science export hub share
/// one submission path — the report formats and observer-code handling live in
/// exactly one place. Scoped to the single tapped candidate.
class TransientSubmitDialog extends StatelessWidget {
  const TransientSubmitDialog({super.key, required this.detection});

  final TransientDetectionRow detection;

  /// Open the submit dialog for [detection].
  static Future<void> show(
    BuildContext context,
    TransientDetectionRow detection,
  ) {
    return showDialog<void>(
      context: context,
      builder: (_) => TransientSubmitDialog(detection: detection),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return SkotiqDialog(
      title: 'Submit discovery',
      icon: LucideIcons.upload,
      width: 480,
      actions: [
        SkotiqButton(
          label: 'Close',
          variant: ButtonVariant.ghost,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      child: TransientReportPanel(
        colors: colors,
        detections: [detection],
      ),
    );
  }
}
