// A native event stream that cannot be opened or ends while the backend is in
// use leaves the host with no device, guiding or sequence events for the rest
// of the night. That is logged and reported once; an error on the stream is
// logged and still reaches the listeners.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/src/backend/ffi_backend.dart';
import 'package:skotiq_core/src/models/backend/event_types.dart';
import 'package:skotiq_core/src/providers/native_events_lost_notice.dart';
import 'package:skotiq_core/src/providers/ui_notification_provider.dart';
import 'package:skotiq_core/src/services/host_mutation_event_hub.dart';
import 'package:skotiq_core/utils.dart';

import '../harness/captured_log.dart';

void main() {
  late LoggingService appLog;
  late StreamController<bridge.SkotiqEvent> native;
  late List<String> lost;

  setUp(() async {
    appLog = await captureAppLog();
    native = StreamController<bridge.SkotiqEvent>();
    lost = [];
  });

  FfiBackend backendOn(Stream<bridge.SkotiqEvent> Function() events) {
    final backend = FfiBackend(nativeEvents: events, onEventsLost: lost.add);
    addTearDown(backend.dispose);
    return backend;
  }

  List<String> errorsLogged() => logFrom(
    appLog,
    'FfiBackend',
  ).where((e) => e.level == LogLevel.error).map((e) => e.message).toList();

  test('a stream that ends while in use is logged and reported once', () async {
    final backend = backendOn(() => native.stream);
    var listenerSawDone = false;
    backend.eventStream.listen((_) {}, onDone: () => listenerSawDone = true);

    await native.close();
    await Future<void>.delayed(Duration.zero);

    expect(listenerSawDone, isTrue);
    expect(lost, ['the native event stream ended']);
    expect(errorsLogged(), ['The native event stream ended']);
  });

  test('a stream that cannot be opened is logged and reported', () async {
    final backend = backendOn(() => throw StateError('RustLib not ready'));
    backend.eventStream.listen((_) {});
    await Future<void>.delayed(Duration.zero);

    expect(lost, hasLength(1));
    expect(lost.single, contains('could not be opened'));
    expect(lost.single, contains('RustLib not ready'));
    expect(
      errorsLogged().single,
      startsWith('Failed to get the native event stream'),
    );
  });

  test('an error on the stream is logged and passed on', () async {
    final backend = backendOn(() => native.stream);
    final seen = <Object>[];
    backend.eventStream.listen((_) {}, onError: (Object e) => seen.add(e));

    native.addError(StateError('decode failed'));
    await Future<void>.delayed(Duration.zero);

    expect(seen, hasLength(1));
    expect(lost, isEmpty);
    expect(
      errorsLogged().single,
      contains('The native event stream reported an error'),
    );
    expect(errorsLogged().single, contains('decode failed'));
  });

  test('a report that throws is logged and the stream still closes', () async {
    final backend = FfiBackend(
      nativeEvents: () => native.stream,
      onEventsLost: (_) => throw StateError('container disposed'),
    );
    addTearDown(backend.dispose);
    var listenerSawDone = false;
    backend.eventStream.listen((_) {}, onDone: () => listenerSawDone = true);

    await native.close();
    await Future<void>.delayed(Duration.zero);

    expect(listenerSawDone, isTrue);
    expect(errorsLogged(), [
      'The native event stream ended',
      'The lost native event stream could not be reported: '
          'Bad state: container disposed',
    ]);
  });

  test('the stream ending after dispose is not a loss', () async {
    final backend = FfiBackend(
      nativeEvents: () => native.stream,
      onEventsLost: lost.add,
    );
    backend.eventStream.listen((_) {}, onError: (_) {});
    backend.dispose();

    await native.close();
    await Future<void>.delayed(Duration.zero);

    expect(lost, isEmpty);
    expect(errorsLogged(), isEmpty);
  });

  test(
    'the loss reaches the event history, linked clients and this window',
    () async {
      final hub = HostMutationEventHub();
      addTearDown(hub.dispose);
      final broadcast = <SkotiqEvent>[];
      hub.wsBroadcast = broadcast.add;
      final local = <SkotiqEvent>[];
      hub.stream.listen(local.add);
      final notifications = UiNotificationNotifier();
      addTearDown(notifications.dispose);

      announceNativeEventsLost(hub: hub, notifications: notifications);
      await Future<void>.delayed(Duration.zero);

      for (final events in [local, broadcast]) {
        expect(events, hasLength(1));
        final event = events.single;
        expect(event.eventType, 'Notification');
        expect(event.category, EventCategory.system);
        expect(event.severity, EventSeverity.error);
        expect(event.data['title'], nativeEventsLostTitle);
        expect(event.data['message'], nativeEventsLostMessage);
        expect(event.data['level'], 'error');
      }
      expect(notifications.state, hasLength(1));
      expect(notifications.state.single.level, UiNotificationLevel.error);
      expect(notifications.state.single.message, nativeEventsLostMessage);
    },
  );
}
