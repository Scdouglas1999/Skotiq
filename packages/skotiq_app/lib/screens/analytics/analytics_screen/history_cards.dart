// ignore_for_file: unused_element_parameter

part of '../analytics_screen.dart';

class _ProjectsTab extends ConsumerWidget {
  const _ProjectsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isRemote = ref.watch(backendProvider) is NetworkBackend;
    return Padding(
      padding: const EdgeInsets.all(SkotiqTokens.space2xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Entry point into the multi-panel mosaic projects list (the durable
          // capture/integrate/stitch projects created from the Mosaic Wizard).
          // Always present, independent of the target-tracking data below, so
          // the list is reachable even before any single target is tracked.
          Align(
            alignment: Alignment.centerRight,
            child: SkotiqButton(
              key: const ValueKey('mosaic_projects_entry'),
              label: isRemote
                  ? 'Mosaic projects on imaging host'
                  : 'Mosaic projects',
              icon: LucideIcons.layoutGrid,
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () {
                if (isRemote) {
                  context.showInfoSnackBar(
                    'Open Mosaic Projects on the imaging host.',
                  );
                  return;
                }
                context.push('/mosaic');
              },
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          const Expanded(child: ProjectTrackingPanel()),
        ],
      ),
    );
  }
}

/// Session history card widget
class _SessionHistoryCard extends ConsumerWidget {
  final ImagingSession session;

  const _SessionHistoryCard({required this.session});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);

    // Both surfaces go through sessionElapsed(), which prints wall-clock time
    // only for the session that is genuinely running: a row with no end_time
    // would otherwise accrue `now - startTime` without bound.
    final sessionState = ref.watch(sessionStateProvider);
    final isLive =
        sessionState.isActive && sessionState.dbSessionId == session.id;
    final elapsed = sessionElapsed(
      session,
      isLive: isLive,
      lastFrameAt: ref.watch(lastFrameBySessionProvider)[session.id],
    );

    // Null while the frame catalogue has not been read; a session the map has
    // no entry for has no light frames at all.
    final grading = ref.watch(gradingBySessionProvider)?[session.id];

    final titleRow = Row(
      children: [
        Flexible(
          child: Text(
            session.name ?? context.l10n.text('analyticsUnnamedSession'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: SkotiqTypography.bodyStrong.copyWith(
              color: colors.textPrimary,
            ),
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        // One chip component, one chip geometry. The old badge was a solid
        // fill with 9 px text -- a size that 03 §2 says does not exist.
        SkotiqChip(
          label: session.status,
          tone: _statusTone(session.status),
        ),
      ],
    );

    final dateText = Text(
      DateFormat('MMM d, yyyy HH:mm').format(session.startTime),
      style: SkotiqTypography.bodySm.copyWith(
        color: colors.textSecondary,
      ),
    );

    // Stats reflow as a Wrap so a narrow phone column never overflows; on wide
    // layouts the chips sit on a single line beside the session info.
    // Every chip carries a caption. Four bare numbers behind icons ("4h 12m",
    // "206", "3.4h", "2.14") left the two durations indistinguishable and gave
    // no clue that the last figure was HFR in pixels.
    // Five measurements, so five Readouts (05 §3): a mono value over a quiet
    // uppercase label. They used to be boxed icon+number chips, which is the
    // chip component's job and not a measurement's.
    final statReadouts = <Widget>[
      Readout(
        size: ReadoutSize.sm,
        label: elapsed.captionLabel,
        value: elapsed.valueLabel,
      ),
      // "frames returned", not "frames": the number is
      // `successful_exposures`, which counts what the CAMERA handed back. A
      // night whose every sub was culled still counts them all here, so the row
      // read `COMPLETED · 6 frames · 0 integration` — a good night with an odd
      // integration figure rather than a night that kept nothing.
      Readout(
        size: ReadoutSize.sm,
        label: 'Frames returned',
        value: '${session.successfulExposures}',
      ),
      // The culling's own verdict, from `captured_images.is_accepted`, and only
      // when it threw something away: a night that kept everything is the
      // common case and does not need a readout saying so, but a night that
      // kept nothing must not look like one.
      if (grading != null && grading.rejected > 0)
        Readout(
          size: ReadoutSize.sm,
          label: 'Rejected',
          value: '${grading.rejected}',
          valueColor: colors.warning,
        ),
      Readout(
        size: ReadoutSize.sm,
        label: 'Integration',
        value: _formatIntegrationHours(session.totalIntegrationSecs),
      ),
      Readout(
        size: ReadoutSize.sm,
        label: 'HFR',
        unit: 'px',
        value: session.avgHfr?.toStringAsFixed(2),
      ),
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceMd),
      child: Semantics(
        button: true,
        enabled: true,
        child: SkotiqCard(
          // A tappable container IS a card (05 §1); what is forbidden is a
          // card standing in for a panel. The InkWell that used to sit inside
          // it made this one a panel wrapping a button.
          onTap: () => _showSessionDetail(context, ref, session),
          padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isPhone =
                  constraints.maxWidth < BreakpointTokens.breakpointPhone;

              if (isPhone) {
                return Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          titleRow,
                          const SizedBox(height: SkotiqTokens.spaceXs),
                          dateText,
                          const SizedBox(height: SkotiqTokens.spaceMd),
                          Wrap(
                            spacing: _historyReadoutGap,
                            runSpacing: SkotiqTokens.spaceMd,
                            children: statReadouts,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: SkotiqTokens.spaceSm),
                    Icon(LucideIcons.chevronRight,
                        size: SkotiqTokens.iconSm, color: colors.textMuted),
                  ],
                );
              }

              return Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        titleRow,
                        const SizedBox(height: SkotiqTokens.spaceXs),
                        dateText,
                      ],
                    ),
                  ),
                  Wrap(
                    spacing: _historyReadoutGap,
                    runSpacing: SkotiqTokens.spaceMd,
                    children: statReadouts,
                  ),
                  const SizedBox(width: SkotiqTokens.spaceMd),
                  Icon(LucideIcons.chevronRight,
                      size: SkotiqTokens.iconSm, color: colors.textMuted),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// A session's status as a chip tone. Status colours mean status (02);
  /// an unknown status has no tone at all rather than an invented one.
  static ChipTone _statusTone(String status) {
    switch (status.toLowerCase()) {
      case 'completed':
        return ChipTone.success;
      case 'active':
        return ChipTone.primary;
      case 'aborted':
        return ChipTone.warning;
      case 'error':
        return ChipTone.error;
      default:
        return ChipTone.neutral;
    }
  }

  /// Integration in hours, dropping to minutes and seconds below the point
  /// where "0.0h" stops carrying information.
  static String? _formatIntegrationHours(double seconds) {
    if (!seconds.isFinite || seconds <= 0) return null;
    if (seconds >= 3600) return '${(seconds / 3600).toStringAsFixed(1)}h';
    if (seconds >= 60) return '${(seconds / 60).round()}m';
    return '${seconds.round()}s';
  }

  void _showSessionDetail(
      BuildContext context, WidgetRef ref, ImagingSession session) {
    showDialog(
      context: context,
      builder: (context) => _SessionDetailDialog(session: session),
    );
  }
}

/// Gap between two of a history card's [Readout]s.
const double _historyReadoutGap = 20;

/// Session detail dialog with export functionality
