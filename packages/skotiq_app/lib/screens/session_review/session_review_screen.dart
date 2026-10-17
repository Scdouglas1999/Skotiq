import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'auto_integration_service.dart';
import 'narrative_view.dart';
import 'session_review_controller.dart';
import 'workbench_view.dart';

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

  /// True while a Darkroom pass this screen started is running. Fast-path
  /// polish only: it makes the button latch on the press rather than on the
  /// next poll. What actually decides whether a pass may start is the durable
  /// `darkroom_jobs` row — [_darkroomLive] here, and the refusal
  /// `DawnAutopilotService` raises beneath it, which is what a screen that was
  /// popped and re-pushed still obeys.
  bool _darkroomRunning = false;

  /// True while `darkroom_jobs` holds a queued or running row for this session,
  /// whoever started it. Polled, because a pass can be started by the dawn
  /// autopilot or by another surface while this screen is open.
  bool _darkroomLive = false;

  /// True once the operator has asked the running pass to stop. The stop is
  /// cooperative — the engine's flag is polled between tiles and the pipeline
  /// checks it between masters — so the control says "Stopping…" and stays
  /// disabled rather than pretending the pass is already over.
  bool _stopRequested = false;

  /// Polls the durable job state for this session.
  Timer? _darkroomPoll;

  /// How often the durable pass state is re-read. A pass runs for minutes, so
  /// this is about the control being right within a couple of seconds of the
  /// operator looking at it, not about tracking progress.
  static const Duration _darkroomPollInterval = Duration(seconds: 2);

  SessionReviewController get _controller =>
      ref.read(sessionReviewControllerProvider(widget.scope).notifier);

  @override
  void initState() {
    super.initState();
    final sessionId = widget.scope.sessionId;
    if (sessionId == null) return;
    unawaited(_refreshDarkroomLive(sessionId));
    _darkroomPoll = Timer.periodic(
      _darkroomPollInterval,
      (_) => unawaited(_refreshDarkroomLive(sessionId)),
    );
  }

  @override
  void dispose() {
    _darkroomPoll?.cancel();
    super.dispose();
  }

  /// Re-read whether a pass is live over this session.
  ///
  /// A read that fails leaves the last known answer standing and says so in the
  /// log: the enqueue seam refuses a second pass on its own, so a stale button
  /// costs a refusal toast rather than a second pass.
  Future<void> _refreshDarkroomLive(int sessionId) async {
    final bool live;
    try {
      live = await ref
          .read(autoIntegrationServiceProvider)
          .isDarkroomPassLiveForSession(sessionId);
    } catch (error) {
      ref.read(loggingServiceProvider).warning(
        'The live Darkroom pass state could not be read; the header keeps its '
        'last answer',
        source: 'SessionReviewScreen',
        fields: {'sessionId': sessionId, 'error': '$error'},
      );
      return;
    }
    if (!mounted || live == _darkroomLive) return;
    setState(() {
      _darkroomLive = live;
      // A pass that has ended clears the stop latch, so the control offers
      // "Process now" again rather than staying stuck on "Stopping…".
      if (!live) _stopRequested = false;
    });
  }

  /// Run the Darkroom pass for this session on request.
  ///
  /// Only offered for a session scope: the pass reads a session's frames to
  /// find the masters they were folded into, and a target scope spans nights
  /// that were each processed on their own.
  Future<void> _processTonightNow(int sessionId) async {
    if (_darkroomRunning) return;
    setState(() {
      _darkroomRunning = true;
      _stopRequested = false;
    });
    final ManualDarkroomRun run;
    try {
      run = await ref
          .read(autoIntegrationServiceProvider)
          .runDarkroomNow(sessionId);
    } finally {
      if (mounted) {
        setState(() {
          _darkroomRunning = false;
          _stopRequested = false;
        });
      }
    }
    if (!mounted) return;
    if (run.alreadyRunning) {
      // The press landed on a session another pass already holds. Nothing was
      // started, so nothing was re-read; the header catches up on its next poll
      // and offers Stop instead.
      unawaited(_refreshDarkroomLive(sessionId));
      SkotiqToastHelper.show(
        context: context,
        message: run.message,
        severity: SkotiqAlertSeverity.info,
      );
      return;
    }
    // The masters are re-read because a finished pass has written recipes the
    // library panel's Darkroom buttons now open.
    await _controller.refresh();
    if (!mounted) return;
    SkotiqToastHelper.show(
      context: context,
      message: run.autoDraftEnabled
          ? run.message
          : '${run.message} Automatic drafts are switched off, so this one was '
              'made because you asked.',
      severity: run.succeeded
          ? SkotiqAlertSeverity.success
          : SkotiqAlertSeverity.warning,
    );
  }

  /// Ask the running Darkroom pass to stop.
  ///
  /// The pass is minutes of native rendering per master, and without this the
  /// only way out of one started by mistake — over the wrong night, with the
  /// wrong masters, or while the operator wants the machine for something else
  /// — is to wait it out or kill the app. The stop is cooperative: the engine's
  /// cancellation flag is raised for this job's render id and the autopilot's
  /// own flag stops the pipeline before the next master, so a render already
  /// inside Rust ends at its next poll rather than instantly. The toast says
  /// exactly that; the pass's own outcome toast reports how it actually ended.
  Future<void> _stopTonightsPass(int sessionId) async {
    if (_stopRequested) return;
    setState(() => _stopRequested = true);
    final List<int> jobIds;
    try {
      jobIds = await ref
          .read(autoIntegrationServiceProvider)
          .cancelDarkroomPassForSession(
            sessionId,
            reason: 'Stopped from Session Review',
          );
    } catch (error) {
      if (!mounted) return;
      setState(() => _stopRequested = false);
      SkotiqToastHelper.show(
        context: context,
        message: 'The Darkroom pass could not be stopped: $error',
        severity: SkotiqAlertSeverity.error,
      );
      return;
    }
    if (!mounted) return;
    if (jobIds.isEmpty) {
      // Nothing was asked to stop, so the control goes back to offering it.
      setState(() => _stopRequested = false);
      SkotiqToastHelper.show(
        context: context,
        message: 'There is no Darkroom pass to stop for this session — it has '
            'either finished already or has not reached its job yet.',
        severity: SkotiqAlertSeverity.info,
      );
      return;
    }
    SkotiqToastHelper.show(
      context: context,
      message: jobIds.length == 1
          ? 'Stopping the Darkroom pass. A master already being rendered '
              'finishes that render first; nothing after it is started.'
          : 'Stopping all ${jobIds.length} Darkroom passes over this session. '
              'A master already being rendered finishes that render first; '
              'nothing after it is started.',
      severity: SkotiqAlertSeverity.warning,
    );
  }

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
      // it: "Process now" ran a full Darkroom pass AND its delivery on a client,
      // writing a `darkroom_jobs` row and nine `delivery_journal` rows into a
      // database no dawn job on the rig will ever read.
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
    final sessionId = widget.scope.sessionId;
    // The durable row is the authority; the local latch only closes the gap
    // between the press and the first poll that sees the row it created.
    final passIsLive = _darkroomLive || _darkroomRunning;

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
                // The manual half of the dawn autopilot. Reaching it here is
                // deliberate: this is the screen an operator is already on
                // when they decide tonight is worth drafting now rather than
                // at dawn. The whole screen is host-only — the role arm above
                // returns before this — so the pass only ever runs on the
                // machine that owns the masters it reads.
                Tooltip(
                  message: sessionId == null
                      ? 'This review spans a target rather than one night. '
                          'Open a single session to process it.'
                      : passIsLive
                          ? 'A Darkroom pass over this night is already '
                              'under way. Stop it before starting another.'
                          : 'Draft tonight\'s masters in the Darkroom now, '
                              'without waiting for dawn',
                  child: SkotiqButton(
                    key: const ValueKey('session_review_process_now'),
                    label: 'Process now',
                    icon: SkotiqIcons.sliders,
                    variant: ButtonVariant.secondary,
                    size: ButtonSize.small,
                    isLoading: _darkroomRunning,
                    // Disabled on the DURABLE answer, so a screen that was
                    // popped and re-pushed over a session already being
                    // processed does not offer to process it again.
                    onPressed: (sessionId == null || passIsLive)
                        ? null
                        : () => _processTonightNow(sessionId),
                  ),
                ),
                // The way out of a pass that is already under way. Present
                // only while one is: a Stop that is always on the header
                // would be a control with nothing to stop.
                if (passIsLive && sessionId != null)
                  Tooltip(
                    message: 'Stop the Darkroom pass. The master being '
                        'rendered finishes; nothing after it starts.',
                    child: SkotiqButton(
                      key: const ValueKey('session_review_stop_pass'),
                      label: _stopRequested ? 'Stopping…' : 'Stop',
                      icon: SkotiqIcons.stop,
                      variant: ButtonVariant.destructive,
                      size: ButtonSize.small,
                      onPressed: _stopRequested
                          ? null
                          : () => _stopTonightsPass(sessionId),
                    ),
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
                  phase: progress.phase, fraction: progress.fraction),
            Expanded(
              child: state.loading
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2))
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

  const _ProgressStrip({required this.phase, required this.fraction});

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
      child: SkotiqProgressBar(
        value: fraction.clamp(0.0, 1.0),
        style: SkotiqProgressStyle.standard,
        state: SkotiqProgressState.normal,
        label: _phaseLabel(phase),
        showPercentage: true,
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
