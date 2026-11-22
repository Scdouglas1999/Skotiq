// A sequence Notification node's warning, as the in-app toast bridge sees it.
// A node that names its own transports is the notification router's to send
// on exactly those (an in-app banner only when it lists one); a node with no
// list of its own keeps its toast.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

class _MockFfiBackend extends Mock implements FfiBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

SkotiqEvent _nodeWarning({List<String>? transports}) => SkotiqEvent(
  timestamp: DateTime.now().millisecondsSinceEpoch,
  severity: EventSeverity.warning,
  category: EventCategory.system,
  eventType: 'Notification',
  data: {
    'title': 'Clouds',
    'message': 'Cloud cover is rising.',
    'level': 'warning',
    'explicit_transports': ?transports,
  },
);

void main() {
  Future<List<UiNotification>> toastsFor(SkotiqEvent event) async {
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
    controller.add(event);
    await pumpEventQueue();
    return container.read(uiNotificationProvider);
  }

  test('a node with its own transports raises no bridge toast', () async {
    expect(await toastsFor(_nodeWarning(transports: ['telegram'])), isEmpty);
  });

  test('a node with no transports of its own keeps its toast', () async {
    final toasts = await toastsFor(_nodeWarning());
    expect(toasts.single.title, 'Clouds');
  });
}
