// PRODUCER 4 of the stop pipeline.
//
// Without the cancellation check here, one operator Stop raises TWO toasts: the
// info "Sequence stopped / Sequence stopped by request at 01:54." AND a RED
// "Sequence Error / Sequence cancelled" beside it.
//
// `errorNotificationBridgeProvider` (providers/event_provider.dart) forwards
// EVERY error-severity backend event straight to `uiNotificationProvider` with a
// title built from the event's category, which for a sequencer event is
// literally "Sequence Error". It never goes through the NotificationRouter, so
// neither the router's classification nor its content dedupe can reach it —
// the check has to be asked for here, as the other producers ask it.
//
// The counter-input is the REAL wire shape, taken from the FFI mapper
// (`backend/ffi_backend/event_mapping.dart:490` — `SequencerEvent_Error` maps to
// eventType 'Error' with `{'message': …}`) at the severity the bridge stamps
// (`bridge/src/api/sequencer/event_bridge.rs:374` — `EventSeverity::Error`).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nightshade_core/nightshade_core.dart';

class _MockFfiBackend extends Mock implements FfiBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, NightshadeBackend backend) : super() {
    state = backend;
  }

  /// What connecting to a remote host does: the app's backend is replaced.
  void swapTo(NightshadeBackend backend) => state = backend;
}

/// The exact event the native executor's cancelled arm produces.
NightshadeEvent _sequencerError(String message) => NightshadeEvent(
  timestamp: DateTime.now().millisecondsSinceEpoch,
  severity: EventSeverity.error,
  category: EventCategory.sequencer,
  eventType: 'Error',
  data: {'message': message},
);

Future<(ProviderContainer, StreamController<NightshadeEvent>)> _bridge() async {
  final backend = _MockFfiBackend();
  final controller = StreamController<NightshadeEvent>.broadcast();
  when(() => backend.eventStream).thenAnswer((_) => controller.stream);
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
    ],
  );
  // The bridge is a side-effecting Provider<void>; the shell watches it.
  container.read(errorNotificationBridgeProvider);
  return (container, controller);
}

void main() {
  test('an operator Stop raises no red toast from the error bridge', () async {
    final (container, controller) = await _bridge();
    addTearDown(container.dispose);
    addTearDown(controller.close);

    controller.add(_sequencerError('Sequence cancelled'));
    await pumpEventQueue();

    expect(
      container.read(uiNotificationProvider),
      isEmpty,
      reason:
          'the stop already has its INFO "Sequence stopped" toast; this '
          'producer added a second, RED "Sequence Error / Sequence cancelled" '
          'card beside it',
    );
  });

  test('the American spelling is the same notice', () async {
    final (container, controller) = await _bridge();
    addTearDown(container.dispose);
    addTearDown(controller.close);

    controller.add(_sequencerError('Sequence canceled'));
    await pumpEventQueue();

    expect(container.read(uiNotificationProvider), isEmpty);
  });

  // The counter-inputs that make the match EXACT rather than a substring test.
  // A real fault whose text merely contains "cancelled" must still reach the
  // operator — swallowing it would be the worse bug.
  test('a real fault that merely contains the word still toasts', () async {
    final (container, controller) = await _bridge();
    addTearDown(container.dispose);
    addTearDown(controller.close);

    controller.add(_sequencerError('Temperature compensation cancelled'));
    controller.add(_sequencerError('Focuser lost communication'));
    await pumpEventQueue();

    final shown = container.read(uiNotificationProvider);
    expect(shown.length, 2);
    expect(shown.every((n) => n.level == UiNotificationLevel.error), isTrue);
    expect(shown.first.title, 'Sequence Error');
    expect(shown.map((n) => n.message).toList(), [
      'Temperature compensation cancelled',
      'Focuser lost communication',
    ]);
  });

  // Toast-flood fixes: PHD2 emits StarLost per lost frame; a mount heartbeat
  // flap raised several toasts per incident (HeartbeatStatusChanged +
  // the Error event ALSO surfaced by DeviceService via errorService).
  NightshadeEvent guiding(
    String type, {
    EventSeverity severity = EventSeverity.warning,
    String? message,
  }) => NightshadeEvent(
    timestamp: DateTime.now().millisecondsSinceEpoch,
    severity: severity,
    category: EventCategory.guiding,
    eventType: type,
    data: {if (message != null) 'message': message},
  );

  NightshadeEvent equipment(
    String type,
    String message,
    EventSeverity severity,
  ) => NightshadeEvent(
    timestamp: DateTime.now().millisecondsSinceEpoch,
    severity: severity,
    category: EventCategory.equipment,
    eventType: type,
    data: {'message': message, 'device_type': 'mount'},
  );

  test(
    'a lost-star episode toasts once; per-frame hunt noise cannot re-arm it',
    () async {
      final (container, controller) = await _bridge();
      addTearDown(container.dispose);
      addTearDown(controller.close);

      controller.add(guiding('StarLost', message: 'Guide star lost'));
      controller.add(guiding('StarLost', message: 'Guide star lost'));
      await pumpEventQueue();

      var shown = container.read(uiNotificationProvider);
      expect(shown.length, 1);
      expect(shown.single.level, UiNotificationLevel.warning);

      // Mid-episode noise: PHD2 auto-reselects then loses the star again,
      // and keeps emitting per-frame events while hunting — the real log
      // alternates StarSelected ↔ StarLost every ~10 s for minutes. None
      // of these end the episode. Fresh messages keep the 30 s content
      // dedupe from masking whether the latch held.
      controller.add(guiding('StarSelected', severity: EventSeverity.info));
      controller.add(guiding('LoopingExposures', severity: EventSeverity.info));
      controller.add(guiding('GuideStep', severity: EventSeverity.info));
      controller.add(
        guiding('StarLost', message: 'Guide star lost (still hunting)'),
      );
      await pumpEventQueue();

      shown = container.read(uiNotificationProvider);
      expect(shown.length, 1);

      // Guiding genuinely recovering (settle → guiding state) ends the
      // episode; the NEXT StarLost is a new episode and earns a toast.
      controller.add(guiding('SettleDone', severity: EventSeverity.info));
      controller.add(guiding('GuidingStarted', severity: EventSeverity.info));
      controller.add(
        guiding('StarLost', message: 'Guide star lost (new episode)'),
      );
      await pumpEventQueue();

      shown = container.read(uiNotificationProvider);
      expect(shown.length, 2);
    },
  );

  test(
    'HeartbeatStatusChanged never toasts (it has no human message)',
    () async {
      final (container, controller) = await _bridge();
      addTearDown(container.dispose);
      addTearDown(controller.close);

      controller.add(
        equipment('HeartbeatStatusChanged', '', EventSeverity.warning),
      );
      controller.add(
        equipment('HeartbeatStatusChanged', '', EventSeverity.error),
      );
      await pumpEventQueue();

      expect(container.read(uiNotificationProvider), isEmpty);
    },
  );

  test(
    'error-severity equipment Error is left to DeviceService, not toasted',
    () async {
      final (container, controller) = await _bridge();
      addTearDown(container.dispose);
      addTearDown(controller.close);
      container.read(deviceServiceProvider);

      controller.add(
        equipment('Error', 'Device not responding', EventSeverity.error),
      );
      controller.add(
        equipment('Error', 'Device vanished', EventSeverity.critical),
      );
      await pumpEventQueue();

      final shown = container.read(uiNotificationProvider);
      expect(
        shown.where((n) => n.message.contains('Device not responding')).length,
        1,
        reason:
            'DeviceService._handleDeviceError surfaces these via errorService '
            'with its own dedupe; the bridge must not double-toast them',
      );
      expect(
        shown.where((n) => n.message.contains('Device vanished')).length,
        1,
      );
    },
  );

  // The suppression above is only right while a DeviceService is listening
  // to the same backend. It is created lazily, by the first thing that reads
  // it, so a phone that only watches a remote host may never have one, and a
  // backend swap leaves the old one subscribed to the old backend.
  test('an equipment Error still reaches the operator when no DeviceService '
      'is listening', () async {
    final (container, controller) = await _bridge();
    addTearDown(container.dispose);
    addTearDown(controller.close);

    controller.add(
      equipment(
        'Error',
        'Device unresponsive after 3 heartbeat failures',
        EventSeverity.error,
      ),
    );
    await pumpEventQueue();

    expect(
      container.read(uiNotificationProvider).map((n) => n.message),
      contains('Device unresponsive after 3 heartbeat failures'),
      reason: 'the mount dropped and nothing told the operator',
    );
  });

  test(
    'an equipment Error from a swapped-in backend still reaches the operator',
    () async {
      final (container, controller) = await _bridge();
      addTearDown(container.dispose);
      addTearDown(controller.close);
      // The app used a device before connecting to the remote host.
      container.read(deviceServiceProvider);

      final remote = _MockFfiBackend();
      final remoteEvents = StreamController<NightshadeEvent>.broadcast();
      addTearDown(remoteEvents.close);
      when(() => remote.eventStream).thenAnswer((_) => remoteEvents.stream);
      (container.read(backendProvider.notifier) as _FixedBackendNotifier)
          .swapTo(remote);
      container.read(errorNotificationBridgeProvider);
      await pumpEventQueue();

      remoteEvents.add(
        equipment(
          'Error',
          'Device unresponsive after 3 heartbeat failures',
          EventSeverity.error,
        ),
      );
      await pumpEventQueue();

      expect(
        container.read(uiNotificationProvider).map((n) => n.message),
        contains(contains('Device unresponsive after 3 heartbeat failures')),
      );
    },
  );

  test(
    'warning-severity equipment Error still toasts once (30 s dedupe)',
    () async {
      final (container, controller) = await _bridge();
      addTearDown(container.dispose);
      addTearDown(controller.close);

      controller.add(
        equipment('Error', 'Guide exposure failed', EventSeverity.warning),
      );
      controller.add(
        equipment('Error', 'Guide exposure failed', EventSeverity.warning),
      );
      await pumpEventQueue();

      final shown = container.read(uiNotificationProvider);
      expect(shown.length, 1);
      expect(shown.single.level, UiNotificationLevel.warning);
    },
  );
}
