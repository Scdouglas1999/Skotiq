import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

/// The session whose frames Tonight shows; null when nothing is imaging.
final nightSessionIdProvider = Provider<int?>((ref) {
  final local = ref.watch(
    sessionStateProvider.select((state) => state.dbSessionId),
  );
  if (local != null) return local;
  // endSession clears SessionState; the terminal result retains the exact
  // session identity so finished-night charts and integration stay visible.
  final terminal = ref.watch(shownTerminalRunResultProvider);
  if (terminal?.dbSessionId != null &&
      ref.watch(sequenceExecutionStateProvider).canStart) {
    return terminal!.isCalibration
        ? ref.watch(completedImagingRunProvider)?.result.dbSessionId
        : terminal.dbSessionId;
  }
  return ref.watch(watchedHostSessionIdProvider);
});
