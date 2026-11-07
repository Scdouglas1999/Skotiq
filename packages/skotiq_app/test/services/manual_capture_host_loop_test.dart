import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/services/manual_capture_controller.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

// The manual Loop runs on the imaging host whichever window starts it. On a
// linked client, Loop and Stop are commands to the host and the loop state is
// the host's, so both windows show one loop with Stop.

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockNetworkBackend backend;
  late ProviderContainer client;

  setUp(() {
    backend = _MockNetworkBackend();
    when(
      () => backend.connectionState,
    ).thenReturn(BackendConnectionState.connected);
    when(() => backend.isAuthTokenRejected).thenReturn(false);
    when(
      () => backend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(() => backend.startHostManualLoop(any())).thenAnswer((_) async {});
    when(() => backend.stopHostManualLoop()).thenAnswer((_) async {});
    client = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
  });

  tearDown(() => client.dispose());

  void hostSays(ManualLoopStatus status) =>
      client.read(manualLoopStatusProvider.notifier).state = status;

  test('Loop on a client asks the host and lasts as long as the host loop',
      () async {
    final controller = client.read(manualCaptureControllerProvider.notifier);
    final errors = <String>[];
    var ended = false;
    final run = controller.loop(onError: errors.add).then((_) => ended = true);
    await pumpEventQueue();

    final request = verify(() => backend.startHostManualLoop(captureAny()))
        .captured
        .single as Map<String, dynamic>;
    expect(manualLoopSettingsFromJson(request).exposureTime, isPositive);

    hostSays(const ManualLoopStatus(looping: true, frames: 1));
    expect(client.read(manualCaptureControllerProvider).isLooping, isTrue);
    hostSays(
      const ManualLoopStatus(
        looping: true,
        frames: 2,
        lastError: 'Camera timed out',
        errorCount: 1,
      ),
    );
    await pumpEventQueue();
    expect(ended, isFalse);
    expect(errors, ['Camera timed out']);

    hostSays(const ManualLoopStatus(frames: 2, errorCount: 1));
    await run;
    expect(client.read(manualCaptureControllerProvider).isLooping, isFalse);
  });

  test('Stop on a client stops a loop the host started', () async {
    hostSays(const ManualLoopStatus(looping: true, frames: 4));
    final state = client.read(manualCaptureControllerProvider);
    expect(state.isLooping, isTrue);
    expect(state.loopFrames, 4);

    client.read(manualCaptureControllerProvider.notifier).stop();
    await pumpEventQueue();
    verify(() => backend.stopHostManualLoop()).called(1);
  });

  test('a host that refuses the loop ends it here with its reason', () async {
    when(() => backend.startHostManualLoop(any())).thenThrow(
      Exception('A snapshot or loop is already running on the host.'),
    );
    final errors = <String>[];
    await client
        .read(manualCaptureControllerProvider.notifier)
        .loop(onError: errors.add);
    expect(errors.single, contains('already running'));
    expect(client.read(manualCaptureControllerProvider).isLooping, isFalse);
  });
}
