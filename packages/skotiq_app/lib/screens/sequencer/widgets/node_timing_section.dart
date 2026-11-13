import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Checks if a node type has a meaningful duration that should be displayed.
///
/// `SequenceNode` is sealed: the switch is exhaustive, so adding a new node
/// type forces a decision here at compile time rather than silently
/// defaulting to "no duration".
bool hasMeaningfulDuration(SequenceNode node) {
  return switch (node) {
    ExposureNode _ ||
    AutofocusNode _ ||
    DelayNode _ ||
    WaitTimeNode _ ||
    SlewNode _ ||
    CenterNode _ ||
    MeridianFlipNode _ ||
    DitherNode _ ||
    FilterChangeNode _ ||
    RotatorNode _ ||
    ParkNode _ ||
    UnparkNode _ ||
    HomeMountNode _ ||
    CoolCameraNode _ ||
    WarmCameraNode _ ||
    StartGuidingNode _ ||
    StopGuidingNode _ ||
    OpenDomeNode _ ||
    CloseDomeNode _ ||
    ParkDomeNode _ ||
    PolarAlignmentNode _ ||
    ScriptNode _ ||
    // SmartExposure has a meaningful (and often very
    // large) duration — display the time estimate inline like ExposureNode.
    SmartExposureNode _ ||
    // Plugin nodes carry an OPTIONAL per-node timeout that
    // bounds wall-clock cost; treat the duration as meaningful when the
    // operator supplied one, so the editor's timing section shows the
    // worst-case budget and the user can immediately tell which plugin
    // nodes might overrun the night.
    PluginInstructionNode _ ||
    // SciencePhotometry captures `count` frames at
    // `exposureSecs` apiece — total wall-clock is the count × exposure
    // sum (plus per-frame overhead), which is meaningful in the same
    // way ExposureNode's is. Surfacing the estimate in the editor warns
    // the user when a 600-frame burst would overrun the night.
    SciencePhotometryNode _ =>
      true,
    // Container/notification/cover/calibrator nodes have no intrinsic duration
    TargetHeaderNode _ ||
    InstructionSetNode _ ||
    LoopNode _ ||
    ParallelNode _ ||
    ConditionalNode _ ||
    RecoveryNode _ ||
    NotificationNode _ ||
    OpenCoverNode _ ||
    CloseCoverNode _ ||
    CalibratorOnNode _ ||
    CalibratorOffNode _ ||
    // TargetScheduler is a container — its duration is the
    // sum/max of its children's durations, which the timing estimator
    // computes by walking the subtree. The container itself has no
    // intrinsic per-node duration to display in the section header.
    TargetSchedulerNode _ ||
    // LiveStacking arms the broadcast and returns
    // immediately. The wall-clock cost is paid by sibling exposure
    // nodes, so this node itself has no displayable duration.
    LiveStackingNode _ =>
      false,
  };
}

class NodeTimingSection extends ConsumerWidget {
  final SkotiqColors colors;
  final SequenceNode node;

  const NodeTimingSection({
    super.key,
    required this.colors,
    required this.node,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sequence = ref.watch(currentSequenceProvider);
    if (sequence == null) return const SizedBox.shrink();

    // The node's time and the whole run's, from the plan's one timing. The
    // details below are the node's inputs; every time on the panel is the
    // estimator's.
    final plan = ref.watch(currentPlanTimingProvider);
    final nodeTiming = plan?.of(node.id);
    final totalDuration = plan?.total ?? Duration.zero;
    final durationDetails =
        _getDurationDetails(ref, ref.watch(sequencerOverheadConfigProvider));

    if (nodeTiming == null && durationDetails == null) {
      return const SizedBox.shrink();
    }

    final duration = nodeTiming?.duration ?? Duration.zero;
    final percentage = totalDuration.inSeconds > 0
        ? (duration.inSeconds / totalDuration.inSeconds * 100)
        : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Hairline, eyebrow, readouts (06 §Sequencer).
        Container(height: 1, color: colors.border),
        const SizedBox(height: SkotiqTokens.spaceMd),
        Text(
          'ESTIMATE',
          style: SkotiqTypography.eyebrow.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        ReadoutRow(
          gap: SkotiqTokens.space2xl,
          children: <Readout>[
            Readout(
              value: DurationFormat.of(duration, style: DurationStyle.short),
              label: 'Duration',
            ),
            if (totalDuration.inSeconds > 0 && percentage > 0.1)
              Readout(
                value: percentage.toStringAsFixed(1),
                unit: '%',
                label: 'Of total',
              ),
          ],
        ),
        if (durationDetails != null) ...[
          const SizedBox(height: SkotiqTokens.spaceMd),
          KeyValueList(
            rows: <(String, String)>[
              for (final detail in durationDetails)
                (detail.label, detail.value),
            ],
          ),
        ],
        const SizedBox(height: SkotiqTokens.spaceLg),
      ],
    );
  }

  /// The node's inputs that set its time (counts, per-frame download from
  /// [overhead], settle and timeout settings), or null when it has none.
  List<_DurationDetail>? _getDurationDetails(
    WidgetRef ref,
    SequenceOverheadConfig overhead,
  ) {
    if (node is ExposureNode) {
      final exposure = node as ExposureNode;
      final downloadOverhead =
          exposure.count * overhead.downloadOverheadPerExposureSecs;

      return [
        _DurationDetail(
          label: 'Exposures',
          value:
              '${exposure.count} x ${exposure.durationSecs.toStringAsFixed(exposure.durationSecs == exposure.durationSecs.truncate() ? 0 : 1)}s',
        ),
        _DurationDetail(
          label: 'Download overhead',
          value: '~${downloadOverhead.toStringAsFixed(0)}s',
        ),
      ];
    }

    if (node is AutofocusNode) {
      final autofocus = node as AutofocusNode;
      final run = AutofocusRun.ofNode(
          ref.watch(autofocusSettingsProvider), autofocus);
      String seconds(double value) => '${QuantityFormat.trimmed(value)}s';

      return [
        _DurationDetail(
          label: 'Focuser positions',
          value: '${run.points}',
        ),
        _DurationDetail(
          label: 'At each',
          value: '${run.exposuresPerPoint} x ${seconds(run.exposureSecs)}'
              ' after ${seconds(run.focuserSettleSecs)} settle',
        ),
        _DurationDetail(
          label: 'Download overhead',
          value: '~${seconds(run.points *
              run.exposuresPerPoint *
              overhead.downloadOverheadPerExposureSecs)}',
        ),
        _DurationDetail(
          label: 'Source',
          value: autofocus.useSettingsDefaults
              ? 'Autofocus settings'
              : 'This step',
        ),
      ];
    }

    if (node is DelayNode) {
      final delay = node as DelayNode;
      return [
        _DurationDetail(
          label: 'Delay',
          value: DurationFormat.of(Duration(milliseconds: (delay.seconds * 1000).round()), style: DurationStyle.short),
        ),
      ];
    }

    if (node is WaitTimeNode) {
      final wait = node as WaitTimeNode;
      if (wait.waitUntil != null) {
        return [
          _DurationDetail(
            label: 'Wait until',
            value:
                '${wait.waitUntil!.hour.toString().padLeft(2, '0')}:${wait.waitUntil!.minute.toString().padLeft(2, '0')}',
          ),
        ];
      } else if (wait.waitForTwilight != null) {
        final twilightName = switch (wait.waitForTwilight!) {
          TwilightType.civil => 'Civil twilight',
          TwilightType.nautical => 'Nautical twilight',
          TwilightType.astronomical => 'Astronomical twilight',
        };
        return [
          _DurationDetail(
            label: 'Wait for',
            value: twilightName,
          ),
        ];
      }
    }

    if (node is CenterNode) {
      final center = node as CenterNode;
      return [
        _DurationDetail(
          label: 'Max attempts',
          value: '${center.maxAttempts}',
        ),
      ];
    }

    if (node is MeridianFlipNode) {
      final flip = node as MeridianFlipNode;
      return [
        _DurationDetail(
          label: 'Auto-center',
          value: flip.autoCenter ? 'Yes' : 'No',
        ),
        _DurationDetail(
          label: 'Settle time',
          value: '${flip.settleTime.toStringAsFixed(0)}s',
        ),
      ];
    }

    if (node is CoolCameraNode) {
      final cool = node as CoolCameraNode;
      return [
        _DurationDetail(
          label: 'Max cooling time',
          value: '${(cool.durationMins ?? 10).toStringAsFixed(0)}m',
        ),
      ];
    }

    if (node is WarmCameraNode) {
      final warm = node as WarmCameraNode;
      return [
        _DurationDetail(
          label: 'Warming rate',
          value: '${warm.ratePerMin}C/min',
        ),
        _DurationDetail(
          label: 'Target temp',
          value: '${warm.targetTemp.toStringAsFixed(1)}C',
        ),
      ];
    }

    if (node is DitherNode) {
      final dither = node as DitherNode;
      return [
        _DurationDetail(
          label: 'Settle time',
          value: '${dither.settleTime.toStringAsFixed(0)}s',
        ),
      ];
    }

    if (node is StartGuidingNode) {
      final guiding = node as StartGuidingNode;
      return [
        _DurationDetail(
          label: 'Settle timeout',
          value: '${guiding.settleTimeout.toStringAsFixed(0)}s',
        ),
      ];
    }

    if (node is PolarAlignmentNode) {
      return const [
        _DurationDetail(
          label: 'Note',
          value: '3 plate solves + adjustment',
        ),
      ];
    }

    if (node is ScriptNode) {
      final script = node as ScriptNode;
      return [
        _DurationDetail(
          label: 'Timeout',
          value: '${script.timeoutSecs ?? 30}s',
        ),
      ];
    }

    if (node is SciencePhotometryNode) {
      final phot = node as SciencePhotometryNode;
      final downloadOverhead =
          phot.count * overhead.downloadOverheadPerExposureSecs;
      return [
        _DurationDetail(
          label: 'Frames',
          value:
              '${phot.count} x ${phot.exposureSecs.toStringAsFixed(phot.exposureSecs == phot.exposureSecs.truncate() ? 0 : 1)}s',
        ),
        _DurationDetail(
          label: 'Filter',
          value: phot.filter,
        ),
        _DurationDetail(
          label: 'Download overhead',
          value: '~${downloadOverhead.toStringAsFixed(0)}s',
        ),
      ];
    }

    return null;
  }
}

class _DurationDetail {
  final String label;
  final String value;

  const _DurationDetail({
    required this.label,
    required this.value,
  });
}
