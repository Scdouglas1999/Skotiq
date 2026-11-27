import 'package:flutter/material.dart';
import 'package:skotiq_core/providers.dart' show Clock, ClockTimeOfDay;

/// Asks for a step's time of day on [clock] and returns the next instant at
/// that time, or null when the operator cancels. The picker starts at
/// [initial], or at now when there is none.
Future<DateTime?> pickStepTimeOfDay(
  BuildContext context,
  Clock clock, {
  DateTime? initial,
}) async {
  final shown = clock.wallClockOf(initial ?? clock.nowUtc());
  final picked = await showTimePicker(
    context: context,
    initialTime: TimeOfDay(hour: shown.hour, minute: shown.minute),
  );
  if (picked == null) return null;
  return clock.nextTimeOfDay(picked.hour, picked.minute);
}
