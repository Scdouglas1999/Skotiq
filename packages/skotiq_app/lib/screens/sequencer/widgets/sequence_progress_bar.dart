import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../services/run_control/run_timing.dart';

class SequenceProgressBar extends ConsumerStatefulWidget {
  final SkotiqColors colors;

  const SequenceProgressBar({super.key, required this.colors});

  @override
  ConsumerState<SequenceProgressBar> createState() =>
      SequenceProgressBarState();
}

/// Static alpha value used to tint the progress bar background when the
/// sequence is paused. Picked so it sits inside the running pulse range
/// (0.05–0.08) but stays constant, so users get a calm, non-animating
/// warning-tinted background instead of a strobing primary-tinted one.
const double _kPausedBackgroundAlpha = 0.06;

class SequenceProgressBarState extends ConsumerState<SequenceProgressBar>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;

  /// Monotonic elapsed time for the stall detector below.
  ///
  /// A `Ticker` rather than `DateTime.now()` so the measurement is the same
  /// clock the frames are painted on — and so a widget test can advance it.
  Ticker? _elapsedTicker;
  Duration _tickerElapsed = Duration.zero;

  /// Test-only accessor for the background-pulse `AnimationController`.
  ///
  /// Exposed so widget tests can assert pause/resume behaviour without
  /// having to walk the subtree's `AnimatedBuilder`s (which now collide
  /// with framework-internal AnimatedBuilders backed by `ValueNotifier`).
  @visibleForTesting
  AnimationController get debugPulseControllerForTesting => _pulseController;

  /// Test-only view of whether the stall-detector clock is running.
  ///
  /// An active `Ticker` schedules a frame on every vsync, so "is this ticker
  /// active" is the same question as "is this widget pumping frames".
  @visibleForTesting
  bool get debugElapsedTickerActiveForTesting =>
      _elapsedTicker?.isActive ?? false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    // Defer starting the pulse to build(), which knows the current
    // execution state. This keeps the controller idle if the widget
    // mounts while already paused.
    //
    // The elapsed ticker is deferred to build() for the same reason —
    // see _syncElapsedTicker.
    _elapsedTicker = createTicker((elapsed) => _tickerElapsed = elapsed);
  }

  @override
  void dispose() {
    _elapsedTicker?.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  // When the run last actually moved.
  //
  // A meridian flip whose plate solve fails enters its retry ladder and can
  // hold the run for minutes while every surface stays cheerful: status
  // **Running**, `Progress 4/8 · 50%`, `Mount: Tracking`, and this row's
  // `~1m 8s · done ~00:12:13` — a finish time still on screen long after it
  // has passed, with no frame captured. The estimate is fed by completed
  // frames, so a run that stops capturing keeps its last one forever and it
  // decays into a promise the run is not working toward.
  //
  // Fields the run advances when it is genuinely working. `message` is included
  // because a run can legitimately be busy between frames (slewing, focusing,
  // and — now — a flip announcing its retry).
  Object? _lastProgressSignature;
  Duration? _lastProgressChangeAt;

  /// How long the run has been silent, or null when it is progressing (or when
  /// there is no cadence to judge it against).
  Duration? _stalledFor(SequenceProgress progress, {required bool isRunning}) {
    final signature = Object.hash(
      progress.completedExposures,
      progress.completedIntegrationSecs,
      progress.currentNodeId,
      progress.message,
      progress.elapsedSecs,
    );
    final now = _tickerElapsed;
    if (signature != _lastProgressSignature) {
      _lastProgressSignature = signature;
      _lastProgressChangeAt = now;
    }
    if (!isRunning) return null;
    final threshold = runStallThreshold(progress);
    final since = _lastProgressChangeAt;
    if (threshold == null || since == null) return null;
    final quiet = now - since;
    return quiet >= threshold ? quiet : null;
  }

  /// Start/stop the elapsed-time ticker to match whether the run is actually
  /// executing.
  ///
  /// The ticker exists only to clock the stall detector, and the stall
  /// detector is switched off unless the run is `running` — `_stalledFor`
  /// returns null the moment `isRunning` is false. An active `Ticker`
  /// schedules a frame on every vsync whether or not anything is dirty, and
  /// the Linux embedder submits a full-window frame per scheduled frame, so
  /// leaving it running while the run is PAUSED cost ~56 fps and ~62% of a
  /// core to service a detector that was not looking. (The bar is mounted for
  /// running AND paused: `sequencer_screen.dart` folds paused into
  /// `isRunning`.) While the run really is running this costs nothing extra —
  /// `_pulseController` is already pumping vsync — so the ticker is not the
  /// thing that makes a live run expensive.
  ///
  /// Mirrors `_syncTicker` in `run_dashboard/recovery_banner.dart`.
  void _syncElapsedTicker({required bool isRunning}) {
    final ticker = _elapsedTicker;
    if (ticker == null) return;
    if (isRunning) {
      if (!ticker.isActive) ticker.start();
    } else if (ticker.isActive) {
      ticker.stop();
      // `Ticker.elapsed` restarts from zero on the next `start()`, so the
      // stall window has to restart with it. Comparing a fresh elapsed
      // against a stale `_lastProgressChangeAt` would otherwise measure a
      // negative silence and, worse, could measure a false one.
      _tickerElapsed = Duration.zero;
      _lastProgressChangeAt = null;
      _lastProgressSignature = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = ref.watch(sequenceProgressProvider);
    final executionState = ref.watch(sequenceExecutionStateProvider);
    final isPaused = executionState == SequenceExecutionState.paused;

    _syncElapsedTicker(
      isRunning: executionState == SequenceExecutionState.running,
    );

    // The pulse is owned by the gate, not by this build: `repeating` says
    // whether we want it at all (a paused run gets a calm, static
    // warning-tinted background instead of a strobing one), and the gate ANDs
    // that with whether the bar is actually being painted. The RepaintBoundary
    // sits OUTSIDE the gate so the per-frame repaint is isolated from the rest
    // of the screen rather than the gate being isolated from the paint it needs
    // to observe.
    return RepaintBoundary(
      child: OnScreenAnimationGate(
        controller: _pulseController,
        repeating: !isPaused,
        child: AnimatedBuilder(
          animation: _pulseController,
          builder: (context, child) => LayoutBuilder(
            builder: (context, constraints) {
              // Recomputed inside the pulse builder, not in `build`: `build` only
              // reruns when a provider changes, and a stalled run by definition
              // changes nothing. The pulse ticks every frame, which is what lets the
              // silence be noticed at all.
              final stalledFor = _stalledFor(
                progress,
                isRunning: executionState == SequenceExecutionState.running,
              );
              final backgroundColor = isPaused
                  ? widget.colors.warning
                      .withValues(alpha: _kPausedBackgroundAlpha)
                  : widget.colors.primary.withValues(
                      alpha: 0.05 + _pulseController.value * 0.03,
                    );

              final Widget status = Row(
                children: [
                  if (isPaused)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      margin: const EdgeInsets.only(right: 12),
                      decoration: SkotiqDecorations.statusChip(
                        widget.colors.warning,
                        borderRadius:
                            BorderRadius.circular(SkotiqTokens.radiusInline4),
                        bordered: false,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            LucideIcons.pause,
                            size: 12,
                            color: widget.colors.warning,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'PAUSED',
                            style: TextStyle(
                              fontSize: SkotiqTypography.fontSize10,
                              fontWeight: FontWeight.w700,
                              color: widget.colors.warning,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    _PulsingIndicator(colors: widget.colors),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          progress.currentNodeName ??
                              (isPaused
                                  ? 'Paused: no active node'
                                  : 'Starting...'),
                          style: SkotiqTypography.labelStrong
                              .copyWith(color: widget.colors.textPrimary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (progress.message != null)
                          Text(
                            progress.message!,
                            style: TextStyle(
                              fontSize: SkotiqTypography.fontSize11,
                              color: widget.colors.textMuted,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                ],
              );
              final Widget countValue = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    // No total for a run that loops until its
                    // window closes: count what it has taken.
                    progress.totalExposures > 0
                        ? '${progress.completedExposures}/${progress.totalExposures}'
                        : '${progress.completedExposures} taken',
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize10,
                      fontWeight: FontWeight.w600,
                      color: widget.colors.textSecondary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (progress.totalExposures > 0) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: SkotiqDecorations.statusChip(
                        widget.colors.primary,
                        borderRadius:
                            BorderRadius.circular(SkotiqTokens.radiusInline4),
                        bordered: false,
                      ),
                      child: Text(
                        '${(progress.progressPercent * 100).toStringAsFixed(0)}%',
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize10,
                          fontWeight: FontWeight.w700,
                          color: widget.colors.primary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ],
              );
              final Widget counts = Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Progress',
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize10,
                      color: widget.colors.textMuted,
                    ),
                  ),
                  countValue,
                ],
              );
              final Widget bar = Stack(
                children: [
                  Container(
                    height: 8,
                    decoration: BoxDecoration(
                      color: widget.colors.surfaceAlt,
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusInline4),
                    ),
                  ),
                  FractionallySizedBox(
                    widthFactor: progress.progressPercent.clamp(0.0, 1.0),
                    child: Container(
                      height: 8,
                      decoration: BoxDecoration(
                        color: widget.colors.primary,
                        borderRadius:
                            BorderRadius.circular(SkotiqTokens.radiusInline4),
                      ),
                    ),
                  ),
                  if (progress.totalIntegrationSecs > 0)
                    FractionallySizedBox(
                      widthFactor: (progress.completedIntegrationSecs /
                              progress.totalIntegrationSecs)
                          .clamp(0.0, 1.0),
                      child: Container(
                        height: 8,
                        decoration: BoxDecoration(
                          // absolute: lightening sheen over the filled progress bar
                          color: ImageOverlayColors.foreground
                              .withValues(alpha: 0.1),
                          borderRadius:
                              BorderRadius.circular(SkotiqTokens.radiusInline4),
                        ),
                      ),
                    ),
                ],
              );
              final Widget elapsed = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    LucideIcons.timer,
                    size: 12,
                    color: widget.colors.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    DurationFormat.seconds(progress.elapsedSecs,
                        rounding: DurationRounding.truncate),
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize11,
                      color: widget.colors.textSecondary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              );
              final Widget? remaining = stalledFor != null
                  ?
                  // The run has not moved for longer than its own frame
                  // cadence allows, so it has no finish time to offer. Say
                  // what is true — how long it has been silent — and let the
                  // run's own message (the flip retry, the wait, the failed
                  // step) explain it on the left half of this bar.
                  Tooltip(
                      message: 'No frame has completed for longer than this '
                          "run's own frame cadence, so its finish time is not "
                          'shown. The current step is on the left.',
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            LucideIcons.alertTriangle,
                            size: 12,
                            color: widget.colors.warning,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              'no progress for '
                              '${DurationFormat.seconds(stalledFor.inSeconds.toDouble(), rounding: DurationRounding.truncate)}',
                              style: TextStyle(
                                fontSize: SkotiqTypography.fontSize11,
                                color: widget.colors.warning,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    )
                  : progress.estimatedRemainingSecs != null
                      ? Tooltip(
                          // The estimate is planned integration only — it does
                          // not include pending autofocus / dither / meridian-flip
                          // overhead, so the finish time is a floor, not a promise.
                          message: 'Integration time only: excludes pending '
                              'autofocus, dither, and meridian-flip overhead.',
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                LucideIcons.hourglass,
                                size: 12,
                                color: widget.colors.textMuted,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  '~${DurationFormat.seconds(progress.estimatedRemainingSecs!, rounding: DurationRounding.truncate)}'
                                  ' · done ~${ClockFormat.hms(ref.watch(clockProvider).now().add(Duration(seconds: progress.estimatedRemainingSecs!.round())))}',
                                  style: TextStyle(
                                    fontSize: SkotiqTypography.fontSize11,
                                    color: widget.colors.textMuted,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures()
                                    ],
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        )
                      : null;
              // A phone column: what is running and the counts on one line, the
              // bar across the width, then elapsed and remaining. The wide row's
              // fixed 220 px bar and dividers overflowed it.
              // The width the bar is given, not the window's: a phone on its
              // side is wider than a phone column but far narrower than the
              // wide row needs.
              final compact = constraints.maxWidth <
                  ShellChromeMetrics.shellLayoutBreakpoint;
              // A phone, upright or on its side: one line and a hairline
              // bar. The plan under it is what the operator came to this
              // screen for, and the step's row in it already shows the same
              // progress. On its side the wide row's height left the plan a
              // sliver.
              if (constraints.maxWidth < SkotiqTokens.breakpointMobile ||
                  ShellLayout.of(context).isPhone) {
                final message = progress.message;
                // The frame count repeats the count beside it; a wait or a
                // retry says something the count does not.
                final saysMore =
                    message != null && !progress.messageIsFrameCount;
                return Container(
                  padding: const EdgeInsets.fromLTRB(
                    SkotiqTokens.spaceLg,
                    SkotiqTokens.spaceXs,
                    SkotiqTokens.spaceLg,
                    SkotiqTokens.spaceXs,
                  ),
                  decoration: BoxDecoration(
                    color: backgroundColor,
                    border: Border(
                      bottom: BorderSide(color: widget.colors.border),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          if (isPaused)
                            Icon(
                              LucideIcons.pause,
                              size: 12,
                              color: widget.colors.warning,
                            )
                          else
                            _PulsingIndicator(colors: widget.colors),
                          const SizedBox(width: SkotiqTokens.spaceSm),
                          Expanded(
                            child: Text(
                              progress.currentNodeName ??
                                  (isPaused ? 'Paused' : 'Starting...'),
                              style: SkotiqTypography.labelStrong
                                  .copyWith(color: widget.colors.textPrimary),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: SkotiqTokens.spaceSm),
                          countValue,
                          if (remaining != null) ...[
                            const SizedBox(width: SkotiqTokens.spaceSm),
                            Flexible(child: remaining),
                          ],
                        ],
                      ),
                      if (saysMore)
                        Text(
                          message,
                          style: TextStyle(
                            fontSize: SkotiqTypography.fontSize11,
                            color: widget.colors.textMuted,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      const SizedBox(height: SkotiqTokens.spaceXs),
                      SizedBox(
                        height: 3,
                        child: FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: progress.progressPercent.clamp(0.0, 1.0),
                          child: ColoredBox(color: widget.colors.primary),
                        ),
                      ),
                    ],
                  ),
                );
              }
              if (compact) {
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SkotiqTokens.spaceLg,
                    vertical: SkotiqTokens.spaceSm,
                  ),
                  decoration: BoxDecoration(
                    color: backgroundColor,
                    border: Border(
                      bottom: BorderSide(color: widget.colors.border),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(child: status),
                          const SizedBox(width: SkotiqTokens.spaceSm),
                          countValue,
                        ],
                      ),
                      const SizedBox(height: 6),
                      bar,
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          elapsed,
                          const Spacer(),
                          if (remaining != null) Flexible(child: remaining),
                        ],
                      ),
                    ],
                  ),
                );
              }
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: backgroundColor,
                  border: Border(
                    bottom: BorderSide(color: widget.colors.border),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: status,
                    ),
                    if (progress.currentTarget != null ||
                        progress.currentFilter != null) ...[
                      Container(
                        width: 1,
                        height: 30,
                        margin: const EdgeInsets.symmetric(horizontal: 16),
                        color: widget.colors.border,
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (progress.currentTarget != null)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  LucideIcons.target,
                                  size: 12,
                                  color: widget.colors.textMuted,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  progress.currentTarget!,
                                  style: TextStyle(
                                    fontSize: SkotiqTypography.fontSize11,
                                    color: widget.colors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          if (progress.currentFilter != null)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  LucideIcons.circle,
                                  size: 12,
                                  color: widget.colors.textMuted,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  progress.currentFilter!,
                                  style: TextStyle(
                                    fontSize: SkotiqTypography.fontSize11,
                                    color: widget.colors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ],
                    Container(
                      width: 1,
                      height: 30,
                      margin: const EdgeInsets.symmetric(horizontal: 16),
                      color: widget.colors.border,
                    ),
                    SizedBox(
                      width: 220,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          counts,
                          const SizedBox(height: 6),
                          bar,
                        ],
                      ),
                    ),
                    Container(
                      width: 1,
                      height: 30,
                      margin: const EdgeInsets.symmetric(horizontal: 16),
                      color: widget.colors.border,
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        elapsed,
                        if (remaining != null) remaining,
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _PulsingIndicator extends StatefulWidget {
  final SkotiqColors colors;

  const _PulsingIndicator({required this.colors});

  @override
  State<_PulsingIndicator> createState() => _PulsingIndicatorState();
}

class _PulsingIndicatorState extends State<_PulsingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // Created idle and started by the OnScreenAnimationGate in build(): a
    // repeat() that outlives visibility schedules a frame on every vsync and
    // stops the whole app from idling.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return OnScreenAnimationGate(
      controller: _controller,
      repeating: true,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.colors.success.withValues(
                alpha: 0.5 + _controller.value * 0.5,
              ),
            ),
          );
        },
      ),
    );
  }
}
