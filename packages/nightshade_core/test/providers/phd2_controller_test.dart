// Behavioural tests for Phd2Controller's trust/reliability hardening:
//   * command gate (double-tap → one native call or deterministic rejection),
//   * Stop can pre-empt an in-flight Start (safe abort),
//   * async command failure is caught and does NOT clear live state,
//   * unrecognised PHD2 AppState → `unknown` (never a false `stopped`),
//   * explicit Disconnect cancels the crash-relaunch path and stays down,
//   * a NON-user link loss still auto-relaunches,
//   * local/FFI connect honours the requested host/port instead of silently
//     discarding it.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nightshade_core/nightshade_core.dart';

class _MockBackend extends Mock implements NightshadeBackend {}

class _MockFfiBackend extends Mock implements FfiBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, NightshadeBackend backend) : super() {
    state = backend;
  }
}

/// Settings with a NON-local PHD2 host so the auto-launch branch
/// (`Phd2Launcher.ensureRunning`, which would try to spawn a process / probe a
/// socket) is skipped in tests — only the TCP connect is exercised.
class _SettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState(
    phd2Host: '10.0.0.9',
    phd2Port: 4400,
    phd2Path: '',
  );
}

const _connectedStatus = Phd2Status(
  state: 'Guiding',
  connected: true,
  rmsRa: 0,
  rmsDec: 0,
  rmsTotal: 0,
  snr: 0,
  starMass: 0,
  avgDistance: 0,
);

NightshadeEvent _guidingEvent(String eventType, [Map<String, dynamic>? data]) =>
    NightshadeEvent(
      timestamp: 0,
      severity: EventSeverity.info,
      category: EventCategory.guiding,
      eventType: eventType,
      data: data ?? const {},
    );

ProviderContainer _container(
  NightshadeBackend backend, {
  DateTime Function()? now,
}) {
  return ProviderContainer(
    overrides: [
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
      appSettingsProvider.overrideWith(_SettingsNotifier.new),
      loggingServiceProvider.overrideWithValue(LoggingService()),
      if (now != null)
        phd2ControllerProvider.overrideWith(
          (ref) => Phd2Controller(ref, backend, now: now),
        ),
    ],
  );
}

void _markConnected(ProviderContainer container) {
  container.read(guiderStateProvider.notifier)
    ..setConnecting('phd2_guider', 'PHD2')
    ..setConnected();
}

void main() {
  setUpAll(() {
    registerFallbackValue(const Stream<NightshadeEvent>.empty());
  });

  test(
    'repeated star loss warnings are bounded and do not drop events',
    () async {
      final events = StreamController<NightshadeEvent>.broadcast();
      addTearDown(events.close);
      final backend = _MockBackend();
      when(() => backend.eventStream).thenAnswer((_) => events.stream);
      final container = _container(backend);
      addTearDown(container.dispose);
      _markConnected(container);
      container.read(phd2ControllerProvider);
      for (var i = 0; i < 20; i++) {
        events.add(_guidingEvent('StarLost'));
      }
      await Future<void>.delayed(Duration.zero);
      final warnings = container
          .read(loggingServiceProvider)
          .getRecentLogs()
          .where((entry) => entry.message.contains('Guide star lost'));
      expect(warnings.length, 1);
      expect(container.read(phd2StateProvider), Phd2State.lostLock);
      expect(container.read(starLostEventProvider), isNotNull);
    },
  );

  test('star loss reminders are bounded until sustained recovery', () async {
    var now = DateTime(2026, 10, 8);
    final events = StreamController<NightshadeEvent>.broadcast();
    addTearDown(events.close);
    final backend = _MockBackend();
    when(() => backend.eventStream).thenAnswer((_) => events.stream);
    final container = _container(backend, now: () => now);
    addTearDown(container.dispose);
    _markConnected(container);
    container.read(guideStatsProvider);
    container.read(phd2ControllerProvider);
    Future<void> emit(String type, [Map<String, dynamic>? data]) async {
      events.add(_guidingEvent(type, data));
      await Future<void>.delayed(Duration.zero);
    }

    int logs(String text) => container
        .read(loggingServiceProvider)
        .getRecentLogs()
        .where((entry) => entry.message.contains(text))
        .length;
    const goodStep = {'RADistanceRaw': 0.3, 'DECDistanceRaw': 0.4};
    await emit('StarLost');
    now = now.add(const Duration(seconds: 59));
    await emit('StarLost');
    expect(logs('Guide star lost'), 1);
    now = now.add(const Duration(seconds: 1));
    await emit('StarLost');
    expect(logs('Guide star lost'), 2);
    await emit('GuideStep', goodStep);
    now = now.add(const Duration(seconds: 9));
    await emit('GuideStep', goodStep);
    expect(logs('Guide star recovered'), 0);
    // A fresh loss resets the stability interval without another warning.
    await emit('StarLost');
    for (var i = 0; i <= 10; i++) {
      await emit('GuideStep', goodStep);
      now = now.add(const Duration(seconds: 1));
    }
    expect(logs('Guide star recovered'), 1);
    expect(container.read(guideStatsProvider).frameCount, 13);
    await emit('StarLost');
    expect(logs('Guide star lost'), 3);
  });

  group('command gate', () {
    test(
      'rapid double Start fires one native call; the second is rejected',
      () async {
        final events = StreamController<NightshadeEvent>.broadcast();
        addTearDown(events.close);
        final backend = _MockBackend();
        when(() => backend.eventStream).thenAnswer((_) => events.stream);
        final startGate = Completer<void>();
        when(
          () => backend.guiderStartGuiding(
            deviceId: any(named: 'deviceId'),
            settlePixels: any(named: 'settlePixels'),
            settleTime: any(named: 'settleTime'),
            settleTimeout: any(named: 'settleTimeout'),
          ),
        ).thenAnswer((_) => startGate.future);

        final container = _container(backend);
        addTearDown(container.dispose);
        _markConnected(container);
        final controller = container.read(phd2ControllerProvider);

        final first = controller.startGuiding();
        final second = controller.startGuiding();

        await expectLater(second, throwsA(isA<GuidingCommandBusyException>()));
        startGate.complete();
        await first;

        verify(
          () => backend.guiderStartGuiding(
            deviceId: any(named: 'deviceId'),
            settlePixels: any(named: 'settlePixels'),
            settleTime: any(named: 'settleTime'),
            settleTimeout: any(named: 'settleTimeout'),
          ),
        ).called(1);
      },
    );

    test(
      'rapid double Stop fires one native call; the second is rejected',
      () async {
        final events = StreamController<NightshadeEvent>.broadcast();
        addTearDown(events.close);
        final backend = _MockBackend();
        when(() => backend.eventStream).thenAnswer((_) => events.stream);
        final stopGate = Completer<void>();
        when(
          () => backend.guiderStopGuiding(deviceId: any(named: 'deviceId')),
        ).thenAnswer((_) => stopGate.future);

        final container = _container(backend);
        addTearDown(container.dispose);
        _markConnected(container);
        final controller = container.read(phd2ControllerProvider);

        final first = controller.stopGuiding();
        final second = controller.stopGuiding();

        await expectLater(second, throwsA(isA<GuidingCommandBusyException>()));
        stopGate.complete();
        await first;

        verify(
          () => backend.guiderStopGuiding(deviceId: any(named: 'deviceId')),
        ).called(1);
      },
    );

    test('Stop interrupts Start and fences it with a final Stop', () async {
      final events = StreamController<NightshadeEvent>.broadcast();
      addTearDown(events.close);
      final backend = _MockBackend();
      when(() => backend.eventStream).thenAnswer((_) => events.stream);
      final startGate = Completer<void>();
      when(
        () => backend.guiderStartGuiding(
          deviceId: any(named: 'deviceId'),
          settlePixels: any(named: 'settlePixels'),
          settleTime: any(named: 'settleTime'),
          settleTimeout: any(named: 'settleTimeout'),
        ),
      ).thenAnswer((_) => startGate.future);
      when(
        () => backend.guiderStopGuiding(deviceId: any(named: 'deviceId')),
      ).thenAnswer((_) async {});

      final container = _container(backend);
      addTearDown(container.dispose);
      _markConnected(container);
      final controller = container.read(phd2ControllerProvider);

      final start = controller.startGuiding();
      final stop = controller.stopGuiding();
      await Future<void>.delayed(Duration.zero);
      // The first Stop is issued immediately to interrupt settling.
      verify(
        () => backend.guiderStopGuiding(deviceId: any(named: 'deviceId')),
      ).called(1);

      // Once Start drains, a second Stop becomes the terminal command.
      startGate.complete();
      await start;
      await stop;
      verify(
        () => backend.guiderStopGuiding(deviceId: any(named: 'deviceId')),
      ).called(1);
    });

    test('Stop works from the paused state', () async {
      final events = StreamController<NightshadeEvent>.broadcast();
      addTearDown(events.close);
      final backend = _MockBackend();
      when(() => backend.eventStream).thenAnswer((_) => events.stream);
      when(
        () => backend.guiderStopGuiding(deviceId: any(named: 'deviceId')),
      ).thenAnswer((_) async {});

      final container = _container(backend);
      addTearDown(container.dispose);
      _markConnected(container);
      container.read(phd2StateProvider.notifier).state = Phd2State.paused;
      final controller = container.read(phd2ControllerProvider);

      await controller.stopGuiding();
      verify(
        () => backend.guiderStopGuiding(deviceId: any(named: 'deviceId')),
      ).called(1);
    });

    test(
      'async command failure is caught and does not clear live state',
      () async {
        final events = StreamController<NightshadeEvent>.broadcast();
        addTearDown(events.close);
        final backend = _MockBackend();
        when(() => backend.eventStream).thenAnswer((_) => events.stream);
        when(
          () => backend.guiderStartGuiding(
            deviceId: any(named: 'deviceId'),
            settlePixels: any(named: 'settlePixels'),
            settleTime: any(named: 'settleTime'),
            settleTimeout: any(named: 'settleTimeout'),
          ),
        ).thenThrow(StateError('driver rejected start'));

        final container = _container(backend);
        addTearDown(container.dispose);
        _markConnected(container);
        container.read(phd2StateProvider.notifier).state = Phd2State.guiding;
        final controller = container.read(phd2ControllerProvider);

        await expectLater(
          controller.startGuiding(),
          throwsA(isA<StateError>()),
        );
        // The controller must not optimistically flip to an idle state on failure.
        expect(container.read(phd2StateProvider), Phd2State.guiding);
      },
    );
  });

  group('settle semantics', () {
    test('start normalises an impossible settleTimeout < settleTime', () async {
      final events = StreamController<NightshadeEvent>.broadcast();
      addTearDown(events.close);
      final backend = _MockBackend();
      when(() => backend.eventStream).thenAnswer((_) => events.stream);
      double? sentTimeout;
      double? sentTime;
      when(
        () => backend.guiderStartGuiding(
          deviceId: any(named: 'deviceId'),
          settlePixels: any(named: 'settlePixels'),
          settleTime: any(named: 'settleTime'),
          settleTimeout: any(named: 'settleTimeout'),
        ),
      ).thenAnswer((invocation) async {
        sentTime = invocation.namedArguments[#settleTime] as double;
        sentTimeout = invocation.namedArguments[#settleTimeout] as double;
      });

      final container = _container(backend);
      addTearDown(container.dispose);
      _markConnected(container);
      final controller = container.read(phd2ControllerProvider);

      // settleTime (45) > settleTimeout (30): the settle could never complete.
      await controller.startGuiding(settleTime: 45, settleTimeout: 30);

      // Timeout is lifted to at least the required stable duration.
      expect(sentTime, 45);
      expect(sentTimeout, greaterThanOrEqualTo(sentTime!));
    });
  });

  group('guider capabilities', () {
    test('PHD2-only pause and resume reject the built-in guider', () async {
      final events = StreamController<NightshadeEvent>.broadcast();
      addTearDown(events.close);
      final backend = _MockBackend();
      when(() => backend.eventStream).thenAnswer((_) => events.stream);

      final container = _container(backend);
      addTearDown(container.dispose);
      container.read(guiderStateProvider.notifier)
        ..setConnecting(builtinGuiderDeviceId, 'Built-in Guider')
        ..setConnected();
      final controller = container.read(phd2ControllerProvider);

      await expectLater(
        controller.pauseGuiding(),
        throwsA(isA<UnsupportedError>()),
      );
      await expectLater(
        controller.resumeGuiding(),
        throwsA(isA<UnsupportedError>()),
      );
      verifyNever(() => backend.phd2SetPaused(any()));
    });
  });

  group('state classification', () {
    test(
      'an unrecognised PHD2 AppState maps to unknown, not stopped',
      () async {
        final events = StreamController<NightshadeEvent>.broadcast();
        addTearDown(events.close);
        final backend = _MockBackend();
        when(() => backend.eventStream).thenAnswer((_) => events.stream);

        final container = _container(backend);
        addTearDown(container.dispose);
        // Create the controller so it subscribes to the event stream.
        container.read(phd2ControllerProvider);

        events.add(_guidingEvent('AppState', {'State': 'SomeFutureState'}));
        await Future<void>.delayed(Duration.zero);

        expect(container.read(phd2StateProvider), Phd2State.unknown);
      },
    );
  });

  group('disconnect authority', () {
    test(
      'backend cleanup Disconnected event cannot recursively clean up again',
      () {
        fakeAsync((async) {
          final events = StreamController<NightshadeEvent>.broadcast();
          final backend = _MockBackend();
          when(() => backend.eventStream).thenAnswer((_) => events.stream);
          when(() => backend.phd2Disconnect()).thenAnswer((_) async {
            events.add(_guidingEvent('Disconnected'));
          });

          final container = _container(backend);
          _markConnected(container);
          container.read(phd2ControllerProvider);
          async.flushMicrotasks();

          events.add(_guidingEvent('Disconnected'));
          async.flushMicrotasks();

          verify(() => backend.phd2Disconnect()).called(1);
          expect(
            container.read(guiderStateProvider).connectionState,
            DeviceConnectionState.disconnected,
          );

          // Further duplicate terminal events belong to the same link-loss
          // episode and must remain inert.
          events.add(_guidingEvent('Disconnected'));
          async.flushMicrotasks();
          verifyNever(() => backend.phd2Disconnect());

          events.close();
          container.dispose();
        });
      },
    );

    test('explicit Disconnect cancels relaunch and never auto-reconnects', () {
      fakeAsync((async) {
        final events = StreamController<NightshadeEvent>.broadcast();
        final backend = _MockBackend();
        when(() => backend.eventStream).thenAnswer((_) => events.stream);
        when(() => backend.phd2Disconnect()).thenAnswer((_) async {});
        when(() => backend.phd2StopGuiding()).thenAnswer((_) async {});
        when(
          () => backend.phd2Connect(
            host: any(named: 'host'),
            port: any(named: 'port'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => backend.phd2GetStatus(),
        ).thenAnswer((_) async => _connectedStatus);

        final container = _container(backend);
        _markConnected(container);
        container.read(guiderStateProvider.notifier).setAutoReconnect(true);
        final controller = container.read(phd2ControllerProvider);
        async.flushMicrotasks();

        // User taps Disconnect, then the bridge publishes the Disconnected
        // event the teardown produced.
        controller.disconnect();
        async.flushMicrotasks();
        events.add(_guidingEvent('Disconnected'));
        async.flushMicrotasks();

        // Wait out the entire relaunch backoff ladder.
        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();

        verifyNever(
          () => backend.phd2Connect(
            host: any(named: 'host'),
            port: any(named: 'port'),
          ),
        );

        events.close();
        container.dispose();
      });
    });

    test('a non-user link loss still auto-relaunches (regression guard)', () {
      fakeAsync((async) {
        final events = StreamController<NightshadeEvent>.broadcast();
        final backend = _MockBackend();
        when(() => backend.eventStream).thenAnswer((_) => events.stream);
        when(() => backend.phd2Disconnect()).thenAnswer((_) async {});
        when(
          () => backend.phd2Connect(
            host: any(named: 'host'),
            port: any(named: 'port'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => backend.phd2GetStatus(),
        ).thenAnswer((_) async => _connectedStatus);

        final container = _container(backend);
        _markConnected(container);
        container.read(guiderStateProvider.notifier).setAutoReconnect(true);
        container.read(phd2ControllerProvider);
        // Warm the settings provider the relaunch path reads.
        container.read(appSettingsProvider);
        async.flushMicrotasks();

        // PHD2 dies externally (no user Disconnect).
        events.add(_guidingEvent('Disconnected'));
        async.flushMicrotasks();
        // First backoff is 5s; fire it and let the reconnect complete.
        async.elapse(const Duration(seconds: 6));
        async.flushMicrotasks();

        verify(
          () => backend.phd2Connect(
            host: any(named: 'host'),
            port: any(named: 'port'),
          ),
        ).called(greaterThanOrEqualTo(1));

        events.close();
        container.dispose();
      });
    });
  });

  group('connect serialization', () {
    test('a duplicate concurrent connect joins the same outcome', () async {
      final events = StreamController<NightshadeEvent>.broadcast();
      addTearDown(events.close);
      final backend = _MockBackend();
      when(() => backend.eventStream).thenAnswer((_) => events.stream);
      final connectGate = Completer<void>();
      when(
        () => backend.phd2Connect(
          host: any(named: 'host'),
          port: any(named: 'port'),
        ),
      ).thenAnswer((_) => connectGate.future);
      when(
        () => backend.phd2GetStatus(),
      ).thenAnswer((_) async => _connectedStatus);

      final container = _container(backend);
      addTearDown(container.dispose);
      final controller = container.read(phd2ControllerProvider);

      final first = controller.connect('imaging.local', 4400);
      final second = controller.connect('imaging.local', 4400);
      expect(identical(first, second), isTrue);

      connectGate.complete();
      await first;
      await second;

      verify(
        () => backend.phd2Connect(
          host: any(named: 'host'),
          port: any(named: 'port'),
        ),
      ).called(1);
    });
  });

  group('configured endpoint', () {
    test('local FFI connect honours the requested host/port', () async {
      final events = StreamController<NightshadeEvent>.broadcast();
      addTearDown(events.close);
      final backend = _MockFfiBackend();
      when(() => backend.eventStream).thenAnswer((_) => events.stream);
      when(
        () => backend.phd2Connect(
          host: any(named: 'host'),
          port: any(named: 'port'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => backend.phd2GetStatus(),
      ).thenAnswer((_) async => _connectedStatus);

      final container = _container(backend);
      addTearDown(container.dispose);
      final controller = container.read(phd2ControllerProvider);

      await controller.connect('192.168.5.5', 4444);

      verify(
        () => backend.phd2Connect(host: '192.168.5.5', port: 4444),
      ).called(1);
      expect(
        container.read(guiderStateProvider).connectionState,
        DeviceConnectionState.connected,
      );
    });
  });
}
