// The Tonight header: title, run pill, plan and progress, the night strip and
// the run controls (Tonight.dc.html, TonightReady.dc.html).
//
// Which controls show is the view model's call: a null NightControlVm is not
// shown, a disabled one shows its reason in the tooltip and the semantics
// hint. Pause, Resume, Skip step, Stop and Start now go through
// SequenceActionService; Start at dark goes through the action controller,
// which owns the armed timer.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../../../models/command_action_result.dart';
import '../../../services/sequence_action_service.dart';
import '../../../utils/snackbar_helper.dart';
import '../../sequencer/sequencer_screen.dart' show kSequencerRoutePath;
import '../../sequencer/widgets/preflight_validation_dialog.dart';
import '../actions/night_action_controller.dart';
import '../data/plan/night_header_provider.dart';
import '../data/plan/night_run_phase_provider.dart';
import '../data/plan/night_timeline_provider.dart';
import '../left/night_time_format.dart';
import '../night_control_contracts.dart';
import '../night_control_layout.dart';

/// The header slot of [NightControlLayout].
///
/// One row when the window leaves the night strip its full width beside the
/// controls; otherwise the strip moves to a second row, and on a narrow
/// window the controls take a row of their own as well.
class NightHeaderBar extends ConsumerWidget {
  const NightHeaderBar({super.key});

  /// The night strip's width in the one-row header.
  static const double timelineWidth = 360;

  /// The least room the plan name and progress line get before the header
  /// gives the strip a row of its own.
  static const double minInfoWidth = 280;

  /// The least room the title, pill and plan get beside the controls before
  /// the controls wrap onto a row of their own.
  static const double minInlineInfoWidth = 220;

  /// The most of the info row the run pill takes.
  static const double pillShare = 0.6;

  static const double _gap = 14;
  static const double _controlGap = SkotiqTokens.spaceSm;
  static const EdgeInsets _padding = EdgeInsets.fromLTRB(16, 8, 12, 8);

  static TextStyle get _titleStyle =>
      SkotiqTypography.pageTitle.copyWith(fontSize: 17);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = SkotiqLocalizations.of(context);
    final colors = context.skotiqColors;
    final header = ref.watch(nightHeaderProvider);
    final timeline = ref.watch(nightTimelineProvider);
    final now = nightNowOnClock(ref);
    final density = NightControlDensity.maybeOf(context);

    final controls = _controls(context, ref, l10n, header, density);
    final strip = timeline == null ? null : _strip(l10n, timeline);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - _padding.horizontal;
        final title = l10n.text('nightCtlTitle');
        final titleWidth =
            measureTextWidth(context, text: title, style: _titleStyle);
        final controlsWidth = _controlsWidth(context, controls);
        final singleColumn = density?.mode == NightControlMode.singleColumn;
        final besideStrip = width -
            titleWidth -
            controlsWidth -
            (strip == null ? 0 : timelineWidth + 2 * _gap + 1) -
            3 * _gap;
        final oneRow = !singleColumn && besideStrip >= minInfoWidth;
        final inlineControls =
            width - titleWidth - controlsWidth - 3 * _gap >= minInlineInfoWidth;

        final titleText = Semantics(
          header: true,
          child: Text(
            title,
            style: _titleStyle.copyWith(color: colors.textPrimary),
            maxLines: 1,
          ),
        );
        final info = _InfoRow(
          header: header,
          timeline: timeline,
          now: now,
          stacked: !oneRow && !inlineControls,
        );
        final controlRow = Row(
          mainAxisSize: MainAxisSize.min,
          children: _spaced(controls.map((c) => c.widget), _controlGap),
        );

        if (oneRow) {
          return Padding(
            padding: _padding,
            child: Row(
              children: <Widget>[
                titleText,
                const SizedBox(width: _gap),
                Expanded(child: info),
                if (strip != null) ...<Widget>[
                  const SizedBox(width: _gap),
                  SizedBox(width: timelineWidth, child: strip),
                  const SizedBox(width: _gap),
                  Container(width: 1, height: 22, color: colors.border),
                ],
                const SizedBox(width: _gap),
                controlRow,
              ],
            ),
          );
        }

        return Padding(
          padding: _padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  titleText,
                  const SizedBox(width: _gap),
                  Expanded(child: info),
                  if (inlineControls && controls.isNotEmpty) ...<Widget>[
                    const SizedBox(width: _gap),
                    controlRow,
                  ],
                ],
              ),
              if (!inlineControls && controls.isNotEmpty) ...<Widget>[
                const SizedBox(height: SkotiqTokens.spaceSm),
                Wrap(
                  spacing: _controlGap,
                  runSpacing: _controlGap,
                  children: <Widget>[for (final c in controls) c.widget],
                ),
              ],
              if (strip != null) ...<Widget>[
                const SizedBox(height: SkotiqTokens.spaceSm),
                strip,
              ],
            ],
          ),
        );
      },
    );
  }

  static List<Widget> _spaced(Iterable<Widget> children, double gap) {
    final out = <Widget>[];
    for (final child in children) {
      if (out.isNotEmpty) out.add(SizedBox(width: gap));
      out.add(child);
    }
    return out;
  }

  double _controlsWidth(BuildContext context, List<_Control> controls) {
    if (controls.isEmpty) return 0;
    var total = _controlGap * (controls.length - 1);
    for (final control in controls) {
      total += control.measure(context);
    }
    return total;
  }

  // -- Night strip ------------------------------------------------------------

  Widget _strip(SkotiqLocalizations l10n, NightTimelineVm timeline) {
    final now = timeline.now;
    final labels = <(DateTime, NightTimelineLabel)>[
      if (timeline.astroDark case final dark?)
        (
          dark,
          NightTimelineLabel(
            l10n.text('nightCtlTlDark', params: {'time': nightHm(dark)}),
          ),
        ),
      (
        now,
        NightTimelineLabel(
          l10n.text('nightCtlTlNow', params: {'time': nightHm(now)}),
          emphasized: true,
        ),
      ),
      for (final window in timeline.windows)
        (
          window.end,
          NightTimelineLabel(
            l10n.text('nightCtlTlWindowEnd', params: {
              'name': window.name,
              'time': nightHmMaybeEstimated(
                window.end,
                estimated: window.estimated,
              ),
            }),
          ),
        ),
      if (timeline.astroDawn case final dawn?)
        (
          dawn,
          NightTimelineLabel(
            l10n.text('nightCtlTlDawn', params: {'time': nightHm(dawn)}),
          ),
        ),
    ]..sort((a, b) => a.$1.compareTo(b.$1));

    return NightTimelineStrip(
      start: timeline.sunset,
      end: timeline.sunrise,
      darkStart: timeline.astroDark,
      darkEnd: timeline.astroDawn,
      now: now,
      spans: <NightTimelineSpan>[
        for (final window in timeline.windows)
          NightTimelineSpan(
            start: window.start,
            end: window.end,
            state: switch (window.state) {
              TimelineWindowState.done => NightTimelineSpanState.done,
              TimelineWindowState.active => NightTimelineSpanState.active,
              TimelineWindowState.planned => NightTimelineSpanState.planned,
            },
          ),
      ],
      labels: <NightTimelineLabel>[for (final label in labels) label.$2],
      semanticLabel: _stripSentence(l10n, timeline),
    );
  }

  /// "Night from sunset 18:18 to sunrise 07:14, now 23:52; M74 until ≈03:40,
  /// then NGC 891 until ≈05:30".
  static String _stripSentence(
    SkotiqLocalizations l10n,
    NightTimelineVm timeline,
  ) {
    final base = l10n.text('nightCtlTlSemantics', params: {
      'sunset': nightHm(timeline.sunset),
      'sunrise': nightHm(timeline.sunrise),
      'now': nightHm(timeline.now),
    });
    if (timeline.windows.isEmpty) return base;
    final windows = timeline.windows
        .map(
          (w) => l10n.text('nightCtlTlSemWindow', params: {
            'name': w.name,
            'time': nightHmMaybeEstimated(w.end, estimated: w.estimated),
          }),
        )
        .join(', ${l10n.text('nightCtlTlSemThen')} ');
    return '$base; $windows';
  }

  // -- Controls ---------------------------------------------------------------

  List<_Control> _controls(
    BuildContext context,
    WidgetRef ref,
    SkotiqLocalizations l10n,
    NightHeaderVm header,
    NightControlDensity? density,
  ) {
    final phase = header.phase;
    final controls = <_Control>[];

    final openDrawer = density?.openPlanDrawer;
    if (openDrawer != null) {
      controls.add(
        _ButtonControl(
          label: l10n.text('nightPlanDrawer'),
          icon: LucideIcons.panelLeftOpen,
          control: const NightControlVm.enabled(),
          onPressed: openDrawer,
        ),
      );
    }

    if (!phase.isRunLive) {
      controls.add(
        _ButtonControl(
          label: l10n.text('nightCtlEditPlan'),
          control: const NightControlVm.enabled(),
          onPressed: () => context.go(kSequencerRoutePath),
        ),
      );
    }

    if (header.pauseResume case final control?) {
      final resume = phase == NightRunPhase.pausedByUser ||
          phase == NightRunPhase.pausedForAction;
      controls.add(
        _ButtonControl(
          label: l10n.text(resume ? 'nightCtlResume' : 'nightCtlPause'),
          control: control,
          onPressed: () => _runCommand(
            context,
            ref,
            (service) => resume ? service.resume() : service.pause(),
          ),
        ),
      );
    }
    if (header.skipStep case final control?) {
      controls.add(
        _ButtonControl(
          label: l10n.text('nightCtlSkip'),
          control: control,
          onPressed: () => _runCommand(context, ref, (s) => s.skip()),
        ),
      );
    }
    if (header.stop case final control?) {
      controls.add(
        _StopControl(
          label: l10n.text('nightCtlStop'),
          control: control,
          onConfirmed: () => _runCommand(
            context,
            ref,
            (s) => s.stop(preserveCheckpoint: true),
          ),
        ),
      );
    }

    if (header.startAtDark case final control?) {
      final armedAt = header.armedStartAt;
      if (phase == NightRunPhase.armed && armedAt != null) {
        controls.add(
          _ArmedControl(
            armedAt: armedAt,
            onCancel: () => ref.read(nightActionApiProvider).cancelArmedStart(),
          ),
        );
      } else {
        controls.add(
          _ButtonControl(
            label: l10n.text('nightActStartAtDark'),
            control: control,
            onPressed: () => _armStartAtDark(context, ref),
          ),
        );
      }
    }
    if (header.startNow case final control?) {
      controls.add(
        _ButtonControl(
          label: l10n.text('nightCtlStartNow'),
          control: control,
          variant: ButtonVariant.primary,
          onPressed: () => _startNow(context, ref),
        ),
      );
    }
    return controls;
  }

  static Future<void> _runCommand(
    BuildContext context,
    WidgetRef ref,
    Future<CommandActionResult> Function(SequenceActionService) command,
  ) async {
    final result = await command(ref.read(sequenceActionServiceProvider));
    if (!context.mounted) return;
    context.showCommandActionResult(result);
  }

  /// Start now goes through the same pre-flight gate every other Start in
  /// the app uses, so the header cannot skip the safety checks.
  static Future<void> _startNow(BuildContext context, WidgetRef ref) {
    return showDialog<void>(
      context: context,
      builder: (_) => PreFlightValidationDialog(
        onStartSequence: () async {
          final result = await ref.read(sequenceActionServiceProvider).start();
          if (!context.mounted) return;
          context.showCommandActionResult(result);
        },
      ),
    );
  }

  static Future<void> _armStartAtDark(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final api = ref.read(nightActionApiProvider);
    await api.armStartAtDark();
    if (!context.mounted) return;
    // The controller clears its error when arming succeeds, so an error now
    // is this attempt's refusal.
    final error = api.state.error;
    if (error != null) {
      context.showErrorSnackBar(error.resolve(SkotiqLocalizations.of(context)));
    }
  }
}

// ---------------------------------------------------------------------------
// Pill, plan name and progress
// ---------------------------------------------------------------------------

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.header,
    required this.timeline,
    required this.now,
    required this.stacked,
  });

  final NightHeaderVm header;
  final NightTimelineVm? timeline;
  final DateTime now;

  /// On a narrow window the plan line goes under the pill instead of
  /// beside it, so neither is cut to nothing.
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    final colors = context.skotiqColors;
    final planName = header.planName;
    final progress = _progress(l10n);
    final keepOpen = header.phase == NightRunPhase.armed
        ? l10n.text('nightActArmedKeepOpen')
        : null;
    final detail = keepOpen ?? progress;

    final planLine = Text.rich(
      TextSpan(
        children: <InlineSpan>[
          TextSpan(
            text: planName ?? l10n.text('nightCtlNoPlan'),
            style: SkotiqTypography.labelStrong.copyWith(
              color: planName == null ? colors.textMuted : colors.textPrimary,
            ),
          ),
          if (detail != null && detail.isNotEmpty)
            TextSpan(
              text: '   $detail',
              style: SkotiqTypography.caption.copyWith(
                color: keepOpen != null ? colors.warning : colors.textSecondary,
              ),
            ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
    );
    final pill = _RunPill(header: header, now: now);

    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          pill,
          const SizedBox(height: SkotiqTokens.spaceXs),
          planLine,
        ],
      );
    }
    // The pill keeps its natural width up to a share of the row, so the
    // run state is the last thing to be cut; the plan line takes the rest.
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        children: <Widget>[
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: constraints.maxWidth * NightHeaderBar.pillShare,
            ),
            child: pill,
          ),
          const SizedBox(width: 14),
          Expanded(child: planLine),
        ],
      ),
    );
  }

  /// "target 1 of 2 · step 7 of 12 · Ha 180 s · 44/60" during a run;
  /// "2 targets · 12 steps · ≈7 h planned · dark in 1 h 12 m" before one.
  String? _progress(SkotiqLocalizations l10n) {
    final parts = <String>[];
    if (header.phase.isRunLive) {
      final (ti, tc) = (header.targetIndex, header.targetCount);
      if (ti != null && tc != null) {
        parts.add(
          l10n.text('nightCtlTargetOf',
              params: {'index': '$ti', 'count': '$tc'}),
        );
      }
      final (si, sc) = (header.stepIndex, header.stepCount);
      if (si != null && sc != null) {
        parts.add(
          l10n.text('nightCtlStepOf', params: {'index': '$si', 'count': '$sc'}),
        );
      }
      final exposure = [
        if (header.currentFilter case final filter?) filter,
        if (header.currentExposureSecs case final secs?) '${_secs(secs)} s',
      ].join(' ');
      if (exposure.isNotEmpty) parts.add(exposure);
      if (header.framesDone case final done?) {
        final total = header.framesTotal;
        parts.add(total == null ? '$done' : '$done/$total');
      }
    } else {
      if (header.planName == null) return null;
      if (header.targetCount case final count?) {
        parts.add(
          count == 1
              ? l10n.text('nightCtlCountTarget1')
              : l10n.text('nightCtlCountTargets', params: {'count': '$count'}),
        );
      }
      if (header.stepCount case final count?) {
        parts.add(
          count == 1
              ? l10n.text('nightCtlCountStep1')
              : l10n.text('nightCtlCountSteps', params: {'count': '$count'}),
        );
      }
      if (header.plannedDuration case final planned?) {
        parts.add(
          l10n.text('nightCtlPlanned', params: {
            'duration': '$kNightEstimatePrefix${nightSpan(l10n, planned)}',
          }),
        );
      }
      final dark = timeline?.astroDark;
      if (dark != null && now.isBefore(dark)) {
        parts.add(
          l10n.text('nightCtlDarkIn', params: {
            'duration': nightSpan(l10n, dark.difference(now)),
          }),
        );
      }
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  static String _secs(double secs) => secs == secs.roundToDouble()
      ? secs.toStringAsFixed(0)
      : secs.toStringAsFixed(1);
}

/// "Running 4 h 04 m", "Ready · not started", "Paused for autofocus".
///
/// The state is a live region, so a screen reader hears it change; the
/// ticking duration beside it is not, so it is not announced every minute.
class _RunPill extends StatelessWidget {
  const _RunPill({required this.header, required this.now});

  final NightHeaderVm header;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    final colors = context.skotiqColors;
    final tone = _tone(header.phase).resolve(colors);
    final ink = tone ?? colors.textSecondary;
    final state = _label(l10n);
    final started = header.runStartedAt;
    final duration = header.phase == NightRunPhase.running && started != null
        ? nightSpan(l10n, now.difference(started))
        : null;
    final style = SkotiqChip.textStyle().copyWith(
      color: ink,
      fontWeight: FontWeight.w600,
    );

    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: SkotiqDecorations.chip(
          colors,
          tone: tone,
          radius: SkotiqTokens.radiusFull,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            StatusDot(color: ink),
            const SizedBox(width: 6),
            Flexible(
              child: ExcludeSemantics(
                child: Text.rich(
                  TextSpan(
                    children: <InlineSpan>[
                      TextSpan(text: state),
                      if (duration != null) TextSpan(text: ' $duration'),
                    ],
                  ),
                  style: style,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                ),
              ),
            ),
            // The announced state, kept apart from the duration.
            Semantics(
              container: true,
              liveRegion: true,
              label: state,
              child: const SizedBox.shrink(),
            ),
            if (duration != null)
              Semantics(
                label: l10n.text('nightCtlRunningFor', params: {
                  'duration': duration,
                }),
                child: const SizedBox.shrink(),
              ),
          ],
        ),
      ),
    );
  }

  String _label(SkotiqLocalizations l10n) => switch (header.phase) {
        NightRunPhase.notSetUp => l10n.text('nightCtlPillNotSetUp'),
        NightRunPhase.ready => l10n.text('nightCtlPillReady'),
        NightRunPhase.armed => l10n.text('nightCtlPillArmed'),
        NightRunPhase.running => l10n.text('nightCtlPillRunning'),
        NightRunPhase.pausedByUser => l10n.text('nightCtlPillPaused'),
        NightRunPhase.pausedForAction => switch (header.pausedFor) {
            null => l10n.text('nightCtlPillPaused'),
            final id => l10n.text(_pausedForKey(id)),
          },
        NightRunPhase.stopping => l10n.text('nightCtlPillStopping'),
        NightRunPhase.finished => l10n.text('nightCtlPillFinished'),
      };

  static String _pausedForKey(ManualActionId id) => switch (id) {
        ManualActionId.snapshot => 'nightCtlPausedForSnapshot',
        ManualActionId.loop => 'nightCtlPausedForLoop',
        ManualActionId.autofocus => 'nightCtlPausedForAutofocus',
        ManualActionId.solveSync => 'nightCtlPausedForSolveSync',
        ManualActionId.center => 'nightCtlPausedForCenter',
        ManualActionId.dither => 'nightCtlPausedForDither',
        ManualActionId.flip => 'nightCtlPausedForFlip',
        ManualActionId.tracking => 'nightCtlPausedForTracking',
        ManualActionId.cooler => 'nightCtlPausedForCooler',
      };

  static ChipTone _tone(NightRunPhase phase) => switch (phase) {
        NightRunPhase.running => ChipTone.success,
        NightRunPhase.ready || NightRunPhase.armed => ChipTone.primary,
        NightRunPhase.pausedByUser ||
        NightRunPhase.pausedForAction ||
        NightRunPhase.stopping =>
          ChipTone.warning,
        NightRunPhase.notSetUp || NightRunPhase.finished => ChipTone.neutral,
      };
}

// ---------------------------------------------------------------------------
// Controls
// ---------------------------------------------------------------------------

/// One header control: the widget, and the width it needs so the header can
/// choose its layout before building it.
abstract class _Control {
  const _Control();

  Widget get widget;

  double measure(BuildContext context);
}

/// A plain button, wrapped in a tooltip that says why when it is disabled.
class _ButtonControl extends _Control {
  const _ButtonControl({
    required this.label,
    required this.control,
    required this.onPressed,
    this.icon,
    this.variant = ButtonVariant.secondary,
  });

  final String label;
  final NightControlVm control;
  final VoidCallback onPressed;
  final IconData? icon;
  final ButtonVariant variant;

  @override
  double measure(BuildContext context) => SkotiqButton.measureWidth(
        context,
        label: label,
        hasIcon: icon != null,
        size: ButtonSize.small,
      );

  @override
  Widget get widget => Builder(
        builder: (context) => _ReasonTooltip(
          control: control,
          child: SkotiqButton(
            label: label,
            icon: icon,
            size: ButtonSize.small,
            variant: variant,
            onPressed: control.enabled ? onPressed : null,
            semanticsHint: _ReasonTooltip.reasonOf(context, control),
          ),
        ),
      );
}

/// Stop: hold to confirm, so a stray click never ends an overnight run.
/// The checkpoint is kept so the run can be resumed later.
class _StopControl extends _Control {
  const _StopControl({
    required this.label,
    required this.control,
    required this.onConfirmed,
  });

  final String label;
  final NightControlVm control;
  final VoidCallback onConfirmed;

  @override
  double measure(BuildContext context) => SkotiqButton.measureWidth(
        context,
        label: label,
        size: ButtonSize.small,
      );

  @override
  Widget get widget => Builder(
        builder: (context) {
          final l10n = SkotiqLocalizations.of(context);
          final colors = context.skotiqColors;
          return _ReasonTooltip(
            control: control,
            child: Semantics(
              hint: _ReasonTooltip.reasonOf(context, control),
              child: HoldToConfirmButton(
                enabled: control.enabled,
                holdColor: colors.error,
                confirmText: l10n.text('nightCtlStopHold'),
                semanticsLabel: l10n.text('nightCtlStopSemantics'),
                onConfirmed: onConfirmed,
                child: IgnorePointer(
                  child: ExcludeSemantics(
                    child: SkotiqButton(
                      label: label,
                      size: ButtonSize.small,
                      variant: ButtonVariant.destructive,
                      onPressed: control.enabled ? () {} : null,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
}

/// "Starts at 19:48 · Cancel" while Start at dark is armed.
class _ArmedControl extends _Control {
  const _ArmedControl({required this.armedAt, required this.onCancel});

  final DateTime armedAt;
  final VoidCallback onCancel;

  static TextStyle get _style => SkotiqTypography.labelSm;

  String _label(SkotiqLocalizations l10n) =>
      l10n.text('nightActArmedStartsAt', params: {'time': nightHm(armedAt)});

  @override
  double measure(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    return measureTextWidth(context, text: _label(l10n), style: _style) +
        SkotiqTokens.spaceXs +
        SkotiqButton.measureWidth(
          context,
          label: l10n.text('nightActCancel'),
          size: ButtonSize.small,
        );
  }

  @override
  Widget get widget => Builder(
        builder: (context) {
          final l10n = SkotiqLocalizations.of(context);
          final colors = context.skotiqColors;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Flexible(
                child: SkotiqTooltip(
                  message: l10n.text('nightActArmedKeepOpen'),
                  child: Semantics(
                    hint: l10n.text('nightActArmedKeepOpen'),
                    child: Text(
                      _label(l10n),
                      style: _style.copyWith(color: colors.primary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceXs),
              SkotiqButton(
                label: l10n.text('nightActCancel'),
                size: ButtonSize.small,
                variant: ButtonVariant.ghost,
                semanticsHint: l10n.text('nightCtlCancelArmedHint'),
                onPressed: onCancel,
              ),
            ],
          );
        },
      );
}

/// Shows a disabled control's reason on hover; an enabled one passes
/// through untouched.
class _ReasonTooltip extends StatelessWidget {
  const _ReasonTooltip({required this.control, required this.child});

  final NightControlVm control;
  final Widget child;

  /// The reason a disabled control gives, or null for an enabled one.
  static String? reasonOf(BuildContext context, NightControlVm control) {
    final reason = control.disabledReason;
    if (control.enabled || reason == null) return null;
    return reason.resolve(SkotiqLocalizations.of(context));
  }

  @override
  Widget build(BuildContext context) {
    final text = reasonOf(context, control);
    if (text == null) return child;
    return SkotiqTooltip(message: text, child: child);
  }
}
