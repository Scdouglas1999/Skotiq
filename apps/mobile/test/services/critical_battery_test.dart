import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightshade_core/nightshade_core.dart';
import 'package:nightshade_mobile/services/mobile_sequence_hooks.dart';
import 'package:nightshade_mobile/services/notification_service.dart';

/// Owner decision 2026-10-06: only a risk to the hardware pauses or ends a
/// run by itself. The phone's own battery running low is not one: at 10% the
/// phone paused the run, including a desktop host's run it was only watching
/// over the network. It now tells the operator and leaves the run alone.
void main() {
  test('a critical phone battery never pauses the run', () async {
    final backend = _PauseRecordingBackend();
    final hooksProvider = Provider((ref) => MobileSequenceHooks(ref));
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(sequenceExecutionStateProvider.notifier).state =
        SequenceExecutionState.running;

    await container.read(hooksProvider).handleCriticalBatteryForTesting();

    expect(backend.pauses, 0);
  });

  test('the critical battery notice says the run keeps going', () {
    final message = lowBatteryMessage(9);
    expect(message, contains('9%'));
    expect(message, isNot(contains('paused')));
    expect(message, contains('keeps running'));
  });
}

class _PauseRecordingBackend extends DisconnectedBackend {
  int pauses = 0;

  @override
  Future<void> sequencerPause() async {
    pauses++;
  }
}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, NightshadeBackend backend) {
    state = backend;
  }
}
