// Overview's "Session" block.
//
// Accepted, rejected and integration come from the session's light rows
// (`captured_images.is_accepted`), the one place every verdict on a frame is
// recorded: the run's grader, the science pipeline's auto-grader and the
// operator's own flags. Analytics, History and `/api/sessions` count the same
// rows. The run's own counters (`liveSequenceStatsProvider`) know only the
// run's grader, so a night the auto-grader culled read "7 accepted, 1
// rejected" here and "4 accepted, 4 excluded" in Analytics (rig, 2026-11-03).
// They stay the source before the first row lands, and for the frame count,
// autofocus runs and dithers. A metric with no source is left out of the list.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart' show MetricGridTone;

import '../../night_control_contracts.dart';
import 'session_format.dart';
import 'run_grading_provider.dart';
import 'session_frames_provider.dart';

/// Free space on the capture volume, in bytes; null until a sample lands.
/// Its own provider so a test pins it without the polling stream.
final nightCaptureFreeBytesProvider = Provider<int?>((ref) {
  return ref.watch(captureDirDiskSpaceProvider).valueOrNull?.freeBytes;
});

final nightSessionStatsProvider = Provider<NightSessionVm>((ref) {
  final calibrationFinished =
      ref.watch(shownTerminalRunResultProvider)?.isCalibration == true;
  final live = calibrationFinished
      ? ref.watch(completedImagingRunProvider)?.stats
      : ref.watch(liveSequenceStatsProvider);
  final lights = ref.watch(nightSessionLightRowsProvider);
  final session = ref.watch(sessionStateProvider);
  final remaining = ref.watch(
    sequenceProgressProvider.select((p) => p.estimatedRemainingSecs),
  );
  final freeBytes = ref.watch(nightCaptureFreeBytesProvider);
  final now = ref.watch(nightSessionNowProvider);

  final runStart = session.isActive ? session.startTime : live?.startTime;
  // The night's first frame, when an earlier run of the same night (one a
  // crash or a restart ended) began before this one.
  final firstFrame = lights.isEmpty ? null : lights.first.capturedAt;
  final start = runStart == null
      ? firstFrame
      : firstFrame != null &&
              firstFrame.isBefore(runStart) &&
              observingNight(firstFrame) == observingNight(runStart)
          ? firstFrame
          : runStart;
  final end = session.isActive ? now : live?.endTime ?? now;
  final elapsed =
      start == null || end.isBefore(start) ? null : end.difference(start);

  int? accepted;
  int? rejected;
  double? integration;
  if (lights.isNotEmpty) {
    final kept = lights.where((row) => row.isAccepted).toList();
    accepted = kept.length;
    rejected = lights.length - kept.length;
    integration = kept.fold<double>(0, (sum, r) => sum + r.exposureDuration);
  } else if (live != null) {
    accepted = live.framesCaptured - live.framesRejected;
    rejected = live.framesRejected;
    integration = live.integrationSecs;
  }

  // The disconnect log is not reactive; it is read again whenever the
  // frames, the clock or the run counters move, which is often enough for a
  // count.
  final dropouts = start == null
      ? null
      : ref.watch(usbDisconnectLogProvider).countSince(start);

  return NightSessionVm(
    // The night's rows once there are any: the run's own counter starts
    // over with a run restored after a restart.
    frameCount: lights.isNotEmpty ? lights.length : live?.framesCaptured,
    elapsed: elapsed,
    metrics: <MetricVm>[
      if (accepted != null)
        MetricVm(
          label: const NightText('nightSessionStatAccepted'),
          value: '$accepted',
        ),
      if (rejected != null)
        MetricVm(
          label: const NightText('nightSessionStatRejected'),
          value: '$rejected',
          valueTone: rejected > 0 ? MetricGridTone.bad : MetricGridTone.neutral,
        ),
      if (integration != null)
        MetricVm(
          label: const NightText('nightSessionStatIntegration'),
          // Zero accepted seconds is a real count early in a run.
          value: integration > 0 ? nightDuration(integration) : '0m',
        ),
      if (live?.endTime == null && remaining != null && remaining > 0)
        MetricVm(
          label: const NightText('nightSessionStatRemaining'),
          value: nightDuration(remaining),
        ),
      if (live != null) ...[
        MetricVm(
          label: const NightText('nightSessionStatAutofocus'),
          value: '${live.autofocusRuns}',
        ),
        MetricVm(
          label: const NightText('nightSessionStatDithers'),
          value: '${live.ditherCount}',
        ),
      ],
      if (freeBytes != null)
        MetricVm(
          label: const NightText('nightSessionStatDisk'),
          value: ByteFormat.size(freeBytes),
        ),
      if (dropouts != null)
        MetricVm(
          label: const NightText('nightSessionStatDropouts'),
          value: '$dropouts',
          valueTone:
              dropouts > 0 ? MetricGridTone.warning : MetricGridTone.neutral,
        ),
    ],
    rejectStreak:
        session.isActive ? _rejectStreak(ref.watch(runGradingProvider)) : null,
  );
});

/// "3 frames rejected in a row: HFR 4.10 above 3.00" while the run's grader
/// is rejecting frames one after another; null once it accepts one.
NightText? _rejectStreak(FrameGradeRunSummary grading) {
  final count = grading.consecutiveRejects;
  if (count == 0) return null;
  final reason = grading.lastReject?.reason.trim() ?? '';
  final key =
      count == 1 ? 'nightSessionRejectedLast' : 'nightSessionRejectedInARow';
  return NightText(
    reason.isEmpty ? key : '${key}Reason',
    params: <String, String>{'count': '$count', 'reason': reason},
  );
}
