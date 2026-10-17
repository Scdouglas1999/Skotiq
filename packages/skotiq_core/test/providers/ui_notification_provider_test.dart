import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/providers/ui_notification_provider.dart';

void main() {
  group('UiNotificationNotifier burst safety', () {
    test('retains at most maxRetained notifications under a flood', () {
      final notifier = UiNotificationNotifier();

      // Simulate the "Disconnect All" amplification: a synchronous burst of
      // far more notifications than the queue is allowed to retain.
      for (var i = 0; i < 5000; i++) {
        notifier.showError('device $i failed', title: 'Device Error');
      }

      expect(
        notifier.state.length,
        UiNotificationNotifier.maxRetained,
        reason: 'queue must be bounded so a burst cannot grow it without limit',
      );
    });

    test('keeps the most recent notifications, dropping the oldest', () {
      final notifier = UiNotificationNotifier();

      for (var i = 0; i < UiNotificationNotifier.maxRetained + 5; i++) {
        notifier.showInfo('message $i');
      }

      final messages = notifier.state.map((n) => n.message).toList();
      // The first 5 (message 0..4) must have been trimmed from the front.
      expect(messages.first, 'message 5');
      expect(
        messages.last,
        'message ${UiNotificationNotifier.maxRetained + 4}',
      );
    });

    test('assigns a unique id to every notification, even within one ms', () {
      final notifier = UiNotificationNotifier();

      for (var i = 0; i < UiNotificationNotifier.maxRetained; i++) {
        notifier.showWarning('w $i');
      }

      final ids = notifier.state.map((n) => n.id).toSet();
      expect(
        ids.length,
        notifier.state.length,
        reason:
            'ids must be unique so ValueKey/dismiss-by-id never conflate '
            'two burst entries',
      );
    });

    test('dismiss removes only the targeted notification', () {
      final notifier = UiNotificationNotifier();
      notifier.showError('a');
      notifier.showError('b');
      final targetId = notifier.state.first.id;

      notifier.dismiss(targetId);

      expect(notifier.state.any((n) => n.id == targetId), isFalse);
      expect(notifier.state.length, 1);
    });
  });
}
