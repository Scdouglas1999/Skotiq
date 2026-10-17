import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  test('test push fails when no transport is listening', () async {
    final service = PushNotificationService();
    addTearDown(service.dispose);

    await expectLater(
      service.sendTestNotification(),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'test push reports success only after it enters a live transport',
    () async {
      final service = PushNotificationService();
      addTearDown(service.dispose);
      final received = service.notifications.first;

      await service.sendTestNotification();

      expect((await received).eventType, 'Test');
    },
  );

  test('test push fails while the master push gate is disabled', () async {
    final service = PushNotificationService(
      config: const PushNotificationConfig(enabled: false),
    );
    addTearDown(service.dispose);
    final subscription = service.notifications.listen((_) {});
    addTearDown(subscription.cancel);

    await expectLater(
      service.sendTestNotification(),
      throwsA(isA<StateError>()),
    );
  });
}
