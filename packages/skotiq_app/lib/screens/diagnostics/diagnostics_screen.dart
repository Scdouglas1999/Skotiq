import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../localization/skotiq_localizations.dart';
import '../accessible_dropdown.dart';
import '../analytics/quick_capture_selection.dart';
import '../analytics/widgets/analytics_empty_state.dart';
import 'diagnostics_screen/psf_field_map_view.dart';
part 'diagnostics_screen/header_widgets.dart';
part 'diagnostics_screen/content_layout.dart';
part 'diagnostics_screen/health_summary_cards.dart';
part 'diagnostics_screen/optical_alignment_cards.dart';
part 'diagnostics_screen/psf_field_map.dart';
part 'diagnostics_screen/residual_vector.dart';
part 'diagnostics_screen/issues_and_skeleton.dart';

/// Session id standing for "the frames that belong to no session".
///
/// Local alias for the shared [kQuickCaptureSessionSelection] sentinel, which
/// gives the session-less bucket a pickable identity; the content switches to
/// the `sessionless*` providers when it is chosen.
const int _kQuickCaptureSessionId = kQuickCaptureSessionSelection;

/// Thin shell that hosts [DiagnosticsTabContent].
///
/// Diagnostics lives inside Analytics as a tab, and the `/diagnostics` route
/// redirects to `/analytics?tab=diagnostics`, so this screen is unreachable
/// through the router. It is kept so any direct embedding (tests, debug entry
/// points) keeps working until the redirect is removed.
class DiagnosticsScreen extends StatelessWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Standalone route: nothing else on screen names the page, so this one
    // surface keeps the title the Analytics tab drops.
    return const DiagnosticsTabContent(showTitle: true);
  }
}

/// Optical-train diagnostics surface, embedded inside the Analytics screen.
class DiagnosticsTabContent extends ConsumerStatefulWidget {
  /// Whether to paint the page title. False inside Analytics: the tab strip
  /// two rows above already says "Diagnostics", and none of the four sibling
  /// tabs prints an H1 of its own.
  final bool showTitle;

  const DiagnosticsTabContent({super.key, this.showTitle = false});

  @override
  ConsumerState<DiagnosticsTabContent> createState() =>
      _DiagnosticsTabContentState();
}

class _DiagnosticsTabContentState extends ConsumerState<DiagnosticsTabContent> {
  int? _selectedSessionId;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final isMobile = Responsive.isMobile(context);
    final sessionsAsync = ref.watch(allSessionsProvider);
    final l10n = context.l10n;

    // Auto-select current session if none selected
    final sessionState = ref.watch(sessionStateProvider);
    if (_selectedSessionId == null && sessionState.dbSessionId != null) {
      _selectedSessionId = sessionState.dbSessionId;
    }

    // Quick captures own no session row, so they are offered as their own
    // bucket — but only when the science pipeline actually produced something
    // to analyze for them.
    final hasQuickCaptureDiagnostics =
        (ref.watch(sessionlessPsfTilesProvider).valueOrNull?.isNotEmpty ??
                false) ||
            (ref
                    .watch(sessionlessResidualVectorsProvider)
                    .valueOrNull
                    ?.isNotEmpty ??
                false);
    // A bucket that just went empty (frames cleared) must not stay selected.
    if (_selectedSessionId == _kQuickCaptureSessionId &&
        !hasQuickCaptureDiagnostics) {
      _selectedSessionId = null;
    }

    // Phone tier reflows the header: the session selector drops to its own
    // line under the title so the wide dropdown can't push the title into a
    // RenderFlex overflow on a narrow phone.
    final isPhone = Responsive.isPhone(context);

    final titleRow = Row(
      children: [
        Icon(LucideIcons.microscope, size: 22, color: colors.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            l10n.text('diagnosticsTitle'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: isMobile
                  ? SkotiqTypography.fontSize18
                  : SkotiqTypography.fontSize22,
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
            ),
          ),
        ),
      ],
    );

    final sessionSelector = sessionsAsync.when(
      data: (sessions) => _SessionSelector(
        sessions: sessions,
        selectedSessionId: _selectedSessionId,
        offerQuickCaptures: hasQuickCaptureDiagnostics,
        onChanged: (id) => setState(() => _selectedSessionId = id),
        colors: colors,
      ),
      // Small skeleton chip rather than a spinner so the header doesn't
      // visibly jitter when sessions resolve.
      loading: () => const ShimmerLoading(
        child: SkeletonBox(width: 200, height: 28),
      ),
      error: (e, _) => Text(
        l10n.text('diagnosticsLoadSessionsFailed'),
        style: TextStyle(
            color: colors.error, fontSize: SkotiqTypography.fontSize12),
      ),
    );

    return Padding(
      padding: EdgeInsets.all(isMobile ? 12 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          if (isPhone) ...[
            if (widget.showTitle) ...[
              titleRow,
              const SizedBox(height: 10),
            ],
            // Constrain so a long session name ellipsizes instead of forcing
            // the dropdown wider than the phone column.
            Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.sizeOf(context).width - 24,
                ),
                child: sessionSelector,
              ),
            ),
          ] else
            Row(
              children: [
                if (widget.showTitle)
                  Expanded(child: titleRow)
                else
                  const Spacer(),
                const SizedBox(width: 12),
                // Bounded width so the (isExpanded) dropdown has finite
                // constraints and ellipsizes a long session label.
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 280),
                  child: sessionSelector,
                ),
              ],
            ),
          // No explainer paragraph and no "Learn more" link: 07 "What NOT to
          // do" forbids both, and the tab's EmptyState already says what
          // diagnostics needs. Screen-level help belongs to the top-bar help
          // popover.
          const SizedBox(height: SkotiqTokens.spaceLg),

          // Main content
          Expanded(
            child: _selectedSessionId == null
                // Scroll-wrap so the centered empty state never overflows when
                // a phone is short (landscape).
                ? LayoutBuilder(
                    builder: (context, constraints) => SingleChildScrollView(
                      child: ConstrainedBox(
                        constraints:
                            BoxConstraints(minHeight: constraints.maxHeight),
                        // The shared EmptyState, same as this tab's four
                        // siblings, so one reader learns one pattern rather
                        // than a per-tab dialect.
                        child: AnalyticsEmptyState(
                          icon: LucideIcons.stethoscope,
                          title: l10n.text('diagnosticsNoSessionTitle'),
                          body: l10n.text('diagnosticsNoSessionBody'),
                        ),
                      ),
                    ),
                  )
                : _DiagnosticsContent(
                    sessionId: _selectedSessionId!,
                    isMobile: isMobile,
                  ),
          ),
        ],
      ),
    );
  }
}

// Sits under the intro paragraph as a low-key affordance. Inline `InkWell`
// over a small icon + label keeps the chip visually quieter than
// `SkotiqButton.ghost`, which is sized for primary actions.
