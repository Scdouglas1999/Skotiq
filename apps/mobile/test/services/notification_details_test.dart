import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_mobile/services/notification_service.dart';

/// The eighteen notify* methods share six presentations. Two of them look like
/// near-duplicates of a sibling and are not: `criticalAlarm` asks Android to
/// treat the post as an alarm, and `infoPassive` is deliberately quieter than
/// the rest of the info channel. Pin both so a future dedup pass cannot fold
/// them away silently.
void main() {
  const details = MobileNotificationService.detailsByName;

  AndroidNotificationDetails android(String name) => details[name]!.android!;
  DarwinNotificationDetails darwin(String name) => details[name]!.iOS!;

  test('every presentation targets a declared channel', () {
    expect(details.keys, hasLength(6));
    expect(
      details.values.map((d) => d.android!.channelId).toSet(),
      {'skotiq_sequence', 'skotiq_warnings', 'skotiq_info', 'skotiq_critical'},
      reason: 'a presentation must not invent a channel that is never created',
    );
    for (final entry in details.entries) {
      expect(
        entry.value.android!.icon,
        '@mipmap/ic_launcher',
        reason: '${entry.key} must carry the app icon',
      );
    }
  });

  test('sequence and warning posts are high priority and audible', () {
    for (final name in ['sequence', 'warning']) {
      expect(android(name).importance, Importance.high, reason: name);
      expect(android(name).priority, Priority.high, reason: name);
      expect(android(name).playSound, isTrue, reason: name);
      expect(android(name).enableVibration, isTrue, reason: name);
      expect(darwin(name).presentSound, isTrue, reason: name);
    }
  });

  test('info posts are silent and do not badge', () {
    expect(android('info').importance, Importance.defaultImportance);
    expect(android('info').priority, Priority.defaultPriority);
    expect(android('info').playSound, isFalse);
    expect(darwin('info').presentBadge, isFalse);
    expect(darwin('info').presentSound, isFalse);
  });

  test('critical posts interrupt Do Not Disturb', () {
    for (final name in ['critical', 'criticalAlarm']) {
      expect(android(name).importance, Importance.max, reason: name);
      expect(android(name).priority, Priority.max, reason: name);
      expect(
        darwin(name).interruptionLevel,
        InterruptionLevel.critical,
        reason: name,
      );
    }
  });

  test('only the safety alert is categorised as an alarm', () {
    expect(
      android('criticalAlarm').category,
      AndroidNotificationCategory.alarm,
    );
    expect(android('critical').category, isNull);
  });

  test('the passive info variant stays quieter than the base info post', () {
    expect(android('infoPassive').channelId, android('info').channelId);
    expect(android('infoPassive').priority, Priority.low);
    expect(darwin('infoPassive').interruptionLevel, InterruptionLevel.passive);
    expect(darwin('info').interruptionLevel, isNot(InterruptionLevel.passive));
  });
}
