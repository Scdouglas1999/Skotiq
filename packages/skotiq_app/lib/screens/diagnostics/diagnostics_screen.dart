import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../localization/skotiq_localizations.dart';
import '../analytics/quick_capture_selection.dart';
import '../analytics/widgets/analytics_empty_state.dart';
import 'diagnostics_screen/psf_field_map_view.dart';
part 'diagnostics_screen/content_layout.dart';
part 'diagnostics_screen/health_summary_cards.dart';
part 'diagnostics_screen/optical_alignment_cards.dart';
part 'diagnostics_screen/psf_field_map.dart';
part 'diagnostics_screen/residual_vector.dart';
part 'diagnostics_screen/issues_and_skeleton.dart';

/// The optical diagnostics of one session: tilt, curvature, the PSF field map
/// and the astrometric residuals of its frames. Shown as the Optics view of
/// Analytics > Session, which owns the session picker.
class OpticsDiagnosticsView extends ConsumerWidget {
  const OpticsDiagnosticsView({
    super.key,
    required this.sessionId,
    this.onOpenLatest,
  });

  /// The session to analyze, [kQuickCaptureSessionSelection] for the frames
  /// that belong to none, or null when nothing is selected.
  final int? sessionId;

  /// Selects the most recent session; offered when nothing is selected and a
  /// session is on record.
  final VoidCallback? onOpenLatest;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    var selected = sessionId;
    // Quick captures have diagnostics only when the science pipeline measured
    // some of them.
    if (selected == kQuickCaptureSessionSelection &&
        (ref.watch(sessionlessPsfTilesProvider).valueOrNull?.isEmpty ?? true) &&
        (ref.watch(sessionlessResidualVectorsProvider).valueOrNull?.isEmpty ??
            true)) {
      selected = null;
    }
    if (selected == null) {
      return LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: AnalyticsEmptyState(
              icon: LucideIcons.stethoscope,
              title: l10n.text('diagnosticsNoSessionTitle'),
              body: l10n.text('diagnosticsNoSessionBody'),
              actionLabel: onOpenLatest == null
                  ? 'Go to Imaging'
                  : 'Open the latest session',
              onAction: onOpenLatest,
            ),
          ),
        ),
      );
    }
    return _DiagnosticsContent(
      sessionId: selected,
      isMobile: Responsive.isMobile(context),
    );
  }
}
