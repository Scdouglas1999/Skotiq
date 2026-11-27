// The assistant's status cache is a dynamic shortcut on Android, and every
// write of it is a ShortcutService save. It is written when what the
// assistant would say changes, not on every second of a run.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_mobile/services/voice_control_lifecycle_provider.dart';
import 'package:skotiq_mobile/services/voice_control_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/voice_status_publish');

  late List<String> calls;
  late VoiceControlLifecycleController controller;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return null;
        });
    final service = VoiceControlService(
      channel: channel,
      skipPlatformGuard: true,
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final provider = Provider(
      (ref) => VoiceControlLifecycleController(ref, service: service),
    );
    controller = container.read(provider);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  SequenceStatusSnapshot at(int elapsed, {int done = 3, int eta = 3600}) =>
      SequenceStatusSnapshot(
        sequenceId: '7',
        sequenceName: 'M74 Plan',
        targetName: 'M74',
        executionState: 'running',
        framesCompleted: done,
        framesTotal: 75,
        elapsedSeconds: elapsed,
        estimatedRemainingSeconds: eta - elapsed,
        currentFilter: 'L',
        currentNodeName: 'Smart Exposure',
        updatedAtMillis: 1000 * elapsed,
      );

  test('seconds ticking by in one exposure write the cache once', () async {
    for (var second = 0; second < 10; second++) {
      await controller.publishForTest(at(second));
    }
    expect(calls, ['publishStatus']);
  });

  test('a new frame, a new minute of ETA or a new state is written', () async {
    await controller.publishForTest(at(0));
    await controller.publishForTest(at(1, done: 4));
    await controller.publishForTest(at(90, done: 4));
    expect(calls, ['publishStatus', 'publishStatus', 'publishStatus']);
  });

  test('clearing an already clear cache writes nothing', () async {
    await controller.publishForTest(null);
    await controller.publishForTest(null);
    expect(calls, ['clearStatus']);
  });
}
