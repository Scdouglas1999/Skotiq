// The notification router tells a mount fault ("Mount fault");
// the toast bridge leaves it alone.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

class _MockFfiBackend extends Mock implements FfiBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

SkotiqEvent _mountFault() => SkotiqEvent(
  timestamp: DateTime.now().millisecondsSinceEpoch,
  severity: EventSeverity.critical,
  category: EventCategory.safety,
  eventType: 'MountMotionFault',
  data: const {
    'device_id': 'sim_mount_1',
    'kind': 'runaway',
    'message': 'The mount moved at 4.7 degrees per second with no command.',
  },
);

void main() {
  Future<List<UiNotification>> bridgeToastsFor(
    SkotiqEvent event, {
    bool notificationsOn = true,
  }) async {
    final backend = _MockFfiBackend();
    final controller = StreamController<SkotiqEvent>.broadcast();
    addTearDown(controller.close);
    when(() => backend.eventStream).thenAnswer((_) => controller.stream);
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        // Not listening to the stream: only the bridge's own toasts land.
        notificationRouterProvider.overrideWith(
          (ref) => NotificationRouter(
            transports: [
              InAppTransport(ref.read(uiNotificationProvider.notifier)),
            ],
            matrix: NotificationRoutingMatrix.defaults().copyWith(
              enabled: notificationsOn,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(notificationRouterProvider);
    container.read(errorNotificationBridgeProvider);
    controller.add(event);
    await pumpEventQueue();
    return container.read(uiNotificationProvider);
  }

  test('a mount fault the router shows raises no bridge toast', () async {
    expect(await bridgeToastsFor(_mountFault()), isEmpty);
  });

  // The router's rows are the operator's answer for what it routes: with
  // routing off the bridge does not tell it in their place.
  test('with notifications off the bridge does not tell it', () async {
    expect(
      await bridgeToastsFor(_mountFault(), notificationsOn: false),
      isEmpty,
    );
  });
}
