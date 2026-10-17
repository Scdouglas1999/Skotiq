import 'package:flutter/widgets.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Shared formatting for observatory devices (dome / cover-calibrator /
/// switch). Single source of truth so the inline equipment telemetry strip
/// and the dedicated Observatory cockpit panel render identical labels and
/// colours. Mirrors the camera/mount helpers in the telemetry strip.

String observatoryDomeShutterLabel(DomeState dome) {
  switch (dome.shutterStatus) {
    case ShutterStatus.open:
      return 'Open';
    case ShutterStatus.closed:
      return 'Closed';
    case ShutterStatus.opening:
      return 'Opening';
    case ShutterStatus.closing:
      return 'Closing';
    case ShutterStatus.error:
      return 'Error';
    case ShutterStatus.unknown:
      return 'Unknown';
  }
}

String observatoryDomeStatusText(DomeState dome) {
  if (dome.isSlewing) return 'Slewing';
  if (dome.isParked) return 'Parked';
  return observatoryDomeShutterLabel(dome);
}

Color observatoryDomeShutterColor(DomeState dome, SkotiqColors colors) {
  switch (dome.shutterStatus) {
    case ShutterStatus.open:
      return colors.success;
    case ShutterStatus.opening:
    case ShutterStatus.closing:
      return colors.warning;
    case ShutterStatus.closed:
      return colors.textSecondary;
    case ShutterStatus.error:
      return colors.error;
    case ShutterStatus.unknown:
      return colors.textMuted;
  }
}

String observatoryCoverStatusLabel(CoverStatus status) {
  switch (status) {
    case CoverStatus.open:
      return 'Open';
    case CoverStatus.closed:
      return 'Closed';
    case CoverStatus.moving:
      return 'Moving';
    case CoverStatus.notPresent:
      return 'Not present';
    case CoverStatus.error:
      return 'Error';
    case CoverStatus.unknown:
      return 'Unknown';
  }
}

Color observatoryCoverStatusColor(CoverStatus status, SkotiqColors colors) {
  switch (status) {
    case CoverStatus.open:
      return colors.success;
    case CoverStatus.moving:
      return colors.warning;
    case CoverStatus.closed:
      return colors.textSecondary;
    case CoverStatus.error:
      return colors.error;
    case CoverStatus.notPresent:
    case CoverStatus.unknown:
      return colors.textMuted;
  }
}

String observatoryCalibratorStatusLabel(CalibratorStatus status) {
  switch (status) {
    case CalibratorStatus.ready:
      return 'On';
    case CalibratorStatus.off:
      return 'Off';
    case CalibratorStatus.notReady:
      return 'Warming';
    case CalibratorStatus.notPresent:
      return 'Not present';
    case CalibratorStatus.error:
      return 'Error';
    case CalibratorStatus.unknown:
      return 'Unknown';
  }
}

Color observatoryCalibratorStatusColor(
    CalibratorStatus status, SkotiqColors colors) {
  switch (status) {
    case CalibratorStatus.ready:
      return colors.success;
    case CalibratorStatus.notReady:
      return colors.warning;
    case CalibratorStatus.off:
      return colors.textSecondary;
    case CalibratorStatus.error:
      return colors.error;
    case CalibratorStatus.notPresent:
    case CalibratorStatus.unknown:
      return colors.textMuted;
  }
}

String observatorySwitchSummaryLabel(SwitchState sw) {
  if (sw.channelStates.isEmpty) {
    return '${sw.channelCount} ch';
  }
  final onCount = sw.channelStates.where((s) => s).length;
  return '$onCount/${sw.channelStates.length} on';
}

/// One row's worth of switch-channel data: the channel label, whether it is
/// on, and (for callers that don't have their own row builder) a default
/// "+N more" overflow marker. Returned as plain data so each surface can
/// render it with its own row widget.
class ObservatorySwitchChannel {
  final String label;
  final bool on;

  /// True for the synthetic "+N more" overflow row (which has no on/off state).
  final bool isOverflow;

  const ObservatorySwitchChannel({
    required this.label,
    required this.on,
    this.isOverflow = false,
  });
}

/// Per-channel rows for the switch block. Names come from the driver snapshot
/// when present; otherwise a "Channel N" label keyed by index. Capped at
/// [maxRows] so a 16-channel power box doesn't run a card off-screen; the
/// remainder is summarised in a trailing overflow entry.
List<ObservatorySwitchChannel> observatorySwitchChannels(
  SwitchState sw, {
  int maxRows = 8,
}) {
  final states = sw.channelStates;
  if (states.isEmpty) return const [];
  final names = sw.channelNames;
  final rows = <ObservatorySwitchChannel>[];
  final shown = states.length > maxRows ? maxRows : states.length;
  for (var i = 0; i < shown; i++) {
    final label = (i < names.length && names[i].trim().isNotEmpty)
        ? names[i]
        : 'Channel ${i + 1}';
    rows.add(ObservatorySwitchChannel(label: label, on: states[i]));
  }
  if (states.length > maxRows) {
    rows.add(const ObservatorySwitchChannel(
      label: '…',
      on: false,
      isOverflow: true,
    ));
  }
  return rows;
}
