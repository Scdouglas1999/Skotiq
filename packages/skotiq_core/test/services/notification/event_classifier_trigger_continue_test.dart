// reverify RV-04: with rotating filters, master and client toasted "Trigger
// fired / Trigger Filter Change fired." on every frame; that trigger's action
// is to carry on, so it changed nothing.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/backend/event_types.dart';
import 'package:skotiq_core/src/models/notification/notification_categories.dart';
import 'package:skotiq_core/src/services/notification/event_classifier.dart';

SkotiqEvent _trigger(String name, String action) => SkotiqEvent(
  timestamp: DateTime.now().millisecondsSinceEpoch,
  severity: EventSeverity.info,
  category: EventCategory.sequencer,
  eventType: 'TriggerFired',
  data: {'trigger_id': 't', 'trigger_name': name, 'action': action},
);

void main() {
  test('a trigger that carries on is not a notification', () {
    expect(
      NotificationEventClassifier.classify(
        _trigger('Filter Change', 'Continue'),
      ),
      isNull,
    );
  });

  test('a trigger that acts is still notified', () {
    expect(
      NotificationEventClassifier.classify(
        _trigger('Dawn Approaching', 'ParkAndAbort'),
      )?.category,
      NotificationCategory.triggerFired,
    );
  });
}
