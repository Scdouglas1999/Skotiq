// The notice the background database check raises on a host, as the host's
// window and a linked client receive it.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/bridge_events.dart' as typed;

class _MockFfiBackend extends Mock implements FfiBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

const _repairNotice = DatabaseHealthNotice(
  title: 'Database needs repair',
  message: 'Skotiq found damage in its database.',
  severity: EventSeverity.warning,
);

void main() {
  test('an announced notice reaches the window and the linked clients', () async {
    final hub = HostMutationEventHub();
    addTearDown(hub.dispose);
    final broadcast = <SkotiqEvent>[];
    hub.wsBroadcast = broadcast.add;
    final local = <SkotiqEvent>[];
    final sub = hub.stream.listen(local.add);
    addTearDown(sub.cancel);

    hub.announce(_repairNotice.toEvent());
    await pumpEventQueue();

    expect(local.single.eventType, 'Notification');
    expect(broadcast.single.data['title'], 'Database needs repair');
  });

  test('a linked client rebuilds it as the system notification it is', () {
    final sent = _repairNotice.toEvent();
    final received = SkotiqEvent.fromWireJson({'type': 'event', ...sent.toJson()});

    final event = typedEventFromWire(received);

    expect(event, isNotNull);
    final payload = event!.payload as typed.EventPayload_System;
    final notification = payload.field0 as typed.SystemEvent_Notification;
    expect(notification.title, 'Database needs repair');
    expect(notification.message, 'Skotiq found damage in its database.');
    expect(notification.level, 'warning');
    expect(event.severity, typed.EventSeverity.warning);
  });

  test("a linked client's toast carries the notice's own title", () async {
    final backend = _MockFfiBackend();
    final controller = StreamController<SkotiqEvent>.broadcast();
    addTearDown(controller.close);
    when(() => backend.eventStream).thenAnswer((_) => controller.stream);
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(errorNotificationBridgeProvider);

    controller.add(_repairNotice.toEvent());
    await pumpEventQueue();

    final toast = container.read(uiNotificationProvider).single;
    expect(toast.title, 'Database needs repair');
    expect(toast.message, 'Skotiq found damage in its database.');
    expect(toast.level, UiNotificationLevel.warning);
  });
}
