import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'sequence/sequencer_defaults.dart' show sequencerDefaultsProvider;
import '../services/live_stacking_broadcast_service.dart';

/// Provider for the broadcast service. Singleton per app — the HTTP
/// handler reads from this every request.
final liveStackingBroadcastServiceProvider =
    Provider<LiveStackingBroadcastService>((ref) {
      final svc = LiveStackingBroadcastService(ref);
      ref.onDispose(svc.dispose);
      return svc;
    });

/// Bridges the "Disable broadcast everywhere" toggle in
/// Sequencer Settings (`SequencerDefaults.livestackingDisableEverywhere`)
/// into the live broadcast service. Watched once at app start by the
/// shell so the kill switch:
///
///   * applies on cold start (a process that started with the switch on
///     comes up disabled, not in a brief "armed" window), and
///   * propagates live: flipping the toggle during an active broadcast
///     force-deactivates the session.
final liveStackingKillSwitchBridgeProvider = Provider<void>((ref) {
  final svc = ref.watch(liveStackingBroadcastServiceProvider);
  // Initial seed: read once, apply.
  final initial = ref.watch(sequencerDefaultsProvider);
  svc.setKillSwitch(initial.livestackingDisableEverywhere);
  // No explicit listener needed — `ref.watch` rebuilds this provider
  // whenever the kill-switch field changes, which re-runs the setter
  // above. The Provider re-evaluation is cheap because setKillSwitch
  // is a no-op when the value hasn't changed.
});
