// A connect that did not succeed is not a lost device.
//
// The native side publishes the same equipment `Error` for both, and every
// one was told as "Equipment disconnected": a focuser that had no power at
// startup raised that notice (and its phone push) beside the two that said
// it had not connected.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'recording_router.dart';

SkotiqEvent _equipment(String eventType, {String? message}) => SkotiqEvent(
  timestamp: DateTime.now().millisecondsSinceEpoch,
  severity: eventType == 'Error' ? EventSeverity.error : EventSeverity.info,
  category: EventCategory.equipment,
  eventType: eventType,
  data: {
    'device_type': 'focuser',
    'device_id': 'sim_focuser_1',
    if (message != null) 'message': message,
  },
);

Future<void> _settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late NotificationRouter router;
  late RecordingTransport inApp;
  late StreamController<SkotiqEvent> events;

  List<NotificationMessage> disconnects() => [
    for (final message in inApp.sent)
      if (message.category == NotificationCategory.equipmentDisconnected)
        message,
  ];

  setUp(() {
    final recording = recordingRouter();
    router = recording.router;
    inApp = recording.transports[NotificationTransportKind.inApp]!;
    events = StreamController<SkotiqEvent>();
    router.attachEventStream(events.stream);
  });

  tearDown(() async {
    await events.close();
    await router.dispose();
  });

  test('an error while a device is connecting is not told as a disconnect',
      () async {
    events
      ..add(_equipment('Connecting'))
      ..add(_equipment('Error', message: 'no power'));
    await _settle();
    expect(disconnects(), isEmpty);
  });

  test('an error on a device that had connected is told as a disconnect',
      () async {
    events
      ..add(_equipment('Connecting'))
      ..add(_equipment('Connected'))
      ..add(_equipment('Error', message: 'USB cable unplugged'));
    await _settle();
    expect(disconnects(), hasLength(1));
  });

  test('an error on a device never seen connecting is told as a disconnect',
      () async {
    events.add(_equipment('Error', message: 'USB cable unplugged'));
    await _settle();
    expect(disconnects(), hasLength(1));
  });

  test('a lost device is told once, not again for each failed reconnect',
      () async {
    events
      ..add(_equipment('Connected'))
      ..add(_equipment('Error', message: 'USB cable unplugged'))
      ..add(_equipment('Connecting'))
      ..add(_equipment('Error', message: 'device not found'));
    await _settle();
    expect(disconnects(), hasLength(1));
  });
}
