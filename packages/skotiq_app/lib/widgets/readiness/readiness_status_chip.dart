import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'readiness_panel.dart';

/// Compact, tappable readiness indicator built on [StatusPill].
///
/// Shows `LucideIcons.listChecks`, the report's [ReadinessReport.summaryLabel]
/// as its label, and a count of outstanding items (e.g. `2 to fix`) as its
/// value. The pill status is mapped from the overall [ReadinessLevel] so the
/// traffic-light treatment (and its red-night collapse) comes straight from
/// the design system — no hardcoded colors. Tapping opens [ReadinessPanel] in
/// a [SkotiqDialog].
class ReadinessStatusChip extends ConsumerWidget {
  const ReadinessStatusChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref.watch(readinessReportProvider);

    return StatusPill(
      icon: LucideIcons.listChecks,
      label: report.summaryLabel,
      value: _value(report),
      status: readinessLevelPillStatus(report.overall),
      onTap: () => showReadinessDialog(context),
    );
  }

  /// The pill's trailing value: how much work is outstanding.
  ///
  /// Blocked items are the headline count when present (they gate first
  /// light); otherwise caution items are surfaced; when neither remains the
  /// rig is ready.
  String _value(ReadinessReport report) {
    final blocked = report.blockedItems.length;
    final caution = report.cautionItems.length;
    if (blocked > 0) return '$blocked to fix';
    if (caution > 0) return '$caution to review';
    return 'All set';
  }
}
