import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/services/capture_preview_loader.dart'
    show capturePreviewPublisherProvider;

class _MockFfiBackend extends Mock implements FfiBackend {}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

PlateSolveResult _solve({double ra = 83.82, double dec = -5.39}) =>
    PlateSolveResult(
      success: true,
      ra: ra,
      dec: dec,
      pixelScale: 1.52,
      rotation: 12.5,
      fieldWidth: 1.2,
      fieldHeight: 0.8,
      solveTimeSecs: 2.4,
      cd11: -0.0004,
      cd12: 0.00001,
      cd21: 0.00001,
      cd22: 0.0004,
      sipAOrder: 2,
      sipBOrder: 2,
      sipACoeffs: Float64List.fromList([0.1, 0.2]),
      sipBCoeffs: Float64List.fromList([0.3]),
      sipApOrder: 0,
      sipBpOrder: 0,
      sipApCoeffs: Float64List(0),
      sipBpCoeffs: Float64List(0),
    );

/// A host container: an FfiBackend that owns the hardware, with the WebSocket
/// broadcast captured.
({ProviderContainer container, List<SkotiqEvent> sent}) _host() {
  final backend = _MockFfiBackend();
  when(
    () => backend.eventStream,
  ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
    ],
  );
  final sent = <SkotiqEvent>[];
  container.read(hostMutationEventHubProvider).wsBroadcast = sent.add;
  container.read(hostRuntimeMirrorProvider);
  return (container: container, sent: sent);
}

_MockNetworkBackend _clientBackend() {
  final backend = _MockNetworkBackend();
  when(
    () => backend.connectionState,
  ).thenReturn(BackendConnectionState.connected);
  when(() => backend.isAuthTokenRejected).thenReturn(false);
  when(
    () => backend.eventStream,
  ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
  return backend;
}

ProviderContainer _client(_MockNetworkBackend backend) => ProviderContainer(
  overrides: [
    backendProvider.overrideWith((ref) => _FixedBackendNotifier(ref, backend)),
  ],
);

/// What a client receives on `/events`: the event as JSON and back.
SkotiqEvent _overWire(SkotiqEvent event) =>
    SkotiqEvent.fromWireJson(jsonDecode(jsonEncode(event.toJson())));

Iterable<HostRuntimeUpdate> _updates(List<SkotiqEvent> sent, String channel) =>
    sent
        .where((e) => e.eventType == hostRuntimeStateEventType)
        .map((e) => HostRuntimeUpdate.fromJson(e.data)!)
        .where((u) => u.channel == channel && u.value != null);

void main() {
  setUpAll(() {
    registerFallbackValue(const Stream<SkotiqEvent>.empty());
  });

  group('host publishes', () {
    test('a plate solve on the host reaches a linked client', () async {
      final host = _host();
      addTearDown(host.container.dispose);

      host.container.read(plateSolveStateProvider.notifier).state =
          PlateSolveState(lastResult: _solve());

      final updates = _updates(host.sent, 'plateSolve').toList();
      expect(updates, hasLength(1));

      final backend = _clientBackend();
      final client = _client(backend);
      addTearDown(client.dispose);

      await applyRemoteSyncEvent(
        client,
        _overWire(updates.single.toEvent()),
        networkBackend: backend,
      );

      final mirrored = client.read(plateSolveStateProvider).lastResult;
      expect(mirrored, isNotNull);
      expect(samePlateSolveOutcome(mirrored!, _solve()), isTrue);
      expect(mirrored.cd11, -0.0004);
      expect(mirrored.sipACoeffs, [0.1, 0.2]);
    });

    test('an unchanged value is not broadcast twice', () {
      final host = _host();
      addTearDown(host.container.dispose);
      final controller = host.container.read(plateSolveStateProvider.notifier);

      controller.state = PlateSolveState(lastResult: _solve());
      controller.state = PlateSolveState(lastResult: _solve());

      expect(_updates(host.sent, 'plateSolve'), hasLength(1));
    });

    test('the store serves the latest value of every channel', () {
      final host = _host();
      addTearDown(host.container.dispose);

      host.container
          .read(autofocusResultProvider.notifier)
          .state = const AutofocusResult(
        bestPosition: 6620,
        bestHfr: 2.94,
        focusData: [
          FocusDataPoint(position: 6500, hfr: 3.4, starCount: 40),
          FocusDataPoint(position: 6620, hfr: 2.94, starCount: 52),
        ],
        method: 'Hyperbolic',
        timestamp: 1,
        curveFitQuality: 0.97,
        backlashApplied: true,
      );

      final snapshot = host.container
          .read(hostRuntimeStateStoreProvider)
          .snapshot();
      final af = snapshot.singleWhere((u) => u.channel == 'autofocusResult');
      expect(af.value?['bestPosition'], 6620);
      expect(af.value?['focusData'], hasLength(2));
    });

    test('a host that does not own the hardware publishes nothing', () {
      final backend = _clientBackend();
      final client = _client(backend);
      addTearDown(client.dispose);
      final sent = <SkotiqEvent>[];
      client.read(hostMutationEventHubProvider).wsBroadcast = sent.add;
      client.read(hostRuntimeMirrorProvider);

      client.read(plateSolveStateProvider.notifier).state = PlateSolveState(
        lastResult: _solve(),
      );

      expect(sent, isEmpty);
    });
  });

  group('client applies', () {
    test('an older revision than the one applied is dropped', () async {
      final backend = _clientBackend();
      final client = _client(backend);
      addTearDown(client.dispose);

      HostRuntimeUpdate update(int revision, double ra) => HostRuntimeUpdate(
        channel: 'plateSolve',
        revision: revision,
        value: const PlateSolveChannel().encode(
          PlateSolveState(lastResult: _solve(ra: ra)),
        ),
      );

      applyHostRuntimeUpdate(client, update(20, 10), networkBackend: backend);
      applyHostRuntimeUpdate(client, update(10, 99), networkBackend: backend);

      expect(client.read(plateSolveStateProvider).lastResult?.ra, 10);
    });

    test('a value this client reported is not applied again', () {
      final backend = _clientBackend();
      final client = _client(backend);
      addTearDown(client.dispose);

      applyHostRuntimeUpdate(
        client,
        HostRuntimeUpdate(
          channel: 'centeringResult',
          revision: 1,
          origin: runtimeMirrorOrigin,
          value: const {
            'success': true,
            'iterations': 2,
            'finalOffsetArcsec': 8.0,
          },
        ),
        networkBackend: backend,
      );

      expect(client.read(lastCenteringResultProvider), isNull);
    });

    test('the same solve outcome keeps the result object already held', () {
      final backend = _clientBackend();
      final client = _client(backend);
      addTearDown(client.dispose);
      final own = _solve();
      client.read(plateSolveStateProvider.notifier).state = PlateSolveState(
        lastResult: own,
      );

      applyHostRuntimeUpdate(
        client,
        HostRuntimeUpdate(
          channel: 'plateSolve',
          revision: 5,
          value: const PlateSolveChannel().encode(
            PlateSolveState(lastResult: _solve()),
          ),
        ),
        networkBackend: backend,
      );

      expect(
        identical(client.read(plateSolveStateProvider).lastResult, own),
        isTrue,
      );
    });

    test('hydration fills every channel from the host', () async {
      final backend = _clientBackend();
      when(() => backend.getHostRuntimeState()).thenAnswer(
        (_) async => [
          HostRuntimeUpdate(
            channel: 'centeringStatus',
            revision: 3,
            value: const CenteringStatusChannel().encode(
              const CenteringStatus(
                state: CenteringState.slewing,
                currentIteration: 2,
                maxIterations: 5,
                currentOffsetArcsec: 95.5,
                iterationHistory: [],
              ),
            ),
          ),
        ],
      );
      final client = _client(backend);
      addTearDown(client.dispose);

      await hydrateHostRuntimeState(client, backend);

      final status = client.read(centeringStatusProvider);
      expect(status.state, CenteringState.slewing);
      expect(status.currentIteration, 2);
      expect(status.currentOffsetArcsec, 95.5);
    });

    test('a new frame on the host fetches it; the frame already shown does '
        'not', () async {
      final backend = _clientBackend();
      when(
        () => backend.cameraGetLastImage(any()),
      ).thenAnswer((_) async => null);
      final client = _client(backend);
      addTearDown(client.dispose);
      client.read(cameraStateProvider.notifier)
        ..setConnecting('sim_camera_1', 'Simulated Camera')
        ..setConnected();

      applyHostRuntimeUpdate(
        client,
        const HostRuntimeUpdate(
          channel: 'currentFrame',
          revision: 1,
          value: {
            'capturedAt': 1000,
            'width': 100,
            'height': 80,
            'filePath': r'C:\data\L_001.fits',
          },
        ),
        networkBackend: backend,
      );
      await pumpEventQueue();

      verify(() => backend.cameraGetLastImage('sim_camera_1')).called(1);
    });
  });

  group('client reports', () {
    test('a centering result computed here is sent to the host', () async {
      final backend = _clientBackend();
      when(
        () => backend.reportRuntimeState(
          channel: any(named: 'channel'),
          value: any(named: 'value'),
          origin: any(named: 'origin'),
        ),
      ).thenAnswer((_) async {});
      final client = _client(backend);
      addTearDown(client.dispose);
      client.read(clientRuntimeReporterProvider);

      client
          .read(lastCenteringResultProvider.notifier)
          .state = CenteringResult.success(
        finalOffsetArcsec: 12.0,
        iterations: 3,
        iterationHistory: const [],
      );
      await pumpEventQueue();

      final captured = verify(
        () => backend.reportRuntimeState(
          channel: 'centeringResult',
          value: captureAny(named: 'value'),
          origin: runtimeMirrorOrigin,
        ),
      ).captured;
      expect((captured.single as Map)['finalOffsetArcsec'], 12.0);
    });

    test('a value that came from the host is not reported back', () async {
      final backend = _clientBackend();
      when(
        () => backend.reportRuntimeState(
          channel: any(named: 'channel'),
          value: any(named: 'value'),
          origin: any(named: 'origin'),
        ),
      ).thenAnswer((_) async {});
      final client = _client(backend);
      addTearDown(client.dispose);
      client.read(clientRuntimeReporterProvider);

      applyHostRuntimeUpdate(
        client,
        const HostRuntimeUpdate(
          channel: 'centeringResult',
          revision: 1,
          value: {'success': true, 'iterations': 1, 'finalOffsetArcsec': 4.0},
        ),
        networkBackend: backend,
      );
      await pumpEventQueue();

      expect(client.read(lastCenteringResultProvider)?.finalOffsetArcsec, 4.0);
      verifyNever(
        () => backend.reportRuntimeState(
          channel: any(named: 'channel'),
          value: any(named: 'value'),
          origin: any(named: 'origin'),
        ),
      );
    });

    test('the host applies a report and rebroadcasts it under its origin', () {
      final host = _host();
      addTearDown(host.container.dispose);

      final applied = applyClientRuntimeReport(
        host.container,
        channel: 'autofocusResult',
        value: const {
          'bestPosition': 2506,
          'bestHfr': 2.1,
          'focusData': [],
          'method': 'Hyperbolic',
          'timestamp': 5,
          'curveFitQuality': 0.95,
          'backlashApplied': false,
        },
        origin: 'client-a',
      );

      expect(applied, isTrue);
      expect(host.container.read(autofocusResultProvider)?.bestPosition, 2506);
      final update = _updates(host.sent, 'autofocusResult').last;
      expect(update.origin, 'client-a');
    });

    test('the host refuses reports for a host-only channel', () {
      final host = _host();
      addTearDown(host.container.dispose);

      final applied = applyClientRuntimeReport(
        host.container,
        channel: 'plateSolve',
        value: const {'isSolving': true},
        origin: 'client-a',
      );

      expect(applied, isFalse);
      expect(host.container.read(plateSolveStateProvider).isSolving, isFalse);
    });
  });

  test('runtime envelopes stay out of the typed event stream', () {
    expect(
      isHostSyncEnvelope(
        const HostRuntimeUpdate(channel: 'plateSolve', revision: 1).toEvent(),
      ),
      isTrue,
    );
  });

  group('channels', () {
    /// Host value -> JSON -> client provider.
    Future<ProviderContainer> roundTrip(
      void Function(ProviderContainer host) produce,
      String channel, {
      void Function(ProviderContainer client)? prepareClient,
    }) async {
      final host = _host();
      addTearDown(host.container.dispose);
      produce(host.container);
      // Throttled channels publish the newest value when their gap ends.
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      final backend = _clientBackend();
      when(
        () => backend.cameraGetLastImage(any()),
      ).thenAnswer((_) async => null);
      final client = _client(backend);
      addTearDown(client.dispose);
      prepareClient?.call(client);
      for (final update in _updates(host.sent, channel)) {
        await applyRemoteSyncEvent(
          client,
          _overWire(update.toEvent()),
          networkBackend: backend,
        );
      }
      return client;
    }

    test(
      'weather readings land on the client card of the same device',
      () async {
        final client = await roundTrip(
          (host) {
            final notifier = host.read(weatherStateProvider.notifier);
            notifier
              ..setConnecting('sim_weather_1')
              ..setConnected()
              ..updateConditions(cloudCover: 5, humidity: 45, temperature: 10);
          },
          'environment',
          prepareClient: (client) {
            final notifier = client.read(weatherStateProvider.notifier);
            notifier
              ..setConnecting('sim_weather_1')
              ..setConnected();
          },
        );
        final weather = client.read(weatherStateProvider);
        expect(weather.cloudCover, 5);
        expect(weather.humidity, 45);
        expect(weather.temperature, 10);
      },
    );

    test('a reading for another device is not applied', () async {
      final client = await roundTrip(
        (host) {
          final notifier = host.read(weatherStateProvider.notifier);
          notifier
            ..setConnecting('sim_weather_1')
            ..setConnected()
            ..updateConditions(cloudCover: 5);
        },
        'environment',
        prepareClient: (client) {
          final notifier = client.read(weatherStateProvider.notifier);
          notifier
            ..setConnecting('other_station')
            ..setConnected();
        },
      );
      expect(client.read(weatherStateProvider).cloudCover, isNull);
    });

    test('each host cooler reading is added once with the host time', () async {
      final at = DateTime.utc(2026, 10, 21, 22, 1);
      final client = await roundTrip(
        (host) => host
            .read(temperatureHistoryProvider.notifier)
            .addPoint(-9.5, targetTemp: -10, coolerPower: 40, at: at),
        'coolerReading',
      );
      final history = client.read(temperatureHistoryProvider);
      expect(history, hasLength(1));
      expect(history.single.temperature, -9.5);
      expect(history.single.coolerPower, 40);
      expect(history.single.time.toUtc(), at);
    });

    test('a client watching the host run gets its step statuses and session '
        'counters', () async {
      final client = await roundTrip((host) {
        host.read(sequenceProgressProvider.notifier)
          ..updateNodeStatus('unpark', NodeStatus.success)
          ..updateNodeStatus('exp-l', NodeStatus.running)
          ..updateNodeProgress('exp-l', 50, 'Frame 1 of 2');
        host
            .read(sessionStateProvider.notifier)
            .mirrorHostSession(
              const SessionState(
                isActive: true,
                completedExposures: 4,
                dbSessionId: 12,
              ),
            );
      }, 'sequenceRun');

      final progress = client.read(sequenceProgressProvider);
      expect(progress.nodeStatuses['unpark'], NodeStatus.success);
      expect(progress.nodeStatuses['exp-l'], NodeStatus.running);
      expect(progress.nodeProgressDetail['exp-l'], 'Frame 1 of 2');
      final session = client.read(sessionStateProvider);
      expect(session.completedExposures, 4);
      expect(session.dbSessionId, 12);
    });

    test('a client that started the run keeps its own step statuses', () async {
      final client = await roundTrip(
        (host) => host
            .read(sequenceProgressProvider.notifier)
            .updateNodeStatus('unpark', NodeStatus.failure),
        'sequenceRun',
        prepareClient: (client) {
          client.read(currentRunIdProvider.notifier).state = 7;
          client
              .read(sequenceProgressProvider.notifier)
              .updateNodeStatus('unpark', NodeStatus.success);
        },
      );
      expect(
        client.read(sequenceProgressProvider).nodeStatuses['unpark'],
        NodeStatus.success,
      );
    });

    test('a flip on the host shows on the client', () async {
      final client = await roundTrip((host) {
        host.read(flipExecutionStateProvider.notifier).state =
            FlipExecutionState.executing;
        host.read(flipCurrentStepProvider.notifier).state =
            FlipStep.slewingToTarget;
        host.read(flipProgressProvider.notifier).state = 40;
      }, 'meridianFlip');
      expect(
        client.read(flipExecutionStateProvider),
        FlipExecutionState.executing,
      );
      expect(client.read(flipCurrentStepProvider), FlipStep.slewingToTarget);
      expect(client.read(flipProgressProvider), 40);
    });

    test('an autofocus run that ended in the other window ends here', () async {
      const result = AutofocusResult(
        bestPosition: 25070,
        bestHfr: 2.11,
        focusData: [],
        method: 'Hyperbolic',
        timestamp: 1,
        curveFitQuality: 0.95,
        backlashApplied: false,
      );
      final client = await roundTrip(
        (host) {
          final notifier = host.read(autofocusOverlayProvider.notifier);
          notifier
            ..onAutofocusStarted()
            ..onAutofocusCompleted(result);
        },
        'autofocusRun',
        prepareClient: (client) =>
            client.read(autofocusOverlayProvider.notifier).onAutofocusStarted(),
      );
      final overlay = client.read(autofocusOverlayProvider);
      expect(overlay.isRunning, isFalse);
      expect(overlay.result?.bestPosition, 25070);
    });

    test('a frame saved on the host after it was shown takes its path '
        'without a second download', () async {
      final shownAt = DateTime.utc(2026, 10, 21, 22, 2);
      final backend = _clientBackend();
      final client = _client(backend);
      addTearDown(client.dispose);
      client.read(currentImageProvider.notifier).state = CapturedImageData(
        width: 10,
        height: 8,
        displayData: Uint8List(320),
        histogram: const [],
        stats: const ImageStats(min: 0, max: 0, mean: 0, median: 0, stdDev: 0),
        capturedAt: shownAt,
        settings: const ExposureSettings(
          exposureTime: 5,
          gain: 100,
          offset: 50,
          binningX: 1,
          binningY: 1,
          frameType: FrameType.light,
        ),
      );

      applyHostRuntimeUpdate(
        client,
        HostRuntimeUpdate(
          channel: 'currentFrame',
          revision: 1,
          value: {
            'capturedAt': shownAt.millisecondsSinceEpoch,
            'width': 10,
            'height': 8,
            'filePath': r'C:\data\L_001.fits',
          },
        ),
        networkBackend: backend,
      );
      await pumpEventQueue();

      expect(
        client.read(currentImageProvider)?.filePath,
        r'C:\data\L_001.fits',
      );
      verifyNever(() => backend.cameraGetLastImage(any()));
    });
  });

  test('a client connecting mid-night opens on the host event log', () async {
    final backend = _clientBackend();
    when(() => backend.getHostRecentEvents()).thenAnswer(
      (_) async => const [
        SkotiqEvent(
          timestamp: 1000,
          severity: EventSeverity.info,
          category: EventCategory.sequencer,
          eventType: 'Started',
          data: {'sequence_name': 'Parity run'},
        ),
        SkotiqEvent(
          timestamp: 2000,
          severity: EventSeverity.info,
          category: EventCategory.sequencer,
          eventType: 'TriggerFired',
          data: {
            'trigger_id': 't1',
            'trigger_name': 'Meridian Flip',
            'action': 'flip',
          },
        ),
      ],
    );
    final client = _client(backend);
    addTearDown(client.dispose);

    await seedEventLogFromHost(client, backend);
    await seedEventLogFromHost(client, backend);

    final history = client.read(eventHistoryProvider);
    expect(history, hasLength(2));
    // Newest first, as live events are kept.
    expect(history.first.timestamp.toInt(), 2000);
    verify(() => backend.getHostRecentEvents()).called(1);
  });

  test('a frame the host announced is not solved again here; the host '
      'solve is adopted', () async {
    final backend = _clientBackend();
    var solves = 0;
    final client = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        backgroundFrameSolverProvider.overrideWithValue(({
          required String imagePath,
          required bool Function() isCurrent,
          double? hintRaHours,
          double? hintDecDegrees,
        }) async {
          solves++;
          return null;
        }),
      ],
    );
    addTearDown(client.dispose);
    client.read(frameAutoSolveProvider);
    final at = DateTime.utc(2026, 10, 21, 22, 49);
    const path = '/data/Zenith_R_0008.fits';
    client.read(hostFrameSolvesProvider).mirroredFrame = at;
    client.read(currentImageProvider.notifier).state = CapturedImageData(
      width: 10,
      height: 8,
      displayData: Uint8List(320),
      histogram: const [],
      stats: const ImageStats(min: 0, max: 0, mean: 0, median: 0, stdDev: 0),
      capturedAt: at,
      settings: const ExposureSettings(
        exposureTime: 2,
        gain: 100,
        offset: 50,
        binningX: 1,
        binningY: 1,
        frameType: FrameType.light,
      ),
      filePath: path,
    );
    await pumpEventQueue();
    expect(
      client.read(currentFrameSolveProvider)?.status,
      FrameSolveStatus.waiting,
    );

    applyHostRuntimeUpdate(
      client,
      const HostRuntimeUpdate(
        channel: 'frameSolve',
        revision: 1,
        value: {
          'path': path,
          'status': 'solved',
          'ra': 339.0,
          'dec': 40.0,
          'rotation': 0.0,
          'scale': 1.5,
        },
      ),
      networkBackend: backend,
    );

    final solve = client.read(currentFrameSolveProvider);
    expect(solve?.status, FrameSolveStatus.solved);
    expect(solve?.raDegrees, 339.0);
    expect(solves, 0);
  });

  test('a frame followed from the host is shown without its raw pixels', () {
    final backend = _clientBackend();
    final client = _client(backend);
    addTearDown(client.dispose);

    client
        .read(capturePreviewPublisherProvider)
        .publish(
          client,
          CapturedImageData(
            width: 10,
            height: 8,
            displayData: Uint8List(320),
            histogram: const [],
            stats: const ImageStats(
              min: 0,
              max: 0,
              mean: 0,
              median: 0,
              stdDev: 0,
            ),
            capturedAt: DateTime.utc(2026, 10, 21, 22, 50),
            settings: const ExposureSettings(
              exposureTime: 2,
              gain: 100,
              offset: 50,
              binningX: 1,
              binningY: 1,
              frameType: FrameType.light,
            ),
          ),
          'sim_camera_1',
          loadRaw: false,
        );

    expect(
      client.read(currentImageProvider)?.rawLoadStatus,
      RawLoadStatus.idle,
    );
    verifyNever(() => backend.getLastRawImageData(any()));
  });

  test('each end of the link learns which action the other is running', () {
    final host = _host();
    addTearDown(host.container.dispose);
    host.container.read(localManualActionProvider.notifier).state = 'autofocus';
    final backend = _clientBackend();
    final client = _client(backend);
    addTearDown(client.dispose);
    for (final update in _updates(host.sent, 'manualAction')) {
      applyHostRuntimeUpdate(client, update, networkBackend: backend);
    }
    expect(client.read(linkedManualActionProvider)?.action, 'autofocus');

    applyClientRuntimeReport(
      host.container,
      channel: 'manualAction',
      value: const {'action': 'center'},
      origin: 'linux-client',
    );
    expect(host.container.read(linkedManualActionProvider)?.action, 'center');
    // The host's own action is unchanged by the report.
    expect(host.container.read(localManualActionProvider), 'autofocus');
  });

  test('an update missing a field is dropped, not shown with a made-up '
      'number', () {
    final backend = _clientBackend();
    final client = _client(backend);
    addTearDown(client.dispose);
    final own = _solve();
    client.read(plateSolveStateProvider.notifier).state = PlateSolveState(
      lastResult: own,
    );

    applyHostRuntimeUpdate(
      client,
      const HostRuntimeUpdate(
        channel: 'plateSolve',
        revision: 9,
        value: {
          'isSolving': false,
          'result': {'success': true, 'dec': 41.2},
        },
      ),
      networkBackend: backend,
    );

    expect(
      identical(client.read(plateSolveStateProvider).lastResult, own),
      isTrue,
    );
  });

  test('a client that goes idle tells the host, even when the host was idle '
      'too', () async {
    final backend = _clientBackend();
    when(
      () => backend.reportRuntimeState(
        channel: any(named: 'channel'),
        value: any(named: 'value'),
        origin: any(named: 'origin'),
      ),
    ).thenAnswer((_) async {});
    final client = _client(backend);
    addTearDown(client.dispose);
    client.read(clientRuntimeReporterProvider);
    applyHostRuntimeUpdate(
      client,
      const HostRuntimeUpdate(channel: 'manualAction', revision: 1),
      networkBackend: backend,
    );

    client.read(localManualActionProvider.notifier).state = 'autofocus';
    await pumpEventQueue();
    client.read(localManualActionProvider.notifier).state = null;
    await pumpEventQueue();

    final sent = verify(
      () => backend.reportRuntimeState(
        channel: 'manualAction',
        value: captureAny(named: 'value'),
        origin: any(named: 'origin'),
      ),
    ).captured;
    expect(sent, [
      {'action': 'autofocus'},
      null,
    ]);
  });
}
