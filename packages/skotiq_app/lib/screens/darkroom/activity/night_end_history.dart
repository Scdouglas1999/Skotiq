import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/darkroom_navigation.dart' show darkroomPassLocation;
import 'activity_panel.dart';

/// How many nights the history shows before "Show all".
const int _nightsShown = 7;

/// Every night the automation handled, newest first, each step with its
/// outcome; then the builds started by hand and the integration passes.
class NightEndHistoryPanel extends ConsumerStatefulWidget {
  const NightEndHistoryPanel({super.key});

  @override
  ConsumerState<NightEndHistoryPanel> createState() =>
      _NightEndHistoryPanelState();
}

class _NightEndHistoryPanelState extends ConsumerState<NightEndHistoryPanel> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final runs = ref.watch(nightEndRunsProvider);
    final shown = _all ? runs : runs.take(_nightsShown).toList();
    return ActivityPanel(
      key: const ValueKey('darkroom_activity_history'),
      title: 'Night-end history',
      note: 'what each night end did, step by step',
      trailing: runs.length > _nightsShown
          ? SkotiqButton(
              label: _all ? 'Show fewer' : 'Show all ${runs.length}',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () => setState(() => _all = !_all),
            )
          : null,
      child: runs.isEmpty
          ? const ActivityQuiet(
              'No night has ended with the automation on yet. When one does, '
              'each step and its outcome is listed here.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < shown.length; i++)
                  _NightRun(run: shown[i], last: i == shown.length - 1),
              ],
            ),
    );
  }
}

class _NightRun extends StatelessWidget {
  const _NightRun({required this.run, required this.last});

  final NightEndRun run;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final finished = run.finishedAt;
    return Container(
      key: ValueKey('darkroom_activity_night_${run.id}'),
      padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceMd),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                nightLabel(run.startedAt),
                style: SkotiqTypography.bodyStrong.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceMd),
              Expanded(
                child: Text(
                  run.reason,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ),
              Text(
                finished == null
                    ? 'running since ${clockLabel(run.startedAt)}'
                    : '${clockLabel(run.startedAt)} to ${clockLabel(finished)}',
                style: SkotiqTypography.monoXs.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          _StepRow(label: 'Calibrate', step: run.calibrate),
          _StepRow(
            label: 'Build',
            step: run.build,
            // A night that built nothing says why once, and names what it
            // imaged, instead of a line per target saying the same thing.
            detail: run.build.state == NightEndStepState.skipped
                ? _skippedBuild(run)
                : null,
            children: run.build.state == NightEndStepState.skipped
                ? const []
                : [for (final t in run.targets) _TargetLine(target: t)],
          ),
          _StepRow(
            label: 'Deliver',
            step: run.deliver,
            detail: run.deliver.state == NightEndStepState.skipped ||
                    run.deliver.state == NightEndStepState.pending
                ? run.deliver.detail
                : null,
            children: [
              for (final t in run.targets)
                if (t.deliver.detail != null &&
                    t.deliver.state != NightEndStepState.skipped)
                  _Line(
                    lead: t.target,
                    text: t.deliver.detail!,
                    state: t.deliver.state,
                  ),
            ],
          ),
          _StepRow(label: 'Morning message', step: run.message),
        ],
      ),
    );
  }
}

/// Why a night built nothing, and what it imaged.
String _skippedBuild(NightEndRun run) => [
      for (final t in run.targets.take(1))
        if (t.build.detail case final detail?) detail,
      if (run.targets.isNotEmpty)
        'Imaged: ${run.targets.map((t) => t.target).join(', ')}.',
    ].join(' ');

/// One step: its state icon and name, then its detail or its lines.
class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.label,
    required this.step,
    this.children = const [],
    this.detail,
  });

  final String label;
  final NightEndStep step;
  final List<Widget> children;
  final String? detail;

  static const double _labelWidth = 136;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final (icon, color) = stepLook(step.state, colors);
    final text = detail ?? (children.isEmpty ? step.detail : null);
    return Semantics(
      container: true,
      label: '$label: ${stepWord(step.state)}',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceXs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(icon, size: SkotiqTokens.iconXs, color: color),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            SizedBox(
              width: _labelWidth,
              child: Text(
                label,
                style: SkotiqTypography.label.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ),
            Expanded(
              child: children.isEmpty
                  ? Text(
                      text ?? stepWord(step.state),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: SkotiqTypography.bodySm.copyWith(
                        color: colors.textSecondary,
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: children,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A target's build in one line: its name (opening the target, or the
/// framing check when it waits there) and what happened.
class _TargetLine extends StatelessWidget {
  const _TargetLine({required this.target});

  final NightEndTarget target;

  @override
  Widget build(BuildContext context) {
    final waiting = target.build.state == NightEndStepState.waiting;
    final nights = target.nights;
    return _Line(
      lead: nights == null
          ? target.target
          : '${target.target} ($nights night${nights == 1 ? '' : 's'})',
      text: target.build.detail ?? stepWord(target.build.state),
      state: target.build.state,
      onOpen: () => context.go(
        waiting
            ? darkroomFramingRoute(target.target)
            : darkroomTargetRoute(target.target),
      ),
      openLabel: waiting ? 'Open the framing check' : 'Open ${target.target}',
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({
    required this.lead,
    required this.text,
    required this.state,
    this.onOpen,
    this.openLabel,
  });

  final String lead;
  final String text;
  final NightEndStepState state;
  final VoidCallback? onOpen;
  final String? openLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final (_, color) = stepLook(state, colors);
    final name = Text(
      lead,
      style: SkotiqTypography.labelStrongSm.copyWith(
        color: onOpen == null ? colors.textPrimary : colors.link,
        decoration: onOpen == null ? null : TextDecoration.underline,
        decorationColor: colors.link,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceXs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (onOpen == null)
            name
          else
            Semantics(
              button: true,
              label: openLabel,
              excludeSemantics: true,
              child: InkWell(
                onTap: onOpen,
                borderRadius: SkotiqTokens.borderRadiusSm,
                child: name,
              ),
            ),
          Text(
            text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: SkotiqTypography.bodySm.copyWith(
              color: state == NightEndStepState.failed ||
                      state == NightEndStepState.waiting
                  ? color
                  : colors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Builds that ended outside a night-end run, newest first.
class RecentBuildsPanel extends ConsumerWidget {
  const RecentBuildsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final builds = [
      for (final b in ref.watch(darkroomRecentBuildsProvider))
        if (b.nightRunId == null) b,
    ];
    if (builds.isEmpty) return const SizedBox.shrink();
    return ActivityPanel(
      key: const ValueKey('darkroom_activity_recent'),
      title: 'Other builds',
      note: 'started from a target',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final b in builds.take(10))
            Padding(
              padding: const EdgeInsets.symmetric(
                vertical: SkotiqTokens.spaceXs,
              ),
              child: Row(
                children: [
                  Icon(
                    switch (b.stage) {
                      DarkroomJobStage.done => SkotiqIcons.success,
                      DarkroomJobStage.failed => SkotiqIcons.error,
                      _ => SkotiqIcons.warning,
                    },
                    size: SkotiqTokens.iconXs,
                    color: switch (b.stage) {
                      DarkroomJobStage.done => colors.success,
                      DarkroomJobStage.failed => colors.error,
                      _ => colors.warning,
                    },
                  ),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Expanded(
                    child: InkWell(
                      onTap: () => context.go(darkroomTargetRoute(b.target)),
                      child: Text(
                        '${b.target}: ${b.stage == DarkroomJobStage.failed ? (b.error ?? b.message) : b.message}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: SkotiqTypography.bodySm.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                  Text(
                    clockLabel(b.finishedAt ?? b.startedAt),
                    style: SkotiqTypography.monoXs.copyWith(
                      color: colors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The integration passes recorded on this computer: the per-session
/// integrations whose lanes the pass view draws.
class PassesPanel extends ConsumerWidget {
  const PassesPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final records = ref.watch(darkroomPassRecordsProvider);
    final passes = records.valueOrNull ?? const <PassRecordSummary>[];
    if (records.hasError) {
      return ActivityPanel(
        title: 'Integration passes',
        child: ActivityQuiet('The pass records could not be read: '
            '${records.error}'),
      );
    }
    if (passes.isEmpty) return const SizedBox.shrink();
    return ActivityPanel(
      key: const ValueKey('darkroom_activity_passes'),
      title: 'Integration passes',
      note: 'calibrate, register and integrate, sub by sub',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final pass in passes.take(10))
            Semantics(
              button: true,
              label: 'Open the pass of ${pass.target ?? pass.runId}',
              excludeSemantics: true,
              child: InkWell(
                key: ValueKey('darkroom_activity_pass_${pass.runId}'),
                onTap: () => context.go(darkroomPassLocation(pass.runId)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: SkotiqTokens.spaceSm,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        !pass.ended
                            ? SkotiqIcons.loading
                            : pass.failure == null
                                ? SkotiqIcons.success
                                : SkotiqIcons.error,
                        size: SkotiqTokens.iconXs,
                        color: !pass.ended
                            ? colors.info
                            : pass.failure == null
                                ? colors.success
                                : colors.error,
                      ),
                      const SizedBox(width: SkotiqTokens.spaceSm),
                      Expanded(
                        child: Text(
                          [
                            pass.target ?? 'Session ${pass.sessionId ?? '?'}',
                            if (pass.failure != null) pass.failure!,
                          ].join(': '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: SkotiqTypography.bodySm.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                      Text(
                        '${nightLabel(pass.startedAt)}  ${clockLabel(pass.startedAt)}',
                        style: SkotiqTypography.monoXs.copyWith(
                          color: colors.textMuted,
                        ),
                      ),
                      const SizedBox(width: SkotiqTokens.spaceXs),
                      Icon(
                        SkotiqIcons.chevronRight,
                        size: SkotiqTokens.iconXs,
                        color: colors.textMuted,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
