import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../utils/darkroom_navigation.dart';
import 'narrative_view.dart';
import 'session_review_controller.dart';
import 'workbench_view.dart';
import 'widgets/build_in_darkroom_button.dart';

/// Session Review / Morning Report.
///
/// The cohesive "review the night" surface, rendered as two views of one
/// [SessionReviewController] model: a top-to-bottom *narrative* report (the
/// default) and a dense *workbench* console, switched by a single header
/// toggle. A live [SkotiqProgressBar] (phase + fraction) appears whenever a
/// long-running integration is in flight.
///
/// Reached from the run/session/analytics context via the `/session-review`
/// route with a `?session=<id>` or `?target=<id>` query.
class SessionReviewScreen extends ConsumerStatefulWidget {
  final SessionReviewScope scope;

  const SessionReviewScreen({super.key, required this.scope});

  @override
  ConsumerState<SessionReviewScreen> createState() =>
      _SessionReviewScreenState();
}

class _SessionReviewScreenState extends ConsumerState<SessionReviewScreen> {
  String? _lastShownError;
  String? _lastShownShortfall;

  SessionReviewController get _controller =>
      ref.read(sessionReviewControllerProvider(widget.scope).notifier);

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    if (ref.watch(isRemoteClientProvider)) {
      // Session Review owns persisted masters, night reports, culling state,
      // and previews whose paths are local to the imaging host. Instantiating
      // its DAO-backed controller on a remote client would write a second,
      // client-local history after running compute on the host. Keep the
      // boundary explicit until the whole aggregate (including artifact
      // streaming) has a host-authoritative API.
      //
      // The client ROLE, not the connection. `backend is NetworkBackend` is a
      // CONNECTION fact, and a desktop launched with `--remote-host` that has
      // not reached its rig is `Disconnected` — so that test read false for the
      // whole pre-handshake window and this whole screen opened over the
      // client's own database. Every rig-executing control it carries went with
      // it, writing rows into a database no job on the rig will ever read.
      //
      // Gating the surface rather than each button is what closes the class:
      // the pass, its Stop, the integration and A/B runs, the finishing steps,
      // the master library's accumulate/finalize/delete, and the Darkroom entry
      // points are all inside this arm, so a control added later cannot arrive
      // ungated.
      return Scaffold(
        backgroundColor: colors.background,
        body: const SafeArea(
          bottom: false,
          child: Column(
            children: [
              PageHeader(
                title: 'Session review',
                context: 'Host-only processing',
                icon: SkotiqIcons.image,
              ),
              Expanded(
                child: EmptyState(
                  icon: SkotiqIcons.device,
                  title: 'Open Session Review on the imaging host',
                  body: 'Full-resolution subs, integrated masters, and their '
                      'previews are stored on the imaging computer. Open '
                      'Skotiq there to review, cull, integrate, or finish '
                      'this session. Remote Session Review is unavailable in '
                      'this release.',
                ),
              ),
            ],
          ),
        ),
      );
    }
    final state = ref.watch(sessionReviewControllerProvider(widget.scope));

    // Surface controller errors as a toast, once each *occurrence*. Resetting
    // on the cleared state matters: actions clear the error before they run, so
    // retrying an action that keeps failing the same way toasts every time
    // instead of going quiet after the first attempt and leaving the control
    // looking dead.
    if (state.error == null) {
      _lastShownError = null;
    } else if (state.error != _lastShownError) {
      _lastShownError = state.error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        SkotiqToastHelper.show(
          context: context,
          message: state.error!,
          severity: SkotiqAlertSeverity.error,
        );
      });
    }

    // An integration that dropped subs is not an error — it returns a master —
    // but it must never be silent. Same once-each dedupe as the error toast.
    final shortfall =
        SessionReviewController.integrationShortfall(state.lastOutcome);
    if (shortfall != null && shortfall != _lastShownShortfall) {
      _lastShownShortfall = shortfall;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        SkotiqToastHelper.show(
          context: context,
          message: shortfall,
          severity: SkotiqAlertSeverity.warning,
        );
      });
    }

    final isNarrative = state.viewMode == SessionReviewViewMode.narrative;
    final progress = state.progress;

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            PageHeader(
              title: 'Session review',
              // The night, as the header's one qualifying fact. It used to BE
              // the title, which left the screen unable to say which screen it
              // was, and the accepted / rejected counts sat under it as a
              // subtitle — a measurement in prose. They are Readouts on the
              // cull rail now, beside the subs they count.
              context: state.title,
              icon: SkotiqIcons.image,
              // The narrative / workbench switch was a second header row of
              // pill chips under the first. One tab style, in the page header
              // (05 §4).
              tabs: AdaptiveTabBar(
                tabs: const [
                  AdaptiveTab(
                    label: 'Narrative',
                    icon: SkotiqIcons.image,
                    buttonKey: ValueKey('session_review_tab_narrative'),
                  ),
                  AdaptiveTab(
                    label: 'Workbench',
                    icon: SkotiqIcons.sliders,
                    buttonKey: ValueKey('session_review_tab_workbench'),
                  ),
                ],
                selectedIndex: isNarrative ? 0 : 1,
                onSelected: (index) => _controller.setViewMode(
                  index == 0
                      ? SessionReviewViewMode.narrative
                      : SessionReviewViewMode.workbench,
                ),
              ),
              actions: [
                // Masters are built in one place: the Darkroom's guided
                // build for this night's target, from all of its nights.
                BuildInDarkroomButton(
                  targetName: state.targetName,
                  buttonKey: const ValueKey('session_review_header_build'),
                  compact: true,
                ),
                SkotiqIconButton(
                  icon: SkotiqIcons.refresh,
                  tooltip: 'Re-read this night\'s subs and masters',
                  onPressed: () => _controller.refresh(),
                ),
              ],
            ),
            // Live integration progress (phase + fraction). Only present while a
            // long-running run is reporting progress.
            if (progress != null)
              _ProgressStrip(
                phase: progress.phase,
                fraction: progress.fraction,
                passRunId: widget.scope.sessionId == null
                    ? null
                    : ref
                        .read(darkroomPassRecorderProvider)
                        .runningForSession(widget.scope.sessionId!),
              ),
            Expanded(
              child: state.loading
                  ? const Center(
                      child: SkotiqMark(
                          motion: SkotiqMarkMotion.loading, size: 36))
                  : isNarrative
                      ? NarrativeView(scope: widget.scope)
                      : WorkbenchView(scope: widget.scope),
            ),
          ],
        ),
      ),
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
