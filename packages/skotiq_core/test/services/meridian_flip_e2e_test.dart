// E2E test for the meridian-flip disconnect safety guard
//.
//
// What this exercises end-to-end through real Riverpod providers:
//   1. The `meridianFlipDisconnectGuardProvider` StateNotifier wired into a
//      ProviderContainer with a real `mountStateProvider`.
//   2. While a flip is "executing", the mount transitions to `disconnected`.
//      The guard's `ref.listen` callback fires and must:
//        - reset `flipExecutionStateProvider` → `FlipExecutionState.aborted`
//        - clear `flipCurrentStepProvider`, `flipProgressProvider`,
//          `flipCurrentAttemptProvider`
//        - set `flipLastErrorProvider` to an actionable message
//   3. A second scenario: the mount disconnects while the flip is in
//      `idle` — guard must NOT modify state (no spurious aborts).
//   4. A third scenario: the mount disconnects while the flip is `retrying`
//      — guard must abort (both `executing` and `retrying` are in-progress).
//
// The Rust sequencer is deliberately not spun up here. The disconnect guard is
// a pure Dart Riverpod listener with one input (`mountStateProvider`) and five
// outputs (the flip-state providers). Driving it via a ProviderContainer with a
// mock backend hits every line of the guard code, the same surface an
// integration test against a live sequencer would exercise for this behaviour.
// `app_shell.dart` mounts the guard; the guard itself is the unit under test.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/models/meridian_flip_event.dart'
    show FlipStep;
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment/mount_state_provider.dart';
import 'package:skotiq_core/src/providers/meridian_flip_provider.dart';

/// Test backend that satisfies the surface used by `mountStateProvider`:
///   - `eventStream` (broadcast)
///   - `getMountStatus` (polling, returns a benign default)
///   - `dispose`
///
/// Everything else is mocktail's default. The mount-state notifier polls
/// `getMountStatus` every 2s when "connected", but we never set the state
/// to connected for long enough for the timer to fire — the test transitions
/// directly via `MountStateNotifier.setConnected()` and
/// `MountStateNotifier.setDisconnected()`.
class _MeridianFlipTestBackend extends Mock implements SkotiqBackend {
  final StreamController<SkotiqEvent> _events =
      StreamController<SkotiqEvent>.broadcast();
  final StreamController<Map<String, dynamic>> _polar =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<SkotiqEvent> get eventStream => _events.stream;

  @override
  Stream<Map<String, dynamic>> get polarAlignmentEvents => _polar.stream;

  @override
  void dispose() {
    if (!_events.isClosed) _events.close();
    if (!_polar.isClosed) _polar.close();
  }

  void closeStreams() => dispose();
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  group('Meridian flip disconnect guard E2E', () {
    late _MeridianFlipTestBackend backend;
    late ProviderContainer container;

    setUp(() {
      backend = _MeridianFlipTestBackend();
      container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, backend),
          ),
        ],
      );

      // Watch the guard so the StateNotifier comes online and registers its
      // `ref.listen<MountState>` subscription. In production this watch
      // happens in `app_shell.dart`.
      container.read(meridianFlipDisconnectGuardProvider);
    });

    tearDown(() {
      container.dispose();
      backend.closeStreams();
    });

    test(
      'disconnect during executing flip aborts and clears flip state',
      () async {
        // Bring the mount up — without a deviceId the notifier stays in its
        // default state, so we drive it directly via the public notifier API.
        // `setConnecting`/`setConnected` is what `MountStateNotifier.connect()`
        // calls internally when a real device service connects.
        final mountNotifier = container.read(mountStateProvider.notifier);
        mountNotifier.setConnecting('mount-test');
        mountNotifier.setConnected();
        expect(
          container.read(mountStateProvider).connectionState,
          equals(DeviceConnectionState.connected),
        );

        // Pretend the sequencer has just scheduled a flip and the trigger
        // framework moved into the executing phase.
        container.read(flipExecutionStateProvider.notifier).state =
            FlipExecutionState.executing;
        container.read(flipCurrentStepProvider.notifier).state =
            FlipStep.slewingToTarget;
        container.read(flipProgressProvider.notifier).state = 35;
        container.read(flipCurrentAttemptProvider.notifier).state = 1;

        expect(
          container.read(flipExecutionStateProvider),
          equals(FlipExecutionState.executing),
        );

        // The mount drops mid-flip. In production this comes from a heartbeat
        // failure or transport disconnect — we drive it directly.
        mountNotifier.setDisconnected();

        // The guard reacts inside `ref.listen`, which schedules its callback
        // on the next microtask. Let one drain cycle complete before asserting.
        await Future<void>.value();
        await Future<void>.value();

        // Assertions: every output of the guard must have fired
        expect(
          container.read(flipExecutionStateProvider),
          equals(FlipExecutionState.aborted),
          reason:
              'flipExecutionStateProvider must transition executing→aborted '
              'when the mount disconnects mid-flip',
        );
        expect(container.read(flipCurrentStepProvider), isNull);
        expect(container.read(flipProgressProvider), equals(0));
        expect(container.read(flipCurrentAttemptProvider), equals(0));
        final errorMessage = container.read(flipLastErrorProvider);
        expect(errorMessage, isNotNull);
        expect(errorMessage!.toLowerCase(), contains('mount disconnected'));

        // The post-flip exposure must NOT proceed: the sequencer would observe
        // `flipExecutionStateProvider == aborted` (or check
        // `isFlipInProgressProvider == false` and the error) and refuse to
        // schedule the next imaging instruction. Both invariants verified:
        expect(container.read(isFlipInProgressProvider), isFalse);
        expect(
          container.read(flipExecutionStateProvider),
          isNot(equals(FlipExecutionState.executing)),
        );
        expect(
          container.read(flipExecutionStateProvider),
          isNot(equals(FlipExecutionState.retrying)),
        );
      },
    );

    test(
      'disconnect during retrying flip aborts and clears flip state',
      () async {
        final mountNotifier = container.read(mountStateProvider.notifier);
        mountNotifier.setConnecting('mount-test');
        mountNotifier.setConnected();

        container.read(flipExecutionStateProvider.notifier).state =
            FlipExecutionState.retrying;
        container.read(flipCurrentStepProvider.notifier).state =
            FlipStep.slewingToTarget;
        container.read(flipCurrentAttemptProvider.notifier).state = 2;

        mountNotifier.setDisconnected();
        await Future<void>.value();
        await Future<void>.value();

        expect(
          container.read(flipExecutionStateProvider),
          equals(FlipExecutionState.aborted),
          reason: 'retrying state must also trigger the disconnect-guard reset',
        );
        expect(container.read(flipCurrentStepProvider), isNull);
        expect(container.read(flipCurrentAttemptProvider), equals(0));
      },
    );

    test(
      'disconnect while idle does NOT abort (no false positive on cold mount)',
      () async {
        final mountNotifier = container.read(mountStateProvider.notifier);
        mountNotifier.setConnecting('mount-test');
        mountNotifier.setConnected();

        // Flip state is the default `idle` — no flip is in progress.
        expect(
          container.read(flipExecutionStateProvider),
          equals(FlipExecutionState.idle),
        );

        mountNotifier.setDisconnected();
        await Future<void>.value();
        await Future<void>.value();

        // The guard must leave state untouched: a mount disconnect when no
        // flip is in progress is not an abort condition.
        expect(
          container.read(flipExecutionStateProvider),
          equals(FlipExecutionState.idle),
        );
        expect(container.read(flipLastErrorProvider), isNull);
      },
    );
  });
}
