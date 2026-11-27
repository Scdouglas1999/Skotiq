// What a linked phone shows for one happening that it alerts on directly from
// the host's events and that the host also pushes, in either order: each
// posted notification as `<id> <channel> <title>`. A post that reuses an id
// replaces the notification under that id; a push under a fresh id stacks.
//
// The in-app notices of every role are pinned in
// packages/skotiq_app/test/notifications/notice_routing_by_role_test.dart.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skotiq_core/backend.dart' show wireEventFromTyped;
import 'package:skotiq_core/bridge_events.dart' as sk;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_mobile/services/mobile_event_notifier.dart';
import 'package:skotiq_mobile/services/mobile_preferences.dart';
import 'package:skotiq_mobile/services/notification_service.dart';

const _channel = MethodChannel('dexterous.com/flutter/local_notifications');

SkotiqEvent _fromHost(
  sk.EventCategory category,
  sk.EventPayload payload,
  sk.EventSeverity severity,
) {
  final wire = wireEventFromTyped(
    sk.SkotiqEvent(
      eventId: BigInt.zero,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      severity: severity,
      category: category,
      payload: payload,
    ),
  );
  return SkotiqEvent.fromWireJson(
    jsonDecode(jsonEncode(wire.toJson())) as Map<String, dynamic>,
  );
}

SkotiqEvent _seq(sk.SequencerEvent event, sk.EventSeverity severity) =>
    _fromHost(
      sk.EventCategory.sequencer,
      sk.EventPayload.sequencer(event),
      severity,
    );

/// The event the phone alerts on, or null for a happening it learns of only
/// from the host's push.
final Map<NotificationCategory, SkotiqEvent? Function()> _happenings = {
  NotificationCategory.sequenceCompleted: () => null,
  NotificationCategory.sequenceFailed: () => _seq(
    const sk.SequencerEvent.failed(error: 'Mount did not answer'),
    sk.EventSeverity.error,
  ),
  NotificationCategory.recoveryGaveUp: () => _seq(
    const sk.SequencerEvent.recoveryGaveUp(
      startedAtIso: '2026-11-26T02:00:00Z',
      causeKind: 'guiding_lost',
      attemptCount: 3,
      maxAttempts: 3,
      retryIntervalSecs: 30,
      maxDurationSecs: 600,
      phase: 'GaveUp',
      abortedByUser: false,
    ),
    sk.EventSeverity.critical,
  ),
  NotificationCategory.targetCompleted: () => _seq(
    const sk.SequencerEvent.targetCompleted(targetName: 'M31'),
    sk.EventSeverity.info,
  ),
  NotificationCategory.meridianFlipPerformed: () => _seq(
    const sk.SequencerEvent.meridianFlipOutcome(
      outcome: sk.FlipOutcome.success,
      targetName: 'M31',
      newPierSide: 'West',
      durationSecs: 90,
      attempts: 1,
      failedSteps: [],
    ),
    sk.EventSeverity.info,
  ),
  NotificationCategory.autofocusContinued: () => _seq(
    const sk.SequencerEvent.decisionLogged(
      timestampIso: '2026-11-26T02:00:00Z',
      category: 'system_event',
      summary: 'Autofocus did not converge',
      detailsJson: '{}',
      notice: sk.SequencerNotice.autofocusContinued(),
    ),
    sk.EventSeverity.info,
  ),
  NotificationCategory.autofocusFailed: () => _fromHost(
    sk.EventCategory.equipment,
    sk.EventPayload.equipment(
      sk.EquipmentEvent.propertyChanged(
        deviceType: 'focuser',
        deviceId: 'sim_focuser',
        property: 'AutofocusFinished',
        value: jsonEncode({'status': 'Failure', 'in_run': false}),
      ),
    ),
    sk.EventSeverity.info,
  ),
  NotificationCategory.exposureFailed: () => _fromHost(
    sk.EventCategory.imaging,
    const sk.EventPayload.imaging(
      sk.ImagingEvent.exposureFailed(error: 'Readout timed out'),
    ),
    sk.EventSeverity.error,
  ),
  NotificationCategory.guidingLost: () => _fromHost(
    sk.EventCategory.guiding,
    const sk.EventPayload.guiding(sk.GuidingEvent.disconnected()),
    sk.EventSeverity.warning,
  ),
  NotificationCategory.weatherUnsafe: () => _fromHost(
    sk.EventCategory.safety,
    const sk.EventPayload.safety(
      sk.SafetyEvent.weatherUnsafe(reason: 'High wind'),
    ),
    sk.EventSeverity.error,
  ),
  NotificationCategory.mountFault: () => _fromHost(
    sk.EventCategory.safety,
    const sk.EventPayload.safety(
      sk.SafetyEvent.mountMotionFault(
        deviceId: 'sim_mount',
        kind: 'runaway',
        message: 'The mount moved with no command.',
      ),
    ),
    sk.EventSeverity.critical,
  ),
  NotificationCategory.diskSpaceLow: () => _fromHost(
    sk.EventCategory.system,
    const sk.EventPayload.system(sk.SystemEvent.diskSpaceLow(availableGb: 1.5)),
    sk.EventSeverity.error,
  ),
  NotificationCategory.equipmentDisconnected: () => _fromHost(
    sk.EventCategory.equipment,
    const sk.EventPayload.equipment(
      sk.EquipmentEvent.error(
        deviceType: 'Camera',
        deviceId: 'sim_camera',
        message: 'Device not responding',
      ),
    ),
    sk.EventSeverity.error,
  ),
};

enum _Order { eventFirst, pushFirst }

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final posts = <String>[];
  setUp(() {
    posts.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'show') {
            final args = Map<String, Object?>.from(call.arguments as Map);
            final id = args['id']! as int;
            final specifics = args['platformSpecifics'] as Map?;
            // A push under a fresh id is told apart from the fixed ids by
            // range; the counter itself depends on test order.
            posts.add(
              '${id >= 200 ? 'fresh' : '$id'} '
              '${specifics?['channelId']} ${args['title']}',
            );
          }
          return null;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  Future<List<String>> postsFor(
    NotificationCategory category,
    _Order order,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final events = StreamController<SkotiqEvent>.broadcast();
    addTearDown(events.close);
    final service = MobileNotificationService();
    final notifier = MobileEventNotifier(
      eventStream: events.stream,
      preferences: MobilePreferences(prefs),
      notificationService: service,
    )..start();
    addTearDown(notifier.stop);

    final push = <String, dynamic>{
      'title': 'Host: ${category.label}',
      'body': 'From the host',
      'priority': 'critical',
      'eventType': category.storageKey,
    };
    Future<void> deliverPush() async {
      // What the push listener does with a push from the host.
      notifier.recordPushReceived(category.storageKey);
      await service.notifyPush(push);
    }

    Future<void> deliverEvent() async {
      final event = _happenings[category]!();
      if (event == null) return;
      events.add(event);
      await pumpEventQueue();
    }

    if (order == _Order.eventFirst) {
      await deliverEvent();
      await deliverPush();
    } else {
      await deliverPush();
      await deliverEvent();
    }
    await pumpEventQueue();
    return List.of(posts);
  }

  for (final category in _happenings.keys) {
    for (final order in _Order.values) {
      final key = '${category.name} ${order.name}';
      test(key, () async {
        final got = await postsFor(category, order);
        if (_printTable) {
          // ignore: avoid_print
          print("TABLE  '$key': ${jsonEncode(got)},");
          return;
        }
        expect(got, _expected[key], reason: key);
      });
    }
  }
}

/// Set to print the observed table instead of checking it.
const bool _printTable = bool.fromEnvironment('NOTICE_TABLE_PRINT');

const _expected = <String, List<String>>{
  'sequenceCompleted eventFirst': ['100 skotiq_push Host: Sequence completed'],
  'sequenceCompleted pushFirst': ['100 skotiq_push Host: Sequence completed'],
  'sequenceFailed eventFirst': [
    '101 skotiq_sequence Sequence failed',
    '101 skotiq_push Host: Sequence failed',
  ],
  'sequenceFailed pushFirst': ['101 skotiq_push Host: Sequence failed'],
  'recoveryGaveUp eventFirst': [
    '101 skotiq_sequence Recovery gave up',
    'fresh skotiq_push Host: Recovery gave up',
  ],
  'recoveryGaveUp pushFirst': ['fresh skotiq_push Host: Recovery gave up'],
  'targetCompleted eventFirst': [
    '110 skotiq_info Target Complete',
    'fresh skotiq_push Host: Target completed',
  ],
  'targetCompleted pushFirst': ['fresh skotiq_push Host: Target completed'],
  'meridianFlipPerformed eventFirst': [
    '102 skotiq_info Meridian Flip',
    'fresh skotiq_push Host: Meridian flip performed',
  ],
  'meridianFlipPerformed pushFirst': [
    'fresh skotiq_push Host: Meridian flip performed',
  ],
  'autofocusContinued eventFirst': [
    '108 skotiq_warnings Autofocus Failed',
    'fresh skotiq_push Host: Autofocus continued',
  ],
  'autofocusContinued pushFirst': [
    'fresh skotiq_push Host: Autofocus continued',
  ],
  'autofocusFailed eventFirst': [
    '108 skotiq_warnings Autofocus Failed',
    'fresh skotiq_push Host: Autofocus failed',
  ],
  'autofocusFailed pushFirst': ['fresh skotiq_push Host: Autofocus failed'],
  'exposureFailed eventFirst': [
    '107 skotiq_warnings Exposure Failed',
    'fresh skotiq_push Host: Exposure failed',
  ],
  'exposureFailed pushFirst': ['fresh skotiq_push Host: Exposure failed'],
  'guidingLost eventFirst': [
    '106 skotiq_critical Guiding Lost',
    'fresh skotiq_push Host: Guiding lost',
  ],
  'guidingLost pushFirst': ['fresh skotiq_push Host: Guiding lost'],
  'weatherUnsafe eventFirst': [
    '105 skotiq_critical Weather unsafe',
    'fresh skotiq_push Host: Weather unsafe',
  ],
  'weatherUnsafe pushFirst': ['fresh skotiq_push Host: Weather unsafe'],
  'mountFault eventFirst': [
    '117 skotiq_critical Mount fault',
    'fresh skotiq_push Host: Mount fault',
  ],
  'mountFault pushFirst': ['fresh skotiq_push Host: Mount fault'],
  'diskSpaceLow eventFirst': [
    '103 skotiq_warnings Low Disk Space',
    'fresh skotiq_push Host: Disk space low',
  ],
  'diskSpaceLow pushFirst': ['fresh skotiq_push Host: Disk space low'],
  'equipmentDisconnected eventFirst': [
    '109 skotiq_critical Device Disconnected',
    'fresh skotiq_push Host: Equipment disconnected',
  ],
  'equipmentDisconnected pushFirst': [
    'fresh skotiq_push Host: Equipment disconnected',
  ],
};
