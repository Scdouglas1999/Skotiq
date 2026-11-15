import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../utils/darkroom_navigation.dart';
import '../../../session_review/narrative_view.dart';
import '../../../session_review/session_review_controller.dart';
import '../../../session_review/widgets/build_in_darkroom_button.dart';
import '../../../session_review/workbench_view.dart';

/// What the review of a night can do from the night's header: build the
/// target's masters in the Darkroom, and read the night's subs and masters
/// again. Shown only on the imaging host, which holds them.
class NightReviewActions extends ConsumerWidget {
  const NightReviewActions({
    super.key,
    required this.sessionId,
    this.workbench = false,
  });

  final int sessionId;

  /// The Workbench rather than the Report is showing.
  final bool workbench;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(isRemoteClientProvider)) return const SizedBox.shrink();
    final scope = SessionReviewScope.session(sessionId);
    // A Report with no master yet offers the build where the master will be,
    // so the header does not offer it a second time.
    final reportOffersBuild = !workbench &&
        ref.watch(
          sessionReviewControllerProvider(scope).select(
            (state) =>
                !state.loading && state.reviewedMaster?.previewPngPath == null,
          ),
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!reportOffersBuild) ...[
          BuildInDarkroomButton(
            targetName: ref.watch(
              sessionReviewControllerProvider(scope)
                  .select((state) => state.targetName),
            ),
            buttonKey: const ValueKey('night_review_build'),
            compact: true,
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
        ],
        SkotiqIconButton(
          icon: SkotiqIcons.refresh,
          tooltip: "Read this night's subs and masters again",
          onPressed: () => ref
              .read(sessionReviewControllerProvider(scope).notifier)
              .refresh(),
        ),
      ],
    );
  }
}

/// The review of one night's subs and masters: the Report (the narrative of
/// what the night achieved) or the Workbench (culling, integration and the
/// master library). Both read the same review of the session.
///
/// Full-resolution subs and masters live on the imaging host, so a linked
/// client is told to open the night there.
class NightReviewView extends ConsumerStatefulWidget {
  const NightReviewView({
    super.key,
    required this.sessionId,
    required this.workbench,
  });

  final int sessionId;

  /// The Workbench rather than the Report.
  final bool workbench;

  @override
  ConsumerState<NightReviewView> createState() => _NightReviewViewState();
}

class _NightReviewViewState extends ConsumerState<NightReviewView> {
  /// The error whose banner was dismissed, so it stays dismissed until the
  /// review reports a different one.
  String? _dismissedError;

  @override
  Widget build(BuildContext context) {
    if (ref.watch(isRemoteClientProvider)) {
      return const EmptyState(
        icon: SkotiqIcons.device,
        title: 'Open this on the imaging host',
        body: 'Full-resolution subs, integrated masters and their previews '
            'are stored on the imaging computer. Open Skotiq there to '
            'review, cull or integrate this night.',
      );
    }
    final scope = SessionReviewScope.session(widget.sessionId);
    final state = ref.watch(sessionReviewControllerProvider(scope));
    final error = state.error;
    final progress = state.progress;

    return Column(
      children: [
        if (error != null && error != _dismissedError)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SkotiqTokens.spaceLg,
              SkotiqTokens.spaceLg,
              SkotiqTokens.spaceLg,
              0,
            ),
            child: SkotiqBanner(
              tone: BannerTone.error,
              title: 'The review could not be completed',
              message: error,
              onDismiss: () => setState(() => _dismissedError = error),
            ),
          ),
        if (progress != null)
          _ProgressStrip(
            phase: progress.phase,
            fraction: progress.fraction,
            passRunId: ref
                .read(darkroomPassRecorderProvider)
                .runningForSession(widget.sessionId),
          ),
        Expanded(
          child: state.loading
              ? const Center(
                  child:
                      SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36),
                )
              // The two views pad themselves by one step; the rest of the
              // page gutter is added here so they line up with the header.
              : Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: MediaQuery.sizeOf(context).width <
                            BreakpointTokens.breakpointPhone
                        ? 0
                        : SkotiqTokens.screenPadding.left - SkotiqTokens.spaceLg,
                  ),
                  child: widget.workbench
                      ? WorkbenchView(scope: scope)
                      : NarrativeView(scope: scope),
                ),
        ),
      ],
    );
  }
}

/// The live integration-progress strip: a phase label + a determinate
/// [SkotiqProgressBar], bound to `state.progress` (the
/// `seam.integrationProgress()` → controller binding). Shown only while a run
/// is reporting progress; absent otherwise.
class _ProgressStrip extends StatelessWidget {
  final String phase;
  final double fraction;

  /// The pass this run reports to, opened by Watch; null hides it.
  final String? passRunId;

  const _ProgressStrip({
    required this.phase,
    required this.fraction,
    this.passRunId,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceLg,
        vertical: SkotiqTokens.spaceMd,
      ),
      child: Row(
        children: [
          Expanded(
            child: SkotiqProgressBar(
              value: fraction.clamp(0.0, 1.0),
              style: SkotiqProgressStyle.standard,
              state: SkotiqProgressState.normal,
              label: _phaseLabel(phase),
              showPercentage: true,
            ),
          ),
          if (passRunId != null) ...[
            const SizedBox(width: SkotiqTokens.spaceMd),
            SkotiqButton(
              label: 'Watch in the Darkroom',
              icon: SkotiqIcons.aperture,
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: () => context.push(darkroomPassLocation(passRunId!)),
            ),
          ],
        ],
      ),
    );
  }

  /// Map a raw phase token (`registering`, `integrating`, …) to a friendly,
  /// capitalised label with an ellipsis.
  static String _phaseLabel(String phase) {
    if (phase.isEmpty) return 'Working…';
    final pretty = phase[0].toUpperCase() + phase.substring(1);
    return '$pretty…';
  }
}
