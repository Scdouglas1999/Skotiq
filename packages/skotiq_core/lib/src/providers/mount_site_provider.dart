import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/mount_site_reconciliation.dart';
import '../services/mount_site/mount_site_reconciler.dart';
import 'backend_provider.dart';
import 'settings_provider.dart';

/// Wires the reconciler to the live backend and the settings store.
///
/// The "write the computer's location" callback goes through the batched
/// settings setter so adopting a mount's site is one persisted write rather
/// than three that could half-apply.
final mountSiteReconcilerProvider = Provider<MountSiteReconciler>((ref) {
  final backend = ref.watch(backendProvider);
  return MountSiteReconciler(
    backend: backend,
    writeComputerLocation: (latitude, longitude, elevation) async {
      await ref
          .read(appSettingsProvider.notifier)
          .updateLocation(
            latitude: latitude,
            longitude: longitude,
            elevation: elevation,
          );
    },
  );
});

/// The comparison waiting for an operator decision, if any.
///
/// Core raises it; the app layer decides how to show it. Holding it as state
/// rather than pushing a dialog from here keeps `skotiq_core` free of UI
/// and lets a headless host ignore it entirely.
class PendingMountSiteReconciliation
    extends StateNotifier<MountSiteReconciliation?> {
  PendingMountSiteReconciliation() : super(null);

  void raise(MountSiteReconciliation comparison) => state = comparison;

  /// Clear the prompt. Called after the operator chooses, dismisses, or the
  /// mount disconnects underneath it.
  void clear() => state = null;

  /// Drop the prompt if it belongs to [deviceId] — used when that mount goes
  /// away, so a card cannot outlive the device it is asking about.
  void clearFor(String deviceId) {
    if (state?.deviceId == deviceId) state = null;
  }
}

final pendingMountSiteReconciliationProvider =
    StateNotifierProvider<
      PendingMountSiteReconciliation,
      MountSiteReconciliation?
    >((ref) => PendingMountSiteReconciliation());
