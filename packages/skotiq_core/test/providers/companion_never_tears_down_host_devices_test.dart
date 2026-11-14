// A companion (NetworkBackend) never disconnects, reconnects or pauses anything
// on the imaging host because of its own link trouble or an event the host
// relayed. Only an explicit user action may disconnect a host device.

import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/utils.dart';

import '../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

SkotiqEvent _guiding(String type) => SkotiqEvent(
  timestamp: 0,
  severity: EventSeverity.info,
  category: EventCategory.guiding,
  eventType: type,
  data: const {},
);

void main() {
  setUpAll(() {
    registerFallbackValue(DeviceType.guider);
  });

  late StreamController<SkotiqEvent> events;
  late _MockNetworkBackend backend;

  setUp(() {
    events = StreamController<SkotiqEvent>.broadcast();
    backend = _MockNetworkBackend();
    when(() => backend.eventStream).thenAnswer((_) => events.stream);
    when(() => backend.phd2Disconnect()).thenAnswer((_) async {});
    when(
      () => backend.phd2Connect(
        host: any(named: 'host'),
        port: any(named: 'port'),
      ),
    ).thenAnswer((_) async {});
    when(() => backend.connectDevice(any(), any())).thenAnswer((_) async {});
    when(() => backend.disconnectDevice(any(), any())).thenAnswer((_) async {});
    when(
      () => backend.guiderGetStatus(),
    ).thenAnswer((_) async => kPhd2DisconnectedStatus);
  });

  ProviderContainer containerFor() {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        loggingServiceProvider.overrideWithValue(LoggingService()),
      ],
    );
    return container;
  }

  void expectNoHostCommands() {
    verifyNever(() => backend.phd2Disconnect());
    verifyNever(
      () => backend.phd2Connect(
        host: any(named: 'host'),
        port: any(named: 'port'),
      ),
    );
    verifyNever(() => backend.connectDevice(any(), any()));
    verifyNever(() => backend.disconnectDevice(any(), any()));
  }

  test('a relayed PHD2 Disconnected is not echoed back to the host', () {
    fakeAsync((async) {
      final container = containerFor();
      container.read(phd2ControllerProvider);
      events.add(_guiding('Connected'));
      async.flushMicrotasks();

      events.add(_guiding('Disconnected'));
      async.elapse(const Duration(minutes: 2));

      expectNoHostCommands();
      expect(
        container.read(guiderStateProvider).connectionState,
        DeviceConnectionState.disconnected,
        reason: 'the companion still shows the host guider as disconnected',
      );
      container.dispose();
    });
  });

  test('a WebSocket error from the host is not treated as PHD2 link loss', () {
    fakeAsync((async) {
      final container = containerFor();
      container.read(phd2ControllerProvider);
      events.add(_guiding('Connected'));
      async.flushMicrotasks();

      events.addError(const SocketException('Connection reset by peer'));
      async.elapse(const Duration(minutes: 2));

      expectNoHostCommands();
      container.dispose();
    });
  });

  test('a failed PHD2 connect on a companion does not disconnect the host', () {
    fakeAsync((async) {
      when(
        () => backend.phd2Connect(
          host: any(named: 'host'),
          port: any(named: 'port'),
        ),
      ).thenThrow(TimeoutException('host busy'));
      final container = containerFor();
      Object? failure;
      container
          .read(deviceServiceProvider)
          .connect(DeviceType.guider, kPhd2CanonicalId)
          .catchError((Object e) => failure = e);
      async.elapse(const Duration(seconds: 30));

      expect(failure, isNotNull);
      verifyNever(() => backend.phd2Disconnect());
      container.dispose();
    });
  });

  test(
    'a relayed camera or focuser Disconnected mid-run sends nothing back',
    () {
      fakeAsync((async) {
        when(() => backend.saveCheckpoint()).thenAnswer((_) async {});
        when(() => backend.sequencerPause()).thenAnswer((_) async {});
        final container = containerFor();
        container.read(deviceServiceProvider);
        container
            .read(runRecordProvider.notifier)
            .setLifecycle(SequenceExecutionState.running);
        for (final (type, id) in [
          ('camera', 'sim_camera_1'),
          ('focuser', 'sim_focuser_1'),
          ('filterWheel', 'sim_wheel_1'),
        ]) {
          events.add(
            SkotiqEvent(
              timestamp: 0,
              severity: EventSeverity.warning,
              category: EventCategory.equipment,
              eventType: 'Disconnected',
              data: {'device_type': type, 'device_id': id},
            ),
          );
        }
        async.elapse(const Duration(minutes: 2));

        expectNoHostCommands();
        verifyNever(() => backend.saveCheckpoint());
        verifyNever(() => backend.sequencerPause());
        container.dispose();
      });
    },
  );
}
