// Overview's "Session" block.
//
// The run's own counters (`liveSequenceStatsProvider`) are the source while a
// run is live: they count the autofocus runs, dithers and rejections as the
// executor saw them. Without a run the frame counts fall back to the session
// rows. A metric with no source is left out of the list.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../night_control_contracts.dart';
import 'session_format.dart';
import 'session_frames_provider.dart';

/// Free space on the capture volume, in bytes; null until a sample lands.
/// Its own provider so a test pins it without the polling stream.
final nightCaptureFreeBytesProvider = Provider<int?>((ref) {
  return ref.watch(captureDirDiskSpaceProvider).valueOrNull?.freeBytes;
});

final nightSessionStatsProvider = Provider<NightSessionVm>((ref) {
  final live = ref.watch(liveSequenceStatsProvider);
  final lights = ref.watch(nightSessionLightRowsProvider);
  final session = ref.watch(sessionStateProvider);
  final remaining = ref.watch(
    sequenceProgressProvider.select((p) => p.estimatedRemainingSecs),
  );
  final freeBytes = ref.watch(nightCaptureFreeBytesProvider);
  final now = ref.watch(nightSessionNowProvider);

  final start = session.isActive ? session.startTime : live?.startTime;
  final elapsed =
      start == null || now.isBefore(start) ? null : now.difference(start);

  int? accepted;
  int? rejected;
  double? integration;
  if (live != null) {
    accepted = live.framesCaptured - live.framesRejected;
    rejected = live.framesRejected;
    integration = live.integrationSecs;
  } else if (lights.isNotEmpty) {
    final kept = lights.where((row) => row.isAccepted).toList();
    accepted = kept.length;
    rejected = lights.length - kept.length;
    integration = kept.fold<double>(0, (sum, r) => sum + r.exposureDuration);
  }

  // The disconnect log is not reactive; it is read again whenever the
  // frames, the clock or the run counters move, which is often enough for a
  // count.
  final dropouts = start == null
      ? null
      : ref.watch(usbDisconnectLogProvider).countSince(start);

  return NightSessionVm(
    frameCount: live?.framesCaptured ?? (lights.isEmpty ? null : lights.length),
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
          valueTone: rejected > 0 ? MetricTone.bad : MetricTone.neutral,
        ),
      if (integration != null)
        MetricVm(
          label: const NightText('nightSessionStatIntegration'),
          // Zero accepted seconds is a real count early in a run.
          value: integration > 0 ? nightDuration(integration) : '0m',
        ),
      if (remaining != null && remaining > 0)
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
          value: nightBytes(freeBytes),
        ),
      if (dropouts != null)
        MetricVm(
          label: const NightText('nightSessionStatDropouts'),
          value: '$dropouts',
          valueTone: dropouts > 0 ? MetricTone.warning : MetricTone.neutral,
        ),
    ],
  );
});
