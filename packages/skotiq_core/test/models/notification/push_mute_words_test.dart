// A phone mutes pushes by event type; the host sends a notification
// category's name as that type.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/notification/notification_categories.dart';
import 'package:skotiq_remote_protocol/host.dart' show DevicePushPreferences;

void main() {
  test('every event type a phone can mute names a notification category', () {
    final categories = {
      for (final c in NotificationCategory.values) c.storageKey,
    };
    for (final type in DevicePushPreferences.mutableEventTypes) {
      expect(categories, contains(type));
    }
  });
}
