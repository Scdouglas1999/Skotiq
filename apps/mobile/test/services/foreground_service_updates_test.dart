// Every update of the foreground service makes Android release and take the
// service's wake and WiFi locks again, so the ongoing notification is updated
// only when its words change, not on every progress tick.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_mobile/services/foreground_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_foreground_task/methods');

  test(
    'a progress tick that leaves the line unchanged updates nothing',
    () async {
      final updates = <Object?>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'updateService') updates.add(call.arguments);
            return true;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final service = ImagingForegroundService()..setRunning(true);
      addTearDown(() => service.setRunning(false));
      const running = SequenceExecutionState.running;
      SequenceProgress tick(double elapsed, {int done = 3}) => SequenceProgress(
        currentNodeName: 'Smart Exposure',
        currentFilter: 'L',
        completedExposures: done,
        totalExposures: 75,
        elapsedSecs: elapsed,
      );

      for (var second = 0; second < 5; second++) {
        service.updateProgress(running, tick(second.toDouble()));
        await Future<void>.delayed(Duration.zero);
      }
      expect(updates, hasLength(1));

      service.updateProgress(running, tick(6, done: 4));
      await Future<void>.delayed(Duration.zero);
      expect(updates, hasLength(2));
    },
  );
}
